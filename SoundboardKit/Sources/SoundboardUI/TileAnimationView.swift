import CoreImage
import CoreVideo
import SwiftUI
import VisualEngine

/// Renders a firing tile's animation, paced against the sound.
///
/// Two separate things had to be true for a tile to animate, and each was
/// missing on its own.
///
/// First, something had to display the frames at all. `VisualEngine`,
/// `AnimationSession` and `DecodeSessionPool` were built and covered,
/// `SoundboardController.fire` called into them, and nothing ever showed the
/// result: `nextFrame()` was never called and `endAnimation` never released
/// the decoder.
///
/// Second - and this is the part that is easy to get wrong twice - the frames
/// have to be *paced*. Pulling one frame per display tick looks correct on a
/// 60 Hz simulator and is badly wrong on a 120 Hz phone: a 30 fps clip runs at
/// four times speed and finishes in a quarter of the time, while the audio
/// plays at normal speed. Each frame carries its own presentation offset, and
/// the clip is anchored to the instant the audio actually starts, so picture
/// and sound stay together on any display rate. That anchor is what
/// `FrameSchedule` was for.
struct TileAnimationView: View {
    /// Looked up per tick rather than passed in, because the session is
    /// acquired asynchronously after the tap: the tile starts rendering the
    /// moment the decoder is ready, with no observation plumbing in between.
    let session: () -> AnimationSession?
    /// The host-clock instant the audio starts. Frames are due relative to
    /// this, never to when this view happened to appear.
    let audioStart: () -> TimeInterval?
    /// Shown until the first frame is due, and again once the clip ends, so a
    /// tile never flashes empty.
    let poster: CGImage?

    @State private var frame: CGImage?
    /// Decoded but not yet due. Holding one frame back is what turns "as fast
    /// as the display ticks" into "at the rate it was encoded".
    @State private var pending: (image: CGImage, offset: TimeInterval)?

    var body: some View {
        TimelineView(.animation) { context in
            Group {
                if let image = frame ?? poster {
                    Image(decorative: image, scale: 1)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                } else {
                    Color.black
                }
            }
            .onChange(of: context.date) { _, _ in advance() }
        }
    }

    /// Shows the pending frame if it is due, then decodes at most one more.
    ///
    /// At most one decode per tick on purpose: decoding ahead would buffer
    /// frames that are 2 MB each at tile size, which is the cost this whole
    /// layer exists to avoid.
    private func advance() {
        guard let session = session() else { return }
        let elapsed = ProcessInfo.processInfo.systemUptime - (audioStart() ?? ProcessInfo.processInfo.systemUptime)

        if let held = pending, held.offset <= elapsed {
            frame = held.image
            pending = nil
        }
        guard pending == nil, let next = session.nextFrame() else { return }
        guard let image = Self.image(from: next.pixelBuffer) else { return }
        if next.offset <= elapsed {
            // Already due, which happens on the first frame and after a
            // dropped tick. Showing it immediately is right: the clip should
            // catch up to the sound rather than drift behind it.
            frame = image
        } else {
            pending = (image, next.offset)
        }
    }

    private static func image(from buffer: CVPixelBuffer) -> CGImage? {
        let ciImage = CIImage(cvPixelBuffer: buffer)
        return SharedCIContext.shared.createCGImage(ciImage, from: ciImage.extent)
    }
}

/// One context for the whole app. Creating a `CIContext` per frame allocates a
/// Metal command queue each time, which is exactly the per-frame cost this
/// layer exists to avoid.
private enum SharedCIContext {
    static let shared = CIContext(options: [.useSoftwareRenderer: false])
}
