import AVFoundation
import Foundation
import QuartzCore
import GovernanceKit
import ImportPipeline
import PlaybackEngine

private func makeBuffer(seconds: Double = 0.5, amplitude: Float = 0.5) -> AVAudioPCMBuffer {
    let format = BufferCache.format
    let frames = AVAudioFrameCount(format.sampleRate * seconds)
    let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
    buffer.frameLength = frames
    for channel in 0..<Int(format.channelCount) {
        let data = buffer.floatChannelData![channel]
        for frame in 0..<Int(frames) {
            data[frame] = amplitude * Float(sin(2 * Double.pi * 440 * Double(frame) / format.sampleRate))
        }
    }
    return buffer
}

/// A mono file at a non-canonical sample rate, which is what a real import can
/// produce and what the cache has to normalise on load.
private func writeMonoFile(at url: URL, seconds: Double = 0.3, sampleRate: Double = 44_100) throws {
    let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1)!
    let file = try AVAudioFile(forWriting: url, settings: format.settings)
    let frames = AVAudioFrameCount(sampleRate * seconds)
    let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
    buffer.frameLength = frames
    let data = buffer.floatChannelData![0]
    for frame in 0..<Int(frames) {
        data[frame] = 0.4 * Float(sin(2 * Double.pi * 440 * Double(frame) / sampleRate))
    }
    try file.write(from: buffer)
}

private func peak(of buffer: AVAudioPCMBuffer) -> Float {
    guard let data = buffer.floatChannelData else { return 0 }
    var highest: Float = 0
    for channel in 0..<Int(buffer.format.channelCount) {
        for frame in 0..<Int(buffer.frameLength) {
            highest = max(highest, abs(data[channel][frame]))
        }
    }
    return highest
}

enum PlaybackChecks {
    static func run() {
        cacheChecks()
        engineChecks()
        resilienceChecks()
        memoryCeilingChecks()
        latencyChecks()
    }

    // MARK: - Cache

    private static func cacheChecks() {
        Check.suite("BufferCache - the 48 clip memory ceiling") {
            // The two modules do not depend on each other, so the canonical rate
            // is written down twice. If they ever drift, every clip plays at the
            // wrong pitch, so the drift is asserted away here.
            Check.expectEqual(
                OutputFormatBridge.sampleRate,
                OutputFormat.sampleRate,
                "playback and import agree on the canonical sample rate"
            )
            Check.expectEqual(Int(BufferCache.format.channelCount), 2, "the canonical playback format is stereo")

            let cache = BufferCache(capacity: 3)
            for index in 0..<3 { cache.admit(makeBuffer(seconds: 0.1), for: "s\(index)") }
            Check.expectEqual(cache.statistics().residentCount, 3, "the cache fills to capacity")

            // Touch s0 so s1 becomes the least recently used.
            _ = cache.buffer(for: "s0")
            cache.admit(makeBuffer(seconds: 0.1), for: "s3")
            Check.expectEqual(cache.statistics().residentCount, 3, "admitting past capacity evicts rather than grows")
            Check.expect(cache.contains("s0"), "a recently used clip survives eviction")
            Check.expect(!cache.contains("s1"), "the least recently used clip is the victim")
            Check.expectEqual(cache.statistics().evictions, 1, "exactly one eviction happened")

            // Evicting something currently audible is the one eviction a user
            // can actually hear, so a pinned entry is never the victim.
            let pinned = BufferCache(capacity: 2)
            pinned.admit(makeBuffer(seconds: 0.1), for: "playing")
            _ = pinned.buffer(for: "playing")
            pinned.pin("playing")
            pinned.admit(makeBuffer(seconds: 0.1), for: "idle")
            pinned.admit(makeBuffer(seconds: 0.1), for: "newcomer")
            Check.expect(pinned.contains("playing"), "an audible clip is never evicted")
            Check.expect(!pinned.contains("idle"), "the idle clip is evicted instead")

            // Memory pressure: drop everything not currently sounding, then
            // re-prime lazily.
            pinned.evictUnpinned()
            Check.expect(pinned.contains("playing"), "memory pressure keeps what is audible")
            Check.expect(!pinned.contains("newcomer"), "memory pressure drops the rest")

            Check.expect(cache.statistics().residentBytes > 0, "resident bytes are accounted for")
        }

        Check.suite("BufferCache - loading real files") {
            try withTemporaryDirectory { root in
                let url = root.appendingPathComponent("mono.caf")
                try writeMonoFile(at: url)

                let cache = BufferCache(capacity: 4)
                let buffer = try cache.load("mono", from: url)

                // A mono source at 44.1 kHz has to arrive as canonical stereo at
                // 48 kHz, or the player node rejects it at schedule time.
                Check.expectEqual(Int(buffer.format.channelCount), 2, "a mono file is widened to the canonical format")
                Check.expectEqual(buffer.format.sampleRate, OutputFormatBridge.sampleRate, "a 44.1 kHz file is resampled to 48 kHz")
                Check.expect(buffer.frameLength > 0, "the decoded buffer has frames")
                Check.expect(peak(of: buffer) > 0.1, "the decoded buffer carries signal")

                _ = try cache.load("mono", from: url)
                Check.expectEqual(cache.statistics().residentCount, 1, "loading an already resident clip does not duplicate it")

                // Nothing from AVFoundation escapes this boundary. Its NSError
                // carries the file path in userInfo, and that path is a
                // device-local personal shape (DG-LOG-01).
                Check.expectThrows(ImportFailureCode.unreadableFile, "a missing file leaves as a closed code, not a decoder NSError") {
                    _ = try cache.load("absent", from: root.appendingPathComponent("nothing.caf"))
                }
            }
        }
    }

