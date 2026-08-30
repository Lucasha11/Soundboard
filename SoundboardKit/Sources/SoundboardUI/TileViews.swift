import SwiftUI

/// The diagonal hatch that stands in for gif art throughout the design.
///
/// The prototype draws this with `repeating-linear-gradient(135deg, ...)`.
/// SwiftUI has no repeating gradient, so vertical bands are drawn once and the
/// whole context rotated, which is both exact and cheaper than stacking
/// gradient stops.
struct DiagonalStripes: View {
    var bandWidth: CGFloat = 5
    var period: CGFloat = 11
    var opacity: Double = 0.08

    var body: some View {
        Canvas { context, size in
            let extent = size.width + size.height
            context.translateBy(x: size.width / 2, y: size.height / 2)
            context.rotate(by: .degrees(45))
            context.translateBy(x: -extent / 2, y: -extent / 2)
            var x: CGFloat = 0
            while x < extent {
                context.fill(
                    Path(CGRect(x: x, y: 0, width: bandWidth, height: extent)),
                    with: .color(.white.opacity(opacity))
                )
                x += period
            }
        }
        .allowsHitTesting(false)
    }
}

/// Fires on touch-down rather than on release.
///
/// A SwiftUI `Button` acts on touch-up, and the gap between pressing and
/// lifting is long enough to be plainly audible on a soundboard. The whole
/// engine is built to a sub-30 ms budget, so giving that back at the last step
/// in the UI would waste it. A zero-distance drag gesture is the lightest
/// thing that reports the press itself.
struct FireOnTouchDown: ViewModifier {
    let action: () -> Void
    @State private var armed = true

    func body(content: Content) -> some View {
        content
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { _ in
                        guard armed else { return }
                        armed = false
                        action()
                    }
                    .onEnded { _ in armed = true }
            )
    }
}

extension View {
    func fireOnTouchDown(perform action: @escaping () -> Void) -> some View {
        modifier(FireOnTouchDown(action: action))
    }
}

/// Explore tile: square, 4 across, caption over placeholder art.
struct ExploreTileView: View {
    let tile: SoundTile
    let isFiring: Bool
    /// Decoded poster from the blob store. Absent for a sound whose poster has
    /// not been decoded yet, and for the design's own placeholder catalogue.
    var poster: CGImage?
    let onFire: () -> Void

    var body: some View {
        ZStack {
            if let poster {
                Image(decorative: poster, scale: 1)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .allowsHitTesting(false)
            } else {
                Color(hex: tile.artHex)
                DiagonalStripes()
                EllipticalGradient(
                    colors: [.white.opacity(0.12), .clear],
                    center: UnitPoint(x: 0.5, y: 0.34),
                    startRadiusFraction: 0,
                    endRadiusFraction: 0.7
                )
                .allowsHitTesting(false)
            }

            StrokedText(
                text: tile.title,
                font: DS.Fonts.display(11, .heavy),
                strokeWidth: 1.2
            )
            .padding(.horizontal, 3)

            VStack {
                Spacer()
                HStack {
                    Text(tile.durationLabel)
                        .font(DS.Fonts.mono(7.5))
                        .foregroundStyle(.white.opacity(0.72))
                        .padding(.horizontal, 3)
                        .padding(.vertical, 1)
                        .background(DS.Colors.badgeBackground, in: RoundedRectangle(cornerRadius: 3))
                    Spacer()
                }
            }
            .padding(4)

            // Playing state: lime ring plus a scrim. The ring is the only
            // tile-level feedback; per-tile progress bars were tried in the
            // design and removed.
            RoundedRectangle(cornerRadius: DS.Metrics.exploreTileRadius)
                .strokeBorder(DS.Colors.accent, lineWidth: 2)
                .background(
                    RoundedRectangle(cornerRadius: DS.Metrics.exploreTileRadius)
                        .fill(DS.Colors.tileScrim)
                )
                .opacity(isFiring ? 1 : 0)
                .animation(.easeInOut(duration: DS.Metrics.overlayFade), value: isFiring)
                .allowsHitTesting(false)
        }
        .aspectRatio(1, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: DS.Metrics.exploreTileRadius))
        .fireOnTouchDown(perform: onFire)
    }
}

