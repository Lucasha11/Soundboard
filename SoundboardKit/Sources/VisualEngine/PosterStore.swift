import CoreGraphics
import Foundation
import GovernanceKit
import ImageIO

public typealias TileID = String

/// Decoded poster images for the idle grid.
///
/// The grid at rest is nothing but posters. A page of 24 decodes 24 of them per
/// scroll, so this is the hot path for scrolling and the reason animated
/// sources are transcoded to a still plus a video at import rather than played
/// as-is.
///
/// Budgeted in bytes rather than count, because a poster's cost is its pixels:
/// at tile size that is about 2 MB decoded, so 24 of them is 50 MB and the
/// whole media layer has 150 MB to work with.
public final class PosterStore {
    public struct Statistics: Sendable, Equatable {
        public var residentCount: Int
        public var residentBytes: Int
        public var hits: Int
        public var misses: Int
        public var evictions: Int
        public var decodes: Int
    }

    private struct Entry {
        let image: CGImage
        let bytes: Int
        var lastUsed: UInt64
        /// On screen right now. Evicting a visible poster leaves a hole in the
        /// grid the user is looking at, so visibility beats recency.
        var visible: Bool
    }

    private let byteBudget: Int
    private let targetPixelSize: Int
    private var entries: [TileID: Entry] = [:]
    private var clock: UInt64 = 0
    private var stats = Statistics(residentCount: 0, residentBytes: 0, hits: 0, misses: 0, evictions: 0, decodes: 0)
    private let lock = NSLock()

    public init(byteBudget: Int = 48 * 1024 * 1024, targetPixelSize: Int = 720) {
        self.byteBudget = byteBudget
        self.targetPixelSize = targetPixelSize
    }

    /// Returns a decoded poster, decoding it if it is not already resident.
    public func poster(for id: TileID, at url: URL) throws -> CGImage {
        if let cached = cached(id) { return cached }

        let image = try Self.decode(url: url, targetPixelSize: targetPixelSize)
        lock.lock()
        clock += 1
        stats.decodes += 1
        entries[id] = Entry(
            image: image,
            bytes: image.width * image.height * 4,
            lastUsed: clock,
            visible: false
        )
        evictIfNeededLocked(protecting: id)
        recountLocked()
        lock.unlock()
        return image
    }

    public func cached(_ id: TileID) -> CGImage? {
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
        return entry.image
    }

    /// Called by the grid as tiles enter and leave the screen.
    public func setVisible(_ visible: Bool, for ids: [TileID]) {
        lock.lock()
        defer { lock.unlock() }
        for id in ids where entries[id] != nil {
            entries[id]?.visible = visible
            if visible {
                clock += 1
                entries[id]?.lastUsed = clock
            }
        }
    }

    /// Memory pressure: everything off screen goes. The grid re-decodes lazily
    /// as those rows come back.
    public func evictOffscreen() {
        lock.lock()
        defer { lock.unlock() }
        for (id, entry) in entries where !entry.visible {
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

    public func contains(_ id: TileID) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return entries[id] != nil
    }

    /// - Parameter protecting: the entry just decoded, never its own victim.
    ///   Without this a full screen of visible posters evicts the newcomer on
    ///   the way in and the tile renders blank.
    private func evictIfNeededLocked(protecting: TileID?) {
        var total = entries.values.reduce(0) { $0 + $1.bytes }
        while total > byteBudget {
            let victim = entries
                .filter { !$0.value.visible && $0.key != protecting }
                .min { $0.value.lastUsed < $1.value.lastUsed }
            guard let victim else { return }   // everything else is on screen
            total -= victim.value.bytes
            entries.removeValue(forKey: victim.key)
            stats.evictions += 1
        }
    }

    private func recountLocked() {
        stats.residentCount = entries.count
        stats.residentBytes = entries.values.reduce(0) { $0 + $1.bytes }
    }

    /// Decodes at tile size rather than full size. `kCGImageSourceThumbnail*`
    /// asks ImageIO to produce the smaller image directly, so a large source is
    /// never fully decoded on the way to a small one.
    static func decode(url: URL, targetPixelSize: Int) throws -> CGImage {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else {
            throw ImportFailureCode.unreadableFile
        }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: targetPixelSize,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            throw ImportFailureCode.decodeFailed
        }
        return image
    }
}
