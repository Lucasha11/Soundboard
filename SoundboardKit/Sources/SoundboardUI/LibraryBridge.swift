import CoreGraphics
import Foundation
import GovernanceKit
import SoundLibrary
import SwiftUI
import VisualEngine

/// Resolves tile media out of the on-device blob store.
///
/// Marked `@unchecked Sendable`: `SoundLibrary` guards its own state with a
/// lock, and this type adds none of its own.
public struct LibraryMediaResolver: TileMediaResolving, @unchecked Sendable {
    private let library: SoundLibrary

    public init(library: SoundLibrary) {
        self.library = library
    }

    public func audioURL(for tileID: String) -> URL? { library.audioURL(for: tileID) }
    public func animationURL(for tileID: String) -> URL? { library.animationURL(for: tileID) }
    public func posterURL(for tileID: String) -> URL? { library.posterURL(for: tileID) }
}

extension SoundTile {
    /// Builds a tile from a stored sound.
    ///
    /// The art colour is derived from the id so a sound without a decoded
    /// poster yet still lands on a stable colour rather than flickering
    /// between placeholders as the grid scrolls.
    public init(stored: StoredSound) {
        self.init(
            id: stored.id,
            title: stored.title,
            artHex: Self.placeholderArt(for: stored.id),
            duration: stored.duration,
            playCountLabel: ""
        )
    }

    /// The design's own placeholder swatches, chosen deterministically.
    static func placeholderArt(for id: String) -> UInt32 {
        let palette: [UInt32] = [
            0x3B4A8C, 0x7A3B52, 0x2F6F5E, 0x8A5A2B, 0x5A3B7A, 0x37566B,
            0x6B4A2F, 0x2F6B8A, 0x7D6CE0, 0xB0453F, 0x256054, 0xC9772A,
        ]
        let hash = id.unicodeScalars.reduce(UInt32(5381)) { ($0 &* 33) &+ $1.value }
        return palette[Int(hash % UInt32(palette.count))]
    }
}

/// Decoded posters for the grid, held by the view layer.
///
/// Backed by `PosterStore`, so the byte budget and the "never evict what is on
/// screen" rule apply here exactly as they do everywhere else.
@MainActor
public final class PosterProvider: ObservableObject {
    @Published private var images: [String: CGImage] = [:]
    private let store: PosterStore
    private let resolver: TileMediaResolving

    public init(resolver: TileMediaResolving, store: PosterStore = PosterStore()) {
        self.resolver = resolver
        self.store = store
    }

    public func image(for tileID: String) -> CGImage? { images[tileID] }

    /// Decodes posters for a page of tiles. Driven by scroll position.
    public func load(_ tiles: [SoundTile]) {
        for tile in tiles where images[tile.id] == nil {
            guard let url = resolver.posterURL(for: tile.id) else { continue }
            // A poster that will not decode leaves the tile on its placeholder
            // colour. A blank tile is a bug; a coloured one is a tile.
            guard let image = try? store.poster(for: tile.id, at: url) else { continue }
            images[tile.id] = image
        }
    }

    public func setVisible(_ visible: Bool, for ids: [String]) {
        store.setVisible(visible, for: ids)
    }

    public func handleMemoryPressure() {
        store.evictOffscreen()
        images = images.filter { store.contains($0.key) }
    }
}
