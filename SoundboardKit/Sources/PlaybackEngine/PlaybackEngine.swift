import AVFoundation
import Foundation
import GovernanceKit
import QuartzCore

/// What a trigger produced, handed straight back to the caller so the tile can
/// start animating against the same clock the sound will start on.
public struct TriggerResult: Sendable {
    public let soundID: SoundID
    public let voiceIndex: Int
    /// When the first sample reaches the output, including hardware latency,
    /// on the **host clock**, directly comparable to `CACurrentMediaTime()`.
    ///
    /// The visual layer schedules its first frame against this rather than
    /// against the touch event, which is what keeps picture and sound together.
    /// The host clock is what makes that possible: the render clock counts
    /// samples since the engine started, so a frame deadline computed from it
    /// would be an offset into an unrelated timeline.
    public let expectedStart: TimeInterval
    public let stoleVoice: SoundID?
}

public enum PlaybackError: Error, Equatable {
    case notPrepared
    case notLoaded(SoundID)
    case engineFailed
    /// The offline renderer stopped early. Carries the raw
    /// `AVAudioEngineManualRenderingStatus`.
    case renderIncomplete(Int)
}

/// Rendering target. Offline exists so the engine is verifiable with no audio
/// hardware present, which is also how it runs in CI.
public enum RenderMode: Equatable {
    case realtime
    case offline(maximumFrameCount: AVAudioFrameCount)
}

/// The audio half of a tile press.
///
/// The three decisions that set the feel of this app, per BACKEND_PLAN.md
/// Section 5:
///
/// 1. The engine is started once and never stopped between taps. Starting an
///    engine costs 100 ms or more, which is three times the entire latency
///    budget.
/// 2. Buffers for the visible board are preloaded, so a trigger is a dictionary
///    lookup plus `scheduleBuffer`, with no file I/O on the path.
/// 3. Fire on touch-down. Gesture recognition delay is audible here.
/// Safe to hand across threads: every mutable field is guarded by `lock`, and
/// the warm-up path deliberately calls `prepare()` off the main thread.
public final class PlaybackEngine: @unchecked Sendable {
    public let cache: BufferCache

    private let engine = AVAudioEngine()
    private let mixer = AVAudioMixerNode()
    private let pool: VoicePool
    private let session: AudioSessionControlling
    private let renderMode: RenderMode
    private var prepared = false
    private let lock = NSLock()

    public private(set) var triggerCount = 0
    public private(set) var droppedTriggers = 0

    /// What each voice is holding a cache pin for.
    ///
    /// A pin cannot be released from the completion handler alone. A handler
    /// fires when a buffer finishes, but a voice is also ended by a steal, an
    /// interruption, a `stopAll`, or a graph rebuild, and a pin left behind by
    /// any of those makes its buffer permanently unevictable. Enough of them
    /// and the memory ceiling stops being a ceiling. So the pin is owned here,
    /// keyed by voice, and every path that ends a voice goes through
    /// `releasePin`.
    private var pinnedByVoice: [Int: (soundID: SoundID, generation: UInt64)] = [:]
    private let pinLock = NSLock()

    public init(
        cache: BufferCache = BufferCache(),
        voiceCount: Int = 8,
        session: AudioSessionControlling = NullAudioSession(),
        renderMode: RenderMode = .realtime
    ) {
        self.cache = cache
        self.pool = VoicePool(capacity: voiceCount)
        self.session = session
        self.renderMode = renderMode
    }

    // MARK: - Lifecycle

    /// Builds the graph and starts the engine. Called once, at launch, before
    /// the first board is even on screen.
    public func prepare() throws {
        lock.lock()
        defer { lock.unlock() }
        guard !prepared else { return }
        try session.activate()
        try buildGraphLocked()
        prepared = true
    }

    private func buildGraphLocked() throws {
        engine.attach(mixer)
        engine.connect(mixer, to: engine.mainMixerNode, format: BufferCache.format)

        for node in pool.makeNodes() {
            engine.attach(node)
            engine.connect(node, to: mixer, format: BufferCache.format)
        }

        if case let .offline(maximumFrameCount) = renderMode {
            try engine.enableManualRenderingMode(
                .offline,
                format: BufferCache.format,
                maximumFrameCount: maximumFrameCount
            )
        }

        engine.prepare()
        do {
            try engine.start()
        } catch {
            throw PlaybackError.engineFailed
        }
        // Player nodes are started once, with nothing scheduled. A started node
        // with an empty queue is silent and costs nothing, and starting it here
        // keeps `play()` off the trigger path entirely.
        for voice in pool.voices { voice.node.play() }
    }

