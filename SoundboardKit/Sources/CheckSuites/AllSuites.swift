import Foundation

/// The single ordered list of gate suites, so the executable and the XCTest
/// target run exactly the same assertions.
///
/// Two entry points over one list rather than two copies of the list: a
/// duplicated list drifts, and a gate that runs in CI but not on a developer's
/// machine is a gate nobody trusts.
public enum AllSuites {
    /// Main-actor isolated because some suites drive `@MainActor` UI types.
    /// Top-level code in the executable was implicitly on the main actor, so
    /// this preserves the isolation the suites were written against rather
    /// than loosening it.
    @MainActor
    public static func run() async {
        GovernanceChecks.run()
        await TrackingChecks.run()
        RetentionChecks.run()
        StoreChecks.run()
        VerifierChecks.run()
        await ImportPipelineChecks.run()
        AudioChecks.run()
        PlaybackChecks.run()
        SessionResilienceChecks.run()
        UIChecks.run()
        await VisualChecks.run()
        await LibraryChecks.run()
        await CrashSafetyChecks.run()
        await EndToEndChecks.run()
    }

    /// Prints the tally and exits with the gate's status. Used by the
    /// executable; the XCTest target reads the tally instead, because a test
    /// process must not call `exit`.
    public static func report() -> Never {
        Check.report()
    }
}
