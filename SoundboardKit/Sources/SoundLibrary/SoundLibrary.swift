import Foundation
import GovernanceKit
import ImportPipeline
import MediaStore

/// The user's own sounds: import, persist, resolve, delete.
///
/// This is the personal lane from `BACKEND_PLAN.md` end to end. Nothing here
/// leaves the device, nothing is transmitted, and deletion is immediate and
/// hard rather than a flag (`DG-RET-04`).
public final class SoundLibrary {
    private let root: URL
    private let catalogueURL: URL
    private let store: BlobStore
    private let extractor: ClipExtractor
    private let gifTranscoder: GIFTranscoder
    private let verifier: MediaVerifier
    private var records: [StoredSound] = []
    private let lock = NSLock()

    /// - Parameter root: the app's container directory. Blobs land in
    ///   `media/`, the catalogue beside them.
    public init(root: URL, caps: ImportCaps = .standard) throws {
        self.root = root
        self.catalogueURL = root.appendingPathComponent("catalogue.json")
        self.store = try BlobStore(root: root.appendingPathComponent("media", isDirectory: true))
        self.extractor = ClipExtractor(caps: caps)
        self.gifTranscoder = GIFTranscoder(caps: caps)
        self.verifier = MediaVerifier(caps: caps)
        try load()
    }

    // MARK: - Reading

    public var sounds: [StoredSound] {
        lock.lock()
        defer { lock.unlock() }
        return records
    }

    public func sound(id: String) -> StoredSound? {
        lock.lock()
        defer { lock.unlock() }
        return records.first { $0.id == id }
    }

    public func audioURL(for id: String) -> URL? {
        sound(id: id).map { store.url(for: $0.audio) }
    }

    public func animationURL(for id: String) -> URL? {
        guard let animation = sound(id: id)?.animation else { return nil }
        return store.url(for: animation)
    }

    public func posterURL(for id: String) -> URL? {
        sound(id: id).map { store.url(for: $0.poster) }
    }

    public var totalByteCount: Int { store.totalByteCount() }

    // MARK: - Importing

    /// Imports one clip from a video the user already owns on this device.
    ///
    /// Source scope is deliberately narrow: a local file the user selected.
    /// There is no URL ingestion path anywhere in this type. User-initiated
    /// import is the route `DG-STOP-01/P1` permits at v2.0; automated or bulk
    /// platform retrieval in breach of a platform's terms stays prohibited.
    @discardableResult
    public func importClip(
        from sourceURL: URL,
        start: TimeInterval,
        duration: TimeInterval,
        title: String
    ) async throws -> StoredSound {
        _ = try verifier.verify(fileAt: sourceURL)

        let staging = root
            .appendingPathComponent("staging", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: staging) }

        let artifacts = try await extractor.extract(
            from: sourceURL,
            start: start,
            duration: duration,
            into: staging
        )

        // Blobs are committed before the record that references them, so a
        // crash between the two leaves unreferenced bytes for the sweeper
        // rather than a record pointing at a file that was never written.
        // A blob-store failure is a storage failure from the user's point of
        // view, and its error text is not something to hand onward: only an
        // ImportFailureCode leaves this method (`DG-LOG-01`).
        let audio: BlobRef
        let poster: BlobRef
        let animation: BlobRef?
        do {
            audio = try store.adopt(fileAt: artifacts.audioURL, kind: .audio)
            poster = try store.adopt(fileAt: artifacts.posterURL, kind: .poster)
            animation = try artifacts.animationURL.map { try store.adopt(fileAt: $0, kind: .animation) }
        } catch {
            throw ImportFailureCode.storageFull
        }

        let record = StoredSound(
            title: title,
            durationMs: Int(artifacts.duration * 1000),
            audio: audio,
            animation: animation,
            poster: poster
        )
        // Refuses to persist an undeclared or unclassified field.
        try PersistenceGuard.validate(record, encryptionAvailable: true)

