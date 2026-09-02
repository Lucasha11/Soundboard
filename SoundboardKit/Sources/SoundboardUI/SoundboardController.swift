import Foundation
import GovernanceKit
import PlaybackEngine
import VisualEngine

/// Where a tile's media lives.
///
/// The UI never touches the blob store directly. An app resolves tile ids to
/// the three derivatives the import pipeline produced; previews and checks
/// resolve to nothing and the board still behaves, it just makes no sound.
public protocol TileMediaResolving: Sendable {
    func audioURL(for tileID: String) -> URL?
    func animationURL(for tileID: String) -> URL?
    func posterURL(for tileID: String) -> URL?
}

/// Resolves nothing. The catalogue in this target ships placeholder art, the
/// same as the design, which draws striped colour blocks rather than gifs.
public struct EmptyMediaResolver: TileMediaResolving {
    public init() {}
    public func audioURL(for tileID: String) -> URL? { nil }
    public func animationURL(for tileID: String) -> URL? { nil }
    public func posterURL(for tileID: String) -> URL? { nil }
}

/// Joins the view layer to the engines.
///
/// The ordering here is the whole point of the seam. Audio fires first and
/// reports the host-clock instant its first sample lands; the picture is then
/// scheduled against that instant rather than against the tap. Firing the two
/// independently from the view would put them a hardware-latency apart on
/// every press.
@MainActor
public final class SoundboardController {
    private let playback: PlaybackEngine
    private let visual: VisualEngine
    private let resolver: TileMediaResolving

    public private(set) var lastVisual: TileVisual?
    public private(set) var lastSchedule: FrameSchedule?

    /// Sessions for the tiles currently animating, so the view layer has
    /// something to pull frames from. Previously `fire` threw the session away
    /// the moment it got it, which is why no tile ever animated.
    private var animating: [String: AnimationSession] = [:]
    /// When each firing tile's audio actually starts, on the host clock. The
    /// picture is paced against this rather than against the tap, which is the
    /// whole point of `FrameSchedule` (`BACKEND_PLAN.md` B3.4).
    private var animationStarts: [String: TimeInterval] = [:]

    /// Keeps the engine alive across calls, headphone changes and audio-server
    /// restarts. Held here because it must outlive `warmUp()`: an observer
    /// released at the end of a function stops observing, and the board goes
    /// silent on the first interruption with nothing in the logs to say why.
    private let sessionObserver: AudioSessionObserver

    public init(
        playback: PlaybackEngine = PlaybackEngine(),
        visual: VisualEngine = VisualEngine(),
        resolver: TileMediaResolving = EmptyMediaResolver()
    ) {
        self.playback = playback
        self.visual = visual
        self.resolver = resolver
        self.sessionObserver = AudioSessionObserver(engine: playback)
    }

    /// Called when reacting to a session event fails - a graph rebuild after a
    /// media-services reset, say. Set by the composition, which logs it.
    ///
    /// Recorded *and read*: the observer cannot throw out of a system
    /// callback, so it stores the failure, and something has to collect it or
    /// the storing is theatre.
    public var onSessionFailure: ((String) -> Void)?

    /// The last failure the session observer recorded, if any.
    public var lastSessionFailure: Error? { sessionObserver.lastFailure }

    public func prepare() throws {
        try playback.prepare()
    }

    /// Brings the audio graph up without blocking launch.
    ///
    /// `prepare()` talks to the audio server over IPC. Doing that synchronously
    /// during composition holds up the first frame, and when the machine is
    /// loaded - a second app instance still tearing its audio unit down, say -
    /// that RPC can time out. AudioToolbox reports a timed-out RPC by calling
    /// `abort()`, not by throwing, so `try?` around it buys nothing: the
    /// process dies. Moving the call off the main thread keeps launch
    /// responsive and keeps the app off that contention window.
    ///
    /// The engine is still up long before it is needed. `BACKEND_PLAN.md`
    /// Section 5 forbids starting an engine on tap, and this does not: the user
    /// has to see the grid before they can hit a tile, which is orders of
    /// magnitude longer than the warm-up takes.
    public func warmUp() {
        // Subscribing before the graph is built, not after: an interruption
        // that lands during warm-up is exactly the case a late subscription
        // misses (`BACKEND_PLAN.md` B3.3).
        sessionObserver.onFailure = { [weak self] error in
            self?.onSessionFailure?(String(describing: error))
        }
        sessionObserver.start()
        let playback = self.playback
        Task.detached(priority: .userInitiated) {
            try? playback.prepare()
        }
    }

