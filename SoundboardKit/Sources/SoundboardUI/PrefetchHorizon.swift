import Foundation

/// Which tiles are worth holding in memory right now.
///
/// `BACKEND_PLAN.md` Section 6: the grid is paged at 24 tiles, and the preload
/// horizon is "the visible page plus one page either side". That sentence was
/// documentation rather than behaviour - `SoundboardController.preload` loaded
/// every tile it was handed, and the composition handed it the whole
/// catalogue. At 25 tiles nobody notices. At 120 it is 92 MB of decoded PCM
/// and 21 MB of posters against a 150 MB budget for the entire media layer,
/// which is the ceiling B4's gate exists to defend.
///
/// Pure arithmetic on purpose: paging is the kind of thing that is wrong at
/// exactly one end of exactly one page, and that is much easier to pin down
/// with a table of cases than by scrolling a device and watching a graph.
public struct PrefetchHorizon: Equatable, Sendable {
    /// Tiles per page. 24 is the grid's page size from Section 6.
    public let pageSize: Int
    /// How many pages either side of the visible one stay resident.
    public let neighbours: Int

    public init(pageSize: Int = 24, neighbours: Int = 1) {
        self.pageSize = max(1, pageSize)
        self.neighbours = max(0, neighbours)
    }

    /// The page a tile index falls on.
    public func page(ofIndex index: Int) -> Int {
        max(0, index) / pageSize
    }

    /// The index range to keep resident for a given visible page, clamped to
    /// what actually exists.
    ///
    /// Clamping rather than trusting the caller: a scroll callback reporting a
    /// page past the end during a reload is a normal race, not a programming
    /// error, and it must not read as "evict everything".
    public func residentRange(visiblePage: Int, tileCount: Int) -> Range<Int> {
        guard tileCount > 0 else { return 0..<0 }
        let lastPage = (tileCount - 1) / pageSize
        let centre = min(max(visiblePage, 0), lastPage)
        let first = max(0, centre - neighbours) * pageSize
        let last = min(tileCount, (min(lastPage, centre + neighbours) + 1) * pageSize)
        return first..<last
    }

    /// The tiles to keep resident, in order.
    public func resident<T>(_ tiles: [T], visiblePage: Int) -> [T] {
        Array(tiles[residentRange(visiblePage: visiblePage, tileCount: tiles.count)])
    }

    /// The number of tiles the horizon can hold at once, which is what the
    /// memory budget has to cover.
    public var maximumResidentTiles: Int { pageSize * (neighbours * 2 + 1) }
}