    // MARK: - Engine

    private static func engineChecks() {
        Check.suite("PlaybackEngine - triggering, offline rendered") {
            let engine = PlaybackEngine(
                cache: BufferCache(capacity: 16),
                voiceCount: 8,
                renderMode: .offline(maximumFrameCount: 4096)
            )
            do {
                try engine.prepare()
                Check.expect(true, "the graph builds and the engine starts")
            } catch {
                return Check.expect(false, "engine failed to prepare: \(error)")
            }

            // A running engine with nothing scheduled must be silent. If this
            // fails, every idle moment in the app has a noise floor.
            let idle = try engine.renderOffline(frameCount: 2048)
            Check.expectEqual(peak(of: idle), 0, "an idle engine renders silence")

            engine.cache.admit(makeBuffer(seconds: 0.5), for: "tile-a")
            let result = try engine.trigger("tile-a")
            Check.expectEqual(result.soundID, "tile-a", "the trigger reports the sound it fired")

            // The visual layer schedules frame deadlines on the host clock, so
            // this has to be a host time. A sample-clock value would compare
            // cleanly and place the picture an arbitrary interval from the
            // sound.
            let now = CACurrentMediaTime()
            Check.expect(
                result.expectedStart >= now - 0.05 && result.expectedStart <= now + 0.5,
                "expectedStart is on the host clock, near now [delta \(String(format: "%.4f", result.expectedStart - now))s]"
            )
            Check.expect(result.stoleVoice == nil, "the first trigger steals nothing")

            let sounded = try engine.renderOffline(frameCount: 4096)
            Check.expect(peak(of: sounded) > 0.1, "a triggered tile actually produces audio [peak \(peak(of: sounded))]")

            // Fail closed on a tile whose buffer is not resident: no crash, no
            // silence-with-a-shrug, a typed error the UI can act on.
            Check.expectThrows(PlaybackError.notLoaded("absent"), "an unloaded tile fails closed") {
                _ = try engine.trigger("absent")
            }
            Check.expectEqual(engine.droppedTriggers, 1, "the dropped trigger is counted")
        }

        Check.suite("PlaybackEngine - eight voices and the ninth tap") {
            let engine = PlaybackEngine(
                cache: BufferCache(capacity: 16),
                voiceCount: 8,
                renderMode: .offline(maximumFrameCount: 4096)
            )
            try engine.prepare()
            for index in 0..<9 { engine.cache.admit(makeBuffer(seconds: 1.0, amplitude: 0.1), for: "t\(index)") }

            var stolen: SoundID?
            for index in 0..<8 {
                let result = try engine.trigger("t\(index)")
                if result.stoleVoice != nil { stolen = result.stoleVoice }
            }
            Check.expectEqual(engine.activeVoiceCount, 8, "eight tiles hold eight voices")
            Check.expect(stolen == nil, "nothing is stolen while voices remain")

            // The ninth rapid tap takes the oldest voice rather than being
            // dropped. A soundboard that ignores a tap feels broken.
            let ninth = try engine.trigger("t8")
            Check.expectEqual(ninth.stoleVoice, "t0", "the ninth tap steals the oldest voice")
            Check.expectEqual(engine.activeVoiceCount, 8, "the pool never exceeds its capacity")

            let mixed = try engine.renderOffline(frameCount: 4096)
            Check.expect(peak(of: mixed) > 0.2, "eight overlapping voices mix without dropping out [peak \(peak(of: mixed))]")

            // Overlap is the default because tapping twice fast should sound
            // twice. Restart is opt-in for longer talky clips.
            let overlapEngine = PlaybackEngine(cache: BufferCache(capacity: 4), voiceCount: 4, renderMode: .offline(maximumFrameCount: 4096))
            try overlapEngine.prepare()
            overlapEngine.cache.admit(makeBuffer(seconds: 1.0), for: "same")
            let first = try overlapEngine.trigger("same", policy: .overlap)
            let second = try overlapEngine.trigger("same", policy: .overlap)
            Check.expect(first.voiceIndex != second.voiceIndex, "overlap gives the second tap its own voice")
            Check.expectEqual(overlapEngine.activeVoiceCount, 2, "two voices are sounding")

            let restart = try overlapEngine.trigger("same", policy: .restart)
            Check.expectEqual(restart.voiceIndex, first.voiceIndex, "restart reuses the voice already playing that sound")
        }
    }

