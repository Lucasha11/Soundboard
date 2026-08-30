import Foundation
import GovernanceKit
import MediaStore

/// A sound the user owns, as persisted.
///
/// Every stored property is declared in `fieldClassifications` and mirrored in
/// `governance/data-map.yaml`. The persistence guard refuses to write a record
/// with a property missing from that map, so adding a field here without
/// declaring it fails at the first save rather than shipping undeclared.
public struct StoredSound: Codable, Identifiable, Equatable, Sendable, ClassifiedRecord {
    public static let storeName = "sound"

    public static let fieldClassifications: [String: FieldSpec] = [
        "id": FieldSpec(dataClass: .c1, purposes: [.serve], retention: .deviceLocalUserContent),
        "title": FieldSpec(dataClass: .c2, purposes: [.serve], retention: .deviceLocalUserContent),
        "durationMs": FieldSpec(dataClass: .c1, purposes: [.serve], retention: .deviceLocalUserContent),
        "createdAt": FieldSpec(dataClass: .c2, purposes: [.serve], retention: .deviceLocalUserContent),
        "audio": FieldSpec(dataClass: .c1, purposes: [.serve], retention: .deviceLocalUserContent),
        "animation": FieldSpec(dataClass: .c1, purposes: [.serve], retention: .deviceLocalUserContent),
        "poster": FieldSpec(dataClass: .c1, purposes: [.serve], retention: .deviceLocalUserContent),
    ]

    public let id: String
    /// User free text. Never logged, never transmitted.
    public let title: String
    public let durationMs: Int
    public let createdAt: Date

    /// References into the blob store. The payloads themselves are C3 and C4;
    /// a digest is not.
    public let audio: BlobRef
    public let animation: BlobRef?
    public let poster: BlobRef

    public init(
        id: String = UUID().uuidString,
        title: String,
        durationMs: Int,
        createdAt: Date = Date(),
        audio: BlobRef,
        animation: BlobRef?,
        poster: BlobRef
    ) {
        self.id = id
        self.title = title
        self.durationMs = durationMs
        self.createdAt = createdAt
        self.audio = audio
        self.animation = animation
        self.poster = poster
    }

    public var duration: TimeInterval { Double(durationMs) / 1000 }

    /// Every blob this record keeps alive.
    var blobs: [BlobRef] { [audio, poster] + (animation.map { [$0] } ?? []) }
}
