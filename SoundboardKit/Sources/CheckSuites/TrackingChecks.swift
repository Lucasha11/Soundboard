import Foundation
import GovernanceKit
import SoundLibrary

/// `BACKEND_PLAN.md` Phase B0 gate, in-process half.
///
/// Two things need proving and neither proves the other:
///
/// - `DG-USER-04`: no tracking identifier is read, and no SDK that reads one
///   is initialised, before ATT resolves. The instrumented UI test asserts an
///   empty ledger, but an empty ledger is also what a broken instrument
///   reports - so these checks drive real attempts through the vault and
///   require them to be caught.
/// - `DG-ACQ-08`: content the user imports for their own board never leaves
///   the device. Asserted by running a full personal-lane cycle with the real
///   outbound observer installed and requiring it to see nothing.
enum TrackingChecks {
    static func run() async {
        Check.suite("TrackingGate - DG-USER-04 ledger") {
            let gate = TrackingGate()
            Check.expect(!gate.isResolved, "the prompt starts unresolved")
            Check.expectEqual(gate.status, .notDetermined, "and the status says so")
            Check.expect(!gate.allowsTrackingIdentifier, "an unresolved prompt permits nothing")
            Check.expectEqual(gate.ledgerSummary, "identifier=0 sdk=0", "a clean launch has an empty ledger")

            Check.expect(
                gate.recordIfUnresolved(.identifier, detail: "advertisingIdentifier"),
                "an attempt before the prompt is reported as pre-prompt"
            )
            Check.expectEqual(gate.ledgerSummary, "identifier=1 sdk=0", "and lands on the ledger")

            gate.resolve(.denied)
            Check.expect(gate.isResolved, "a denial resolves the prompt just as an authorisation does")
            Check.expect(!gate.allowsTrackingIdentifier, "but permits no identifier")
            Check.expect(
                !gate.recordIfUnresolved(.identifier, detail: "advertisingIdentifier"),
                "an attempt after the prompt is not pre-prompt"
            )
            Check.expectEqual(gate.attemptCount(.identifier), 1, "and is not added to the ledger")

            gate.resolve(.authorized)
            Check.expectEqual(
                gate.status, .denied,
                "the prompt resolves once per process and cannot be reopened or overwritten"
            )
        }

        Check.suite("IdentifierVault - DG-USER-04 is the one rule v2.0 will not relax") {
            final class Counter { var reads = 0 }

            let unresolved = TrackingGate()
            let counter = Counter()
            Check.expectThrows(
                IdentifierAccessError.beforeATT(api: "advertisingIdentifier"),
                "a tracking identifier read before ATT resolves is refused"
            ) {
                _ = try IdentifierVault.readTrackingIdentifier(api: "advertisingIdentifier", gate: unresolved) {
                    counter.reads += 1
                    return "idfa"
                }
            }
            Check.expectEqual(counter.reads, 0, "the platform is never asked, so no identifier is generated")
            Check.expectEqual(unresolved.attemptCount(.identifier), 1, "the attempt is on the ledger")

            // The rule bars the SDK's initialisation, not only our read: an ad
            // SDK that starts first has already taken the identifier before
            // any of our code asks it for one.
            let sdkGate = TrackingGate()
            var initialised = false
            Check.expectThrows(
                IdentifierAccessError.beforeATT(api: "SomeAdSDK"),
                "initialising an SDK that reads a tracking identifier is refused too"
            ) {
                try IdentifierVault.registerSDKInitialisation(named: "SomeAdSDK", gate: sdkGate) {
                    initialised = true
                }
            }
            Check.expect(!initialised, "and the SDK does not start")
            Check.expectEqual(sdkGate.attemptCount(.sdk), 1, "the SDK attempt is recorded separately")

            // Resolved but denied is still no. Only authorisation opens it.
            for status in [TrackingAuthorization.denied, .restricted] {
                let refused = TrackingGate()
                refused.resolve(status)
                let refusedCounter = Counter()
                Check.expectThrows(
                    IdentifierAccessError.notAuthorized(api: "advertisingIdentifier", status: status),
                    "\(status.rawValue) resolves the prompt but permits no identifier"
                ) {
                    _ = try IdentifierVault.readTrackingIdentifier(api: "advertisingIdentifier", gate: refused) {
                        refusedCounter.reads += 1
                        return "idfa"
                    }
                }
                Check.expectEqual(refusedCounter.reads, 0, "and the platform is not asked under \(status.rawValue)")
            }

            let authorized = TrackingGate()
            authorized.resolve(.authorized)
            let value = try? IdentifierVault.readTrackingIdentifier(api: "advertisingIdentifier", gate: authorized) { "idfa" }
            Check.expectEqual(value, "idfa", "an authorised read reaches the platform")
        }

        // DG-LOG-01 permits pseudonymous session identifiers in as many words.
        // Without this, a correct redactor and one that strips everything look
        // identical, and the useful half of logging quietly disappears.
        Check.suite("SessionIdentifier - a pseudonymous ID survives the redactor") {
            final class CollectingSink: LogSink {
                var lines: [String] = []
                func write(_ line: String) { lines.append(line) }
            }

            let sink = CollectingSink()
            let logger = RedactingLogger(subsystem: "playback", sink: sink)
            logger.log("tile_fired", [
                "session": SessionIdentifier.logValue,
                "title": LogValue("my dog barking", .c2),
            ])
            let line = sink.lines.first ?? ""

            Check.expect(
                line.contains(SessionIdentifier.current),
                "DG-LOG-01: a pseudonymous session ID is loggable and reaches the sink intact"
            )
            Check.expect(line.contains("<redacted:C2>"), "while a C2 value beside it is still redacted")
            Check.expect(!line.contains("my dog barking"), "and never reaches the sink")
            Check.expect(
                SessionIdentifier.current == SessionIdentifier.current,
                "the ID is stable within a launch, so two log lines correlate"
            )
        }

        // DG-ACQ-08 is the rule with no other enforcement point: the personal
        // lane transmits nothing, and the privacy notice says so today.
        await Check.suite("Personal lane - DG-ACQ-08: nothing leaves the device") {
            let gate = TrackingGate.shared
            gate.reset()
            defer { gate.reset() }

            OutboundObserver.install()
            defer { OutboundObserver.uninstall() }

            try await withTemporaryDirectory { root in
                let source = root.appendingPathComponent("source.mov")
                try await SourceVideo.write(to: source, seconds: 3.0)
                let container = root.appendingPathComponent("container")

                // A complete personal-lane life cycle: import, resolve for
                // playback, reopen, sweep, delete.
                let library = try SoundLibrary(root: container)
                let stored = try await library.importClip(
                    from: source, start: 1.0, duration: 1.0, title: "a private joke"
                )
                _ = library.audioURL(for: stored.id)
                _ = library.posterURL(for: stored.id)
                _ = library.animationURL(for: stored.id)
                let reopened = try SoundLibrary(root: container)
                _ = try reopened.sweep()
                try reopened.delete(id: stored.id)

                Check.expectEqual(
                    gate.observedHosts, [],
                    "DG-ACQ-08: a full import, playback and delete cycle contacts nothing"
                )
                Check.expectEqual(
                    gate.attemptCount(.identifier), 0,
                    "and reads no tracking identifier, so the lane emits nothing at all (P12)"
                )
            }
        }

        // The observer has to be able to see traffic, or the check above is
        // vacuous - an empty host list means nothing if nothing is watching.
        await Check.suite("OutboundObserver - it actually sees a request") {
            let gate = TrackingGate.shared
            gate.reset()
            defer { gate.reset() }

            let configuration = URLSessionConfiguration.ephemeral
            OutboundObserver.configure(configuration)
            // Reserved for documentation use, so this reaches nothing real.
            let url = URL(string: "https://catalog.example.com/v1/manifest?device=abc123")!
            _ = try? await URLSession(configuration: configuration).data(from: url)

            Check.expect(gate.observedHosts.contains("catalog.example.com"), "the host is recorded")
            Check.expect(
                gate.observedHosts.allSatisfy { !$0.contains("abc123") },
                "only the host - a query string is where an identifier would ride"
            )
        }
    }
}
