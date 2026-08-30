import CryptoKit
import Foundation
import GovernanceKit

/// What a blob is, which decides where it lands and how it is handled.
public enum BlobKind: String, Codable, Sendable, CaseIterable {
    /// Canonical trimmed, normalised clip audio.
    case audio
    /// Animated tile visual, transcoded from the source video. No audio track.
    case animation
    /// Still frame shown while the tile is idle.
    case poster

    var directoryName: String { rawValue }

    var fileExtension: String {
        switch self {
        case .audio: return "m4a"
        case .animation: return "mp4"
        case .poster: return "heic"
        }
    }

    /// Section 2 lists biometric-adjacent voice records as C3. Clip audio can
    /// contain a voice, so it is handled at C3 rather than guessed per import.
    /// Visual derivatives carry third-party rights, so C4.
    public var dataClass: DataClass {
        switch self {
        case .audio: return .c3
        case .animation, .poster: return .c4
        }
    }
}

/// A stored blob, addressed by the digest of its own bytes.
public struct BlobRef: Hashable, Codable, Sendable {
    public let digest: String
    public let kind: BlobKind
    public let byteCount: Int

    public init(digest: String, kind: BlobKind, byteCount: Int) {
        self.digest = digest
        self.kind = kind
        self.byteCount = byteCount
    }
}

public enum BlobStoreError: Error, Equatable {
    case writeFailed
    case notFound(String)
    case digestMismatch
}

/// Content-addressed blob storage on the file system.
///
/// Design notes, per `BACKEND_PLAN.md` Section 3:
///
/// - Blobs live on disk, not in the database. A page of 24 tiles decodes 24
///   posters per scroll and the file system plus an image cache handles that
///   far better than row reads.
/// - Addressed by the digest of the *transcoded output*, so importing the same
///   clip twice costs nothing the second time.
/// - Application Support, not Documents: derivatives are not user-facing files.
/// - Commit is staging plus fsync plus atomic move. A crash mid-import can leave
///   staging garbage, which the sweeper removes, but can never leave a metadata
///   row pointing at a file that is not fully written.
public final class BlobStore {
    private let root: URL
    private let staging: URL
    private let fileManager: FileManager
    private let indexURL: URL
    private var refcounts: [String: Int]
    private let queue = DispatchQueue(label: "soundboard.blobstore")

    public init(root: URL, fileManager: FileManager = .default) throws {
        self.root = root
        self.staging = root.appendingPathComponent("staging", isDirectory: true)
        self.fileManager = fileManager
        self.indexURL = root.appendingPathComponent("refcounts.json")

        try fileManager.createDirectory(at: staging, withIntermediateDirectories: true)
        for kind in BlobKind.allCases {
            try fileManager.createDirectory(
                at: root.appendingPathComponent(kind.directoryName, isDirectory: true),
                withIntermediateDirectories: true
            )
        }
        Self.excludeFromBackup(root)

        if let data = try? Data(contentsOf: indexURL),
           let decoded = try? JSONDecoder().decode([String: Int].self, from: data) {
            self.refcounts = decoded
        } else {
            self.refcounts = [:]
        }
    }

    // MARK: - Writing

