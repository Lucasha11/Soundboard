import AVFoundation
import CoreGraphics
import CoreMedia
import CoreVideo
import Foundation
import GovernanceKit
import ImportPipeline
import MediaStore

/// Builds a synthetic source video on disk: vertical, like a phone recording,
/// with a moving bar so frames differ and a quiet tone so the loudness stage has
/// something real to work on. Synthetic only, per DG-STOP-01/P9.
enum SourceVideo {
    static func write(to url: URL, seconds: Double = 3.0, size: CGSize = CGSize(width: 720, height: 1280)) async throws {
        try? FileManager.default.removeItem(at: url)
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)

        let video = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: Int(size.width),
            AVVideoHeightKey: Int(size.height),
        ])
        video.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: video,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: Int(size.width),
                kCVPixelBufferHeightKey as String: Int(size.height),
            ]
        )

        let audio = AVAssetWriterInput(mediaType: .audio, outputSettings: [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 44_100.0,
            AVNumberOfChannelsKey: 2,
            AVEncoderBitRateKey: 128_000,
        ])
        audio.expectsMediaDataInRealTime = false

        writer.add(video)
        writer.add(audio)
        guard writer.startWriting() else { throw ImportFailureCode.encodeFailed }
        writer.startSession(atSourceTime: .zero)

        // Audio goes in first and covers the whole timeline. AVAssetWriter
        // throttles any input that runs ahead of its siblings, so appending all
        // video before any audio stalls the video input indefinitely.
        let sampleRate = 44_100.0
        let totalFrames = Int(sampleRate * seconds)
        var interleaved = [Float](repeating: 0, count: totalFrames * 2)
        for frame in 0..<totalFrames {
            let value = Float(0.05 * sin(2 * Double.pi * 440 * Double(frame) / sampleRate))
            interleaved[frame * 2] = value
            interleaved[frame * 2 + 1] = value
        }
        try awaitReady(audio)
        audio.append(try makeAudioSample(interleaved, frames: totalFrames, sampleRate: sampleRate))
        audio.markAsFinished()

        let frameRate: Int32 = 30
        let frameCount = Int(seconds * Double(frameRate))
        for index in 0..<frameCount {
            var buffer: CVPixelBuffer?
            CVPixelBufferCreate(kCFAllocatorDefault, Int(size.width), Int(size.height), kCVPixelFormatType_32BGRA, nil, &buffer)
            guard let buffer else { throw ImportFailureCode.encodeFailed }
            CVPixelBufferLockBaseAddress(buffer, [])
            if let context = CGContext(
                data: CVPixelBufferGetBaseAddress(buffer),
                width: Int(size.width), height: Int(size.height),
                bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
            ) {
                context.setFillColor(CGColor(red: 0.05, green: 0.05, blue: 0.08, alpha: 1))
                context.fill(CGRect(origin: .zero, size: size))
                let progress = CGFloat(index) / CGFloat(frameCount)
                context.setFillColor(CGColor(red: 1, green: 0.4, blue: 0.1, alpha: 1))
                context.fill(CGRect(x: 0, y: progress * (size.height - 80), width: size.width, height: 80))
            }
            CVPixelBufferUnlockBaseAddress(buffer, [])

            try awaitReady(video)
            adaptor.append(buffer, withPresentationTime: CMTime(value: CMTimeValue(index), timescale: frameRate))
        }
        video.markAsFinished()

        await withCheckedContinuation { continuation in
            writer.finishWriting { continuation.resume() }
        }
        guard writer.status == .completed else { throw ImportFailureCode.encodeFailed }
    }

    /// A writer input that never reports ready is a stalled writer. Failing
    /// after a bounded wait turns that into a red check instead of a hang.
    private static func awaitReady(_ input: AVAssetWriterInput, timeout: TimeInterval = 10) throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !input.isReadyForMoreMediaData {
            if Date() > deadline { throw ImportFailureCode.decodeTimeout }
            usleep(1000)
        }
    }

    private static func makeAudioSample(_ interleaved: [Float], frames: Int, sampleRate: Double) throws -> CMSampleBuffer {
        var asbd = AudioStreamBasicDescription(
            mSampleRate: sampleRate, mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
            mBytesPerPacket: 8, mFramesPerPacket: 1, mBytesPerFrame: 8,
            mChannelsPerFrame: 2, mBitsPerChannel: 32, mReserved: 0
        )
        var format: CMAudioFormatDescription?
        CMAudioFormatDescriptionCreate(
            allocator: kCFAllocatorDefault, asbd: &asbd,
            layoutSize: 0, layout: nil, magicCookieSize: 0, magicCookie: nil,
            extensions: nil, formatDescriptionOut: &format
        )
        guard let format else { throw ImportFailureCode.encodeFailed }

        let byteCount = interleaved.count * MemoryLayout<Float>.size
        var block: CMBlockBuffer?
        CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault, memoryBlock: nil, blockLength: byteCount,
            blockAllocator: kCFAllocatorDefault, customBlockSource: nil,
            offsetToData: 0, dataLength: byteCount, flags: 0, blockBufferOut: &block
        )
        guard let block else { throw ImportFailureCode.encodeFailed }
        interleaved.withUnsafeBytes { raw in
            _ = CMBlockBufferReplaceDataBytes(
                with: raw.baseAddress!, blockBuffer: block,
                offsetIntoDestination: 0, dataLength: byteCount
            )
        }

        var timing = CMSampleTimingInfo(
            duration: CMTime(value: 1, timescale: CMTimeScale(sampleRate)),
            presentationTimeStamp: .zero, decodeTimeStamp: .invalid
        )
        var sample: CMSampleBuffer?
        CMSampleBufferCreateReady(
            allocator: kCFAllocatorDefault, dataBuffer: block, formatDescription: format,
            sampleCount: frames, sampleTimingEntryCount: 1, sampleTimingArray: &timing,
            sampleSizeEntryCount: 0, sampleSizeArray: nil, sampleBufferOut: &sample
        )
        guard let sample else { throw ImportFailureCode.encodeFailed }
        return sample
    }
}

