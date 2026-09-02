import Foundation
#if os(iOS)
import AVFoundation
#endif

/// A session event the engine has to react to, named in our own terms so the
/// routing logic is testable on any platform rather than only on a device.
public enum AudioSessionEvent: Equatable, Sendable {
    /// A call arrived, or another app took the session.
    case interruptionBegan
    /// The interruption ended. `shouldResume` is the system's hint that we may
    /// start again immediately.
    case interruptionEnded(shouldResume: Bool)
    /// Headphones in or out, or any other output route change.
    case routeChanged
    /// The audio server died. Every node and buffer we hold is now invalid.
    case mediaServicesReset
}

/// Connects `AVAudioSession`'s notifications to the engine's handlers.
///
/// `PlaybackEngine` has had `handleInterruptionBegan()`,
/// `handleRouteChange()` and `handleMediaServicesReset()` for a while, and
/// they are covered by checks. Nothing called them. A handler nothing invokes
/// is not resilience, it is the shape of resilience: on a device, one incoming
/// call would have stopped the player nodes and left every later tap silent
/// until the app was force quit. This type is the missing wire, and
/// `BACKEND_PLAN.md` B3.3 is the reason it exists.
///
/// Split deliberately in two. ``apply(_:)`` is the decision - what each event
/// does to the engine - and runs anywhere, so the checks cover it in full.
/// ``start()`` is the platform plumbing that turns an `AVAudioSession`
/// notification into one of those events, and exists only on iOS. The one
/// genuinely error-prone part of that plumbing, reading the interruption type
/// and options out of `userInfo`, is factored into
/// ``interruptionEvent(typeRawValue:optionsRawValue:)`` so it is tested by raw
/// value on every platform rather than only where it can run.
public final class AudioSessionObserver {
    private let engine: PlaybackEngine
    private let center: NotificationCenter
    private var tokens: [NSObjectProtocol] = []

    /// Set when applying an event fails. A failed rebuild is worth surfacing,
    /// but it must not throw out of a notification callback and take the app
    /// with it.
    public private(set) var lastFailure: Error?

    /// Called when ``apply(_:)`` fails, so the failure is collected rather than
    /// only stored. Storing without collecting is how a control ends up
    /// looking present and doing nothing.
    public var onFailure: ((Error) -> Void)?

    public init(engine: PlaybackEngine, center: NotificationCenter = .default) {
        self.engine = engine
        self.center = center
    }

    deinit {
        for token in tokens { center.removeObserver(token) }
    }

    /// Applies one event to the engine.
    ///
    /// Never throws. These arrive on system callbacks where there is no caller
    /// to catch anything, so a failure is recorded rather than propagated -
    /// and recorded rather than swallowed, which is the part `try?` alone
    /// would get wrong.
    public func apply(_ event: AudioSessionEvent) {
        do {
            switch event {
            case .interruptionBegan:
                engine.handleInterruptionBegan()
            case let .interruptionEnded(shouldResume):
                try engine.handleInterruptionEnded(shouldResume: shouldResume)
            case .routeChanged:
                try engine.handleRouteChange()
            case .mediaServicesReset:
                try engine.handleMediaServicesReset()
            }
        } catch {
            lastFailure = error
            onFailure?(error)
        }
    }

    /// Decides what an interruption notification means from the two raw values
    /// the system puts in `userInfo`.
    ///
    /// The values are `AVAudioSession.InterruptionType` (0 began, 1 ended) and
    /// `AVAudioSession.InterruptionOptions` (bit 0 is `.shouldResume`). Kept as
    /// raw values so the mapping is exercised by the checks on macOS, where
    /// `AVAudioSession` does not exist at all.
    public static func interruptionEvent(typeRawValue: UInt, optionsRawValue: UInt?) -> AudioSessionEvent? {
        switch typeRawValue {
        case 0:
            return .interruptionBegan
        case 1:
            // Absent options means "do not resume". Resuming when the system
            // did not invite us to is how an app ends up fighting whatever
            // took the session.
            return .interruptionEnded(shouldResume: (optionsRawValue ?? 0) & 1 == 1)
        default:
            return nil
        }
    }

    #if os(iOS)
    /// Subscribes to the session notifications. Idempotent.
    public func start() {
        guard tokens.isEmpty else { return }

        tokens.append(center.addObserver(
            forName: AVAudioSession.interruptionNotification, object: nil, queue: .main
        ) { [weak self] note in
            let info = note.userInfo
            guard let raw = info?[AVAudioSessionInterruptionTypeKey] as? UInt,
                  let event = Self.interruptionEvent(
                      typeRawValue: raw,
                      optionsRawValue: info?[AVAudioSessionInterruptionOptionKey] as? UInt
                  ) else { return }
            self?.apply(event)
        })

        tokens.append(center.addObserver(
            forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            self?.apply(.routeChanged)
        })

        tokens.append(center.addObserver(
            forName: AVAudioSession.mediaServicesWereResetNotification, object: nil, queue: .main
        ) { [weak self] _ in
            self?.apply(.mediaServicesReset)
        })
    }
    #else
    /// macOS has no `AVAudioSession`, so there is nothing to subscribe to. The
    /// package builds and its checks run here; the app ships only on iOS.
    public func start() {}
    #endif

    public func stop() {
        for token in tokens { center.removeObserver(token) }
        tokens.removeAll()
    }
}