    private func teardownGraphLocked() {
        for voice in pool.voices {
            voice.node.stop()
            releasePin(index: voice.index, generation: nil)
            engine.detach(voice.node)
        }
        engine.stop()
        engine.detach(mixer)
    }

    // MARK: - Preloading

    /// Admits a clip to the buffer cache. Off the trigger path by design: this
    /// touches the file system, and the trigger path must not.
    public func preload(_ id: SoundID, from url: URL) throws {
        try cache.load(id, from: url)
    }

    /// Preloads a page of tiles. The caller drives this from the scroll
    /// position: the visible page plus one either side, per Section 6.
    public func preloadPage(_ items: [(id: SoundID, url: URL)]) -> [SoundID: ImportFailureCode] {
        var failures: [SoundID: ImportFailureCode] = [:]
        for item in items {
            do {
                try preload(item.id, from: item.url)
            } catch let code as ImportFailureCode {
                failures[item.id] = code
            } catch {
                failures[item.id] = .decodeFailed
            }
        }
        return failures
    }

    // MARK: - Triggering

    /// Fires a tile. Call this from touch-down.
    ///
    /// Everything expensive has already happened by the time this runs: the
    /// engine is running, the nodes are attached and playing, and the buffer is
    /// resident. What remains is a lookup, a voice pick, and a schedule call.
    @discardableResult
    public func trigger(_ id: SoundID, policy: RetriggerPolicy = .overlap) throws -> TriggerResult {
        guard prepared else { throw PlaybackError.notPrepared }
        guard let buffer = cache.buffer(for: id) else {
            droppedTriggers += 1
            throw PlaybackError.notLoaded(id)
        }

        let (voice, stolen) = pool.acquire(for: id, policy: policy)
        let index = voice.index
        let generation = voice.generation

        // `.interrupts` replaces whatever this node had queued, in the same
        // call that queues the new buffer.
        //
        // Stopping the node first and then scheduling looks equivalent and is
        // not: `stop()` is asynchronous, and a schedule that lands while it is
        // still in flight gets flushed along with the queue it was clearing.
        // The tile then plays nothing at all, intermittently, which is the
        // worst possible failure for a soundboard. Never stop a node on the
        // trigger path.
        let replacing = policy == .restart || stolen != nil
        // Whatever this voice was holding is released either way, since the new
        // buffer replaces it.
        releasePin(index: index, generation: nil)

        cache.pin(id)
        pinLock.lock()
        pinnedByVoice[index] = (id, generation)
        pinLock.unlock()
        // .dataPlayedBack, not .dataConsumed: the voice is free when the sound
        // has actually left the speaker, not when the buffer was handed to the
        // renderer. Releasing early lets a steal cut audible sound.
        voice.node.scheduleBuffer(
            buffer,
            at: nil,
            options: replacing ? .interrupts : [],
            completionCallbackType: .dataPlayedBack
        ) { [weak self] _ in
            guard let self else { return }
            self.releasePin(index: index, generation: generation)
            self.pool.release(index: index, generation: generation)
        }
        // Nodes are started once at graph build, so this is a no-op on the hot
        // path. It matters only after a stop, where scheduling first and
        // playing second is the ordering that cannot race.
        if !voice.node.isPlaying { voice.node.play() }

        triggerCount += 1
        return TriggerResult(
            soundID: id,
            voiceIndex: index,
            expectedStart: expectedStartTime(for: voice.node),
            stoleVoice: stolen
        )
    }

    /// The moment the first sample is audible, on the host clock.
    ///
    /// Sample time is the tempting value here and it is the wrong one. It
    /// counts samples since the engine started, so it shares no origin with
    /// `CACurrentMediaTime()`, which is the clock every frame deadline is
    /// measured on. Handing the visual layer a sample-clock value produces a
    /// number that looks like a timestamp, compares cleanly, and puts the
    /// picture an arbitrary interval away from the sound.
    private func expectedStartTime(for node: AVAudioPlayerNode) -> TimeInterval {
        guard let renderTime = node.lastRenderTime, renderTime.isHostTimeValid else {
            // Offline rendering, and any node that has not rendered yet, have
            // no host time. Now plus output latency is the honest answer.
            return CACurrentMediaTime() + session.outputLatency
        }
        return AVAudioTime.seconds(forHostTime: renderTime.hostTime) + session.outputLatency
    }

    /// Stops everything immediately. Used when the board is dismissed.
    ///
    /// Stopping does not free memory. The two were one call at first, which
    /// meant dismissing a board silently dropped every preloaded buffer and the
    /// next board paid a full reload. Freeing is the caller's decision, and the
    /// two reasons to make it, dismissal and memory pressure, want different
    /// answers.
    public func stopAll() {
        for voice in pool.voices {
            voice.node.stop()
            releasePin(index: voice.index, generation: nil)
            pool.markIdle(index: voice.index)
        }
    }

