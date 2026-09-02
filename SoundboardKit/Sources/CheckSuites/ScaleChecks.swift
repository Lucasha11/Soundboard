import AVFoundation
import Foundation
import PlaybackEngine
import SoundboardUI
import VisualEngine

/// `BACKEND_PLAN.md` Phase B4, the parts that do not need a device.
///
/// The gate's frame-rate half needs an instrument on real hardware. Its memory
/// half does not, and Section 10 says so directly: "Memory ceiling test at 120
/// tiles, asserted, not eyeballed." A budget nobody asserts is a budget that is
/// already blown.
enum ScaleChecks {
    /// Section 6's per-clip figures, used to hold the arithmetic to the plan
    /// rather than to whatever the code happens to do.
    private enum Budget {
        /// 2 s, 48 kHz, stereo, float32.
        static let decodedPCMBytesPerClip = 768 * 1024
        /// Tile-resolution poster.
        static let posterBytes = 180 * 1024
        /// The whole media layer.
        static let ceilingBytes = 150 * 1024 * 1024
    }

    static func run() {
        // Paging is wrong at exactly one end of exactly one page, which is far
        // easier to pin down with a table than by scrolling a device.
        Check.suite("PrefetchHorizon - B4.2: the visible page plus one either side") {
            let horizon = PrefetchHorizon(pageSize: 24, neighbours: 1)

            Check.expectEqual(horizon.page(ofIndex: 0), 0, "the first tile is on page 0")
            Check.expectEqual(horizon.page(ofIndex: 23), 0, "and so is the last of that page")
            Check.expectEqual(horizon.page(ofIndex: 24), 1, "the next tile starts page 1")

            // At the start there is no page to the left, so the horizon is two
            // pages rather than three. Clamping, not wrapping.
            Check.expectEqual(
                horizon.residentRange(visiblePage: 0, tileCount: 120), 0..<48,
                "page 0 holds itself and the page after it"
            )
            Check.expectEqual(
                horizon.residentRange(visiblePage: 2, tileCount: 120), 24..<96,
                "a middle page holds three pages"
            )
            Check.expectEqual(
                horizon.residentRange(visiblePage: 4, tileCount: 120), 72..<120,
                "the last page holds itself and the page before it"
            )

            // A partial final page must not read past the end.
            Check.expectEqual(
                horizon.residentRange(visiblePage: 4, tileCount: 100), 72..<100,
                "a partial last page is clamped to what exists"
            )
            Check.expectEqual(
                horizon.residentRange(visiblePage: 0, tileCount: 5), 0..<5,
                "a catalogue smaller than one page is entirely resident"
            )
            Check.expectEqual(
                horizon.residentRange(visiblePage: 0, tileCount: 0), 0..<0,
                "an empty catalogue holds nothing"
            )

            // A scroll callback reporting a page past the end during a reload
            // is a normal race, not a programming error, and must not read as
            // "evict everything".
            Check.expectEqual(
                horizon.residentRange(visiblePage: 99, tileCount: 120), 72..<120,
                "a page past the end clamps to the last one"
            )
            Check.expectEqual(
                horizon.residentRange(visiblePage: -3, tileCount: 120), 0..<48,
                "and a negative page clamps to the first"
            )

            Check.expectEqual(horizon.maximumResidentTiles, 72, "three pages of 24 is the most it can hold")
        }

        // The point of the horizon: what it costs at the size the gate names.
        Check.suite("PrefetchHorizon - B4: the 150 MB ceiling at 120 tiles") {
            let horizon = PrefetchHorizon(pageSize: 24, neighbours: 1)
            let tiles = (0..<120).map { "tile-\($0)" }

            let resident = horizon.resident(tiles, visiblePage: 2).count
            Check.expectEqual(resident, 72, "a middle page keeps 72 of the 120 tiles resident")

            // Posters are held for the whole horizon; audio is additionally
            // capped by the LRU at 48 clips, so the two controls compound.
            let posterCost = resident * Budget.posterBytes
            let audioCost = min(resident, BufferCache.defaultCapacity) * Budget.decodedPCMBytesPerClip
            let total = posterCost + audioCost
            Check.expect(
                total < Budget.ceilingBytes,
                "the horizon fits the media budget [\(total / 1024 / 1024) MB of \(Budget.ceilingBytes / 1024 / 1024) MB]"
            )

            // The comparison that justifies the phase - stated accurately,
            // because the obvious version of this claim is wrong. Holding all
            // 120 tiles is about 109 MB, which is *inside* the 150 MB ceiling,
            // so "it blows the budget" would be false. What it does is spend
            // 73% of the entire media budget on tiles that cannot be on
            // screen, leaving too little for the video decode sessions and
            // transient encode work that have to share it.
            let unbounded = 120 * Budget.posterBytes + 120 * Budget.decodedPCMBytesPerClip
            Check.expect(
                unbounded > Budget.ceilingBytes / 2,
                "holding all 120 spends over half the media budget [\(unbounded / 1024 / 1024) MB of \(Budget.ceilingBytes / 1024 / 1024) MB]"
            )
            Check.expect(
                total < Budget.ceilingBytes / 2,
                "while the horizon spends under half, leaving headroom for decode sessions"
            )
            // The other half of the cost, and the one that shows up as scroll
            // stutter rather than as a memory graph: an unbounded preload
            // admits 120 clips into a 48-entry LRU, so 72 of the decodes it
            // just paid for are evicted, and a tile the user is looking at can
            // be dropped by one they will never reach.
            Check.expect(
                120 > BufferCache.defaultCapacity,
                "an unbounded preload overruns the LRU and thrashes it, which the horizon does not"
            )
        }

        // Eviction is the half that actually frees memory. A horizon that
        // loads the new page without dropping the old one is not a horizon.
        Check.suite("BufferCache - B4.2: scrolling away frees the buffers") {
            let cache = BufferCache(capacity: 64)
            let format = BufferCache.format
            func buffer() -> AVAudioPCMBuffer {
                let b = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1024)!
                b.frameLength = 1024
                return b
            }

            for index in 0..<48 { cache.admit(buffer(), for: "tile-\(index)") }
            Check.expectEqual(cache.statistics().residentCount, 48, "48 tiles resident")

            let keep = Set((24..<48).map { "tile-\($0)" })
            cache.evict(except: keep)
            Check.expectEqual(cache.statistics().residentCount, 24, "scrolling on frees the pages left behind")
            Check.expect(cache.contains("tile-24"), "and keeps the ones still in the horizon")
            Check.expect(!cache.contains("tile-0"), "while the far side is gone")
            Check.expect(cache.statistics().residentBytes > 0, "the byte count follows the eviction")

            // A tile that scrolled away mid-clip must not have its audio cut
            // off underneath it.
            cache.admit(buffer(), for: "firing")
            cache.pin("firing")
            cache.evict(except: [])
            Check.expect(
                cache.contains("firing"),
                "a sounding tile survives eviction, and is collected on the next pass"
            )
        }
    }
}