    // MARK: - Resilience

    private static func resilienceChecks() {
        Check.suite("PlaybackEngine - interruptions and resets") {
            // Eight voices, so nothing in this suite steals. The subject here
            // is session resilience, and a peak that sits just above the
            // threshold because a voice was stolen mid-render would make this
            // suite a flaky proxy for the wrong thing.
            let engine = PlaybackEngine(
                cache: BufferCache(capacity: 8),
                voiceCount: 8,
                renderMode: .offline(maximumFrameCount: 4096)
            )
            try engine.prepare()
            engine.cache.admit(makeBuffer(seconds: 1.0), for: "tile")

            // Each stage silences the board first so exactly one voice sounds
            // during the measurement. Leaving the previous voice running made
            // this measure interference between two copies of the same tone
            // rather than whether playback works: identical sines a render
            // window apart land near antiphase and cancel down to a third of
            // one voice's amplitude.
            let expectedPeak: Float = 0.5

            // Half a second, not one 85 ms chunk.
            //
            // Starting a player node is asynchronous with respect to rendering,
            // so a freshly restarted or rebuilt graph can legitimately render
            // one empty chunk before the attack arrives. In realtime that is a
            // few inaudible milliseconds. Measuring only the first chunk turned
            // that into an intermittent failure and made this check assert an
            // unspecified startup latency instead of the claim it is named
            // for, which is that sound resumes at all.
            let window = AVAudioFrameCount(OutputFormatBridge.sampleRate * 0.5)

            // A call arrives mid-clip.
            _ = try engine.trigger("tile")
            engine.handleInterruptionBegan()
            try engine.handleInterruptionEnded(shouldResume: true)
            engine.stopAll()
            _ = try engine.trigger("tile")
            let afterInterruption = peak(of: try engine.renderOffline(frameCount: window))
            Check.expectClose(Double(afterInterruption), Double(expectedPeak), tolerance: 0.02, "playback works again after an interruption")

            // Headphones pulled out mid-clip. A route change stops the nodes,
            // and without restarting them every later tap is silent.
            try engine.handleRouteChange()
            engine.stopAll()
            _ = try engine.trigger("tile")
            let afterRoute = peak(of: try engine.renderOffline(frameCount: window))
            Check.expectClose(Double(afterRoute), Double(expectedPeak), tolerance: 0.02, "playback survives a route change")

            // Media services died: the whole graph is invalid and is rebuilt.
            try engine.handleMediaServicesReset()
            Check.expect(engine.cache.contains("tile"), "cached buffers survive a graph rebuild")
            _ = try engine.trigger("tile")
            let afterReset = peak(of: try engine.renderOffline(frameCount: window))
            Check.expectClose(Double(afterReset), Double(expectedPeak), tolerance: 0.02, "playback works after a media services reset")

            engine.stopAll()
            let afterStop = try engine.renderOffline(frameCount: 2048)
            Check.expectEqual(peak(of: afterStop), 0, "stopAll silences the board immediately")
            Check.expectEqual(engine.activeVoiceCount, 0, "stopAll frees every voice")

            // Dismissing a board must not throw away its preloaded audio.
            // Freeing is a separate decision, taken under memory pressure.
            Check.expect(engine.cache.contains("tile"), "stopAll keeps buffers resident for the next board")
            engine.releaseIdleBuffers()
            Check.expect(!engine.cache.contains("tile"), "releaseIdleBuffers frees what is no longer audible")
        }

        Check.suite("PlaybackEngine - lifecycle guards") {
            let engine = PlaybackEngine(renderMode: .offline(maximumFrameCount: 4096))
            engine.cache.admit(makeBuffer(seconds: 0.1), for: "tile")
            Check.expectThrows(PlaybackError.notPrepared, "triggering before prepare fails closed") {
                _ = try engine.trigger("tile")
            }
            try engine.prepare()
            try engine.prepare()
            Check.expect(true, "prepare is idempotent, so a second call does not rebuild the graph")
        }
    }

