import Foundation

/// Records every host the process contacts, without interfering with any
/// request.
///
/// Deliberately an observer and not a blocker. Under `DATA_GOVERNANCE.md` v2.0
/// the app is rated 12+ and may talk to its own catalog before the ATT prompt
/// resolves, so refusing traffic outright would break a legitimate path.
/// `DG-USER-04` bars reading a *tracking identifier* before ATT, not
/// networking, and that is enforced where identifiers are read, in
/// ``IdentifierVault``. What this adds is evidence for the rule that has no
/// other enforcement point: `DG-ACQ-08`, "content the user records or imports
/// for their own board MUST NOT be transmitted off the device".
///
/// **Coverage, stated honestly.** `URLProtocol.registerClass` covers
/// `URLSession.shared` and sessions built from a default or ephemeral
/// configuration, which is every request this app can make today. It does not
/// cover a session that sets its own `protocolClasses` - those opt in through
/// ``configure(_:)`` - nor raw sockets, nor a vendored SDK using `CFNetwork`
/// directly. An SDK that bypasses `URLSession` cannot be seen here at all,
/// which is a reason to gate SDK initialisation on the ATT gate rather than to
/// rely on this alone.
public final class OutboundObserver: URLProtocol {
    /// Installs the observer process-wide. Called from the app's `init()`,
    /// before anything else in the process can reach the network.
    public static func install() {
        URLProtocol.registerClass(OutboundObserver.self)
    }

    public static func uninstall() {
        URLProtocol.unregisterClass(OutboundObserver.self)
    }

    /// Applies the observer to a session configuration the app builds itself.
    /// `registerClass` does not reach those, so they opt in here.
    public static func configure(_ configuration: URLSessionConfiguration) {
        var classes = configuration.protocolClasses ?? []
        classes.insert(OutboundObserver.self, at: 0)
        configuration.protocolClasses = classes
    }

    override public class func canInit(with request: URLRequest) -> Bool {
        // Only the host is recorded. A full URL is where an identifier would
        // ride in a query string, and this ledger is rendered on screen by the
        // UI-test probe.
        TrackingGate.shared.recordHost(request.url?.host ?? "unknown-host")
        // Declining to handle the request is what keeps this an observer:
        // `canInit` may have side effects, and returning false leaves the
        // request to the normal loading system untouched.
        return false
    }
}
