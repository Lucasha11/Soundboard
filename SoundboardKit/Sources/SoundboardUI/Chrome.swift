import SwiftUI

/// Two tabs, lime when active.
struct TabBarView: View {
    let tab: Tab
    let select: (Tab) -> Void

    var body: some View {
        HStack(spacing: 4) {
            item(.explore, systemImage: "safari", label: "Explore")
            item(.board, systemImage: "square.grid.2x2", label: "Soundboard")
        }
        .padding(.horizontal, 22)
        .padding(.bottom, 14)
        .frame(height: DS.Metrics.tabBarHeight)
        .background(alignment: .top) {
            DS.Colors.surfaceSunken
                .overlay(alignment: .top) { DS.Colors.border.frame(height: 1) }
        }
    }

    private func item(_ target: Tab, systemImage: String, label: String) -> some View {
        VStack(spacing: 4) {
            // The design draws these as inline SVG: a compass rose and a 2x2
            // grid. The SF Symbols are the same shapes at the same weight and
            // come with the platform's own optical sizing.
            Image(systemName: systemImage)
                .font(.system(size: 21, weight: .medium))
            Text(label).font(DS.Fonts.display(10, .bold))
        }
        .foregroundStyle(tab == target ? DS.Colors.accent : DS.Colors.textDim)
        .frame(maxWidth: .infinity)
        .padding(.top, 10)
        .contentShape(Rectangle())
        .onTapGesture { select(target) }
    }
}

/// The five lime bars in the now-playing pill.
struct EqualizerBars: View {
    @State private var raised = false

    private static let delays: [Double] = [0, 0.11, 0.22, 0.33, 0.44]

    var body: some View {
        HStack(alignment: .bottom, spacing: 2) {
            ForEach(Array(Self.delays.enumerated()), id: \.offset) { _, delay in
                Capsule()
                    .fill(DS.Colors.accent)
                    .frame(width: 3, height: raised ? 17 : 6)
                    .animation(
                        .easeInOut(duration: 0.62)
                            .repeatForever(autoreverses: true)
                            .delay(delay),
                        value: raised
                    )
            }
        }
        .frame(height: 18)
        .onAppear { raised = true }
    }
}

/// Now-playing pill, floating above the tab bar while a clip fires.
struct NowPlayingPill: View {
    let title: String
    let isVisible: Bool
    /// Changes on every fire so the sweep restarts rather than sitting at the
    /// width the previous tap left it.
    let sequence: Int

    var body: some View {
        HStack(spacing: 9) {
            ZStack {
                Color(hex: 0x3B4A8C)
                DiagonalStripes(bandWidth: 4, period: 9, opacity: 0.10)
            }
            .frame(width: 34, height: 34)
            .clipShape(RoundedRectangle(cornerRadius: 6))

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(DS.Fonts.display(11.5, .bold))
                    .foregroundStyle(DS.Colors.text)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Text("GIF + AUDIO PLAYING")
                    .font(DS.Fonts.mono(8.5))
                    .kerning(0.5)
                    .foregroundStyle(DS.Colors.accent)
            }
            Spacer(minLength: 0)
            EqualizerBars()
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(DS.Colors.nowPlayingBackground)
        .overlay(alignment: .bottomLeading) { SweepBar(sequence: sequence, isVisible: isVisible) }
        .clipShape(RoundedRectangle(cornerRadius: 11))
        .overlay {
            RoundedRectangle(cornerRadius: 11).strokeBorder(DS.Colors.borderStrong, lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.9), radius: 15, x: 0, y: 12)
        .opacity(isVisible ? 1 : 0)
        .offset(y: isVisible ? 0 : 8)
        .animation(.easeInOut(duration: DS.Metrics.pillFade), value: isVisible)
        .allowsHitTesting(false)
    }
}

/// The lime progress sweep along the bottom of the pill.
private struct SweepBar: View {
    let sequence: Int
    let isVisible: Bool
    @State private var progress: CGFloat = 0

