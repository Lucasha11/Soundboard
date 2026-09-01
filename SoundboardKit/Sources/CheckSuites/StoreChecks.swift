import Foundation
import MediaStore

enum StoreChecks {
    static func run() {
        Check.suite("BlobStore - BACKEND_PLAN.md Phase B1 gate") {
            try withTemporaryDirectory { root in
                let store = try BlobStore(root: root)
                let payload = Data("a two second clip".utf8)

                let first = try store.store(payload, kind: .audio)
                Check.expectEqual(first.digest.count, 64, "blobs are addressed by a full SHA-256")
                Check.expect(store.exists(first), "the blob is readable straight after commit")
                Check.expectEqual(try store.read(first), payload, "bytes round-trip unchanged")

                // Dedupe: importing the same clip twice costs nothing the second time.
                let second = try store.store(payload, kind: .audio)
                Check.expectEqual(second.digest, first.digest, "identical bytes dedupe to one blob")
                Check.expectEqual(store.totalByteCount(), payload.count, "the second import adds no bytes on disk")

                // Different kinds are separate namespaces even for identical bytes,
                // because a poster and an audio blob are handled differently.
                let poster = try store.store(payload, kind: .poster)
                Check.expectEqual(poster.digest, first.digest, "the digest is of content, not of kind")
                Check.expect(store.exists(poster), "the same content stored as another kind lands separately")

                // Refcounting: two tiles can share one blob after dedupe, so
                // deleting one tile must not delete bytes the other still uses.
                store.retain(first)
                store.retain(second)
                Check.expectEqual(store.referenceCount(first), 2, "both tiles hold a reference")
                Check.expectEqual(store.release(first), false, "releasing one reference keeps the bytes")
                Check.expect(store.exists(first), "the blob survives while a second tile points at it")
                Check.expectEqual(store.release(first), true, "releasing the last reference deletes")
                Check.expect(!store.exists(first), "hard delete, not a soft flag (DG-RET-04)")
            }

            // The sweeper is what makes an interrupted import safe: staging
            // leftovers and blobs no record points at are both removed at launch.
            try withTemporaryDirectory { root in
                let store = try BlobStore(root: root)
                let kept = try store.store(Data("keep".utf8), kind: .audio)
                let orphan = try store.store(Data("orphan".utf8), kind: .animation)

                let stagingLeftover = root
                    .appendingPathComponent("staging", isDirectory: true)
                    .appendingPathComponent(UUID().uuidString)
                try Data("half written".utf8).write(to: stagingLeftover)

                let removed = try store.sweepOrphans(known: [kept.digest])
                Check.expectEqual(removed, 2, "the sweeper removes the orphan and the staging leftover")
                Check.expect(store.exists(kept), "a referenced blob is untouched")
                Check.expect(!store.exists(orphan), "an unreferenced blob is deleted")
                Check.expect(
                    !FileManager.default.fileExists(atPath: stagingLeftover.path),
                    "a partially written import leaves nothing behind"
                )
            }

            // Refcounts survive a relaunch, otherwise a restart would silently
            // orphan every shared blob in the store.
            try withTemporaryDirectory { root in
                let ref: BlobRef
                do {
                    let store = try BlobStore(root: root)
                    ref = try store.store(Data("persisted".utf8), kind: .audio)
                    store.retain(ref)
                    store.retain(ref)
                }
                let reopened = try BlobStore(root: root)
                Check.expectEqual(reopened.referenceCount(ref), 2, "refcounts survive a relaunch")
            }
        }
    }
}
