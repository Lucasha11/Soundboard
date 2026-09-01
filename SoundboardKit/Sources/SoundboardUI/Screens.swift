import SwiftUI

// MARK: - Explore

struct ExploreView: View {
    @ObservedObject var model: BoardModel
    let poster: (String) -> CGImage?

    private let columns = Array(
        repeating: GridItem(.flexible(), spacing: DS.Metrics.exploreGridGap),
        count: DS.Metrics.exploreGridColumns
    )

    var body: some View {
        VStack(spacing: 0) {
            header
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(model.exploreSections.enumerated()), id: \.offset) { index, section in
                        sectionHeader(
                            title: index == 0 ? "Trending today" : "Memes of the week",
                            showsHint: index == 0,
                            topPadding: index == 0 ? 10 : 16
                        )
                        grid(section)
                        if model.showAds {
                            ExploreAdCard()
                                .padding(.top, 14)
                                .accessibilityElement(children: .contain)
                                .accessibilityIdentifier(AccessibilityID.exploreAdCard)
                        }
                    }
                }
                .padding(.horizontal, DS.Metrics.screenPadding)
                .padding(.top, 4)
                .padding(.bottom, 16)
            }
        }
        // A plain VStack does not collapse into one accessibility element, so
        // without `.contain` the identifier below leaks onto every descendant
        // instead of naming this container - `.contain` is what makes
        // `app.otherElements[...]` actually find it in a UI test.
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(AccessibilityID.exploreRoot)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .lastTextBaseline, spacing: 10) {
                Text("Explore")
                    .font(DS.Fonts.display(31, .black))
                    .kerning(-31 * 0.035)
                    .foregroundStyle(DS.Colors.text)
                Text("1,284 clips")
                    .font(DS.Fonts.mono(10))
                    .foregroundStyle(DS.Colors.textDim)
            }

            HStack(spacing: 8) {
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 15, weight: .bold))
                    Text("Search sounds and gifs").font(DS.Fonts.display(13, .regular))
                    Spacer(minLength: 0)
                }
                .foregroundStyle(DS.Colors.textDim)
                .padding(.horizontal, 12)
                .frame(height: 38)
                .background(DS.Colors.surface, in: Capsule())
                .overlay { Capsule().strokeBorder(DS.Colors.border, lineWidth: 1) }

                Image(systemName: "square.grid.2x2")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(DS.Colors.textSecondary)
                    .frame(width: 38, height: 38)
                    .background(DS.Colors.surface, in: Circle())
                    .overlay { Circle().strokeBorder(DS.Colors.border, lineWidth: 1) }
            }
            .padding(.top, 11)

            HStack(spacing: 7) {
                ForEach(["All", "Reactions", "Hype", "Fails", "Chat"], id: \.self) { name in
                    chip(name, selected: name == "All")
                }
            }
            .padding(.top, 11)
        }
        .padding(.horizontal, DS.Metrics.screenPadding)
        .padding(.top, DS.Metrics.exploreTopPadding)
        .padding(.bottom, 10)
    }

    private func chip(_ title: String, selected: Bool) -> some View {
        Text(title)
            .font(DS.Fonts.display(12, selected ? .bold : .semibold))
            .foregroundStyle(selected ? DS.Colors.bg : DS.Colors.textSecondary)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(selected ? DS.Colors.accent : DS.Colors.surface, in: Capsule())
            .overlay {
                if !selected { Capsule().strokeBorder(DS.Colors.border, lineWidth: 1) }
            }
            .fixedSize()
    }

    private func sectionHeader(title: String, showsHint: Bool, topPadding: CGFloat) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(title)
                .font(DS.Fonts.display(14, .heavy))
                .foregroundStyle(DS.Colors.text)
            if showsHint {
                Text("TAP TO FIRE")
                    .font(DS.Fonts.mono(9.5))
                    .foregroundStyle(DS.Colors.textFaint)
            }
            Spacer(minLength: 0)
            Text("See all")
                .font(DS.Fonts.display(11.5, .semibold))
                .foregroundStyle(DS.Colors.accent)
        }
        .padding(.top, topPadding)
        .padding(.bottom, 8)
    }

    private func grid(_ tiles: [SoundTile]) -> some View {
        LazyVGrid(columns: columns, spacing: DS.Metrics.exploreGridGap) {
            ForEach(tiles) { tile in
                ExploreTileView(
                    tile: tile,
                    isFiring: model.isFiring(tile.id),
                    poster: poster(tile.id),
                    onFire: { model.fire(tile) }
                )
            }
        }
    }
}

