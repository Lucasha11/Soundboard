import Foundation

/// One entry in the catalogue: a gif paired with a sound.
public struct SoundTile: Identifiable, Equatable, Sendable {
    public let id: String
    public let title: String
    /// Placeholder art colour. Real tiles render their poster instead; the
    /// design ships striped colour blocks because the gifs were not chosen yet.
    public let artHex: UInt32
    public let duration: TimeInterval
    /// Fires shown on a board pad, e.g. "412K".
    public let playCountLabel: String

    public init(id: String, title: String, artHex: UInt32, duration: TimeInterval, playCountLabel: String = "") {
        self.id = id
        self.title = title
        self.artHex = artHex
        self.duration = duration
        self.playCountLabel = playCountLabel
    }

    /// `0:02`, as the tile badge shows it.
    public var durationLabel: String {
        let seconds = Int(duration.rounded())
        return "0:\(String(format: "%02d", seconds))"
    }
}

public enum Tab: String, Sendable {
    case explore
    case board
}

/// Screen state for the two tabs, lifted out of the views so it can be checked
/// without a screen.
///
/// This is a direct port of the prototype's `renderVals` logic. The interesting
/// part is `tapPad`, where one gesture means three different things depending
/// on the pad and the mode, and getting that ordering wrong is invisible in a
/// static mockup.
@MainActor
public final class BoardModel: ObservableObject {
    @Published public private(set) var tab: Tab
    @Published public private(set) var isEditing = false
    /// Pads the user has cleared. Absent means the pad holds its sound.
    @Published public private(set) var clearedPads: Set<Int> = []
    /// Pad the "Fill this pad" sheet is open for, if any.
    @Published public private(set) var sheetSlot: Int?
    /// Tile currently firing, by id.
    @Published public private(set) var firing: String?
    @Published public private(set) var nowPlayingTitle: String = ""
    /// Flipped on every fire so the sweep animation restarts.
    ///
    /// The prototype needed this too: a transition to the same value does not
    /// re-run, so a second tap during the hold window would leave the bar
    /// frozen where the first tap left it.
    @Published public private(set) var fireSequence = 0

    @Published public private(set) var catalogue: [SoundTile]
    public let showAds: Bool

    /// Fires the actual sound. Injected so the model stays testable and so the
    /// view layer never talks to the audio engine directly.
    private let onFire: (SoundTile) -> Void

    /// Told when the user scrolls onto a different page, so the composition
    /// can move the prefetch horizon. Settable rather than injected because
    /// the composition that answers it does not exist yet when the model is
    /// built; the view layer still never talks to the engines directly.
    public var onVisiblePageChange: (Int) -> Void

    /// Where the two-file import has got to.
    ///
    /// The flow is two picks, not one: a user pairing a sound with a gif has
    /// two files, and the sheet has to hold the first while it asks for the
    /// second. Modelled here rather than in the view so the ordering, the
    /// cancel paths and the failure message are testable without a simulator.
    public enum ImportStage: Equatable {
        case idle
        /// Asking for the sound.
        case pickingAudio
        /// Sound chosen, asking for the picture.
        case pickingVisual(audio: URL)
        /// Both chosen, the pipeline is working.
        case importing
        /// Refused, with a message the user can act on. Never decoder text
        /// (`DG-LOG-01`).
        case failed(String)
    }

    @Published public private(set) var importStage: ImportStage = .idle

    /// Runs the paired import. Injected, so the view layer never touches the
    /// library and the model stays testable.
    public var onImport: (URL, URL) async -> String? = { _, _ in "Import is not available." }

    /// The page the user is looking at. Drives which tiles stay in memory
    /// (`BACKEND_PLAN.md` Section 6).
    public private(set) var visiblePage = 0
    private let horizon = PrefetchHorizon()
    private var holdTask: Task<Void, Never>?

    public init(
        catalogue: [SoundTile],
        showAds: Bool = true,
        startTab: Tab = .explore,
        onFire: @escaping (SoundTile) -> Void = { _ in },
        onVisiblePageChange: @escaping (Int) -> Void = { _ in }
    ) {
        self.catalogue = catalogue
        self.showAds = showAds
        self.tab = startTab
        self.onFire = onFire
        self.onVisiblePageChange = onVisiblePageChange
    }

