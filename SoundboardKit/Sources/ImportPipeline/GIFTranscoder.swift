import AVFoundation
import CoreGraphics
import Foundation
import GovernanceKit
import ImageIO
import UniformTypeIdentifiers

/// Turns an animated GIF into the tile's canonical visual pair: an H.264 mp4
/// with no audio track, and a poster still.
///
/// `BACKEND_PLAN.md` 4.3 calls this "the important one", and the reason is
/// memory: 24 animated GIFs on screen means 24 independent `CGImageSource`
/// decode loops, which will not survive a scroll on an older device. Converting
/// once at import means the idle grid is 24 static HEIC posters and only the
/// firing tiles hold a video decode session.
///
/// `AVFoundation` cannot read an animated GIF at all - `AVURLAsset` finds no
/// tracks in one - so the frames come from `ImageIO` and are encoded by hand.
public struct GIFTranscoder {
    private let caps: ImportCaps

    public init(caps: ImportCaps = .standard) {
        self.caps = caps
    }

    /// One decoded source frame and how long it is shown.
    struct Frame {
        let image: CGImage
        let delay: TimeInterval
    }

    /// Decodes frames and per-frame delays.
    ///
    /// Hostile input, so every count is capped as it is read rather than after
    /// (`DG-SEC-04`): a file claiming ten thousand frames is refused on the
    /// frame that crosses the cap, not once all ten thousand are in memory.
    static func decode(url: URL, caps: ImportCaps) throws -> [Frame] {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else {
            throw ImportFailureCode.unreadableFile
        }
        let count = CGImageSourceGetCount(source)
        guard count > 0 else { throw ImportFailureCode.unreadableFile }
        guard count <= caps.maxFrameCount else { throw ImportFailureCode.frameCountTooHigh }

        var frames: [Frame] = []
        frames.reserveCapacity(count)
        for index in 0..<count {
            guard let image = CGImageSourceCreateImageAtIndex(source, index, nil) else { continue }
            guard image.width <= caps.maxPixelDimension, image.height <= caps.maxPixelDimension else {
                throw ImportFailureCode.dimensionsTooLarge
            }
            frames.append(Frame(image: image, delay: Self.delay(of: source, at: index)))
        }
        guard !frames.isEmpty else { throw ImportFailureCode.decodeFailed }
        return frames
    }

    /// GIF delays are stored in hundredths of a second and are routinely
    /// nonsense: 0 means "as fast as possible", which every renderer treats as
    /// 100 ms instead. Copying that convention keeps imported gifs playing at
    /// the speed the user saw them at.
    private static func delay(of source: CGImageSource, at index: Int) -> TimeInterval {
        let properties = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any]
        let gif = properties?[kCGImagePropertyGIFDictionary] as? [CFString: Any]
        let unclamped = gif?[kCGImagePropertyGIFUnclampedDelayTime] as? Double
        let clamped = gif?[kCGImagePropertyGIFDelayTime] as? Double
        let value = unclamped ?? clamped ?? 0
        return value < 0.011 ? 0.1 : value
    }

    /// The frame with the most visual energy, used as the poster.
    ///
    /// Frame 0 is the obvious choice and the wrong one: a great many gifs open
    /// on black or on a fade-in, so the grid would be a wall of dark squares.
    /// Luma variance is a cheap stand-in for "something is happening here".
    static func posterIndex(of frames: [Frame]) -> Int {
        var best = 0
        var bestScore = -1.0
        for (index, frame) in frames.enumerated() {
            let score = Self.energy(of: frame.image)
            if score > bestScore {
                bestScore = score
                best = index
            }
        }
        return best
    }

    /// Variance of a small greyscale sample. Downsampled hard, because this
    /// runs once per frame and the answer only has to rank them.
    private static func energy(of image: CGImage) -> Double {
        let side = 16
        var pixels = [UInt8](repeating: 0, count: side * side)
        guard let context = CGContext(
            data: &pixels, width: side, height: side, bitsPerComponent: 8, bytesPerRow: side,
            space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue
        ) else { return 0 }
        context.draw(image, in: CGRect(x: 0, y: 0, width: side, height: side))

        let values = pixels.map(Double.init)
        let mean = values.reduce(0, +) / Double(values.count)
        return values.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Double(values.count)
    }

    /// Aspect-fills a frame into the square tile canvas.
    ///
    /// Fill rather than fit: a letterboxed tile looks broken next to its
    /// neighbours, and a vertical phone-camera gif is the common case.
    static func square(_ image: CGImage, side: Int) -> CGImage? {
        guard let context = CGContext(
            data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue
        ) else { return nil }

        context.interpolationQuality = .high
        context.setFillColor(gray: 0, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: side, height: side))

        let scale = max(Double(side) / Double(image.width), Double(side) / Double(image.height))
        let width = Double(image.width) * scale
        let height = Double(image.height) * scale
        context.draw(image, in: CGRect(
            x: (Double(side) - width) / 2, y: (Double(side) - height) / 2, width: width, height: height
        ))
        return context.makeImage()
    }
}

extension GIFTranscoder {
    /// The artifacts a gif contributes to a tile: the looping animation and the
    /// poster shown while the tile is idle.
    public struct VisualArtifacts: Sendable {
        public let animationURL: URL
        public let posterURL: URL
    }