// MARK: - Soundboard

struct BoardView: View {
    @ObservedObject var model: BoardModel
    let poster: (String) -> CGImage?

    private let columns = Array(
        repeating: GridItem(.fixed(DS.Metrics.padSize), spacing: DS.Metrics.boardGridGap),
        count: DS.Metrics.boardGridColumns
    )

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 0) {
                if model.showAds {
                    BannerAdView(title: "Boards without ads", callToAction: "Try Sound+", ctaIsAccent: true)
                        .accessibilityElement(children: .contain)
                        .accessibilityIdentifier(AccessibilityID.boardBannerAdTop)
                }

                HStack(alignment: .lastTextBaseline, spacing: 10) {
                    Text("Soundboard")
                        .font(DS.Fonts.display(26, .black))
                        .kerning(-26 * 0.035)
                        .foregroundStyle(DS.Colors.text)
                    Spacer(minLength: 0)
                    Button(action: model.toggleEditing) {
                        HStack(spacing: 6) {
                            Image(systemName: "pencil").font(.system(size: 12, weight: .bold))
                            Text(model.editLabel).font(DS.Fonts.display(11.5, .bold))
                        }
                        .foregroundStyle(DS.Colors.text)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 7)
                        .background(DS.Colors.surface, in: Capsule())
                        .overlay { Capsule().strokeBorder(DS.Colors.borderStrong, lineWidth: 1) }
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier(AccessibilityID.boardEditButton)
                }
                .padding(.top, 14)

                HStack(spacing: 7) {
                    Circle().fill(DS.Colors.accent).frame(width: 5, height: 5)
                    Text(model.hintText)
                        .font(DS.Fonts.display(10.5, .regular))
                        .foregroundStyle(DS.Colors.textMuted)
                        .lineLimit(1)
                }
                .padding(.top, 8)
            }
            .padding(.horizontal, DS.Metrics.screenPadding)
            .padding(.top, DS.Metrics.boardTopPadding)

            // Eight pads, 2 across, sized to fit without scrolling.
            LazyVGrid(columns: columns, spacing: DS.Metrics.boardGridGap) {
                ForEach(Array(model.pads.enumerated()), id: \.offset) { index, tile in
                    BoardPadView(
                        index: index,
                        tile: tile,
                        isFiring: tile.map { model.isFiring($0.id) } ?? false,
                        isEditing: model.isEditing,
                        poster: tile.flatMap { poster($0.id) },
                        onTap: { model.tapPad(index) }
                    )
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(tile?.title ?? "Empty pad \(index + 1)")
                    .accessibilityIdentifier(AccessibilityID.boardPad(index))
                    .accessibilityAddTraits(.isButton)
                }
            }
            .padding(.horizontal, DS.Metrics.screenPadding)
            .padding(.vertical, 10)
            .frame(maxHeight: .infinity, alignment: .top)

            if model.showAds {
                BannerAdView(title: "Zephyr USB mic, $69", callToAction: "Shop", ctaIsAccent: false)
                    .padding(.horizontal, DS.Metrics.screenPadding)
                    .padding(.bottom, 8)
                    .accessibilityElement(children: .contain)
                    .accessibilityIdentifier(AccessibilityID.boardBannerAdBottom)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(AccessibilityID.boardRoot)
    }
}

// MARK: - Fill this pad

struct FillPadSheet: View {
    @ObservedObject var model: BoardModel

    private static let picks: [(String, UInt32)] = [
        ("chef kiss", 0x7D6CE0),
        ("grandma dunk", 0xB0453F),
        ("cowbell", 0x256054),
        ("cat lasagna", 0xC9772A),
    ]

