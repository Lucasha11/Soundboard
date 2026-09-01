import Foundation

/// App Tracking Transparency authorisation, mirrored so `GovernanceKit` does
/// not have to import AppTrackingTransparency and so checks can drive it
/// without a device.
public enum TrackingAuthorization: String, Sendable, Equatable, CaseIterable {
    /// The prompt has not resolved. Nothing may read a tracking identifier.
    case notDetermined
    case denied
    case restricted
    case authorized
}

/// Process-wide record of what happened before the ATT prompt resolved.
///
/// `DG-USER-04` bars reading a tracking identifier, and bars initialising any
/// SDK that reads one, before ATT authorisation resolves. Apple enforces it at
/// review and `DATA_GOVERNANCE.md` says it is not ours to relax, so it is worth
/// more than a code-review convention: this is an instrument installed at
/// process start that observes every attempt and can be read back afterwards.
/// `BACKEND_PLAN.md` Phase B0's gate is the assertion over it.
///
/// The gate is deliberately not a logger. Attempt details are held in memory
/// for the life of the process, never written to disk and never transmitted,
/// so a recorded host or API name cannot become a log line.
public final class TrackingGate: @unchecked Sendable {
    /// One process, one prompt, one gate. A per-instance gate would let a
    /// caller observe different state than the URL protocol does.
    public static let shared = TrackingGate()

    public enum AttemptKind: String, Sendable, Equatable, CaseIterable {
        /// Code asked for a tracking identifier.
        case identifier
        /// An SDK that reads a tracking identifier was initialised.
        case sdk
    }

    /// A single attempt made before ATT resolved. `detail` is an API or SDK
    /// name, never a value.
    public struct Attempt: Sendable, Equatable {
        public let kind: AttemptKind
        public let detail: String

        public init(kind: AttemptKind, detail: String) {
            self.kind = kind
            self.detail = detail
        }
    }

    private let lock = NSLock()
    private var _status: TrackingAuthorization = .notDetermined
    private var _attempts: [Attempt] = []
    private var _observedHosts: [String] = []

    public init() {}

    // MARK: - Gate state

    public var status: TrackingAuthorization {
        lock.lock()
        defer { lock.unlock() }
        return _status
    }

    /// Whether the prompt has resolved, in any direction. Denial resolves the
    /// gate just as authorisation does - it simply resolves it to "no".
    public var isResolved: Bool { status != .notDetermined }

    /// Whether a tracking identifier may be read at all.
    public var allowsTrackingIdentifier: Bool { status == .authorized }

    /// Called once the ATT prompt has returned. Not reversible within a
    /// process: reopening the gate would let post-prompt activity be recorded
    /// as pre-prompt and the ledger would stop meaning anything.
    public func resolve(_ status: TrackingAuthorization) {
        lock.lock()
        defer { lock.unlock() }
        guard _status == .notDetermined, status != .notDetermined else { return }
        _status = status
    }

    // MARK: - Recording

    /// Records an attempt if the prompt has not resolved, and reports whether
    /// it was pre-prompt. Callers use the return value to fail closed.
    @discardableResult
    public func recordIfUnresolved(_ kind: AttemptKind, detail: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard _status == .notDetermined else { return false }
        _attempts.append(Attempt(kind: kind, detail: detail))
        return true
    }

    public var attempts: [Attempt] {
        lock.lock()
        defer { lock.unlock() }
        return _attempts
    }

    public func attemptCount(_ kind: AttemptKind) -> Int {
        lock.lock()
        defer { lock.unlock() }
        return _attempts.filter { $0.kind == kind }.count
    }

    // MARK: - Outbound observation

    /// Records a host the process contacted, at any point.
    ///
    /// This is what makes `DG-ACQ-08` testable rather than asserted. That rule
    /// says content the user records or imports for their own board must never
    /// be transmitted off the device, and the privacy notice repeats the
    /// promise - so a full personal-lane cycle running with the observer
    /// installed must leave this empty.
    public func recordHost(_ host: String) {
        lock.lock()
        defer { lock.unlock() }
        _observedHosts.append(host)
    }

    public var observedHosts: [String] {
        lock.lock()
        defer { lock.unlock() }
        return _observedHosts
    }

    /// A one-line summary, in the shape the UI-test probe renders and the
    /// instrumented test string-matches on.
    public var ledgerSummary: String {
        AttemptKind.allCases
            .map { "\($0.rawValue)=\(attemptCount($0))" }
            .joined(separator: " ")
    }

    /// Test-only. Real launches get a fresh process.
    public func reset() {
        lock.lock()
        defer { lock.unlock() }
        _status = .notDetermined
        _attempts.removeAll()
        _observedHosts.removeAll()
    }
}
