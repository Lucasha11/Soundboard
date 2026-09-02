import AVFoundation
import Foundation
import GovernanceKit

public typealias SoundID = String

/// Preloaded PCM, held so that a trigger is a dictionary lookup and a schedule
/// call rather than file I/O.
///
/// Budgeting, per BACKEND_PLAN.md Section 6: a two second stereo clip at 48 kHz
/// float is 768 KB decoded. Twenty-four fit in 19 MB, but 120 would be 92 MB,
/// so the cache holds a ceiling of 48 and evicts by least recent use. Disk is
/// never the constraint here; memory is.
public final class BufferCache {
    /// Canonical playback format. Every buffer is converted to it on load.
    ///
    /// Mono sources cost half as much decoded, and the import pipeline preserves
    /// mono for exactly that reason. They are still widened here, because an
    /// `AVAudioPlayerNode` only accepts buffers matching its connection format,
    /// and a second graph for mono clips costs more than the memory it saves.
    /// The 48-clip ceiling is sized for stereo, so this is already budgeted.
    public static let format = AVAudioFormat(
        standardFormatWithSampleRate: OutputFormatBridge.sampleRate,
        channels: 2
    )!

    public struct Statistics: Sendable, Equatable {
        public var residentCount: Int
        public var residentBytes: Int
        public var hits: Int
        public var misses: Int
        public var evictions: Int
    }

    private struct Entry {
        let buffer: AVAudioPCMBuffer
        var lastUsed: UInt64
        /// Voices currently playing this buffer. A pinned entry is never the
        /// eviction victim, because dropping what is audible right now is the
        /// one eviction a user can hear.
        var pins: Int
    }

    private let capacity: Int
    private var entries: [SoundID: Entry] = [:]
    private var clock: UInt64 = 0
    private var stats = Statistics(residentCount: 0, residentBytes: 0, hits: 0, misses: 0, evictions: 0)
    private let lock = NSLock()

    /// `BACKEND_PLAN.md` Section 6: 48 clips of decoded PCM is about 37 MB,
    /// which is the share of the 150 MB media budget audio gets. Named rather
    /// than left as a bare default so the plan's number has one home and the
    /// checks can assert against it instead of restating it.
    public static let defaultCapacity = 48

    public init(capacity: Int = BufferCache.defaultCapacity) {
        self.capacity = capacity
    }

    /// Decodes a file into the canonical format and admits it to the cache.
    /// Called off the trigger path, on the preload queue.
    @discardableResult
    public func load(_ id: SoundID, from url: URL) throws -> AVAudioPCMBuffer {
        if let existing = buffer(for: id) { return existing }

        // AVFoundation reports failures as NSError carrying the file URL in
        // userInfo. That error object reaches log lines and crash reports, and
        // a path under /var/mobile is a device-local personal shape, so nothing
        // from the decoder is allowed to escape this boundary (DG-LOG-01).
        // Every failure leaves here as a closed code instead.
        let file: AVAudioFile
        do {
            file = try AVAudioFile(forReading: url)
        } catch {
            throw ImportFailureCode.unreadableFile
        }
        let frames = AVAudioFrameCount(file.length)
        guard frames > 0 else { throw ImportFailureCode.unreadableFile }

        guard let source = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: frames) else {
            throw ImportFailureCode.decodeFailed
        }
        do {
            try file.read(into: source)
        } catch {
            throw ImportFailureCode.decodeFailed
        }