    var body: some View {
        ZStack(alignment: .bottom) {
            DS.Colors.sheetScrim
                .ignoresSafeArea()
                .onTapGesture { model.closeSheet() }

            VStack(alignment: .leading, spacing: 0) {
                Capsule()
                    .fill(DS.Colors.borderDashed)
                    .frame(width: 38, height: 4)
                    .frame(maxWidth: .infinity)
                    .padding(.bottom, 12)

                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text("Fill this pad")
                        .font(DS.Fonts.display(15, .heavy))
                        .foregroundStyle(DS.Colors.text)
                    Text(model.slotLabel)
                        .font(DS.Fonts.mono(9))
                        .foregroundStyle(DS.Colors.textFaint)
                }

                Text("Pick from your saved clips, or browse Explore and tap the plus on any tile.")
                    .font(DS.Fonts.display(11.5, .regular))
                    .foregroundStyle(DS.Colors.textMuted)
                    .lineSpacing(2)
                    .padding(.top, 6)
                    .padding(.bottom, 12)

                LazyVGrid(
                    columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 4),
                    spacing: 6
                ) {
                    ForEach(Array(Self.picks.enumerated()), id: \.offset) { _, pick in
                        ZStack {
                            Color(hex: pick.1)
                            DiagonalStripes()
                            StrokedText(
                                text: pick.0,
                                font: DS.Fonts.display(10, .heavy),
                                strokeWidth: 1.1
                            )
                            .padding(.horizontal, 3)
                        }
                        .aspectRatio(3.0 / 4.0, contentMode: .fit)
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                        .fireOnTouchDown { model.fillOpenSlot() }
                    }
                }

                // The entry point to pairing a user's own gif with a sound,
                // which is the custom-import flow the backend already supports.
                HStack(spacing: 8) {
                    ZStack {
                        Circle().fill(DS.Colors.accent)
                        Text("+")
                            .font(DS.Fonts.display(17, .regular))
                            .foregroundStyle(DS.Colors.bg)
                    }
                    .frame(width: 26, height: 26)
                    Text("Pair your own gif with any sound")
                        .font(DS.Fonts.display(11.5, .regular))
                        .foregroundStyle(DS.Colors.textSecondary)
                    Spacer(minLength: 0)
                    Text("Build")
                        .font(DS.Fonts.display(11, .bold))
                        .foregroundStyle(DS.Colors.accent)
                }
                .padding(10)
                .overlay {
                    RoundedRectangle(cornerRadius: 9)
                        .strokeBorder(DS.Colors.borderDashed, style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
                }
                .padding(.top, 12)
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier(AccessibilityID.boardPersonalImportRow)
            }
            .padding(.horizontal, DS.Metrics.screenPadding)
            .padding(.top, 12)
            .padding(.bottom, 30)
            .background(DS.Colors.surface)
            .clipShape(UnevenRoundedRectangle(topLeadingRadius: 16, topTrailingRadius: 16))
            .overlay(alignment: .top) { DS.Colors.borderStrong.frame(height: 1) }
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier(AccessibilityID.fillPadSheet)
        }
    }
}

// MARK: - Root

public struct SoundboardRootView: View {
    @ObservedObject var model: BoardModel
    @ObservedObject var posters: PosterProvider

    public init(model: BoardModel, posters: PosterProvider) {
        self.model = model
        self.posters = posters
    }

    public var body: some View {
        ZStack {
            DS.Colors.bg.ignoresSafeArea()

            VStack(spacing: 0) {
                Group {
                    switch model.tab {
                    case .explore: ExploreView(model: model, poster: posters.image(for:))
                    case .board: BoardView(model: model, poster: posters.image(for:))
                    }
                }
                .frame(maxHeight: .infinity)

                TabBarView(tab: model.tab, select: model.select(tab:))
            }

            NowPlayingPill(
                title: model.nowPlayingTitle,
                isVisible: model.firing != nil,
                sequence: model.fireSequence
            )
            .padding(.horizontal, DS.Metrics.screenPadding)
            .frame(maxHeight: .infinity, alignment: .bottom)
            .padding(.bottom, DS.Metrics.nowPlayingBottomInset)

            if model.isSheetOpen {
                FillPadSheet(model: model)
                    .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: DS.Metrics.sheetFade), value: model.isSheetOpen)
        .foregroundStyle(DS.Colors.text)
        .preferredColorScheme(.dark)
        .publishingTrackingLedger()
    }
}
