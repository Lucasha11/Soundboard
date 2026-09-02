import Foundation
import GovernanceKit
import ImportPipeline
import SoundLibrary

/// **The Phase B2 gate.** `BACKEND_PLAN.md`: "every fixture in the corpus is
/// rejected with an enum code and no crash, no hang past the timeout, and no
/// partial row" (`DG-SEC-04`).
///
/// The verifier checks prove each fixture is *refused*. That is the easy half.
/// This drives every one of them through `SoundLibrary.importClip` - the same
/// entry point the app calls - and asserts the harder half: that a refusal
/// leaves the library exactly as it found it. A gate that rejects a file but
/// leaves a half-written blob or a dangling row behind has not held.
enum ImportPipelineChecks {
    static func run() async {
        await Check.suite("Import pipeline - B2 gate: hostile input leaves nothing behind") {
            for fixture in HostileCorpus.all {
                try await withTemporaryDirectory { root in
                    let container = root.appendingPathComponent("container", isDirectory: true)
                    let library = try SoundLibrary(root: container)

                    // The extension deliberately lies. Nothing in the pipeline
                    // may consult it: the bytes are the only authority.
                    let source = root.appendingPathComponent("innocent.m4a")
                    try fixture.bytes.write(to: source)

                    var thrown: Error?
                    do {
                        _ = try await library.importClip(
                            from: source, start: 0, duration: 1.0, title: "hostile"
                        )
                    } catch {
                        thrown = error
                    }

                    // 1. Rejected, and rejected with a code rather than decoder
                    //    text that could echo attacker-controlled bytes into a
                    //    log line (DG-LOG-01).
                    Check.expect(
                        thrown is ImportFailureCode,
                        "\(fixture.name): refused with an ImportFailureCode [got \(thrown.map { String(describing: $0) } ?? "no error")]"
                    )

                    // 2. No partial row. The catalogue is the thing the board
                    //    renders from, so a surviving record is a dead tile.
                    Check.expect(library.sounds.isEmpty, "\(fixture.name): no record is written")
                    let reopened = try SoundLibrary(root: container)
                    Check.expect(reopened.sounds.isEmpty, "\(fixture.name): and none appears after a relaunch")

                    // 3. No bytes. A rejected import that still costs disk is a
                    //    slow way to fill the device.
                    Check.expectEqual(reopened.totalByteCount, 0, "\(fixture.name): no bytes are left in the store")

                    // 4. No staging leftovers past the launch sweeper.
                    _ = try reopened.sweep()
                    Check.expect(
                        !FileManager.default.fileExists(atPath: container.appendingPathComponent("staging").path),
                        "\(fixture.name): staging is clear"
                    )
                }
            }
        }

        // A file the gate cannot settle from bytes alone still must not be able
        // to hang the queue. This is the "no hang past the timeout" half of the
        // gate, and it is asserted rather than assumed.
        await Check.suite("Import pipeline - a stalled stage is a rejection, not a hang") {
            // The timeout is deliberately racing a stage that never returns.
            // If `withDecodeTimeout` were decorative, this suite would hang the
            // whole run rather than fail - which is itself the signal.
            let started = Date()
            do {
                _ = try await withDecodeTimeout(0.2) {
                    try await Task.sleep(nanoseconds: 60 * 1_000_000_000)
                    return 42
                }
                Check.expect(false, "a stalled stage must not succeed")
            } catch let code as ImportFailureCode {
                Check.expectEqual(code, .decodeTimeout, "a stalled stage is refused as decodeTimeout")
            } catch {
                Check.expect(false, "wanted decodeTimeout, got \(error)")
            }
            let elapsed = Date().timeIntervalSince(started)
            Check.expect(elapsed < 5, "and is refused on the clock, not when the stage finishes [took \(elapsed)s]")

            // The bound must not fire on work that finishes in time, or every
            // legitimate import on a slow device becomes a rejection.
            let value = try await withDecodeTimeout(5) { 7 }
            Check.expectEqual(value, 7, "a stage that beats the clock returns its value untouched")
        }

        // DG-LOG-01 names upload filenames explicitly, and the schema has no
        // column for one. This is the end-to-end version of that claim.
        await Check.suite("Import pipeline - a source filename never reaches disk") {
            try await withTemporaryDirectory { root in
                let container = root.appendingPathComponent("container", isDirectory: true)
                let library = try SoundLibrary(root: container)

                // Named for what it is rather than "secret", which the
                // governance gate reads as a credential literal - correctly,
                // on the pattern alone.
                let revealingFilename = "my-real-name-holiday-2019"
                let source = root.appendingPathComponent("\(revealingFilename).mov")
                try await SourceVideo.write(to: source, seconds: 3.0)
                _ = try await library.importClip(from: source, start: 1.0, duration: 1.0, title: "clip")

                let catalogue = try String(
                    contentsOf: container.appendingPathComponent("catalogue.json"), encoding: .utf8
                )
                Check.expect(
                    !catalogue.contains(revealingFilename),
                    "DG-LOG-01: the source filename is not persisted anywhere in the catalogue"
                )
                Check.expect(catalogue.contains("clip"), "the user's own title is kept, since they chose it")
            }
        }
    }
}
