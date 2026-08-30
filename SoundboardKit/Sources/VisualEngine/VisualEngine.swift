import CoreGraphics
import Foundation
import GovernanceKit

/// When each frame of a fired tile is due.
///
/// The tile animation is scheduled against the moment the audio will actually
/// be audible, not against the touch event. Those are not the same instant: the
/// engine reports an expected start that already includes hardware output
/// latency, and driving the picture from the touch instead puts it ahead of the
/// sound by that amount on every single fire.
public struct FrameSchedule: Equatable {
    /// Absolute time the first frame is due, taken from the audio trigger.
    public let audioStart: TimeInterval
    /// How long the sound lasts. The picture stops when the sound does.
    public let audioDuration: TimeInterval
    /// Length of one pass of the animation.
    public let animationDuration: TimeInterval

    public init(audioStart: TimeInterval, audioDuration: TimeInterval, animationDuration: TimeInterval) {
        self.audioStart = audioStart
        self.audioDuration = audioDuration
        self.animationDuration = animationDuration
    }

    /// Absolute deadline for a frame at `offset` into pass `loop`.
    public func deadline(forFrameAt offset: TimeInterval, loop: Int = 0) -> TimeInterval {
        audioStart + Double(loop) * animationDuration + offset
    }

    /// A tile whose picture is shorter than its sound loops rather than
    /// freezing on its last frame. A one second animation under a two second
    /// sound would otherwise be still for half the clip.
    public var loopCount: Int {
        guard animationDuration > 0 else { return 0 }
        return max(1, Int(ceil(audioDuration / animationDuration)))
    }

    /// Whether a frame is still wanted, or the sound has already ended.
    public func isWithinClip(_ deadline: TimeInterval) -> Bool {
        deadline < audioStart + audioDuration
    }

    /// How far a frame presented at `actual` is from where it should have been.
    /// Positive means late.
    public func drift(presented actual: TimeInterval, forFrameAt offset: TimeInterval, loop: Int = 0) -> TimeInterval {
        actual - deadline(forFrameAt: offset, loop: loop)
    }
}

/// The picture half of a tile press.
///
/// Two rules define this layer, both from BACKEND_PLAN.md Section 6:
///
/// 1. The idle grid is posters. Nothing animates until it is fired, which is
///    what lets a 24 tile page scroll at 120 Hz.
/// 2. At most four tiles animate at once. A fifth shows its poster, because
///    VideoToolbox will not give out 24 decoders and degrading one tile beats
///    dropping frames across all of them.
public final class VisualEngine {
    public let posters: PosterStore
    public let sessions: DecodeSessionPool

    public init(posters: PosterStore = PosterStore(), sessions: DecodeSessionPool = DecodeSessionPool()) {
        self.posters = posters
        self.sessions = sessions
    }

    /// Decodes posters for a page of tiles. Driven by the scroll position: the
    /// visible page plus one either side.
    @discardableResult
    public func prepare(page: [(id: TileID, posterURL: URL)]) -> [TileID: ImportFailureCode] {
        var failures: [TileID: ImportFailureCode] = [:]
        for tile in page {
            do {
                _ = try posters.poster(for: tile.id, at: tile.posterURL)
            } catch let code as ImportFailureCode {
                failures[tile.id] = code
            } catch {
                failures[tile.id] = .decodeFailed
            }
        }
        return failures
    }

    public func setVisible(_ visible: Bool, for ids: [TileID]) {
        posters.setVisible(visible, for: ids)
    }

    public func poster(for id: TileID) -> CGImage? {
        posters.cached(id)
    }

    /// Fires a tile's picture, against the audio's own start time.
    ///
    /// - Returns: whether the tile animates or falls back to its poster, the
    ///   session if it animates, and the schedule its frames are due on.
    public func fire(
        tileID: TileID,
        animationURL: URL?,
        audioStart: TimeInterval,
        audioDuration: TimeInterval,
        animationDuration: TimeInterval
    ) async -> (visual: TileVisual, session: AnimationSession?, schedule: FrameSchedule) {
        let schedule = FrameSchedule(
            audioStart: audioStart,
            audioDuration: audioDuration,
            animationDuration: animationDuration
        )
        // A still import has no animation, and a tile with only a poster is a
        // legitimate tile. It pulses on fire instead of animating.
        guard let animationURL else {
            return (.poster(tileID: tileID), nil, schedule)
        }
        // The decoder is held only for as long as the sound lasts.
        let (visual, session) = await sessions.acquire(
            tileID: tileID,
            url: animationURL,
            activeUntil: audioStart + audioDuration
        )
        return (visual, session, schedule)
    }

    /// The clip finished, or the tile scrolled away.
    public func endAnimation(tileID: TileID) {
        sessions.release(tileID: tileID)
    }

    /// Memory pressure. Everything off screen goes and every decoder is
    /// retired; the grid falls back to posters and re-primes lazily.
    public func handleMemoryPressure() {
        sessions.releaseAll()
        posters.evictOffscreen()
    }

    /// Bytes the visual layer is currently holding. Counts posters only:
    /// sessions stream, so their cost is a decoder each rather than a frame
    /// buffer each, which is the entire reason for the cap.
    public var residentBytes: Int {
        posters.statistics().residentBytes
    }
}