    // MARK: - Import flow

    /// Starts the two-file import from the fill sheet.
    public func beginImport() {
        importStage = .pickingAudio
    }

    /// The user picked a sound. Ask for the picture next.
    public func pickedAudio(_ url: URL) {
        importStage = .pickingVisual(audio: url)
    }

    /// The user picked a picture, so both halves are in hand.
    public func pickedVisual(_ url: URL) {
        guard case let .pickingVisual(audio) = importStage else {
            // A visual arriving without a sound means the flow was cancelled
            // or restarted underneath us. Dropping it is right: importing a
            // picture with no sound would make a silent tile.
            importStage = .idle
            return
        }
        importStage = .importing
        Task { [onImport] in
            let failure = await onImport(audio, url)
            await MainActor.run {
                if let failure {
                    self.importStage = .failed(failure)
                } else {
                    self.importStage = .idle
                    self.closeSheet()
                }
            }
        }
    }

    /// The user backed out of either picker.
    public func cancelImport() {
        importStage = .idle
    }

    /// Dismisses a failure message without losing the sheet.
    public func acknowledgeImportFailure() {
        if case .failed = importStage { importStage = .idle }
    }

    public var isPickingAudio: Bool {
        if case .pickingAudio = importStage { return true }
        return false
    }

    public var isPickingVisual: Bool {
        if case .pickingVisual = importStage { return true }
        return false
    }

    public var importFailureMessage: String? {
        if case let .failed(message) = importStage { return message }
        return nil
    }

    /// Reported by each tile as it comes on screen.
    ///
    /// Deliberately driven by what actually appeared rather than by a scroll
    /// offset: offsets need the row height, the section headers and the ad
    /// cards all accounted for, and every one of those is a chance to be a
    /// page out. A tile appearing is the ground truth.
    ///
    /// Only a *change* of page is forwarded, because `onAppear` fires for
    /// every tile in a row and re-preloading the same horizon on each one
    /// would be the scroll stutter this phase exists to prevent.
    public func tileAppeared(at index: Int) {
        let page = horizon.page(ofIndex: index)
        guard page != visiblePage else { return }
        visiblePage = page
        onVisiblePageChange(page)
    }

    // MARK: - Derived

    /// The eight pads. A cleared pad reads as empty.
    public var pads: [SoundTile?] {
        (0..<DS.Metrics.padCount).map { index in
            guard !clearedPads.contains(index), index < catalogue.count else { return nil }
            return catalogue[index]
        }
    }

    public var editLabel: String { isEditing ? "Done" : "Edit board" }

    public var hintText: String {
        isEditing
            ? "Tap a pad to clear it, then tap the empty pad to place a new gif and sound."
            : "Starting set: this week's 8 most fired combos. Tap Edit board to make it yours."
    }

    public var slotLabel: String {
        guard let sheetSlot else { return "PAD" }
        return "PAD \(sheetSlot + 1) OF \(DS.Metrics.padCount)"
    }

    public var isSheetOpen: Bool { sheetSlot != nil }

    public func isFiring(_ id: String) -> Bool { firing == id }

    /// Explore sections: twelve tiles, an ad, twelve more, an ad.
    public var exploreSections: [[SoundTile]] {
        stride(from: 0, to: catalogue.count, by: DS.Metrics.tilesPerSection).map { start in
            Array(catalogue[start..<min(start + DS.Metrics.tilesPerSection, catalogue.count)])
        }
    }

    // MARK: - Intents

    public func select(tab: Tab) {
        self.tab = tab
        // Leaving the board drops edit mode, so returning to it is never a
        // surprise armed state where the next tap deletes a pad.
        if tab == .explore { isEditing = false }
    }

    public func toggleEditing() { isEditing.toggle() }

    /// Swaps in a new catalogue, after an import or a delete.
    ///
    /// Cleared pads are dropped rather than carried over: the indices they
    /// referred to point at different sounds now, so keeping them would blank
    /// out arbitrary pads.
    public func setCatalogue(_ tiles: [SoundTile]) {
        catalogue = tiles
        clearedPads = []
        sheetSlot = nil
    }

    public func closeSheet() { sheetSlot = nil }