        let converted = try Self.convert(source, to: Self.format)
        admit(converted, for: id)
        return converted
    }

    public func admit(_ buffer: AVAudioPCMBuffer, for id: SoundID) {
        lock.lock()
        defer { lock.unlock() }
        clock += 1
        entries[id] = Entry(buffer: buffer, lastUsed: clock, pins: 0)
        evictIfNeededLocked(protecting: id)
        recountLocked()
    }

    public func buffer(for id: SoundID) -> AVAudioPCMBuffer? {
        lock.lock()
        defer { lock.unlock() }
        guard var entry = entries[id] else {
            stats.misses += 1
            return nil
        }
        clock += 1
        entry.lastUsed = clock
        entries[id] = entry
        stats.hits += 1
        return entry.buffer
    }

    package func pin(_ id: SoundID) {
        lock.lock()
        defer { lock.unlock() }
        entries[id]?.pins += 1
    }

    package func unpin(_ id: SoundID) {
        lock.lock()
        defer { lock.unlock() }
        guard let current = entries[id]?.pins, current > 0 else { return }
        entries[id]?.pins = current - 1
    }

    public func contains(_ id: SoundID) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return entries[id] != nil
    }

    /// Memory pressure path: drop everything not currently audible. The grid
    /// falls back to posters and re-primes lazily.
    public func evictUnpinned() {
        lock.lock()
        defer { lock.unlock() }
        for (id, entry) in entries where entry.pins == 0 {
            entries.removeValue(forKey: id)
            stats.evictions += 1
        }
        recountLocked()
    }

    /// Drops every buffer outside `keep`, leaving audible ones alone.
    ///
    /// The prefetch horizon's eviction half. A pinned buffer is currently
    /// sounding, and freeing it mid-clip would cut the audio off - so a tile
    /// that scrolled away while firing keeps its buffer until the voice
    /// finishes, and is collected on the next pass.
    public func evict(except keep: Set<SoundID>) {
        lock.lock()
        defer { lock.unlock() }
        for (id, entry) in entries where entry.pins == 0 && !keep.contains(id) {
            entries.removeValue(forKey: id)
            stats.evictions += 1
        }
        recountLocked()
    }

    public func statistics() -> Statistics {
        lock.lock()
        defer { lock.unlock() }
        return stats
    }

    /// - Parameter protecting: the entry just admitted, which is never the
    ///   victim.
    ///
    /// The newcomer needs protecting because it is the only unpinned entry in
    /// the case that matters: a full board where every resident buffer is
    /// currently audible. Without it, admitting a clip evicts that same clip on
    /// the way in and the tile the user just loaded refuses to play.
    ///
    /// When nothing else can be evicted the cache exceeds its ceiling rather
    /// than dropping something audible. The overshoot is bounded by the voice
    /// count, since only a sounding clip is pinned, so the true ceiling is
    /// `capacity + voiceCount` and the plan's 48-clip budget has the room.
    private func evictIfNeededLocked(protecting: SoundID?) {
        while entries.count > capacity {
            let victim = entries
                .filter { $0.value.pins == 0 && $0.key != protecting }
                .min { $0.value.lastUsed < $1.value.lastUsed }
            guard let victim else { return }
            entries.removeValue(forKey: victim.key)
            stats.evictions += 1
        }
    }

    private func recountLocked() {
        stats.residentCount = entries.count
        stats.residentBytes = entries.values.reduce(0) { total, entry in
            total + Int(entry.buffer.frameLength)
                * Int(entry.buffer.format.channelCount)
                * MemoryLayout<Float>.size
        }
    }

    static func convert(_ source: AVAudioPCMBuffer, to format: AVAudioFormat) throws -> AVAudioPCMBuffer {
        if source.format == format { return source }
        guard let converter = AVAudioConverter(from: source.format, to: format) else {
            throw ImportFailureCode.decodeFailed
        }
        let ratio = format.sampleRate / source.format.sampleRate
        let capacity = AVAudioFrameCount(Double(source.frameLength) * ratio) + 1024
        guard let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else {
            throw ImportFailureCode.decodeFailed
        }

        var supplied = false
        var conversionError: NSError?
        converter.convert(to: output, error: &conversionError) { _, status in
            if supplied {
                status.pointee = .endOfStream
                return nil
            }
            supplied = true
            status.pointee = .haveData
            return source
        }
        if conversionError != nil { throw ImportFailureCode.decodeFailed }
        guard output.frameLength > 0 else { throw ImportFailureCode.decodeFailed }
        return output
    }
}

/// The canonical sample rate lives in ImportPipeline, which PlaybackEngine does
/// not depend on. Duplicating the constant here would let the two drift apart
/// silently, so it is named once and asserted equal in the checks.
public enum OutputFormatBridge {
    public static let sampleRate: Double = 48_000
}
