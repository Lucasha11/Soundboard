import Foundation

/// Stable identifiers for UI automation. A tap-coordinate-driven test breaks on
/// every layout change; these give XCUITest (or any other accessibility-tree
/// driver) something durable to address instead.
///
/// The UI test target is a separate process that talks to the app only
/// through the accessibility tree, so it cannot import this enum - its
/// string literals must be kept in sync with this file by hand.
public enum AccessibilityID {
    /// Carries the `DG-USER-04` tracking ledger as its accessibility value.
    /// Present only under the UI-test launch argument.
    public static let trackingLedger = "governance.trackingLedger"

    public static let tabBarExplore = "tabBar.explore"
    public static let tabBarBoard = "tabBar.board"

    public static let exploreRoot = "explore.root"
    public static let exploreAdCard = "explore.adCard"

    public static let boardRoot = "board.root"
    public static let boardBannerAdTop = "board.bannerAd.top"
    public static let boardBannerAdBottom = "board.bannerAd.bottom"
    public static let boardPersonalImportRow = "board.personalImportRow"
    public static let boardEditButton = "board.editButton"
    public static let fillPadSheet = "board.fillPadSheet"

    /// One identifier per pad, so a UI test can address a specific slot rather
    /// than a coordinate that moves with the layout.
    public static func boardPad(_ index: Int) -> String { "board.pad.\(index)" }
}