enum EndToEndChecks {
    /// The whole path a user takes: pick a video they own, scrub to a moment,
    /// take one second, get a tile. Run against a real encoder and a real
    /// decoder rather than a mock, because every interesting failure in this
    /// pipeline lives in AVFoundation and not in our own code.
    static func run() async {
        await Check.suite("End to end - one second of a video becomes a tile") {
            try await withTemporaryDirectory { root in
                let source = root.appendingPathComponent("source.mov")
                try await SourceVideo.write(to: source)
                Check.expect(FileManager.default.fileExists(atPath: source.path), "synthetic source video written")

                let verified = try MediaVerifier().verify(fileAt: source)
                Check.expectEqual(verified.container, .quickTime, "the source passes the verification gate")

                let artifacts = try await ClipExtractor().extract(
                    from: source,
                    start: 1.0,
                    duration: 1.0,
                    into: root.appendingPathComponent("staging")
                )

                Check.expect(FileManager.default.fileExists(atPath: artifacts.audioURL.path), "audio derivative written")
                Check.expect(artifacts.animationURL != nil, "animation derivative written")
                Check.expect(FileManager.default.fileExists(atPath: artifacts.posterURL.path), "poster written")
                Check.expectClose(artifacts.duration, 1.0, tolerance: 0.01, "the stored clip is the requested window, not the whole source")

                // The source is quiet by construction, so the normaliser has to
                // have lifted it. A gain of 1.0 would mean the stage did nothing.
                Check.expect(artifacts.appliedGain > 1.0, "the quiet source was normalised up")

                let audio = AVURLAsset(url: artifacts.audioURL)
                let audioDuration = try await audio.load(.duration).seconds
                let audioTracks = try await audio.loadTracks(withMediaType: .audio)
                Check.expectEqual(audioTracks.count, 1, "the audio derivative has exactly one track")
                Check.expectClose(audioDuration, 1.0, tolerance: 0.1, "only the trimmed second is stored on disk")

                // Square, tile-sized, and audio-free. A second audio path inside
                // the visual would drift against the engine that owns sound.
                let animation = AVURLAsset(url: try require(artifacts.animationURL))
                let animationTrack = try require((try await animation.loadTracks(withMediaType: .video)).first)
                let animationSize = try await animationTrack.load(.naturalSize)
                let animationAudio = try await animation.loadTracks(withMediaType: .audio)
                Check.expectEqual(Int(animationSize.width), OutputFormat.tilePixelSize, "the animation is tile width")
                Check.expectEqual(Int(animationSize.height), OutputFormat.tilePixelSize, "the animation is square, so a vertical source fills the tile")
                Check.expectEqual(animationAudio.count, 0, "the tile visual carries no audio track")

                // Small enough that 120 tiles stay inside the disk budget in
                // BACKEND_PLAN.md Section 6.
                let perTile = try byteCount(artifacts.audioURL)
                    + byteCount(require(artifacts.animationURL))
                    + byteCount(artifacts.posterURL)
                Check.expect(perTile < 1_500_000, "one tile costs under 1.5 MB on disk [\(perTile) bytes]")

                // Committing into the store is the last step, and it is what
                // makes an import survivable across a crash.
                let store = try BlobStore(root: root.appendingPathComponent("media"))
                let audioRef = try store.adopt(fileAt: artifacts.audioURL, kind: .audio)
                let animationRef = try store.adopt(fileAt: require(artifacts.animationURL), kind: .animation)
                let posterRef = try store.adopt(fileAt: artifacts.posterURL, kind: .poster)
                store.retain(audioRef); store.retain(animationRef); store.retain(posterRef)

                Check.expect(
                    store.exists(audioRef) && store.exists(animationRef) && store.exists(posterRef),
                    "all three derivatives commit to the blob store"
                )
                Check.expectEqual(audioRef.kind.dataClass, .c3, "clip audio is handled as C3, since it can carry a voice")
                Check.expectEqual(posterRef.kind.dataClass, .c4, "visual derivatives are handled as C4")

                // Deleting the tile hard-deletes every byte it owned (DG-RET-04).
                _ = store.release(audioRef)
                _ = store.release(animationRef)
                _ = store.release(posterRef)
                Check.expectEqual(store.totalByteCount(), 0, "deleting a tile leaves nothing on disk")
            }
        }
    }

    private static func byteCount(_ url: URL) throws -> Int {
        (try url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
    }
}
