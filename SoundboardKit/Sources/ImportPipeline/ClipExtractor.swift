import AVFoundation
import CoreGraphics
import Foundation
import GovernanceKit
import ImageIO
import UniformTypeIdentifiers

/// The three derivatives a tile needs, produced in one pass over a source the
/// user already holds on their device.
public struct ClipArtifacts: Sendable {
    /// Trimmed, loudness-normalised AAC. C3 where it contains a voice.
    public let audioURL: URL
    /// Square, looping, audio-free animation for the tile. Nil for a still import.
    public let animationURL: URL?
    /// Idle frame. Always produced, because the grid renders posters at rest.
    public let posterURL: URL
    public let duration: TimeInterval
    public let appliedGain: Float
}

/// Turns one second of a video the user owns into a soundboard tile.
///
/// Source scope, deliberately narrow: a file the user selects from their own
/// Photos or Files. There is no URL ingestion path, no platform API client, and
/// no share-sheet link handler. At v2.0 `DG-STOP-01/P1` bars only automated or
/// bulk retrieval that breaches a platform's terms, and user-initiated import
/// of a file the user already owns is explicitly permitted, so this is the
/// permitted route rather than the only legal one. Adding a platform client
/// later would need an official API within its terms, plus the `P2` cache
/// limit; a tile is permanent, so no cache exemption would apply to it.
/// See BACKEND_PLAN.md Section 1.
public struct ClipExtractor {
    private let caps: ImportCaps
    private let meter = LoudnessMeter()

    public init(caps: ImportCaps = .standard) {
        self.caps = caps
    }

    /// - Parameters:
    ///   - sourceURL: a local file the user chose. Never a remote URL.
    ///   - start: where the user scrubbed to.
    ///   - duration: clamped to `caps.maxClipDuration`.
    ///   - outputDirectory: staging. The caller moves results into the blob store.
    /// Extracts one clip, and guarantees the only error that can escape is an
    /// `ImportFailureCode`.
    ///
    /// That guarantee is the point of the closed enum, and it has to be made
    /// here rather than hoped for. `AVFoundation` throws `NSError`s whose
    /// `userInfo` carries the source `NSURL` and the decoder's own failure
    /// text - so letting one propagate would put the user's filename into
    /// whatever logs, reports, or failure screens the caller feeds, which is
    /// precisely what `DG-LOG-01` bars. A foreign error becomes `decodeFailed`:
    /// less specific, and it says nothing about the file.
    public func extract(
        from sourceURL: URL,
        start: TimeInterval,
        duration requestedDuration: TimeInterval,
        into outputDirectory: URL
    ) async throws -> ClipArtifacts {
        do {
            return try await performExtraction(
                from: sourceURL, start: start, duration: requestedDuration, into: outputDirectory
            )
        } catch let code as ImportFailureCode {
            throw code
        } catch {
            throw ImportFailureCode.decodeFailed
        }
    }

    /// Audio only, for the paired-import path where the picture comes from a
    /// separate file. Same trim, loudness normalisation and fades as a full
    /// extraction - the canonical audio form does not depend on where the
    /// picture came from.
    public func extractAudio(
        from sourceURL: URL,
        start: TimeInterval,
        duration requestedDuration: TimeInterval,
        into outputDirectory: URL
    ) async throws -> (audioURL: URL, duration: TimeInterval, appliedGain: Float) {
        do {
            guard sourceURL.isFileURL else { throw ImportFailureCode.unsupportedContainer }
            try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)

            let timeout = caps.decodeTimeout
            let asset = AVURLAsset(url: sourceURL, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
            let sourceDuration = try await withDecodeTimeout(timeout) {
                try await asset.load(.duration).seconds
            }
            guard sourceDuration.isFinite, sourceDuration > 0 else { throw ImportFailureCode.unreadableFile }
            guard sourceDuration <= caps.maxSourceDuration else { throw ImportFailureCode.sourceTooLong }

            let clipDuration = min(requestedDuration, caps.maxClipDuration, max(0, sourceDuration - start))
            guard clipDuration > 0 else { throw ImportFailureCode.unreadableFile }
            let window = CMTimeRange(
                start: CMTime(seconds: start, preferredTimescale: 600),
                duration: CMTime(seconds: clipDuration, preferredTimescale: 600)
            )

            let tracks = try await withDecodeTimeout(timeout) {
                try await asset.loadTracks(withMediaType: .audio)
            }
            guard let track = tracks.first else { throw ImportFailureCode.noAudioTrack }

            let (channels, gain) = try await withDecodeTimeout(timeout) {
                try await self.decodeAndNormalise(track: track, asset: asset, window: window)
            }
            let audioURL = outputDirectory.appendingPathComponent("clip.m4a")
            try await withDecodeTimeout(timeout) {
                try await self.writeAAC(channels: channels, to: audioURL)
            }
            return (audioURL, clipDuration, gain)
        } catch let code as ImportFailureCode {
            throw code
        } catch {
            // Same reason as `extract`: an AVFoundation error carries the
            // source URL and decoder text in its userInfo (`DG-LOG-01`).
            throw ImportFailureCode.decodeFailed
        }
    }