    /// Writes `data` and returns its reference. Idempotent: storing identical
    /// bytes twice returns the same ref and does not duplicate the file.
    @discardableResult
    public func store(_ data: Data, kind: BlobKind) throws -> BlobRef {
        let digest = Self.digest(of: data)
        let destination = url(digest: digest, kind: kind)

        if fileManager.fileExists(atPath: destination.path) {
            return BlobRef(digest: digest, kind: kind, byteCount: data.count)
        }

        let stagingURL = staging.appendingPathComponent(UUID().uuidString)
        try writeDurably(data, to: stagingURL)

        try fileManager.createDirectory(
            at: destination.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        do {
            try fileManager.moveItem(at: stagingURL, to: destination)
        } catch {
            // A concurrent import of identical bytes won the race. Same content,
            // so the loser just drops its copy.
            try? fileManager.removeItem(at: stagingURL)
            guard fileManager.fileExists(atPath: destination.path) else {
                throw BlobStoreError.writeFailed
            }
        }
        Self.applyProtection(destination)
        return BlobRef(digest: digest, kind: kind, byteCount: data.count)
    }

    /// Moves an already-written file, such as an encoder output, into the store.
    @discardableResult
    public func adopt(fileAt source: URL, kind: BlobKind) throws -> BlobRef {
        let data = try Data(contentsOf: source, options: .mappedIfSafe)
        let ref = try store(data, kind: kind)
        try? fileManager.removeItem(at: source)
        return ref
    }

    // MARK: - Reading

    public func url(for ref: BlobRef) -> URL {
        url(digest: ref.digest, kind: ref.kind)
    }

    public func exists(_ ref: BlobRef) -> Bool {
        fileManager.fileExists(atPath: url(for: ref).path)
    }

    public func read(_ ref: BlobRef) throws -> Data {
        let location = url(for: ref)
        guard fileManager.fileExists(atPath: location.path) else {
            throw BlobStoreError.notFound(ref.digest)
        }
        return try Data(contentsOf: location, options: .mappedIfSafe)
    }

    // MARK: - Lifetime

    /// Two tiles can share one blob after dedupe, so deleting a tile must not
    /// delete bytes another tile still points at.
    public func retain(_ ref: BlobRef) {
        queue.sync {
            refcounts[ref.digest, default: 0] += 1
            persistIndex()
        }
    }

    /// Releases one reference. At zero the bytes are hard-deleted immediately.
    /// Soft delete is not a terminal state here (`DG-RET-04`).
    @discardableResult
    public func release(_ ref: BlobRef) -> Bool {
        queue.sync {
            let remaining = (refcounts[ref.digest] ?? 0) - 1
            if remaining > 0 {
                refcounts[ref.digest] = remaining
                persistIndex()
                return false
            }
            refcounts.removeValue(forKey: ref.digest)
            persistIndex()
            try? fileManager.removeItem(at: url(for: ref))
            return true
        }
    }

    /// Sets refcounts to exactly the references given, and deletes any blob
    /// nothing references.
    ///
    /// The catalogue that owns these blobs is the authority on what is
    /// referenced, not this index. Retaining again on every load instead of
    /// reconciling makes a blob's count climb by one per launch, and a delete
    /// then decrements a count that never reaches zero, so the bytes are never
    /// freed. Reconciling also heals drift left by a crash mid-import.
    ///
    /// - Parameter digests: every reference held, including duplicates when
    ///   two records point at the same blob.
    public func reconcileReferences(_ digests: [String]) {
        queue.sync {
            var counts: [String: Int] = [:]
            for digest in digests { counts[digest, default: 0] += 1 }
            refcounts = counts
            persistIndex()
        }
    }

    public func referenceCount(_ ref: BlobRef) -> Int {
        queue.sync { refcounts[ref.digest] ?? 0 }
    }

    /// Launch sweeper. Removes staging leftovers from an interrupted import and
    /// any blob no live record references. `known` is the set of digests the
    /// metadata store still points at, which is the authority.
    @discardableResult
    public func sweepOrphans(known: Set<String>) throws -> Int {
        try queue.sync {
            var removed = 0
            for leftover in (try? fileManager.contentsOfDirectory(at: staging, includingPropertiesForKeys: nil)) ?? [] {
                try? fileManager.removeItem(at: leftover)
                removed += 1
            }
            for kind in BlobKind.allCases {
                let directory = root.appendingPathComponent(kind.directoryName, isDirectory: true)
                let shards = (try? fileManager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
                for shard in shards {
                    let files = (try? fileManager.contentsOfDirectory(at: shard, includingPropertiesForKeys: nil)) ?? []
                    for file in files {
                        let digest = file.deletingPathExtension().lastPathComponent
                        guard !known.contains(digest) else { continue }
                        try fileManager.removeItem(at: file)
                        refcounts.removeValue(forKey: digest)
                        removed += 1
                    }
                }
            }
            persistIndex()
            return removed
        }
    }

    /// Total bytes on disk, for the storage figure shown in settings.
    public func totalByteCount() -> Int {
        var total = 0
        for kind in BlobKind.allCases {
            let directory = root.appendingPathComponent(kind.directoryName, isDirectory: true)
            guard let walker = fileManager.enumerator(at: directory, includingPropertiesForKeys: [.fileSizeKey]) else { continue }
            for case let url as URL in walker {
                total += (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            }
        }
        return total
    }

    // MARK: - Internals

    private func url(digest: String, kind: BlobKind) -> URL {
        let shard = String(digest.prefix(2))
        return root
            .appendingPathComponent(kind.directoryName, isDirectory: true)
            .appendingPathComponent(shard, isDirectory: true)
            .appendingPathComponent("\(digest).\(kind.fileExtension)")
    }

    private func writeDurably(_ data: Data, to url: URL) throws {
        try data.write(to: url, options: .atomic)
        // .atomic gives us rename semantics but not a flushed file. Force the
        // flush so a power loss cannot leave a truncated blob behind a valid name.
        if let handle = try? FileHandle(forWritingTo: url) {
            try? handle.synchronize()
            try? handle.close()
        }
        Self.applyProtection(url)
    }

    private func persistIndex() {
        guard let data = try? JSONEncoder().encode(refcounts) else { return }
        try? data.write(to: indexURL, options: .atomic)
        Self.applyProtection(indexURL)
    }

    static func digest(of data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// `DG-SEC-01`. C3 voice content and C4 licensed content are encrypted at
    /// rest. On iOS that is file protection on the container; the class is
    /// applied per file so it survives a container-level default changing.
    private static func applyProtection(_ url: URL) {
        #if os(iOS)
        try? FileManager.default.setAttributes(
            [.protectionKey: FileProtectionType.complete],
            ofItemAtPath: url.path
        )
        #endif
    }

    /// v1 keeps imported media off iCloud. Backing up C3 voice content makes the
    /// backup provider a processor for that class, which needs a vendors.yaml
    /// entry first (`DG-VEND-01`, `DG-VEND-03`). Open question 8.2 in BACKEND_PLAN.md.
    private static func excludeFromBackup(_ url: URL) {
        var mutable = url
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? mutable.setResourceValues(values)
    }
}
