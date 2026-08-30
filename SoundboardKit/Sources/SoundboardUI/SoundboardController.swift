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

    public init(
        playback: PlaybackEngine = PlaybackEngine(),
        visual: VisualEngine = VisualEngine(),
        resolver: TileMediaResolving = EmptyMediaResolver()
    ) {
        self.playback = playback
        self.visual = visual
        self.resolver = resolver
    }

    public func prepare() throws {
        try playback.prepare()
    }

    /// Decodes posters and preloads audio for a page of tiles. Driven by the
    /// scroll position: the visible page plus one either side.
    @discardableResult
    public func preload(_ tiles: [SoundTile]) -> [String: ImportFailureCode] {
        var failures: [String: ImportFailureCode] = [:]

        let page = tiles.compactMap { tile -> (id: TileID, posterURL: URL)? in
            guard let poster = resolver.posterURL(for: tile.id) else { return nil }
            return (id: tile.id, posterURL: poster)
        }
        failures.merge(visual.prepare(page: page)) { current, _ in current }

        for tile in tiles {
            guard let audio = resolver.audioURL(for: tile.id) else { continue }
            do {
                try playback.preload(tile.id, from: audio)
            } catch let code as ImportFailureCode {
                failures[tile.id] = code
            } catch {
                failures[tile.id] = .decodeFailed
            }
        }
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
        }
    }

    public func stopAll() {
        playback.stopAll()
    }

    public func handleMemoryPressure() {
        playback.releaseIdleBuffers()
        visual.handleMemoryPressure()
    }
}
