import AVFoundation
import Foundation

/// How a tile behaves when it is fired again while still sounding.
public enum RetriggerPolicy: String, Sendable, CaseIterable {
    /// Tap twice fast, hear two voices. This is what people expect from a
    /// soundboard and it is the default for that reason.
    case overlap
    /// Cut the previous voice and start again. Useful for longer talky clips
    /// where two copies just sound like a mistake.
    case restart
}

/// A fixed set of player nodes, attached once at graph build time.
///
/// Nodes are never attached or detached at trigger time. Attaching a node
/// reconfigures the graph, which is far too expensive to do while somebody is
/// drumming on the grid.
final class VoicePool {
    struct Voice {
        let index: Int
        let node: AVAudioPlayerNode
        var soundID: SoundID?
        var startedAt: UInt64
        /// Stamped from the pool's monotonic sequence on every acquisition.
        ///
        /// Two things race with a trigger. A completion handler from a stolen
        /// buffer arrives after the node was handed to a new sound, and a
        /// completion from a node destroyed by a graph rebuild arrives after
        /// the pool has rebuilt around it. Both would release a voice that is
        /// currently audible. A per-voice counter is not enough for the second
        /// case, because a rebuilt pool would start counting again and collide
        /// with the stale value; the sequence never resets, so it cannot.
        var generation: UInt64
    }

    private(set) var voices: [Voice] = []
    private var sequence: UInt64 = 0
    private let lock = NSLock()

    let capacity: Int

    init(capacity: Int = 8) {
        self.capacity = capacity
    }

    /// Builds the nodes and hands them back for attachment. The engine owns
    /// the graph; the pool only owns allocation policy.
    func makeNodes() -> [AVAudioPlayerNode] {
        lock.lock()
        defer { lock.unlock() }
        // `sequence` deliberately survives a rebuild. See Voice.generation.
        voices = (0..<capacity).map { index in
            sequence += 1
            return Voice(index: index, node: AVAudioPlayerNode(), soundID: nil, startedAt: 0, generation: sequence)
        }
        return voices.map(\.node)
    }

    /// Picks a voice for `id`.
    ///
    /// Preference order: a genuinely idle node, then the oldest sounding node.
    /// Stealing the oldest keeps a tenth rapid tap responsive instead of
    /// silently dropped, and by then the stolen clip is the one closest to
    /// finishing anyway.
    ///
    /// Idle is tracked here rather than read from `node.isPlaying`. A player
    /// node reports `isPlaying == true` from the moment it is started, even
    /// with nothing queued, and every node is started once at graph build time
    /// to keep `play()` off the trigger path. Asking the node would therefore
    /// report the whole pool as busy forever.
    func acquire(for id: SoundID, policy: RetriggerPolicy) -> (voice: Voice, stolen: SoundID?) {
        lock.lock()
        defer { lock.unlock() }
        sequence += 1

        if policy == .restart, let index = voices.firstIndex(where: { $0.soundID == id }) {
            let stolen = voices[index].soundID
            voices[index].startedAt = sequence
            voices[index].generation = sequence
            return (voices[index], stolen)
        }

        if let index = voices.firstIndex(where: { $0.soundID == nil }) {
            voices[index].soundID = id
            voices[index].startedAt = sequence
            voices[index].generation = sequence
            return (voices[index], nil)
        }

        let index = voices.indices.min { voices[$0].startedAt < voices[$1].startedAt } ?? 0
        let stolen = voices[index].soundID
        voices[index].soundID = id
        voices[index].startedAt = sequence
        voices[index].generation = sequence
        return (voices[index], stolen)
    }

    /// Called when a scheduled buffer finishes playing back. Ignored if the
    /// voice has already been reassigned.
    func release(index: Int, generation: UInt64) {
        lock.lock()
        defer { lock.unlock() }
        guard voices.indices.contains(index), voices[index].generation == generation else { return }
        voices[index].soundID = nil
    }

    func markIdle(index: Int) {
        lock.lock()
        defer { lock.unlock() }
        guard voices.indices.contains(index) else { return }
        sequence += 1
        voices[index].soundID = nil
        voices[index].generation = sequence
    }

    var activeCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return voices.filter { $0.soundID != nil }.count
    }

    func soundID(at index: Int) -> SoundID? {
        lock.lock()
        defer { lock.unlock() }
        return voices.indices.contains(index) ? voices[index].soundID : nil
    }
}
