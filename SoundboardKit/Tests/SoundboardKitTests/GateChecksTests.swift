import XCTest
@testable import CheckSuites

/// Runs the phase-gate suites under XCTest, so `swift test` and Xcode's test
/// navigator cover exactly what `swift run soundboard-checks` covers.
///
/// The suites are not re-implemented here. `AllSuites.run()` is the one
/// ordered list, and this reads the harness's tally afterwards - duplicating
/// 380-odd assertions into XCTest calls would guarantee the two drift.
final class GateChecksTests: XCTestCase {
    @MainActor
    func testEveryPhaseGatePasses() async throws {
        Check.reset()
        await AllSuites.run()

        XCTAssertGreaterThan(Check.passes, 0, "the suites did not run")
        XCTAssertEqual(
            Check.failures, [],
            "phase gate not met:\n" + Check.failures.joined(separator: "\n")
        )
    }
}
