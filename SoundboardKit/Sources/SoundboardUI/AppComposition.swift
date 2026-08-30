import Foundation
import GovernanceKit
import PlaybackEngine
import SoundLibrary
import VisualEngine

/// Builds the object graph the app runs on.
///
/// Kept out of the `@main` shell so it compiles and can be checked. The shell
/// itself is a few lines that this type does the work for.
@MainActor
public final class SoundboardComposition: ObservableObject {
    public let library: SoundLibrary
    public let controller: SoundboardController
    public let posters: PosterProvider
    public let model: BoardModel

    /// - Parameter root: the app container. On device this is Application
    ///   Support, which is not user-visible in Files and is excluded from
    ///   backup by the blob store.
    public init(root: URL, showAds: Bool = true) throws {
        let library = try SoundLibrary(root: root)
        // Anything left by an interrupted import goes at launch.
        _ = try? library.sweep()

        let resolver = LibraryMediaResolver(library: library)
        let controller = SoundboardController(resolver: resolver)
        let posters = PosterProvider(resolver: resolver)

        let tiles = Self.tiles(from: library)
        let model = BoardModel(
            catalogue: tiles,
            showAds: showAds,
            onFire: { [controller] tile in controller.fire(tile) }
        )

        self.library = library
        self.controller = controller
        self.posters = posters
        self.model = model

        try? controller.prepare()
        controller.preload(tiles)
        posters.load(tiles)
    }

    /// The user's own sounds, or the design's placeholder set while the library
    /// is empty.
    ///
    /// An empty grid on first launch would be an honest but useless first
    /// impression. The placeholders are silent, because nothing resolves media
    /// for them, which is the one thing to fix before this ships.
    private static func tiles(from library: SoundLibrary) -> [SoundTile] {
        let stored = library.sounds.map(SoundTile.init(stored:))
        return stored.isEmpty ? SampleCatalogue.tiles : stored
    }

    /// Re-reads the library after an import or a delete.
    public func refresh() {
        let tiles = Self.tiles(from: library)
        model.setCatalogue(tiles)
        controller.preload(tiles)
        posters.load(tiles)
    }

    /// Imports a clip the user picked, then refreshes the grid.
    @discardableResult
    public func importClip(
        from url: URL,
        start: TimeInterval,
        duration: TimeInterval,
        title: String
    ) async throws -> StoredSound {
        let stored = try await library.importClip(
            from: url, start: start, duration: duration, title: title
        )
        refresh()
        return stored
    }

    public func handleMemoryPressure() {
        controller.handleMemoryPressure()
        posters.handleMemoryPressure()
    }

    /// Application Support, created if absent. The container the app ships with.
    public static func defaultRoot() throws -> URL {
        let base = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let root = base.appendingPathComponent("Soundboard", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }
}