    /// Releases the cache pin a voice holds.
    ///
    /// - Parameter generation: pass the acquisition's generation from a
    ///   completion handler, so a handler arriving after the voice was
    ///   reassigned cannot unpin the sound that took its place. Pass nil from
    ///   paths that are ending the voice right now.
    private func releasePin(index: Int, generation: UInt64?) {
        pinLock.lock()
        guard let held = pinnedByVoice[index],
              generation == nil || held.generation == generation else {
            pinLock.unlock()
            return
        }
        pinnedByVoice.removeValue(forKey: index)
        pinLock.unlock()
        cache.unpin(held.soundID)
    }

    /// Frees every buffer that is not currently audible. The memory pressure
    /// path: the grid falls back to posters and re-primes lazily.
    public func releaseIdleBuffers() {
        cache.evictUnpinned()
    }

    /// Frees buffers outside the prefetch horizon. Audible tiles are kept.
    public func releaseBuffers(except keep: Set<SoundID>) {
        cache.evict(except: keep)
    }

    public var activeVoiceCount: Int { pool.activeCount }

    // MARK: - Interruptions

    /// A call arrives, or another app takes the session. The engine is stopped
    /// but the graph is kept, so resuming is cheap.
    public func handleInterruptionBegan() {
        for voice in pool.voices {
            voice.node.stop()
            releasePin(index: voice.index, generation: nil)
            pool.markIdle(index: voice.index)
        }
        engine.pause()
    }

    public func handleInterruptionEnded(shouldResume: Bool) throws {
        guard shouldResume else { return }
        try session.activate()
        do {
            try engine.start()
        } catch {
            throw PlaybackError.engineFailed
        }
    }

    /// Headphones in or out. The engine survives this on its own; the nodes
    /// need restarting because a route change stops them.
    public func handleRouteChange() throws {
        guard prepared else { return }
        if !engine.isRunning {
            do {
                try engine.start()
            } catch {
                throw PlaybackError.engineFailed
            }
        }
        // Nodes are left alone. The next trigger starts whichever one it needs,
        // after its buffer is queued.
    }

    /// Media services died. The whole graph is invalid, including the nodes, so
    /// it is rebuilt from nothing. Cached buffers survive: they are plain memory
    /// and re-decoding 48 clips here would be a visible stall.
    public func handleMediaServicesReset() throws {
        lock.lock()
        defer { lock.unlock() }
        teardownGraphLocked()
        prepared = false
        try session.activate()
        try buildGraphLocked()
        prepared = true
    }

    // MARK: - Offline rendering

    /// Renders `frameCount` frames in manual rendering mode. Checks only.
    public func renderOffline(frameCount: AVAudioFrameCount) throws -> AVAudioPCMBuffer {
        guard case .offline = renderMode else { throw PlaybackError.engineFailed }
        guard let output = AVAudioPCMBuffer(
            pcmFormat: engine.manualRenderingFormat,
            frameCapacity: frameCount
        ) else { throw PlaybackError.engineFailed }

        var remaining = frameCount
        while remaining > 0 {
            let chunk = min(remaining, engine.manualRenderingMaximumFrameCount)
            guard let slice = AVAudioPCMBuffer(
                pcmFormat: engine.manualRenderingFormat,
                frameCapacity: chunk
            ) else { throw PlaybackError.engineFailed }
            let status = try engine.renderOffline(chunk, to: slice)
            // A render that did not run and a render that produced silence are
            // completely different diagnoses. Returning a short buffer here
            // conflated them and sent the last investigation the wrong way.
            guard status == .success else {
                throw PlaybackError.renderIncomplete(status.rawValue)
            }
            output.append(slice)
            remaining -= chunk
        }
        return output
    }
}

extension AVAudioPCMBuffer {
    /// Appends `other` in place. Offline rendering produces the output in
    /// chunks bounded by the maximum frame count, and the checks want one buffer.
    func append(_ other: AVAudioPCMBuffer) {
        guard format == other.format,
              let destination = floatChannelData,
              let source = other.floatChannelData else { return }
        let copyable = min(other.frameLength, frameCapacity - frameLength)
        guard copyable > 0 else { return }
        for channel in 0..<Int(format.channelCount) {
            memcpy(
                destination[channel] + Int(frameLength),
                source[channel],
                Int(copyable) * MemoryLayout<Float>.size
            )
        }
        frameLength += copyable
    }
}