    /// Decodes posters and preloads audio for the tiles within the prefetch
    /// horizon, and releases what has fallen outside it.
    ///
    /// - Parameters:
    ///   - tiles: the whole catalogue, in order. The horizon decides which of
    ///     them are worth holding, so callers do not have to slice correctly.
    ///   - visiblePage: the page the user is looking at.
    ///   - horizon: the visible page plus one either side, per
    ///     `BACKEND_PLAN.md` Section 6.
    @discardableResult
    public func preload(
        _ tiles: [SoundTile],
        visiblePage: Int,
        horizon: PrefetchHorizon = PrefetchHorizon()
    ) -> [String: ImportFailureCode] {
        let resident = horizon.resident(tiles, visiblePage: visiblePage)
        // Evicting first keeps the peak down: loading the new page before
        // dropping the old one puts both in memory at once, which is exactly
        // the moment the 150 MB ceiling is under most pressure.
        let keep = Set(resident.map(\.id))
        playback.releaseBuffers(except: keep)
        visual.releasePosters(except: keep)
        return preloadResident(resident)
    }

    /// Preloads exactly the tiles given, with no horizon applied. The board's
    /// eight pads are always resident, so they use this directly.
    @discardableResult
    public func preload(_ tiles: [SoundTile]) -> [String: ImportFailureCode] {
        preloadResident(tiles)
    }

    @discardableResult
    private func preloadResident(_ tiles: [SoundTile]) -> [String: ImportFailureCode] {
        var failures: [String: ImportFailureCode] = [:]

        let page = tiles.compactMap { tile -> (id: TileID, posterURL: URL)? in
            guard let poster = resolver.posterURL(for: tile.id) else { return nil }
            return (id: tile.id, posterURL: poster)
        }
        failures.merge(visual.prepare(page: page)) { current, _ in current }

        // `preloadPage` already batches this with the same error mapping;
        // the hand-rolled loop that used to be here was a second copy of it.
        let audio = tiles.compactMap { tile -> (id: SoundID, url: URL)? in
            guard let url = resolver.audioURL(for: tile.id) else { return nil }
            return (id: tile.id, url: url)
        }
        failures.merge(playback.preloadPage(audio)) { current, _ in current }
        return failures
    }

    /// Fires a tile. Call from touch-down.
    public func fire(_ tile: SoundTile) {
        guard resolver.audioURL(for: tile.id) != nil else { return }

        let trigger: TriggerResult
        do {
            trigger = try playback.trigger(tile.id)
        } catch {
            // A tile whose audio is not resident stays silent rather than
            // taking the UI down with it. The engine counts the drop.
            return
        }

        let animation = resolver.animationURL(for: tile.id)
        Task { [visual, weak self] in
            let fired = await visual.fire(
                tileID: tile.id,
                animationURL: animation,
                audioStart: trigger.expectedStart,
                audioDuration: tile.duration,
                animationDuration: tile.duration
            )
            self?.lastVisual = fired.visual
            self?.lastSchedule = fired.schedule
            guard let self else { return }

            // The pool may have refused a session because four tiles are
            // already animating, which is a legitimate outcome: the tile falls
            // back to its poster rather than degrading every other tile.
            guard let session = fired.session else { return }
            self.animating[tile.id] = session
            self.animationStarts[tile.id] = fired.schedule.audioStart

            // Held only for as long as the clip. Without this the pool leaks a
            // decoder per fire and only reclaims one when the cap forces it,
            // which is the difference between four concurrent animations and
            // four *ever*.
            let holdFor = max(0.1, tile.duration)
            try? await Task.sleep(nanoseconds: UInt64(holdFor * 1_000_000_000))
            self.animating.removeValue(forKey: tile.id)
            self.animationStarts.removeValue(forKey: tile.id)
            self.visual.endAnimation(tileID: tile.id)
        }
    }

    /// The animation session for a firing tile, or nil if it is showing its
    /// poster.
    public func animationSession(for tileID: String) -> AnimationSession? {
        animating[tileID]
    }

    /// The host-clock instant this tile's audio starts, so the picture can be
    /// paced against the sound rather than against the display.
    public func animationStart(for tileID: String) -> TimeInterval? {
        animationStarts[tileID]
    }

    public func stopAll() {
        playback.stopAll()
    }

    public func handleMemoryPressure() {
        playback.releaseIdleBuffers()
        visual.handleMemoryPressure()
    }
}
