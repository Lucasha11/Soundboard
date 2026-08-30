import SwiftUI

/// Tile captions: white text with a heavy black outline.
///
/// The design uses `-webkit-text-stroke` with `paint-order: stroke fill`, which
/// SwiftUI has no direct equivalent for. Drawing the string eight times in
/// black around the fill reproduces it closely enough at these sizes, and
/// `paint-order` is the reason the black passes go underneath rather than
/// eating into the glyph.
///
/// Eight directions rather than four: at 2.4px on tight sans-serif weights the
/// diagonals are where a four-pass outline visibly thins.
struct StrokedText: View {
    let text: String
    let font: Font
    let strokeWidth: CGFloat
    var fill: Color = .white
    var stroke: Color = .black

    private static let directions: [(CGFloat, CGFloat)] = [
        (-1, -1), (0, -1), (1, -1),
        (-1, 0), (1, 0),
        (-1, 1), (0, 1), (1, 1),
    ]

    var body: some View {
        ZStack {
            ForEach(Array(Self.directions.enumerated()), id: \.offset) { _, direction in
                label
                    .foregroundStyle(stroke)
                    .offset(x: direction.0 * strokeWidth, y: direction.1 * strokeWidth)
            }
            label.foregroundStyle(fill)
        }
    }

    private var label: some View {
        Text(text)
            .font(font)
            .multilineTextAlignment(.center)
            .lineSpacing(0)
    }
}