/// Soundboard pad: 126pt square, 2 across, with edit and empty states.
struct BoardPadView: View {
    let index: Int
    let tile: SoundTile?
    let isFiring: Bool
    let isEditing: Bool
    var poster: CGImage?
    let onTap: () -> Void

    var body: some View {
        ZStack {
            if let tile {
                if let poster {
                    Image(decorative: poster, scale: 1)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .allowsHitTesting(false)
                } else {
                    Color(hex: tile.artHex)
                    DiagonalStripes(bandWidth: 6, period: 13)
                }
                // Bottom scrim so the index and play count stay readable over
                // any art.
                LinearGradient(
                    stops: [
                        .init(color: Color(hex: 0x090A0D, opacity: 0.72), location: 0),
                        .init(color: Color(hex: 0x090A0D, opacity: 0.05), location: 0.55),
                    ],
                    startPoint: .bottom,
                    endPoint: .top
                )
                .allowsHitTesting(false)

                StrokedText(
                    text: tile.title,
                    font: DS.Fonts.display(13, .heavy),
                    strokeWidth: 1.25
                )
                .padding(.horizontal, 6)

                VStack {
                    Spacer()
                    HStack {
                        Text("\(index + 1)")
                        Spacer()
                        Text(tile.playCountLabel)
                    }
                    .font(DS.Fonts.mono(7.5))
                    .foregroundStyle(.white.opacity(0.72))
                }
                .padding(6)
            } else {
                DS.Colors.bg
            }

            RoundedRectangle(cornerRadius: DS.Metrics.padRadius)
                .strokeBorder(DS.Colors.accent, lineWidth: 2)
                .background(
                    RoundedRectangle(cornerRadius: DS.Metrics.padRadius).fill(DS.Colors.padScrim)
                )
                .opacity(isFiring ? 1 : 0)
                .animation(.easeInOut(duration: DS.Metrics.overlayFade), value: isFiring)
                .allowsHitTesting(false)

            // Empty pad: the entry point for manual configuration.
            if tile == nil {
                ZStack {
                    RoundedRectangle(cornerRadius: DS.Metrics.padRadius)
                        .fill(DS.Colors.padEmptyScrim)
                    RoundedRectangle(cornerRadius: DS.Metrics.padRadius)
                        .strokeBorder(
                            DS.Colors.borderDashed,
                            style: StrokeStyle(lineWidth: 1, dash: [4, 3])
                        )
                    VStack(spacing: 3) {
                        Text("+")
                            .font(DS.Fonts.display(20, .regular))
                            .foregroundStyle(DS.Colors.accent)
                        Text("ADD SOUND")
                            .font(DS.Fonts.mono(7.5))
                            .foregroundStyle(DS.Colors.textMuted)
                    }
                }
                .allowsHitTesting(false)
            }

            // Remove affordance, only while editing a filled pad.
            if isEditing && tile != nil {
                VStack {
                    HStack {
                        ZStack {
                            Circle().fill(DS.Colors.text)
                            Text("\u{2212}")
                                .font(DS.Fonts.display(16, .bold))
                                .foregroundStyle(DS.Colors.bg)
                        }
                        .frame(width: 20, height: 20)
                        Spacer()
                    }
                    Spacer()
                }
                .padding(6)
                .allowsHitTesting(false)
            }
        }
        .frame(width: DS.Metrics.padSize, height: DS.Metrics.padSize)
        .clipShape(RoundedRectangle(cornerRadius: DS.Metrics.padRadius))
        .fireOnTouchDown(perform: onTap)
    }
}
