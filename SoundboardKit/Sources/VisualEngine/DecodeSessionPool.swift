import Foundation
import GovernanceKit
import QuartzCore

/// What a tile is showing right now.
public enum TileVisual: Equatable {
    /// Animating, with a session held from the pool.
    case animating(tileID: TileID)
    /// Showing its still frame. Either the tile is idle, or the pool was full.
    case poster(tileID: TileID)
}

/// Hard cap on concurrent animation decoders.
///
/// This is the real constraint in the whole visual layer. VideoToolbox will not
/// hand out 24 decode sessions, so the grid cannot animate every tile even if
/// the design asked it to. Four is the working budget: a fifth simultaneous
/// fire shows its poster instead, which reads as a tile that flashed rather
/// than a grid that stuttered.
///
/// Dropping frames across every animating tile to accommodate one more is the
/// alternative, and it looks far worse than one tile not animating.
public final class DecodeSessionPool {
    public struct Statistics: Sendable, Equatable {
        public var acquired: Int
        public var stolen: Int
        public var deniedToPoster: Int
        public var active: Int
    }

    private struct Slot {
        /// Nil while the decoder is still opening. The slot still occupies
        /// capacity, so two tiles fired at once cannot both slip past the cap
        /// while neither has finished opening yet.
        var session: AnimationSession?
        var startedAt: UInt64
        let ticket: UInt64
        /// Host-clock time this tile's sound ends. Past that, the animation is
        /// over and its decoder is free to reclaim.
        var activeUntil: TimeInterval
    }

    private enum Reservation {
        case existing(AnimationSession)
        case reserved(ticket: UInt64)
        case denied
    }

    public let capacity: Int
    private var slots: [TileID: Slot] = [:]
    private var sequence: UInt64 = 0
    private var stats = Statistics(acquired: 0, stolen: 0, deniedToPoster: 0, active: 0)
    private let lock = NSLock()

    public init(capacity: Int = 4) {
        self.capacity = capacity
    }

    /// Takes a session for `tileID`.
    ///
    /// - Parameter activeUntil: host-clock time this tile's sound ends. The
    ///   pool reclaims decoders whose tiles have finished and never takes one
    ///   from a tile that is still animating.
    ///
    /// Reclaiming only finished tiles is the whole policy, and the alternative
    /// is worse than it looks. Taking a decoder from a tile that is mid-clip
    /// freezes that tile partway through its animation, which reads as a bug,
    /// while the tile that took it animates normally. A fifth simultaneous
    /// fire showing its poster reads as a tile that flashed. One still tile
    /// beats one broken one.
    ///
    /// The capacity decision is synchronous and the decoder open is not, so the
    /// slot is reserved before awaiting and released again if the open fails.
    public func acquire(
        tileID: TileID,
        url: URL,
        activeUntil: TimeInterval
    ) async -> (visual: TileVisual, session: AnimationSession?) {
        switch reserve(tileID: tileID, activeUntil: activeUntil) {
        case let .existing(session):
            // Already animating: restart in place rather than opening a second
            // decoder for the same tile.
            try? await session.restart()
            return (.animating(tileID: tileID), session)

        case .denied:
            return (.poster(tileID: tileID), nil)

        case let .reserved(ticket):
            let session = AnimationSession(tileID: tileID, url: url)
            do {
                try await session.start()
            } catch {
                // A tile whose animation will not open falls back to its
                // poster. A blank tile is a bug; a still tile is a tile.
                rollback(tileID: tileID, ticket: ticket)
                return (.poster(tileID: tileID), nil)
            }
            guard commit(tileID: tileID, ticket: ticket, session: session) else {
                // The reservation was stolen while the decoder was opening.
                session.stop()
                return (.poster(tileID: tileID), nil)
            }
            return (.animating(tileID: tileID), session)
        }
    }

    private func reserve(tileID: TileID, activeUntil: TimeInterval) -> Reservation {
        lock.lock()
        defer { lock.unlock() }
        sequence += 1

        if let existing = slots[tileID], let session = existing.session {
            slots[tileID]?.startedAt = sequence
            slots[tileID]?.activeUntil = activeUntil
            stats.acquired += 1
            return .existing(session)
        }

        if slots.count >= capacity && slots[tileID] == nil {
            let now = CACurrentMediaTime()
            // Only tiles whose sound has already ended are reclaimable. A tile
            // still animating keeps its decoder.
            let finished = slots.filter { $0.value.activeUntil <= now }
            guard let oldest = finished.min(by: { $0.value.startedAt < $1.value.startedAt }) else {
                stats.deniedToPoster += 1
                return .denied
            }
            oldest.value.session?.stop()
            slots.removeValue(forKey: oldest.key)
            stats.stolen += 1
        }

        let ticket = sequence
        slots[tileID] = Slot(session: nil, startedAt: sequence, ticket: ticket, activeUntil: activeUntil)
        stats.acquired += 1
        return .reserved(ticket: ticket)
    }

    private func commit(tileID: TileID, ticket: UInt64, session: AnimationSession) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard slots[tileID]?.ticket == ticket else { return false }
        slots[tileID]?.session = session
        return true
    }

    private func rollback(tileID: TileID, ticket: UInt64) {
        lock.lock()
        defer { lock.unlock() }
        guard slots[tileID]?.ticket == ticket else { return }
        slots.removeValue(forKey: tileID)
        stats.acquired -= 1
        stats.deniedToPoster += 1
    }

    /// Retires a session when its clip finishes or its tile scrolls away.
    public func release(tileID: TileID) {
        lock.lock()
        defer { lock.unlock() }
        guard let slot = slots.removeValue(forKey: tileID) else { return }
        slot.session?.stop()
    }

    public func releaseAll() {
        lock.lock()
        defer { lock.unlock() }
        for slot in slots.values { slot.session?.stop() }
        slots.removeAll()
    }

    public var activeCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return slots.count
    }

    public func isAnimating(_ tileID: TileID) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return slots[tileID] != nil
    }

    public func statistics() -> Statistics {
        lock.lock()
        defer { lock.unlock() }
        var current = stats
        current.active = slots.count
        return current
    }
}
