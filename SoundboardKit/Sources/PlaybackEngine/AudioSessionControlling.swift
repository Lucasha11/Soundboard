import AVFoundation
import Foundation

/// The session decisions a soundboard has to get right, behind a protocol so
/// the engine is testable off-device.
public protocol AudioSessionControlling: AnyObject {
    /// Configures category and buffer duration. Called once at startup and
    /// again after a media services reset.
    func activate() throws
    func deactivate()
    /// Round trip the hardware adds on top of our scheduling. Counts against
    /// the tap-to-sound budget and is not something we can optimise away.
    var outputLatency: TimeInterval { get }
}

/// No-op session for macOS and for checks. macOS has no AVAudioSession.
public final class NullAudioSession: AudioSessionControlling {
    public init() {}
    public func activate() throws {}
    public func deactivate() {}
    public var outputLatency: TimeInterval { 0 }
}

#if os(iOS)
/// Real iOS session.
public final class SystemAudioSession: AudioSessionControlling {
    private let session = AVAudioSession.sharedInstance()

    /// - Parameter mixWithOthers: off by default. A soundboard is the point of
    ///   the moment it is used in, so it takes the output rather than ducking
    ///   under whatever else is playing.
    public init(mixWithOthers: Bool = false) {
        self.mixWithOthers = mixWithOthers
    }

    private let mixWithOthers: Bool

    public func activate() throws {
        // .playback deliberately: it ignores the ringer switch, which is what a
        // soundboard user wants. A silent tile reads as a broken app.
        try session.setCategory(
            .playback,
            mode: .default,
            options: mixWithOthers ? [.mixWithOthers] : []
        )
        // 5 ms. Every millisecond here is audible as tap-to-sound delay.
        try session.setPreferredIOBufferDuration(0.005)
        try session.setPreferredSampleRate(OutputFormatBridge.sampleRate)
        try session.setActive(true)
    }

    public func deactivate() {
        try? session.setActive(false, options: [.notifyOthersOnDeactivation])
    }

    public var outputLatency: TimeInterval { session.outputLatency }
}
#endif