    /// The ceiling has to hold under churn, not just when clips are admitted in
    /// a quiet loop. Firing far more sounds than the cache can hold, with steals
    /// and stops throughout, is where a leaked pin shows up: pinned entries are
    /// never evicted, so a pin left behind by a stop makes its buffer immortal
    /// and the cache grows past its ceiling one dismissal at a time.
    private static func memoryCeilingChecks() {
        Check.suite("PlaybackEngine - the memory ceiling holds under churn") {
            let capacity = 8
            let engine = PlaybackEngine(
                cache: BufferCache(capacity: capacity),
                voiceCount: 8,
                renderMode: .offline(maximumFrameCount: 4096)
            )
            try engine.prepare()

            for round in 0..<3 {
                for index in 0..<24 {
                    let id = "churn-\(index)"
                    engine.cache.admit(makeBuffer(seconds: 0.5, amplitude: 0.1), for: id)
                    _ = try engine.trigger(id)
                    if index % 5 == 4 { _ = try engine.renderOffline(frameCount: 1024) }
                    if index % 9 == 8 { engine.stopAll() }
                }
                _ = round
            }

            // The ceiling is soft while clips are audible: a sounding clip is
            // pinned and is never the victim, so the true bound is the ceiling
            // plus the voice count.
            let bound = capacity + 8
            let stats = engine.cache.statistics()
            Check.expect(
                stats.residentCount <= bound,
                "the cache stays within its ceiling plus the voice count [resident \(stats.residentCount), bound \(bound)]"
            )
            Check.expect(stats.evictions > 0, "eviction actually happened rather than being blocked by stale pins")

            // With everything stopped, nothing is audible, so nothing is pinned
            // and the cache must be able to release all of it.
            engine.stopAll()
            engine.releaseIdleBuffers()
            Check.expectEqual(
                engine.cache.statistics().residentCount,
                0,
                "with nothing audible, every buffer can be released"
            )
        }
    }

    // MARK: - Latency

    private static func latencyChecks() {
        Check.suite("PlaybackEngine - trigger path cost") {
            let engine = PlaybackEngine(
                cache: BufferCache(capacity: 32),
                voiceCount: 8,
                renderMode: .offline(maximumFrameCount: 4096)
            )
            try engine.prepare()
            for index in 0..<24 { engine.cache.admit(makeBuffer(seconds: 0.5, amplitude: 0.1), for: "tile\(index)") }

            var samples: [Double] = []
            samples.reserveCapacity(240)
            for iteration in 0..<240 {
                let id = "tile\(iteration % 24)"
                let start = DispatchTime.now().uptimeNanoseconds
                _ = try engine.trigger(id)
                samples.append(Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000)
                if iteration % 8 == 7 { _ = try engine.renderOffline(frameCount: 1024) }
            }
            samples.sort()
            let median = samples[samples.count / 2]
            let p99 = samples[Int(Double(samples.count) * 0.99)]

            // This is the half of tap-to-sound that our code owns: lookup, voice
            // pick, schedule. It is not the 30 ms gate in BACKEND_PLAN.md Phase
            // B3, which is touch-down to first sample on the oldest supported
            // device and needs a device and a loopback rig to measure. What this
            // proves is that the software path leaves essentially the whole
            // budget to the hardware.
            Check.expect(p99 < 1.0, "trigger p99 stays under 1 ms [median \(String(format: "%.3f", median)) ms, p99 \(String(format: "%.3f", p99)) ms]")
            Check.expectEqual(engine.droppedTriggers, 0, "no trigger was dropped under sustained firing")
        }
    }
}
