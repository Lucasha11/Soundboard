import CoreVideo
import SwiftUI
import VisualEngine

/// Renders a firing tile's animation, a frame at a time.
///
/// This is the piece that was missing. `VisualEngine`, `AnimationSession` and
/// `DecodeSessionPool` were all built and covered, `SoundboardController.fire`
/// called into them - and nothing ever displayed the result. `lastVisual` and
/// `lastSchedule` were written and never read, `nextFrame()` was never called,
/// and `endAnimation` was never called either, so a session was acquired on
/// every fire and only released when the pool's cap forced it out. Tiles showed
/// a static poster and the gif never moved.
///
/// Frames are pulled on a display-synced timeline rather than buffered: at tile
/// size one BGRA frame is about 2 MB, so a two second tile decoded up front is
/// 120 MB for a single tile.
struct TileAnimationView: View {
    /// Looked up per tick rather than passed in, because the session is
    /// acquired asynchronously after the tap: the tile starts rendering the
    /// moment the decoder is ready, with no observation plumbing in between.
    let session: () -> AnimationSession?
    /// Shown until the first frame arrives, and again once the clip ends, so a
    /// tile never flashes empty.
    let poster: CGImage?

    @State private var frame: CGImage?

    var body: some View {
        TimelineView(.animation) { context in
            let image = frame ?? poster
            Group {
                if let image {
                    Image(decorative: image, scale: 1)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                } else {
                    Color.black
                }
            }
            // The timeline ticks with the display and each tick pulls at most
            // one frame. The session is the clock: when it runs dry the tile
            // settles back onto its poster.
            .onChange(of: context.date) { _, _ in
                if let next = pull() { frame = next }
            }
        }
    }

    /// Pulls the next decoded frame, if one is ready.
    ///
    /// Returns `nil` rather than blocking when the decoder has nothing yet:
    /// dropping a frame is invisible, while waiting on a decode inside a view
    /// update is a dropped scroll.
    private func pull() -> CGImage? {
        guard let next = session()?.nextFrame() else { return nil }
        return Self.image(from: next.pixelBuffer)
    }

    private static func image(from buffer: CVPixelBuffer) -> CGImage? {
        var out: CGImage?
        VTCreateCGImageFromCVPixelBufferShim(buffer, &out)
        return out
    }
}

/// `VTCreateCGImageFromCVPixelBuffer` lives in VideoToolbox and is not
/// available everywhere the package builds, so the conversion goes through
/// Core Image, which is.
private func VTCreateCGImageFromCVPixelBufferShim(_ buffer: CVPixelBuffer, _ out: inout CGImage?) {
    let ciImage = CIImage(cvPixelBuffer: buffer)
    let context = SharedCIContext.shared
    out = context.createCGImage(ciImage, from: ciImage.extent)
}

/// One context for the whole app. Creating a `CIContext` per frame allocates a
/// Metal command queue each time, which is exactly the per-frame cost this
/// layer exists to avoid.
private enum SharedCIContext {
    static let shared = CIContext(options: [.useSoftwareRenderer: false])
}
