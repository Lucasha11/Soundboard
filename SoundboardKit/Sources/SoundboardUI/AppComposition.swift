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

    /// The scheduled deleter, run once per launch. `PLAN.md` Step 1.3 wants it
    /// alive from day one, against a store that is mostly empty.
    private let retention: RetentionWorker

    /// Non-nil if the launch sweep failed. A failed sweep is a compliance
    /// problem, not a reason to refuse the user their soundboard, so it is
    /// surfaced rather than thrown - and it is never swallowed, which is what
    /// `try?` here would amount to.
    public private(set) var retentionFailure: String?

    /// - Parameters:
    ///   - root: the app container. On device this is Application Support,
    ///     which is not user-visible in Files and is excluded from backup by
    ///     the blob store.
    ///   - showAds: `DG-USER-03` permits advertising at v2.0, subject to ATT
    ///     and the CCPA opt-out. There is no age bracket to consult: v2.0
    ///     removed the age gate and the app is rated 12+ (`DG-USER-01`).
    ///   - warmsAudio: brings the `AVAudioEngine` graph up at launch. UI tests
    ///     turn this off: they assert what is on screen, and bringing up
    ///     AURemoteIO makes them depend on the simulator's audio daemon
    ///     answering promptly, which is a dependency none of them need and a
    ///     source of flakiness that has nothing to do with what they check.
    public init(
        root: URL,
        showAds: Bool = true,
        warmsAudio: Bool = true
    ) throws {
        let library = try SoundLibrary(root: root)
        // Anything left by an interrupted import goes at launch.
        _ = try? library.sweep()

        let retention = RetentionWorker(auditURL: root.appendingPathComponent("retention_audit.json"))
        var retentionFailure: String?
        do {
            try retention.run()
        } catch {
            retentionFailure = RedactingLogger.scrubbedForDisplay(String(describing: error))
        }

        let resolver = LibraryMediaResolver(library: library)
        let controller = SoundboardController(
            playback: PlaybackEngine(session: Self.audioSession()),
            resolver: resolver
        )
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
        self.retention = retention
        self.retentionFailure = retentionFailure

        if warmsAudio { controller.warmUp() }
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

    /// Every retention sweep this container has recorded. `PLAN.md` Phase 7's
    /// quarterly retention verification reads this.
    public func retentionAuditTrail() -> [RetentionRun] {
        retention.auditTrail()
    }

    public func handleMemoryPressure() {
        controller.handleMemoryPressure()
        posters.handleMemoryPressure()
    }

    /// The audio session the engine runs under.
    ///
    /// `PlaybackEngine` defaults to `NullAudioSession`, which is right for
    /// checks and for macOS but wrong for the app: on iOS, bringing up
    /// `AVAudioEngine` without an active session leaves `AURemoteIO`
    /// negotiating with the audio server on no agreed format, and that call
    /// times out - which AudioToolbox reports by aborting the process. It is
    /// also what `BACKEND_PLAN.md` Section 5 asks for and was not getting:
    /// `.playback` so a tile is audible with the ringer switch off, and a 5 ms
    /// IO buffer, which is a third of the entire tap-to-sound budget.
    private static func audioSession() -> AudioSessionControlling {
        #if os(iOS)
        return SystemAudioSession()
        #else
        return NullAudioSession()
        #endif
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
