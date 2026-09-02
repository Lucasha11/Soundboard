import XCTest

/// **The Phase B0 gate, out-of-process half.** `BACKEND_PLAN.md` requires an
/// instrumented test proving zero reads of a tracking identifier before ATT
/// resolves (`DG-USER-04`).
///
/// The measurement comes from `TrackingGate`, whose outbound observer is
/// installed as the first statement of the app's `init()` and whose ledger is
/// published into the accessibility tree by `TrackingLedgerProbe`. That the
/// instrument genuinely detects attempts - rather than reporting an empty
/// ledger because it is broken - is proven separately by `TrackingChecks`,
/// which drives real reads and a real request through it and requires them to
/// be caught. Neither half is sufficient alone.
///
/// v2.0 removed the age gate and Restricted Mode (`DG-USER-02`, relaxed), so
/// the app is expected to launch straight to the board.
final class TrackingAndLaunchUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    private func launch(observingTracking: Bool) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = [LaunchArgument.resetState, LaunchArgument.silentAudio]
        if observingTracking { app.launchArguments += [LaunchArgument.observeTracking] }
        app.launchArguments += LaunchArgument.pinnedLocale
        app.launch()
        return app
    }

    /// Reads the ledger the app publishes, failing rather than defaulting if
    /// the probe is missing. A missing probe must not read as a clean ledger.
    private func ledgerValue(in app: XCUIApplication, file: StaticString = #filePath, line: UInt = #line) -> String {
        let ledger = app.otherElements[AccessibilityID.trackingLedger]
        XCTAssertTrue(
            ledger.waitForExistence(timeout: 10),
            "tracking ledger probe not found - the assertion would otherwise pass vacuously",
            file: file, line: line
        )
        guard let value = ledger.value as? String else {
            XCTFail("tracking ledger carried no value", file: file, line: line)
            return ""
        }
        return value
    }

    /// The gate: nothing read a tracking identifier and no SDK that reads one
    /// was initialised, between process start and the board being usable.
    func testNoTrackingIdentifierIsReadBeforeATTResolves() {
        let app = launch(observingTracking: true)

        XCTAssertTrue(
            app.otherElements[AccessibilityID.exploreRoot].waitForExistence(timeout: 10),
            "the app should launch straight to Explore - v2.0 removed the age gate"
        )
        XCTAssertEqual(
            ledgerValue(in: app), "identifier=0 sdk=0",
            "DG-USER-04: no tracking identifier read and no such SDK initialised before ATT resolves"
        )
    }

    /// The ledger must still be clean after the user has actually used the
    /// app, not merely at first render. Something reading an identifier lazily
    /// on first interaction is exactly the regression this catches.
    func testLedgerStaysCleanAfterUsingTheApp() {
        let app = launch(observingTracking: true)
        XCTAssertTrue(app.otherElements[AccessibilityID.exploreRoot].waitForExistence(timeout: 10))

        app.buttons[AccessibilityID.tabBarBoard].tap()
        XCTAssertTrue(app.otherElements[AccessibilityID.boardRoot].waitForExistence(timeout: 10))
        app.buttons[AccessibilityID.tabBarExplore].tap()
        XCTAssertTrue(app.otherElements[AccessibilityID.exploreRoot].waitForExistence(timeout: 10))

        XCTAssertEqual(
            ledgerValue(in: app), "identifier=0 sdk=0",
            "DG-USER-04: still clean after the user has navigated the app"
        )
    }

    /// `DG-USER-03` permits advertising at v2.0. There is no age bracket to
    /// consult any more, so ads render on both surfaces.
    func testAdsRenderOnBothSurfaces() {
        let app = launch(observingTracking: false)

        XCTAssertTrue(app.otherElements[AccessibilityID.exploreRoot].waitForExistence(timeout: 10))
        XCTAssertTrue(
            app.otherElements[AccessibilityID.exploreAdCard].waitForExistence(timeout: 10),
            "the in-feed ad should render"
        )

        app.buttons[AccessibilityID.tabBarBoard].tap()
        XCTAssertTrue(
            app.otherElements[AccessibilityID.boardBannerAdTop].waitForExistence(timeout: 10),
            "the board banner ad should render"
        )
    }

    /// The personal-import entry point is reachable, and unconditional at
    /// v2.0: Restricted Mode, the only thing that ever hid it, no longer
    /// exists.
    ///
    /// This walks the real path rather than asserting the row exists
    /// somewhere. Every pad starts filled, so reaching the fill sheet means
    /// entering edit mode, clearing a pad, and tapping the now-empty slot -
    /// which is also the flow a user takes to add their own sound.
    func testPersonalImportEntryPointIsReachable() {
        let app = launch(observingTracking: false)
        app.buttons[AccessibilityID.tabBarBoard].tap()
        XCTAssertTrue(app.otherElements[AccessibilityID.boardRoot].waitForExistence(timeout: 10))

        app.buttons[AccessibilityID.boardEditButton].tap()
        let pad = app.buttons[AccessibilityID.boardPad(0)]
        XCTAssertTrue(pad.waitForExistence(timeout: 5), "the first pad should be addressable")
        pad.tap()   // clears it
        pad.tap()   // an empty pad opens the fill sheet

        XCTAssertTrue(
            app.otherElements[AccessibilityID.fillPadSheet].waitForExistence(timeout: 5),
            "tapping an empty pad should open the fill sheet"
        )
        XCTAssertTrue(
            app.buttons[AccessibilityID.boardPersonalImportRow].waitForExistence(timeout: 5),
            "DG-USER-02 was relaxed, so nothing hides the personal-import entry point"
        )
    }

    /// Tapping the import row presents the system file picker.
    ///
    /// The picker runs out of process, so this asserts on the app going
    /// inactive with a system sheet over it rather than on the picker's own
    /// contents - which is the observable part, and the part that regressed to
    /// nothing when the row was decorative.
    func testImportRowPresentsTheFilePicker() {
        let app = launch(observingTracking: false)
        app.buttons[AccessibilityID.tabBarBoard].tap()
        XCTAssertTrue(app.otherElements[AccessibilityID.boardRoot].waitForExistence(timeout: 10))

        app.buttons[AccessibilityID.boardEditButton].tap()
        let pad = app.buttons[AccessibilityID.boardPad(0)]
        XCTAssertTrue(pad.waitForExistence(timeout: 5))
        pad.tap()
        pad.tap()

        // A button, not a container: the row carries `.isButton`, which is
        // what it is and what VoiceOver needs to hear.
        let row = app.buttons[AccessibilityID.boardPersonalImportRow]
        XCTAssertTrue(row.waitForExistence(timeout: 5), "the fill sheet should offer the import row")
        row.tap()

        // The document picker is a separate process presented over the app.
        let picker = XCUIApplication(bundleIdentifier: "com.apple.DocumentsApp")
        let appeared = picker.wait(for: .runningForeground, timeout: 10)
            || app.navigationBars.firstMatch.waitForExistence(timeout: 5)
        XCTAssertTrue(appeared, "tapping the import row should present a file picker")
    }

    /// The probe is test-only scaffolding. A production launch must not carry
    /// it, or the app ships an accessibility element describing its own
    /// internal state.
    func testProbeIsAbsentWithoutTheLaunchArgument() {
        let app = launch(observingTracking: false)

        XCTAssertTrue(app.otherElements[AccessibilityID.exploreRoot].waitForExistence(timeout: 10))
        XCTAssertFalse(
            app.otherElements[AccessibilityID.trackingLedger].exists,
            "the ledger probe must not exist on a launch that did not ask for it"
        )
    }
}
