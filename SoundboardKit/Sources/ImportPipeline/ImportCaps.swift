import Foundation

/// Caps applied before a single byte is decoded for real.
///
/// Imported media is hostile input (`DG-SEC-04`): type-verified, size-capped,
/// transcoded away from the source format, and stored non-executable. These
/// numbers are the enforcement, and every one of them is a rejection rather
/// than a clamp, so a malformed file cannot negotiate its way through.
public struct ImportCaps: Sendable {
    public var maxSourceBytes: Int
    public var maxSourceDuration: TimeInterval
    public var maxPixelDimension: Int
    public var maxFrameCount: Int
    public var decodeTimeout: TimeInterval

    /// Longest clip a tile will hold. Clips are 0 to 2 seconds by product
    /// definition, and the trim window is enforced here rather than trusted
    /// from the caller.
    public var maxClipDuration: TimeInterval

    public init(
        maxSourceBytes: Int,
        maxSourceDuration: TimeInterval,
        maxPixelDimension: Int,
        maxFrameCount: Int,
        decodeTimeout: TimeInterval,
        maxClipDuration: TimeInterval
    ) {
        self.maxSourceBytes = maxSourceBytes
        self.maxSourceDuration = maxSourceDuration
        self.maxPixelDimension = maxPixelDimension
        self.maxFrameCount = maxFrameCount
        self.decodeTimeout = decodeTimeout
        self.maxClipDuration = maxClipDuration
    }

    public static let standard = ImportCaps(
        maxSourceBytes: 200 * 1024 * 1024,
        maxSourceDuration: 600,
        maxPixelDimension: 4096,
        maxFrameCount: 600,
        decodeTimeout: 10,
        maxClipDuration: 2.0
    )
}

/// Canonical output format. Every import is normalised to exactly this, so the
/// playback engine never branches on codec, sample rate, or channel count.
public struct OutputFormat: Sendable {
    public static let sampleRate: Double = 48_000
    public static let audioBitRate = 128_000
    /// Two times the largest supported tile, so the poster stays sharp on a 3x screen.
    public static let tilePixelSize = 720
    public static let animationFrameRate: Int32 = 30
    /// EBU R128 target. The difference between a board that feels designed and
    /// one where every third tile is deafening.
    public static let targetLoudness: Double = -16.0
    /// True peak ceiling after normalisation.
    public static let peakCeiling: Double = -1.0
    /// Kills import clicks at the trim boundaries.
    public static let edgeFadeDuration: TimeInterval = 0.004
}

/// Container types accepted at the gate. Sniffed from bytes, never from the
/// file extension or a claimed UTI, both of which the source controls.
public enum SourceContainer: String, Sendable, CaseIterable {
    case mp4
    case quickTime
    case m4a
    case mp3
    case wav
    case aiff
    case caf
    case gif
    case png
    case jpeg
    case heic

    public var carriesVideo: Bool {
        switch self {
        case .mp4, .quickTime, .gif: return true
        case .m4a, .mp3, .wav, .aiff, .caf, .png, .jpeg, .heic: return false
        }
    }

    public var carriesAudio: Bool {
        switch self {
        case .mp4, .quickTime, .m4a, .mp3, .wav, .aiff, .caf: return true
        case .gif, .png, .jpeg, .heic: return false
        }
    }
}
