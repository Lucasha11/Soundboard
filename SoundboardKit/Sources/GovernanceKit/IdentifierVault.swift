import Foundation

public enum IdentifierAccessError: Error, Equatable, CustomStringConvertible {
    case beforeATT(api: String)
    case notAuthorized(api: String, status: TrackingAuthorization)

    public var description: String {
        switch self {
        case let .beforeATT(api):
            return "DG-USER-04  \(api) was read before the ATT prompt resolved"
        case let .notAuthorized(api, status):
            return "DG-USER-04  \(api) is not available: tracking authorisation is \(status.rawValue)"
        }
    }
}

/// The only sanctioned route to a tracking identifier.
///
/// `DG-USER-04` is the one rule `DATA_GOVERNANCE.md` v2.0 explicitly refuses to
/// relax - "Apple enforces this at review; it is not ours to relax" - so it
/// gets a chokepoint rather than a comment on `ASIdentifierManager`. Two things
/// must hold, and both hold here:
///
/// - No tracking identifier is read before the ATT prompt resolves.
/// - No SDK that reads one is initialised before the prompt resolves, via
///   ``registerSDKInitialisation(named:gate:)``.
///
/// The vault **stores nothing**. It generates no identifier of its own and
/// persists no value: no shipped feature consumes a tracking identifier today,
/// and manufacturing one to have it ready would breach `P12` and `DG-PURP-03`.
/// It is a gate over a value the platform already holds, not a store of one.
public enum IdentifierVault {
    /// Reads a tracking identifier through the governance gate.
    ///
    /// - Parameters:
    ///   - api: the platform API being read, recorded on the ledger and named
    ///     in the thrown error. An API name, never a value.
    ///   - gate: injectable so checks can drive a gate of their own without
    ///     mutating process-wide state.
    ///   - provider: the platform call, for example
    ///     `ASIdentifierManager.shared().advertisingIdentifier.uuidString`.
    ///     It is invoked only after the gate passes, so a refused read never
    ///     reaches the platform at all and no identifier is generated.
    public static func readTrackingIdentifier(
        api: String,
        gate: TrackingGate = .shared,
        provider: () -> String?
    ) throws -> String? {
        if gate.recordIfUnresolved(.identifier, detail: api) {
            throw IdentifierAccessError.beforeATT(api: api)
        }
        guard gate.allowsTrackingIdentifier else {
            throw IdentifierAccessError.notAuthorized(api: api, status: gate.status)
        }
        return provider()
    }

    /// Runs an SDK's initialiser, refusing if the prompt has not resolved.
    ///
    /// `DG-USER-04` bars the initialisation itself, not merely the read: an ad
    /// SDK that starts up before the prompt will have taken the identifier
    /// before any of our code asks it for one. Routing SDK start-up through
    /// here makes that a refusal instead of a review finding.
    public static func registerSDKInitialisation(
        named name: String,
        gate: TrackingGate = .shared,
        initialise: () -> Void
    ) throws {
        if gate.recordIfUnresolved(.sdk, detail: name) {
            throw IdentifierAccessError.beforeATT(api: name)
        }
        initialise()
    }
}

/// A pseudonymous identifier for one run of the app.
///
/// `DG-LOG-01` bars C2 and C3 from logs but says in as many words that
/// "pseudonymous device and session identifiers MAY be included", and
/// `BACKEND_PLAN.md` B0.4's gate requires proof that such an identifier
/// survives the redactor while a C2 value does not. Without something in this
/// class, a correct redactor and one that strips everything are
/// indistinguishable.
///
/// Deliberately per-launch and in memory only. A value that persisted across
/// launches would be a device identifier rather than a session one, which is a
/// different class and a different rule; nothing persists it, so it needs no
/// `data-map.yaml` entry and cannot outlive the process.
public enum SessionIdentifier {
    /// Regenerated every launch. C1: it says nothing about the person, only
    /// that two log lines came from one run.
    public static let current = UUID().uuidString

    /// The session ID as a log field, tagged C1 so the redactor passes it.
    public static var logValue: LogValue { LogValue(current, .c1) }
}
