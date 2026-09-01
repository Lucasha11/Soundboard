import Foundation
import MediaStore
import SoundLibrary

/// `BACKEND_PLAN.md` Phase B1 gate: "kill the process at every point in a
/// commit and prove no metadata row ever references a missing blob."
///
/// A process cannot be killed mid-call from inside a test, and simulating it
/// with an injected `fatalError` would only cover the kill points somebody
/// remembered to annotate. What a kill actually produces is a *container
/// state*, and the set of reachable container states is small and enumerable,
/// because only two things in an import are durable: the blob files and
/// `catalogue.json`. Every kill lands the container in one of the states
/// below, so covering them covers every kill point.
///
/// The invariant asserted after each is the one the gate names: a fresh
/// library opens, and no record it holds references a blob that is not on
/// disk.
enum CrashSafetyChecks {
    /// The states an interrupted import can leave behind, applied to a healthy
    /// container.
    private struct Interruption {
        let name: String
        let apply: (URL) throws -> Void
    }

    private static let interruptions: [Interruption] = [
        Interruption(name: "killed after the blobs committed, before the catalogue was written") { container in
            // The window that matters most: blobs on disk, no record naming
            // them. Must yield orphans for the sweeper, never a dangling row.
            try FileManager.default.removeItem(at: container.appendingPathComponent("catalogue.json"))
        },
        Interruption(name: "killed with the catalogue still at its previous version") { container in
            try Data("[]".utf8).write(to: container.appendingPathComponent("catalogue.json"), options: .atomic)
        },
        Interruption(name: "killed mid-transcode, leaving staging garbage") { container in
            let stagings = [
                container.appendingPathComponent("staging", isDirectory: true),
                container.appendingPathComponent("media/staging", isDirectory: true),
            ]
            for staging in stagings {
                try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
                try Data(repeating: 0, count: 4096)
                    .write(to: staging.appendingPathComponent("half-written-\(UUID().uuidString)"))
            }
        },
        Interruption(name: "killed after the catalogue was written but a blob never landed") { container in
            let audio = container.appendingPathComponent("media/audio", isDirectory: true)
            for shard in (try? FileManager.default.contentsOfDirectory(at: audio, includingPropertiesForKeys: nil)) ?? [] {
                for file in (try? FileManager.default.contentsOfDirectory(at: shard, includingPropertiesForKeys: nil)) ?? [] {
                    try FileManager.default.removeItem(at: file)
                }
            }
        },
        Interruption(name: "killed before the refcount index was flushed") { container in
            let index = container.appendingPathComponent("media/refcounts.json")
            if FileManager.default.fileExists(atPath: index.path) {
                try FileManager.default.removeItem(at: index)
            }
        },
        Interruption(name: "killed leaving a truncated refcount index") { container in
            try Data("{\"trunca".utf8)
                .write(to: container.appendingPathComponent("media/refcounts.json"), options: .atomic)
        },
    ]

    static func run() async {
        await Check.suite("SoundLibrary - B1 gate: no row ever references a missing blob") {
            try await withTemporaryDirectory { root in
                let source = root.appendingPathComponent("source.mov")
                try await SourceVideo.write(to: source, seconds: 3.0)

                // Build one healthy container, then replay each interruption
                // against a fresh copy of it.
                let healthy = root.appendingPathComponent("healthy", isDirectory: true)
                do {
                    let library = try SoundLibrary(root: healthy)
                    _ = try await library.importClip(
                        from: source, start: 1.0, duration: 1.0, title: "air horn"
                    )
                }

                for interruption in interruptions {
                    let container = root.appendingPathComponent("case-\(UUID().uuidString)", isDirectory: true)
                    try FileManager.default.copyItem(at: healthy, to: container)
                    try interruption.apply(container)

                    // Relaunch over the damaged container.
                    let reopened = try SoundLibrary(root: container)

                    let dangling = reopened.sounds.filter { sound in
                        [reopened.audioURL(for: sound.id), reopened.posterURL(for: sound.id)]
                            .contains { url in
                                guard let url else { return true }
                                return !FileManager.default.fileExists(atPath: url.path)
                            }
                    }
                    Check.expect(
                        dangling.isEmpty,
                        "\(interruption.name): no record points at a blob that is not on disk"
                    )

                    // The sweeper is the other half: whatever the interruption
                    // orphaned must not be kept forever.
                    _ = try reopened.sweep()
                    Check.expect(
                        !FileManager.default.fileExists(
                            atPath: container.appendingPathComponent("staging").path
                        ),
                        "\(interruption.name): staging is cleared on the next launch"
                    )

                    // And the library is still usable, not wedged.
                    let third = try SoundLibrary(root: container)
                    Check.expectEqual(
                        third.sounds.count, reopened.sounds.count,
                        "\(interruption.name): the healed state is stable across another relaunch"
                    )
                    if third.sounds.isEmpty {
                        Check.expectEqual(
                            third.totalByteCount, 0,
                            "\(interruption.name): an import that never committed leaves no bytes behind"
                        )
                    }
                }
            }
        }

        // Refcounting is what makes deletion safe when two tiles share a blob
        // after dedupe. A crash must not leave a count that can never reach
        // zero, because those bytes would then be undeletable.
        await Check.suite("BlobStore - refcounts heal rather than leaking after a crash") {
            try await withTemporaryDirectory { root in
                let source = root.appendingPathComponent("source.mov")
                try await SourceVideo.write(to: source, seconds: 3.0)
                let container = root.appendingPathComponent("container", isDirectory: true)

                let library = try SoundLibrary(root: container)
                let stored = try await library.importClip(
                    from: source, start: 0.5, duration: 1.0, title: "wow"
                )

                // Simulate a launch loop after a crash: reconciliation must be
                // idempotent, or a count climbs by one per launch and the
                // delete below never frees anything.
                for _ in 0..<5 { _ = try SoundLibrary(root: container) }

                let final = try SoundLibrary(root: container)
                let audio = try require(final.audioURL(for: stored.id))
                try final.delete(id: stored.id)

                Check.expect(
                    !FileManager.default.fileExists(atPath: audio.path),
                    "the blob is freed after repeated relaunches, so refcounts did not leak"
                )
                Check.expectEqual(final.totalByteCount, 0, "and nothing is left on disk")
            }
        }
    }
}
