import Foundation
import GovernanceKit
import SoundLibrary

enum LibraryChecks {
    static func run() async {
        await Check.suite("SoundLibrary - import, persist, resolve, delete") {
            try await withTemporaryDirectory { root in
                let source = root.appendingPathComponent("source.mov")
                try await SourceVideo.write(to: source, seconds: 3.0)

                let library = try SoundLibrary(root: root.appendingPathComponent("container"))
                Check.expect(library.sounds.isEmpty, "a fresh library holds nothing")

                let stored = try await library.importClip(
                    from: source, start: 1.0, duration: 1.0, title: "slow clap"
                )
                Check.expectEqual(library.sounds.count, 1, "the import lands in the catalogue")
                Check.expectEqual(stored.title, "slow clap", "the title is kept")
                Check.expectClose(stored.duration, 1.0, tolerance: 0.05, "the stored duration is the trimmed window")

                // The three derivatives resolve to files that exist on disk.
                let audio = try require(library.audioURL(for: stored.id))
                let poster = try require(library.posterURL(for: stored.id))
                let animation = try require(library.animationURL(for: stored.id))
                for url in [audio, poster, animation] {
                    Check.expect(FileManager.default.fileExists(atPath: url.path), "\(url.lastPathComponent) exists in the store")
                }
                Check.expect(library.totalByteCount > 0, "the store reports the bytes it holds")

                // Reopening is the real test of persistence: a second instance
                // over the same directory must see the same sounds.
                let reopened = try SoundLibrary(root: root.appendingPathComponent("container"))
                Check.expectEqual(reopened.sounds.count, 1, "the catalogue survives a relaunch")
                Check.expectEqual(reopened.sounds.first?.title, "slow clap", "titles survive a relaunch")
                Check.expect(reopened.audioURL(for: stored.id) != nil, "media still resolves after a relaunch")

                // Deleting removes every byte the sound owned.
                try reopened.delete(id: stored.id)
                Check.expect(reopened.sounds.isEmpty, "the record is gone")
                Check.expect(!FileManager.default.fileExists(atPath: audio.path), "audio is hard-deleted, not flagged")
                Check.expect(!FileManager.default.fileExists(atPath: poster.path), "the poster is hard-deleted")
                Check.expectEqual(reopened.totalByteCount, 0, "deleting a sound leaves nothing on disk")

                let third = try SoundLibrary(root: root.appendingPathComponent("container"))
                Check.expect(third.sounds.isEmpty, "the deletion survives a relaunch")
            }
        }

        await Check.suite("SoundLibrary - shared blobs and recovery") {
            try await withTemporaryDirectory { root in
                let source = root.appendingPathComponent("source.mov")
                try await SourceVideo.write(to: source, seconds: 3.0)
                let container = root.appendingPathComponent("container")
                let library = try SoundLibrary(root: container)

                // Whether two imports of the same moment share storage is not
                // something to assert in either direction.
                //
                // Content addressing dedupes identical *bytes*, and the encoder
                // is not byte-deterministic: six repeated extractions of one
                // source produced six mostly-distinct digests, with two
                // colliding by chance. So a re-import may or may not dedupe.
                // Asserting that it does, or that it does not, is a flaky check
                // either way. What is deterministic is that both sounds exist
                // and resolve independently, and that is what is checked here.
                // Blob-level sharing is real and covered by StoreChecks, which
                // stores identical bytes directly.
                let first = try await library.importClip(from: source, start: 1.0, duration: 1.0, title: "one")
                let second = try await library.importClip(from: source, start: 1.0, duration: 1.0, title: "two")

                Check.expectEqual(library.sounds.count, 2, "two sounds exist")
                Check.expect(first.id != second.id, "each import is its own sound")
                Check.expect(library.audioURL(for: first.id) != nil, "the first sound resolves")
                Check.expect(library.audioURL(for: second.id) != nil, "the second sound resolves")

                // Deleting one sound must leave the other completely intact.
                let survivorAudio = try require(library.audioURL(for: second.id))
                try library.delete(id: first.id)
                Check.expectEqual(library.sounds.count, 1, "only the deleted sound is gone")
                Check.expect(
                    FileManager.default.fileExists(atPath: survivorAudio.path),
                    "the surviving sound keeps its media"
                )
                Check.expect(library.audioURL(for: second.id) != nil, "the surviving sound still plays")

                try library.delete(id: second.id)
                Check.expectEqual(library.totalByteCount, 0, "deleting the last sound frees everything")

                // A catalogue entry whose blobs have vanished is dropped rather
                // than surfaced as a tile that cannot play. The blobs are the
                // source of truth; the catalogue is an index over them.
                let recovered = try await library.importClip(from: source, start: 0.5, duration: 1.0, title: "orphan")
                let mediaRoot = container.appendingPathComponent("media", isDirectory: true)
                try FileManager.default.removeItem(at: mediaRoot)
                let afterLoss = try SoundLibrary(root: container)
                Check.expect(
                    afterLoss.sound(id: recovered.id) == nil,
                    "a record whose media is missing is dropped on load"
                )
                Check.expect(afterLoss.sounds.isEmpty, "the catalogue heals rather than showing dead tiles")
            }
        }
    }
}
