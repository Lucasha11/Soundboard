import Foundation
import GovernanceKit
import SoundboardUI

/// The two-file import flow, and the strings it shows.
///
/// Modelled in `BoardModel` rather than the view precisely so this is
/// assertable: the ordering, the cancel paths and the failure message are the
/// parts that go wrong, and none of them needs a simulator to check.
@MainActor
enum ImportFlowChecks {
    static func run() async {
        await Check.suite("BoardModel - the two-file import flow") {
            let model = BoardModel(catalogue: [])
            var received: (audio: URL, visual: URL)?
            model.onImport = { audio, visual in
                received = (audio, visual)
                return nil
            }

            Check.expectEqual(model.importStage, .idle, "nothing is happening to begin with")
            Check.expect(!model.isPickingAudio && !model.isPickingVisual, "and no picker is up")

            model.beginImport()
            Check.expect(model.isPickingAudio, "tapping the row asks for the sound first")
            Check.expect(!model.isPickingVisual, "and only the sound")

            let audio = URL(fileURLWithPath: "/tmp/sound.mp3")
            model.pickedAudio(audio)
            Check.expect(model.isPickingVisual, "choosing a sound asks for the picture next")
            Check.expect(!model.isPickingAudio, "and closes the first picker")
            Check.expectEqual(model.importStage, .pickingVisual(audio: audio), "holding the sound while it asks")

            let visual = URL(fileURLWithPath: "/tmp/picture.gif")
            model.pickedVisual(visual)
            // The import runs on a task; give it a turn to land.
            try await Task.sleep(nanoseconds: 200_000_000)
            Check.expectEqual(received?.audio, audio, "the sound reaches the pipeline")
            Check.expectEqual(received?.visual, visual, "paired with the picture")
            Check.expectEqual(model.importStage, .idle, "and the flow finishes")
        }

        await Check.suite("BoardModel - cancelling and failing") {
            let model = BoardModel(catalogue: [])
            model.onImport = { _, _ in "That file could not be read." }

            model.beginImport()
            model.cancelImport()
            Check.expectEqual(model.importStage, .idle, "backing out of the first picker ends the flow")

            model.beginImport()
            model.pickedAudio(URL(fileURLWithPath: "/tmp/sound.mp3"))
            model.cancelImport()
            Check.expectEqual(model.importStage, .idle, "backing out of the second ends it too")

            // A picture with no sound would make a silent tile, so it is
            // dropped rather than half-imported.
            var called = false
            model.onImport = { _, _ in called = true; return nil }
            model.pickedVisual(URL(fileURLWithPath: "/tmp/picture.gif"))
            try await Task.sleep(nanoseconds: 100_000_000)
            Check.expect(!called, "a picture arriving with no sound is dropped, not imported")
            Check.expectEqual(model.importStage, .idle, "and the flow resets")

            model.onImport = { _, _ in "That file could not be read." }
            model.beginImport()
            model.pickedAudio(URL(fileURLWithPath: "/tmp/sound.mp3"))
            model.pickedVisual(URL(fileURLWithPath: "/tmp/picture.gif"))
            try await Task.sleep(nanoseconds: 200_000_000)
            Check.expectEqual(
                model.importFailureMessage, "That file could not be read.",
                "a refusal is shown to the user"
            )
            model.acknowledgeImportFailure()
            Check.expect(model.importFailureMessage == nil, "and can be dismissed")
        }

        // These strings are the only part of the import path a person reads,
        // and a failure screen leaks the same way a log line does - it gets
        // photographed into a support ticket.
        Check.suite("ImportFailureCode - what the user is told, DG-LOG-01") {
            for code in ImportFailureCode.allCases {
                let message = code.userMessage
                Check.expect(!message.isEmpty, "\(code.rawValue) has a message")
                Check.expect(
                    !message.contains(code.rawValue),
                    "\(code.rawValue) does not leak its own enum name at the user"
                )
                Check.expect(
                    message.first?.isUppercase == true && message.hasSuffix("."),
                    "\(code.rawValue) reads as a sentence"
                )
                // The shapes that would mean decoder text or a path had been
                // pasted into a user-facing string.
                for leak in ["Error", "Domain", "NSError", "/", "0x"] {
                    Check.expect(
                        !message.contains(leak),
                        "\(code.rawValue) carries no \"\(leak)\" - no decoder text, no paths"
                    )
                }
            }
        }
    }
}