    private func performExtraction(
        from sourceURL: URL,
        start: TimeInterval,
        duration requestedDuration: TimeInterval,
        into outputDirectory: URL
    ) async throws -> ClipArtifacts {
        guard sourceURL.isFileURL else { throw ImportFailureCode.unsupportedContainer }
        try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)

        let asset = AVURLAsset(url: sourceURL, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
        // Every stage below is raced against the clock. A malformed file that
        // makes AVFoundation sit forever is a denial of service on the import
        // queue and costs the attacker nothing, so no stage is unbounded
        // (`DG-SEC-04`, BACKEND_PLAN.md 4.1).
        let timeout = caps.decodeTimeout
        let sourceDuration = try await withDecodeTimeout(timeout) {
            try await asset.load(.duration).seconds
        }
        guard sourceDuration.isFinite, sourceDuration > 0 else { throw ImportFailureCode.unreadableFile }
        guard sourceDuration <= caps.maxSourceDuration else { throw ImportFailureCode.sourceTooLong }

        let clipDuration = min(requestedDuration, caps.maxClipDuration, max(0, sourceDuration - start))
        guard clipDuration > 0 else { throw ImportFailureCode.unreadableFile }
        let window = CMTimeRange(
            start: CMTime(seconds: start, preferredTimescale: 600),
            duration: CMTime(seconds: clipDuration, preferredTimescale: 600)
        )

        let audioTracks = try await withDecodeTimeout(timeout) {
            try await asset.loadTracks(withMediaType: .audio)
        }
        guard let audioTrack = audioTracks.first else { throw ImportFailureCode.noAudioTrack }
        let videoTracks = try await withDecodeTimeout(timeout) {
            try await asset.loadTracks(withMediaType: .video)
        }

        let (channels, gain) = try await withDecodeTimeout(timeout) {
            try await self.decodeAndNormalise(track: audioTrack, asset: asset, window: window)
        }
        let audioURL = outputDirectory.appendingPathComponent("clip.m4a")
        try await withDecodeTimeout(timeout) {
            try await self.writeAAC(channels: channels, to: audioURL)
        }

        var animationURL: URL?
        if let videoTrack = videoTracks.first {
            let candidate = outputDirectory.appendingPathComponent("tile.mp4")
            try await withDecodeTimeout(timeout) {
                try await self.writeAnimation(asset: asset, track: videoTrack, window: window, to: candidate)
            }
            animationURL = candidate
        }

        let posterURL = outputDirectory.appendingPathComponent("poster.heic")
        try await withDecodeTimeout(timeout) {
            try await self.writePoster(asset: asset, window: window, to: posterURL, hasVideo: !videoTracks.isEmpty)
        }

        return ClipArtifacts(
            audioURL: audioURL,
            animationURL: animationURL,
            posterURL: posterURL,
            duration: clipDuration,
            appliedGain: gain
        )
    }

    // MARK: - Audio