    var body: some View {
        GeometryReader { proxy in
            DS.Colors.accent
                .frame(width: proxy.size.width * progress, height: 3)
                .clipShape(UnevenRoundedRectangle(bottomTrailingRadius: 3, topTrailingRadius: 3))
        }
        .frame(height: 3)
        .opacity(isVisible ? 1 : 0)
        // Keyed on the fire sequence: re-running an animation to a value it
        // already holds does nothing, so a second tap inside the hold window
        // would leave the bar parked. Resetting to zero without animation and
        // then sweeping is what restarts it.
        .onChange(of: sequence) { _, _ in
            progress = 0
            withAnimation(.linear(duration: DS.Metrics.sweepDuration)) { progress = 1 }
        }
    }
}

/// The in-feed ad on Explore.
struct ExploreAdCard: View {
    var body: some View {
        HStack(spacing: 10) {
            ZStack {
                DS.Colors.surfaceRaised
                DiagonalStripes(bandWidth: 4, period: 9, opacity: 0.06)
                Text("AD\n52\u{00B2}")
                    .font(DS.Fonts.mono(7))
                    .foregroundStyle(DS.Colors.textFaint)
                    .multilineTextAlignment(.center)
            }
            .frame(width: 52, height: 52)
            .clipShape(RoundedRectangle(cornerRadius: 7))

            VStack(alignment: .leading, spacing: 3) {
                Text("Sound+ kills the ads")
                    .font(DS.Fonts.display(12.5, .bold))
                    .foregroundStyle(DS.Colors.text)
                Text("Offline boards, longer clips, 3 months free")
                    .font(DS.Fonts.display(11, .regular))
                    .foregroundStyle(DS.Colors.textMuted)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)

            VStack(alignment: .trailing, spacing: 5) {
                Text("Open")
                    .font(DS.Fonts.display(11, .bold))
                    .foregroundStyle(DS.Colors.accent)
                    .padding(.horizontal, 11)
                    .padding(.vertical, 6)
                    .overlay {
                        Capsule().strokeBorder(DS.Colors.accent, lineWidth: 1)
                    }
                Text("SPONSORED")
                    .font(DS.Fonts.mono(7.5))
                    .kerning(0.6)
                    .foregroundStyle(DS.Colors.textFaint)
            }
        }
        .padding(9)
        .background(DS.Colors.surfaceSunken)
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay { RoundedRectangle(cornerRadius: 10).strokeBorder(DS.Colors.border, lineWidth: 1) }
    }
}

/// The 320x50 banners at the top and bottom of the Soundboard tab.
struct BannerAdView: View {
    let title: String
    let callToAction: String
    let ctaIsAccent: Bool

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(DS.Fonts.display(12, .bold))
                    .foregroundStyle(DS.Colors.text)
                Text("AD \u{00B7} 320\u{00D7}50 BANNER")
                    .font(DS.Fonts.mono(8))
                    .kerning(0.64)
                    .foregroundStyle(DS.Colors.textFaint)
            }
            Spacer(minLength: 0)
            Text(callToAction)
                .font(DS.Fonts.display(10.5, .bold))
                .foregroundStyle(ctaIsAccent ? DS.Colors.accent : DS.Colors.textSecondary)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .overlay {
                    Capsule().strokeBorder(
                        ctaIsAccent ? DS.Colors.accent : DS.Colors.borderStrong,
                        lineWidth: 1
                    )
                }
        }
        .padding(.horizontal, 11)
        .frame(height: DS.Metrics.bannerAdHeight)
        .background {
            ZStack {
                DS.Colors.surfaceSunken
                DiagonalStripes(period: 11, opacity: 0.045)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay { RoundedRectangle(cornerRadius: 8).strokeBorder(DS.Colors.border, lineWidth: 1) }
    }
}
