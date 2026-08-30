import SwiftUI

/// Values transcribed from `design/soundboard-iphone-mobile-handoff/project/Soundboard iPhone.dc.html`.
///
/// Every number here appears literally in that file. They are named rather than
/// inlined so a design change is a diff against the spec instead of a hunt
/// through view code.
public enum DS {

    // MARK: - Colour

    public enum Colors {
        /// App background inside the device frame.
        public static let bg = Color(hex: 0x101216)
        /// Page background outside the frame, used by previews.
        public static let canvas = Color(hex: 0x0B0C0F)
        /// Cards, chips, search field.
        public static let surface = Color(hex: 0x181B21)
        /// Tab bar and ad cards, one step darker than `surface`.
        public static let surfaceSunken = Color(hex: 0x14161B)
        public static let surfaceRaised = Color(hex: 0x22262E)

        public static let border = Color(hex: 0x262A31)
        public static let borderStrong = Color(hex: 0x2F353D)
        public static let borderDashed = Color(hex: 0x3D444E)

        public static let text = Color(hex: 0xE8EAED)
        public static let textSecondary = Color(hex: 0xB6BCC4)
        public static let textMuted = Color(hex: 0x8B9099)
        public static let textDim = Color(hex: 0x6F757E)
        public static let textFaint = Color(hex: 0x5C6169)

        /// The single accent. Playing rings, active tab, every call to action.
        public static let accent = Color(hex: 0xC8FF2E)

        /// Scrim over a tile while it is firing.
        public static let tileScrim = Color(hex: 0x090A0D, opacity: 0.34)
        /// Scrim over a board pad while it is firing, slightly lighter.
        public static let padScrim = Color(hex: 0x090A0D, opacity: 0.30)
        /// Empty pad cover in edit mode.
        public static let padEmptyScrim = Color(hex: 0x090A0D, opacity: 0.66)
        public static let badgeBackground = Color(hex: 0x090A0D, opacity: 0.60)
        public static let sheetScrim = Color(hex: 0x090A0D, opacity: 0.60)
        public static let nowPlayingBackground = Color(hex: 0x14161B, opacity: 0.94)
    }

    // MARK: - Type
    //
    // The design calls for Archivo and JetBrains Mono. Neither ships with iOS,
    // so both must be bundled with the app and declared in its Info.plist. The
    // `custom(_:size:)` calls fall back to the system face when the font is
    // absent, which is why a missing font shows up as slightly wrong metrics
    // rather than a crash. See README in this target.

    public enum Fonts {
        public static let displayFamily = "Archivo"
        public static let monoFamily = "JetBrains Mono"

        public static func display(_ size: CGFloat, _ weight: Font.Weight) -> Font {
            .custom(displayFamily, size: size).weight(weight)
        }

        public static func mono(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
            .custom(monoFamily, size: size).weight(weight)
        }
    }

    // MARK: - Metrics

    public enum Metrics {
        /// iPhone 16 Pro logical size, from the `hint-size` on the design's
        /// `IOSDevice` frame import.
        public static let deviceSize = CGSize(width: 402, height: 874)

        public static let screenPadding: CGFloat = 14
        /// Explore clears the status bar and Dynamic Island.
        public static let exploreTopPadding: CGFloat = 58
        public static let boardTopPadding: CGFloat = 52

        public static let exploreGridColumns = 4
        public static let exploreGridGap: CGFloat = 6
        public static let exploreTileRadius: CGFloat = 12
        /// Twelve tiles, an ad, twelve more, another ad.
        public static let tilesPerSection = 12

        public static let boardGridColumns = 2
        public static let boardGridGap: CGFloat = 8
        /// Fixed, not proportional. The pads were sized down to exactly this so
        /// all eight fit one screen without scrolling.
        public static let padSize: CGFloat = 126
        public static let padRadius: CGFloat = 14
        public static let padCount = 8

        public static let tabBarHeight: CGFloat = 64
        public static let bannerAdHeight: CGFloat = 52
        public static let nowPlayingBottomInset: CGFloat = 78

        /// Playing state holds for this long, then clears.
        public static let fireHoldDuration: TimeInterval = 1.7
        /// The lime bar sweeps the pill over this long.
        public static let sweepDuration: TimeInterval = 1.45
        public static let overlayFade: TimeInterval = 0.12
        public static let pillFade: TimeInterval = 0.16
        public static let sheetFade: TimeInterval = 0.18
    }
}

extension Color {
    /// `0xRRGGBB` literal, which is how the spec writes every colour.
    init(hex: UInt32, opacity: Double = 1) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255,
            opacity: opacity
        )
    }
}