    /// Decodes the trim window to 48 kHz float, measures it, applies the
    /// normalisation gain and the edge fades. The source is never stored, only
    /// the trimmed region, which keeps a 60 second video from leaving 60
    /// seconds of audio on disk.
    private func decodeAndNormalise(
        track: AVAssetTrack,
        asset: AVAsset,
        window: CMTimeRange
    ) async throws -> ([[Float]], Float) {
        let reader = try AVAssetReader(asset: asset)
        reader.timeRange = window

        let sourceChannels = min(2, try await channelCount(of: track))
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: OutputFormat.sampleRate,
            AVNumberOfChannelsKey: sourceChannels,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsNonInterleaved: false,
            AVLinearPCMIsBigEndianKey: false,
        ]
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: settings)
        guard reader.canAdd(output) else { throw ImportFailureCode.decodeFailed }
        reader.add(output)
        guard reader.startReading() else { throw ImportFailureCode.decodeFailed }

        var interleaved: [Float] = []
        let deadline = Date().addingTimeInterval(caps.decodeTimeout)
        while let sample = output.copyNextSampleBuffer() {
            if Date() > deadline { reader.cancelReading(); throw ImportFailureCode.decodeTimeout }
            guard let block = CMSampleBufferGetDataBuffer(sample) else { continue }
            var length = 0
            var pointer: UnsafeMutablePointer<Int8>?
            guard CMBlockBufferGetDataPointer(block, atOffset: 0, lengthAtOffsetOut: nil, totalLengthOut: &length, dataPointerOut: &pointer) == noErr,
                  let base = pointer else { continue }
            base.withMemoryRebound(to: Float.self, capacity: length / MemoryLayout<Float>.size) { floats in
                interleaved.append(contentsOf: UnsafeBufferPointer(start: floats, count: length / MemoryLayout<Float>.size))
            }
        }
        guard reader.status == .completed || reader.status == .reading else { throw ImportFailureCode.decodeFailed }
        guard !interleaved.isEmpty else { throw ImportFailureCode.silentSelection }

        var channels = Self.deinterleave(interleaved, channelCount: sourceChannels)
        let gain = meter.normalisationGain(channels: channels)
        guard gain.isFinite, gain > 0 else { throw ImportFailureCode.silentSelection }

        for index in channels.indices {
            Self.applyGain(gain, to: &channels[index])
            Self.applyEdgeFades(&channels[index])
        }
        return (channels, gain)
    }

    private func channelCount(of track: AVAssetTrack) async throws -> Int {
        let descriptions = try await track.load(.formatDescriptions)
        guard let description = descriptions.first,
              let basic = CMAudioFormatDescriptionGetStreamBasicDescription(description) else {
            return 1
        }
        return max(1, Int(basic.pointee.mChannelsPerFrame))
    }

    package static func deinterleave(_ samples: [Float], channelCount: Int) -> [[Float]] {
        guard channelCount > 1 else { return [samples] }
        let frames = samples.count / channelCount
        var channels = [[Float]](repeating: [Float](repeating: 0, count: frames), count: channelCount)
        for frame in 0..<frames {
            for channel in 0..<channelCount {
                channels[channel][frame] = samples[frame * channelCount + channel]
            }
        }
        return channels
    }

    package static func interleave(_ channels: [[Float]]) -> [Float] {
        guard channels.count > 1, let frames = channels.first?.count else { return channels.first ?? [] }
        var out = [Float](repeating: 0, count: frames * channels.count)
        for frame in 0..<frames {
            for channel in 0..<channels.count {
                out[frame * channels.count + channel] = channels[channel][frame]
            }
        }
        return out
    }

    package static func applyGain(_ gain: Float, to samples: inout [Float]) {
        for index in samples.indices { samples[index] *= gain }
    }

    /// A trim boundary that lands mid-waveform is an audible click on every
    /// single fire, which is unbearable on a soundboard.
    package static func applyEdgeFades(_ samples: inout [Float], sampleRate: Double = OutputFormat.sampleRate) {
        let fadeFrames = min(Int(OutputFormat.edgeFadeDuration * sampleRate), samples.count / 2)
        guard fadeFrames > 0 else { return }
        for index in 0..<fadeFrames {
            let factor = Float(index) / Float(fadeFrames)
            samples[index] *= factor
            samples[samples.count - 1 - index] *= factor
        }
    }

    private func writeAAC(channels: [[Float]], to url: URL) async throws {
        try? FileManager.default.removeItem(at: url)
        let channelCount = channels.count
        let frames = channels.first?.count ?? 0
        guard frames > 0 else { throw ImportFailureCode.audioEncodeFailed }

        let writer = try AVAssetWriter(outputURL: url, fileType: .m4a)
        let input = AVAssetWriterInput(mediaType: .audio, outputSettings: [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: OutputFormat.sampleRate,
            AVNumberOfChannelsKey: channelCount,
            AVEncoderBitRateKey: OutputFormat.audioBitRate,
        ])
        input.expectsMediaDataInRealTime = false
        guard writer.canAdd(input) else { throw ImportFailureCode.audioEncodeFailed }
        writer.add(input)
        guard writer.startWriting() else { throw ImportFailureCode.audioEncodeFailed }
        writer.startSession(atSourceTime: .zero)

        let buffer = try Self.makeSampleBuffer(
            interleaved: Self.interleave(channels),
            channelCount: channelCount,
            frames: frames
        )
        guard input.append(buffer) else { throw ImportFailureCode.audioEncodeFailed }
        input.markAsFinished()

        // Awaited, never semaphore-blocked. Blocking a cooperative thread here
        // starves the pool the encoder's own callbacks run on.
        await withCheckedContinuation { continuation in
            writer.finishWriting { continuation.resume() }
        }
        guard writer.status == .completed else { throw ImportFailureCode.audioEncodeFailed }
    }

    static func makeSampleBuffer(interleaved: [Float], channelCount: Int, frames: Int) throws -> CMSampleBuffer {
        var asbd = AudioStreamBasicDescription(
            mSampleRate: OutputFormat.sampleRate,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
            mBytesPerPacket: UInt32(4 * channelCount),
            mFramesPerPacket: 1,
            mBytesPerFrame: UInt32(4 * channelCount),
            mChannelsPerFrame: UInt32(channelCount),
            mBitsPerChannel: 32,
            mReserved: 0
        )
        var format: CMAudioFormatDescription?
        guard CMAudioFormatDescriptionCreate(
            allocator: kCFAllocatorDefault,
            asbd: &asbd,
            layoutSize: 0, layout: nil,
            magicCookieSize: 0, magicCookie: nil,
            extensions: nil,
            formatDescriptionOut: &format
        ) == noErr, let format else { throw ImportFailureCode.audioEncodeFailed }

        let byteCount = interleaved.count * MemoryLayout<Float>.size
        var block: CMBlockBuffer?
        guard CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault,
            memoryBlock: nil, blockLength: byteCount,
            blockAllocator: kCFAllocatorDefault,
            customBlockSource: nil, offsetToData: 0, dataLength: byteCount,
            flags: 0, blockBufferOut: &block
        ) == noErr, let block else { throw ImportFailureCode.audioEncodeFailed }

        try interleaved.withUnsafeBytes { raw in
            guard let base = raw.baseAddress,
                  CMBlockBufferReplaceDataBytes(with: base, blockBuffer: block, offsetIntoDestination: 0, dataLength: byteCount) == noErr else {
                throw ImportFailureCode.audioEncodeFailed
            }
        }

        var timing = CMSampleTimingInfo(
            duration: CMTime(value: 1, timescale: CMTimeScale(OutputFormat.sampleRate)),
            presentationTimeStamp: .zero,
            decodeTimeStamp: .invalid
        )
        var sample: CMSampleBuffer?
        guard CMSampleBufferCreateReady(
            allocator: kCFAllocatorDefault,
            dataBuffer: block,
            formatDescription: format,
            sampleCount: frames,
            sampleTimingEntryCount: 1,
            sampleTimingArray: &timing,
            sampleSizeEntryCount: 0,
            sampleSizeArray: nil,
            sampleBufferOut: &sample
        ) == noErr, let sample else { throw ImportFailureCode.audioEncodeFailed }
        return sample
    }

    // MARK: - Visual

    /// Source video becomes a square, audio-free H.264 file sized for the tile.
    ///
    /// This is the single most important performance decision in the app. An
    /// animated source played as-is means one independent decode loop per tile
    /// and a memory profile that will not survive a scroll. Transcoding once at
    /// import means the idle grid is static posters and only firing tiles hold
    /// a decode session.
    private func writeAnimation(
        asset: AVAsset,
        track: AVAssetTrack,
        window: CMTimeRange,
        to url: URL
    ) async throws {
        try? FileManager.default.removeItem(at: url)
        let naturalSize = try await track.load(.naturalSize)
        let transform = try await track.load(.preferredTransform)
        let oriented = naturalSize.applying(transform)
        let sourceWidth = abs(oriented.width)
        let sourceHeight = abs(oriented.height)
        guard sourceWidth > 0, sourceHeight > 0 else { throw ImportFailureCode.noVideoTrack }
        guard sourceWidth <= CGFloat(caps.maxPixelDimension), sourceHeight <= CGFloat(caps.maxPixelDimension) else {
            throw ImportFailureCode.dimensionsTooLarge
        }

        let side = CGFloat(OutputFormat.tilePixelSize)
        // Aspect fill, centred. A vertical source is the common case and a
        // letterboxed tile looks broken next to its neighbours.
        let scale = max(side / sourceWidth, side / sourceHeight)
        let scaled = CGAffineTransform(scaleX: scale, y: scale)
        let centring = CGAffineTransform(
            translationX: (side - sourceWidth * scale) / 2,
            y: (side - sourceHeight * scale) / 2
        )

        // Only the video track is composited in. Setting `audioMix` to nil does
        // not strip audio: an export session carries every track of its source,
        // so exporting the asset directly ships a second copy of the sound
        // inside the tile visual, which then drifts against the engine that
        // owns playback. Building a video-only composition is the fix.
        let composition = AVMutableComposition()
        guard let compositedTrack = composition.addMutableTrack(
            withMediaType: .video,
            preferredTrackID: kCMPersistentTrackID_Invalid
        ) else { throw ImportFailureCode.animationEncodeFailed }
        try compositedTrack.insertTimeRange(window, of: track, at: .zero)

        let videoComposition = AVMutableVideoComposition()
        videoComposition.renderSize = CGSize(width: side, height: side)
        videoComposition.frameDuration = CMTime(value: 1, timescale: OutputFormat.animationFrameRate)
        let instruction = AVMutableVideoCompositionInstruction()
        instruction.timeRange = CMTimeRange(start: .zero, duration: composition.duration)
        let layer = AVMutableVideoCompositionLayerInstruction(assetTrack: compositedTrack)
        layer.setTransform(transform.concatenating(scaled).concatenating(centring), at: .zero)
        instruction.layerInstructions = [layer]
        videoComposition.instructions = [instruction]

        guard let session = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetHighestQuality) else {
            throw ImportFailureCode.animationEncodeFailed
        }
        session.outputURL = url
        session.outputFileType = .mp4
        session.videoComposition = videoComposition
        session.shouldOptimizeForNetworkUse = false

        await session.export()
        guard session.status == .completed else {
            // The underlying reason is diagnostic only. It never reaches a log
            // line or the user, per DG-LOG-01.
            assertionFailure("animation export failed: \(String(describing: session.error))")
            throw ImportFailureCode.animationEncodeFailed
        }
    }

    private func writePoster(asset: AVAsset, window: CMTimeRange, to url: URL, hasVideo: Bool) async throws {
        guard hasVideo else {
            throw ImportFailureCode.noVideoTrack
        }
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = CMTime(seconds: 0.1, preferredTimescale: 600)
        let side = CGFloat(OutputFormat.tilePixelSize)
        generator.maximumSize = CGSize(width: side, height: side)

        // Midpoint rather than the first frame. Clips very often open on black,
        // and a grid of black tiles is a broken-looking grid.
        let midpoint = CMTimeAdd(window.start, CMTimeMultiplyByFloat64(window.duration, multiplier: 0.5))
        let (image, _) = try await generator.image(at: midpoint)
        try Self.writeHEIC(image, to: url)
    }

    static func writeHEIC(_ image: CGImage, to url: URL) throws {
        try? FileManager.default.removeItem(at: url)
        guard let destination = CGImageDestinationCreateWithURL(
            url as CFURL, UTType.heic.identifier as CFString, 1, nil
        ) else { throw ImportFailureCode.posterEncodeFailed }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.8] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw ImportFailureCode.posterEncodeFailed }
    }
}