    /// Transcodes `sourceURL` into a tile-sized mp4 and poster in
    /// `outputDirectory`, looping the gif to fill `duration`.
    ///
    /// Looping rather than freezing on the last frame: a 0.4 s reaction gif
    /// under a 2 s clip should keep reacting, which is `BACKEND_PLAN.md` 4.3's
    /// "looped if the source is shorter than the audio".
    public func transcode(
        gifAt sourceURL: URL,
        duration: TimeInterval,
        into outputDirectory: URL
    ) async throws -> VisualArtifacts {
        let frames = try Self.decode(url: sourceURL, caps: caps)
        let side = OutputFormat.tilePixelSize
        let fps = Double(OutputFormat.animationFrameRate)
        let clip = min(max(duration, 0.1), caps.maxClipDuration)

        // Poster first: if the gif is unusable this fails before an encoder
        // session is opened.
        let poster = try Self.square(frames[Self.posterIndex(of: frames)].image, side: side)
            .unwrapOr(ImportFailureCode.posterEncodeFailed)
        let posterURL = outputDirectory.appendingPathComponent("poster.heic")
        try ClipExtractor.writeHEIC(poster, to: posterURL)

        // Flatten the variable-delay gif onto a fixed 30 fps timeline once, so
        // playback never has to think about per-frame delays again.
        var timeline: [CGImage] = []
        let totalFrames = Int((clip * fps).rounded())
        let loopDuration = max(0.05, frames.reduce(0) { $0 + $1.delay })
        var cursor = 0.0
        for _ in 0..<totalFrames {
            let position = cursor.truncatingRemainder(dividingBy: loopDuration)
            var elapsed = 0.0
            var chosen = frames[0].image
            for frame in frames {
                elapsed += frame.delay
                if position < elapsed { chosen = frame.image; break }
            }
            guard let squared = Self.square(chosen, side: side) else {
                throw ImportFailureCode.animationEncodeFailed
            }
            timeline.append(squared)
            cursor += 1 / fps
        }

        let animationURL = outputDirectory.appendingPathComponent("tile.mp4")
        try await Self.write(timeline, fps: fps, side: side, to: animationURL)
        return VisualArtifacts(animationURL: animationURL, posterURL: posterURL)
    }

    /// A still image paired with a sound. There is no animation to build, so
    /// the tile gets a poster and no video blob, and `BACKEND_PLAN.md` 4.3's
    /// rule applies: it pulses on trigger rather than animating.
    public func transcodeStill(at sourceURL: URL, into outputDirectory: URL) async throws -> VisualArtifacts {
        guard let source = CGImageSourceCreateWithURL(sourceURL as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            throw ImportFailureCode.unreadableFile
        }
        guard image.width <= caps.maxPixelDimension, image.height <= caps.maxPixelDimension else {
            throw ImportFailureCode.dimensionsTooLarge
        }
        let poster = try Self.square(image, side: OutputFormat.tilePixelSize)
            .unwrapOr(ImportFailureCode.posterEncodeFailed)
        let posterURL = outputDirectory.appendingPathComponent("poster.heic")
        try ClipExtractor.writeHEIC(poster, to: posterURL)
        // A single-frame mp4 keeps the tile's storage shape uniform, so the
        // playback path never branches on "does this tile have a video".
        let animationURL = outputDirectory.appendingPathComponent("tile.mp4")
        try await Self.write([poster], fps: Double(OutputFormat.animationFrameRate), side: OutputFormat.tilePixelSize, to: animationURL)
        return VisualArtifacts(animationURL: animationURL, posterURL: posterURL)
    }

    /// Encodes a frame timeline to H.264 with no audio track.
    private static func write(_ frames: [CGImage], fps: Double, side: Int, to url: URL) async throws {
        try? FileManager.default.removeItem(at: url)
        guard let writer = try? AVAssetWriter(outputURL: url, fileType: .mp4) else {
            throw ImportFailureCode.animationEncodeFailed
        }
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: side,
            AVVideoHeightKey: side,
        ])
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_32ARGB),
                kCVPixelBufferWidthKey as String: side,
                kCVPixelBufferHeightKey as String: side,
            ]
        )
        guard writer.canAdd(input) else { throw ImportFailureCode.animationEncodeFailed }
        writer.add(input)
        guard writer.startWriting() else { throw ImportFailureCode.animationEncodeFailed }
        writer.startSession(atSourceTime: .zero)

        let scale: Int32 = 600
        for (index, frame) in frames.enumerated() {
            guard let pool = adaptor.pixelBufferPool,
                  let buffer = Self.pixelBuffer(from: frame, side: side, pool: pool) else {
                writer.cancelWriting()
                throw ImportFailureCode.animationEncodeFailed
            }
            // The encoder consumes frames on its own schedule; spinning here
            // rather than blocking keeps the import off the main thread's back.
            while !input.isReadyForMoreMediaData {
                try await Task.sleep(nanoseconds: 2_000_000)
            }
            let time = CMTime(value: CMTimeValue(Double(index) / fps * Double(scale)), timescale: scale)
            guard adaptor.append(buffer, withPresentationTime: time) else {
                writer.cancelWriting()
                throw ImportFailureCode.animationEncodeFailed
            }
        }
        input.markAsFinished()
        await writer.finishWriting()
        guard writer.status == .completed else { throw ImportFailureCode.animationEncodeFailed }
    }

    private static func pixelBuffer(from image: CGImage, side: Int, pool: CVPixelBufferPool) -> CVPixelBuffer? {
        var buffer: CVPixelBuffer?
        guard CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer) == kCVReturnSuccess,
              let buffer else { return nil }
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let context = CGContext(
            data: CVPixelBufferGetBaseAddress(buffer), width: side, height: side,
            bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
            space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue
        ) else { return nil }
        context.draw(image, in: CGRect(x: 0, y: 0, width: side, height: side))
        return buffer
    }
}

extension Optional {
    func unwrapOr(_ error: ImportFailureCode) throws -> Wrapped {
        guard let self else { throw error }
        return self
    }
}
