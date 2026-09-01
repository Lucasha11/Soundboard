import GovernanceKit
import SwiftUI

/// Publishes the `DG-USER-04` ledger into the accessibility tree so a UI test
/// can read it.
///
/// XCUITest runs in its own process and can only see the app through the
/// accessibility tree, so an assertion about in-process state has to be
/// rendered to be readable. Writing the ledger to a file and having the test
/// go looking for the app container is the alternative, and it is worse: it
/// depends on simulator container layout that changes between Xcode versions.
///
/// The probe renders **only** when the app is launched with
/// `--uitest-observe-pre-gate`. A real launch never passes that argument, so
/// this adds one `ProcessInfo` read to production and nothing else - no view,
/// no element, no accessibility surface.
struct TrackingLedgerProbe: ViewModifier {
    static let launchArgument = "--uitest-observe-tracking"

    private let gate: TrackingGate
    private let isEnabled: Bool

    @State private var summary: String = ""

    init(gate: TrackingGate = .shared, processInfo: ProcessInfo = .processInfo) {
        self.gate = gate
        self.isEnabled = processInfo.arguments.contains(Self.launchArgument)
    }

    func body(content: Content) -> some View {
        if isEnabled {
            content.overlay(alignment: .topLeading) {
                // An overlay never affects the layout beneath it, and a 1pt
                // clear square is invisible, so the screen under test is the
                // shipping screen. Not zero-sized: SwiftUI prunes zero-area
                // elements from the accessibility tree, and a probe the test
                // cannot find would make the assertion pass vacuously.
                Color.clear
                    .frame(width: 1, height: 1)
                    .accessibilityElement()
                    .accessibilityIdentifier(AccessibilityID.trackingLedger)
                    .accessibilityValue(summary)
                    .accessibilityHidden(false)
                    .allowsHitTesting(false)
                    .onAppear { summary = gate.ledgerSummary }
                    // A request started during launch may land after first
                    // render. Re-sampling means the test reads a settled
                    // ledger rather than whichever value won a race.
                    .onReceive(Timer.publish(every: 0.2, on: .main, in: .common).autoconnect()) { _ in
                        let latest = gate.ledgerSummary
                        if latest != summary { summary = latest }
                    }
            }
        } else {
            content
        }
    }
}

extension View {
    /// Applied to the first screen, which is where the `DG-USER-04` assertion
    /// is made.
    func publishingTrackingLedger() -> some View {
        modifier(TrackingLedgerProbe())
    }
}
