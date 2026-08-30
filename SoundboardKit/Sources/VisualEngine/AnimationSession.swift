import AVFoundation
import CoreMedia
import CoreVideo
import Foundation
import GovernanceKit

/// One tile's animation, decoded a frame at a time.
///
/// Frames are pulled, never buffered ahead. At tile size a single BGRA frame is
/// about 2 MB, so a two second tile fully decoded is 120 MB for one tile. That
/// number is the reason this type streams and the reason there is a hard cap on
/// how many of these can exist at once.
public final class AnimationSession {
    public struct Frame {
        public let pixelBuffer: CVPixelBuffer
        /// Offset from the start of the clip, not an absolute time. The caller
        /// adds the start deadline, so the same session can be replayed.
        public let offset: TimeInterval
    }

    public let tileID: TileID
    public let url: URL
    public private(set) var framesDelivered = 0
    public private(set) var isFinished = false

    private var reader: AVAssetReader?
    private var output: AVAssetReaderTrackOutput?
    private let lock = NSLock()

    public init(tileID: TileID, url: URL) {
        self.tileID = tileID
        self.url = url
    }

    /// Opens the reader. Separate from init so the pool decides when a session
    /// actually costs anything.
    ///
    /// Asynchronous because track loading is: the synchronous accessor is
    /// deprecated, and for a local file the await resolves immediately. Frame
    /// delivery stays synchronous, which is the part that runs per frame.
    public func start() async throws {
        let opened = try await Self.openReader(url: url)
        install(opened)
    }

    // Locking lives in synchronous helpers. NSLock is unavailable from an async
    // context, and taking one across an await is the wrong shape anyway.
    private func install(_ opened: (reader: AVAssetReader, output: AVAssetReaderTrackOutput)) {
        lock.lock()
        defer { lock.unlock() }
        reader = opened.reader
        output = opened.output
        framesDelivered = 0
        isFinished = false
    }

    private func cancelReader() {
        lock.lock()
        defer { lock.unlock() }
        reader?.cancelReading()
    }

    private static func openReader(url: URL) async throws -> (reader: AVAssetReader, output: AVAssetReaderTrackOutput) {
        let asset = AVURLAsset(url: url)
        let tracks: [AVAssetTrack]
        do {
            tracks = try await asset.loadTracks(withMediaType: .video)
        } catch {
            throw ImportFailureCode.unreadableFile
        }
        guard let track = tracks.first else { throw ImportFailureCode.noVideoTrack }

        let reader: AVAssetReader
        do {
            reader = try AVAssetReader(asset: asset)
        } catch {
            // Nothing from AVFoundation escapes this boundary: its NSError
            // carries the file path, and a device-local path is a personal
            // shape (DG-LOG-01).
            throw ImportFailureCode.unreadableFile
        }
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
        ])
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else { throw ImportFailureCode.decodeFailed }
        reader.add(output)
        guard reader.startReading() else { throw ImportFailureCode.decodeFailed }
        return (reader, output)
    }

    /// Next frame, or nil at the end of the clip.
    public func nextFrame() -> Frame? {
        lock.lock()
        defer { lock.unlock() }
        guard let output, !isFinished else { return nil }
        guard let sample = output.copyNextSampleBuffer(),
              let pixelBuffer = CMSampleBufferGetImageBuffer(sample) else {
            isFinished = true
            return nil
        }
        framesDelivered += 1
        return Frame(
            pixelBuffer: pixelBuffer,
            offset: CMSampleBufferGetPresentationTimeStamp(sample).seconds
        )
    }

    /// Rewinds to the first frame. Tiles loop while their sound plays, and a
    /// reader cannot seek backwards, so this tears down and reopens.
    public func restart() async throws {
        cancelReader()
        try await start()
    }

    /// Releases the decoder. The pool calls this when a session is retired, and
    /// it is what actually frees the decode resource the cap is protecting.
    public func stop() {
        lock.lock()
        defer { lock.unlock() }
        reader?.cancelReading()
        reader = nil
        output = nil
        isFinished = true
    }

    deinit { reader?.cancelReading() }
}
