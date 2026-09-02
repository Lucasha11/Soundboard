import Foundation

/// Mirror of `SoundboardKit/Sources/SoundboardUI/AccessibilityIdentifiers.swift`.
///
/// The UI test target is a separate process that reaches the app only through
/// the accessibility tree, so it cannot import the app's enum. These string
/// literals are kept in sync by hand; the checks in `UIChecks` assert the app
/// side, and a mismatch shows up here as an element that never appears.
enum AccessibilityID {
    static let trackingLedger = "governance.trackingLedger"

    static let tabBarExplore = "tabBar.explore"
    static let tabBarBoard = "tabBar.board"

    static let exploreRoot = "explore.root"
    static let exploreAdCard = "explore.adCard"

    static let boardRoot = "board.root"
    static let boardBannerAdTop = "board.bannerAd.top"
    static let boardBannerAdBottom = "board.bannerAd.bottom"
    static let boardPersonalImportRow = "board.personalImportRow"
    static let boardEditButton = "board.editButton"
    static let importFailureMessage = "board.importFailure"
    static let fillPadSheet = "board.fillPadSheet"
    static func boardPad(_ index: Int) -> String { "board.pad.\(index)" }
}

/// Launch arguments the app understands. All are test-only: a real launch
/// passes none of them.
enum LaunchArgument {
    /// Wipes the container so a run starts with an empty library.
    static let resetState = "--uitest-reset-state"
    /// Renders the `DG-USER-04` tracking ledger into the accessibility tree.
    static let observeTracking = "--uitest-observe-tracking"
    /// Skips bringing up the audio graph. These tests assert what is on
    /// screen; without this they would also depend on the simulator's audio
    /// daemon answering an IPC promptly, which is unrelated to anything they
    /// check and fails intermittently under load.
    static let silentAudio = "--uitest-silent-audio"
    /// Pins the locale so date-picker wheel values are deterministic in CI.
    static let pinnedLocale = ["-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
}