    /// Fires a tile from Explore.
    public func fire(_ tile: SoundTile) {
        onFire(tile)
        firing = tile.id
        nowPlayingTitle = tile.title
        fireSequence += 1
        holdTask?.cancel()
        holdTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(DS.Metrics.fireHoldDuration))
            guard !Task.isCancelled else { return }
            self?.firing = nil
        }
    }

    /// A pad tap means one of three things, and the order matters.
    ///
    /// An empty pad opens the fill sheet whether or not edit mode is on,
    /// because tapping a plus that does nothing until you find the right mode
    /// is the kind of thing that reads as broken. Only a pad that still holds a
    /// sound is clearable, and only while editing.
    public func tapPad(_ index: Int) {
        guard index < DS.Metrics.padCount else { return }
        if clearedPads.contains(index) {
            sheetSlot = index
            return
        }
        if isEditing {
            clearedPads.insert(index)
            return
        }
        guard index < catalogue.count else { return }
        fire(catalogue[index])
    }

    /// Sheet selection fills the pad it was opened for.
    public func fillOpenSlot() {
        guard let slot = sheetSlot else { return }
        clearedPads.remove(slot)
        sheetSlot = nil
    }

    deinit { holdTask?.cancel() }
}

/// The 24 clips the prototype ships, in order. Titles and durations are the
/// design's; the art colours are its placeholder swatches.
public enum SampleCatalogue {
    public static let tiles: [SoundTile] = [
        SoundTile(id: "e0", title: "slow clap", artHex: 0x3B4A8C, duration: 2, playCountLabel: "412K"),
        SoundTile(id: "e1", title: "the fridge scream", artHex: 0x7A3B52, duration: 3, playCountLabel: "388K"),
        SoundTile(id: "e2", title: "bro really said that", artHex: 0x2F6F5E, duration: 4, playCountLabel: "351K"),
        SoundTile(id: "e3", title: "toaster fanfare", artHex: 0x8A5A2B, duration: 2, playCountLabel: "309K"),
        SoundTile(id: "e4", title: "gremlin giggle", artHex: 0x5A3B7A, duration: 1, playCountLabel: "284K"),
        SoundTile(id: "e5", title: "wet dog shake", artHex: 0x37566B, duration: 3, playCountLabel: "266K"),
        SoundTile(id: "e6", title: "keyboard rage", artHex: 0x6B4A2F, duration: 5, playCountLabel: "241K"),
        SoundTile(id: "e7", title: "victory kazoo", artHex: 0x2F6B8A, duration: 2, playCountLabel: "218K"),
        SoundTile(id: "e8", title: "chair collapse", artHex: 0x8C3B4A, duration: 4),
        SoundTile(id: "e9", title: "polite disagree", artHex: 0x4A5A2F, duration: 2),
        SoundTile(id: "e10", title: "goat yell", artHex: 0x6B2F5A, duration: 2),
        SoundTile(id: "e11", title: "mic drop stomp", artHex: 0x2F4A6B, duration: 4),
        SoundTile(id: "e12", title: "double take", artHex: 0x7D6CE0, duration: 2),
        SoundTile(id: "e13", title: "grandma dunk", artHex: 0xB0453F, duration: 3),
        SoundTile(id: "e14", title: "surprise cowbell", artHex: 0x256054, duration: 1),
        SoundTile(id: "e15", title: "chef kiss", artHex: 0xC9772A, duration: 2),
        SoundTile(id: "e16", title: "yeah okay", artHex: 0x3B4A8C, duration: 2),
        SoundTile(id: "e17", title: "cat lasagna", artHex: 0x7A3B52, duration: 3),
        SoundTile(id: "e18", title: "sad trombone", artHex: 0x2F6F5E, duration: 4),
        SoundTile(id: "e19", title: "airhorn intro", artHex: 0x8A5A2B, duration: 3),
        SoundTile(id: "e20", title: "kitchen disaster", artHex: 0x5A3B7A, duration: 3),
        SoundTile(id: "e21", title: "slow motion trip", artHex: 0x37566B, duration: 4),
        SoundTile(id: "e22", title: "unearned confidence", artHex: 0x6B4A2F, duration: 2),
        SoundTile(id: "e23", title: "tiny victory horn", artHex: 0x2F6B8A, duration: 1),
    ]
}