        try save(commit(record))
        return record
    }

    /// Pairs a sound the user picked with a gif they picked, which is the
    /// product's headline move: "pair your own gif with any sound".
    ///
    /// Two sources rather than one, because that is what the feature is. The
    /// single-source `importClip(from:...)` pulls audio and video out of one
    /// asset, which covers a video the user trimmed - but a user pairing an mp3
    /// with a reaction gif has two files, and `AVFoundation` cannot read an
    /// animated gif at all, so neither half of that worked before.
    ///
    /// Both files are the user's own, on this device. Nothing here is
    /// transmitted, served, ranked or indexed (`DG-ACQ-08`).
    @discardableResult
    public func importClip(
        audio audioSourceURL: URL,
        visual visualSourceURL: URL,
        start: TimeInterval,
        duration: TimeInterval,
        title: String
    ) async throws -> StoredSound {
        _ = try verifier.verify(fileAt: audioSourceURL)
        let visualKind = try verifier.verify(fileAt: visualSourceURL)

        let staging = root
            .appendingPathComponent("staging", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: staging) }
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)

        // Audio first. A visual with no sound is not a tile, so failing here
        // costs nothing and avoids opening an encoder session.
        let audioOnly = try await extractor.extractAudio(
            from: audioSourceURL, start: start, duration: duration, into: staging
        )

        let visuals: GIFTranscoder.VisualArtifacts
        switch visualKind.container {
        case .gif:
            visuals = try await gifTranscoder.transcode(
                gifAt: visualSourceURL, duration: audioOnly.duration, into: staging
            )
        case .png, .jpeg, .heic:
            visuals = try await gifTranscoder.transcodeStill(
                at: visualSourceURL, into: staging
            )
        default:
            // A video paired with separate audio is a reasonable feature and
            // is not this one. Refused with a code rather than half-handled.
            throw ImportFailureCode.unsupportedContainer
        }

        let audio: BlobRef
        let poster: BlobRef
        let animation: BlobRef?
        do {
            audio = try store.adopt(fileAt: audioOnly.audioURL, kind: .audio)
            poster = try store.adopt(fileAt: visuals.posterURL, kind: .poster)
            animation = try store.adopt(fileAt: visuals.animationURL, kind: .animation)
        } catch {
            throw ImportFailureCode.storageFull
        }

        let record = StoredSound(
            title: title,
            durationMs: Int(audioOnly.duration * 1000),
            audio: audio,
            animation: animation,
            poster: poster
        )
        try PersistenceGuard.validate(record, encryptionAvailable: true)
        try save(commit(record))
        return record
    }

    // Locking lives in synchronous helpers. NSLock is unavailable from an async
    // context, and holding one across an await is the wrong shape regardless.
    private func commit(_ record: StoredSound) -> [StoredSound] {
        lock.lock()
        defer { lock.unlock() }
        for blob in record.blobs { store.retain(blob) }
        records.append(record)
        return records
    }

    // MARK: - Deleting

    /// Removes a sound and every byte it owned. A blob shared with another
    /// sound survives, because the store refcounts.
    public func delete(id: String) throws {
        lock.lock()
        guard let index = records.firstIndex(where: { $0.id == id }) else {
            lock.unlock()
            return
        }
        let record = records.remove(at: index)
        for blob in record.blobs { _ = store.release(blob) }
        let snapshot = records
        lock.unlock()
        try save(snapshot)
    }

    /// Launch sweeper: removes staging leftovers from an interrupted import and
    /// any blob no record references.
    @discardableResult
    public func sweep() throws -> Int {
        lock.lock()
        let known = Set(records.flatMap { $0.blobs.map(\.digest) })
        lock.unlock()
        try? FileManager.default.removeItem(at: root.appendingPathComponent("staging", isDirectory: true))
        return try store.sweepOrphans(known: known)
    }

    // MARK: - Persistence

    private func load() throws {
        guard let data = try? Data(contentsOf: catalogueURL) else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let loaded = (try? decoder.decode([StoredSound].self, from: data)) ?? []

        // A record whose blobs are missing is dropped rather than surfaced as a
        // tile that cannot play. The blobs are the source of truth; the
        // catalogue is an index over them.
        records = loaded.filter { record in record.blobs.allSatisfy { store.exists($0) } }
        // The catalogue is the authority on what is referenced. Retaining again
        // on each load would add one to every count per launch, and a delete
        // would then decrement a count that never reaches zero.
        store.reconcileReferences(records.flatMap { $0.blobs.map(\.digest) })
        if records.count != loaded.count { try save(records) }
    }

    private func save(_ snapshot: [StoredSound]) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(snapshot)
        try data.write(to: catalogueURL, options: .atomic)
        #if os(iOS)
        // The catalogue holds titles, which are C2 (DG-SEC-01).
        try? FileManager.default.setAttributes(
            [.protectionKey: FileProtectionType.complete],
            ofItemAtPath: catalogueURL.path
        )
        #endif
    }
}
