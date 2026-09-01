import Foundation

/// Data classification from DATA_GOVERNANCE.md Section 2.
///
/// Every persisted field declares its class at definition time. There is no
/// "unclassified" case on purpose: `DG-CLASS-02` says an untagged field is
/// treated as C3, and the persistence guard refuses the write rather than
/// silently applying that default.
public enum DataClass: String, Codable, Sendable, CaseIterable {
    /// Published by us, no restriction.
    case c0 = "C0"
    /// Internal, non-personal.
    case c1 = "C1"
    /// Identifies or relates to a person.
    case c2 = "C2"
    /// Elevated legal duty. Includes biometric-adjacent voice records.
    case c3 = "C3"
    /// Third-party rights attach.
    case c4 = "C4"

    /// `DG-SEC-01`: C2, C3 and C4 require encryption at rest.
    public var requiresEncryptionAtRest: Bool {
        switch self {
        case .c0, .c1: return false
        case .c2, .c3, .c4: return true
        }
    }

    /// `DG-LOG-01`: logs carry only C0 and C1 plus opaque identifiers.
    public var isLoggable: Bool {
        self == .c0 || self == .c1
    }
}

/// A registered processing purpose from `governance/purposes.yaml`.
///
/// The enum is closed. Adding a purpose here without a matching manifest entry
/// fails the governance gate, which is the intended coupling (`DG-PURP-01`).
public enum Purpose: String, Codable, Sendable, CaseIterable {
    case serve = "P-SERVE"
    case rank = "P-RANK"
    case creatorAnalytics = "P-CREATOR-ANALYTICS"
    case safety = "P-SAFETY"
    case payment = "P-PAYMENT"
    case productAnalytics = "P-PRODUCT-ANALYTICS"
    case marketing = "P-MARKETING"
    /// v2.0 additions. `P-ADS` is permitted to users 13 and over subject to
    /// ATT and the CCPA opt-out (`DG-USER-03`); `P-ATTRIB` is install
    /// attribution. Neither is implemented yet - they are here because the
    /// enum is the closed mirror of `purposes.yaml`.
    case ads = "P-ADS"
    case attribution = "P-ATTRIB"
    /// `DG-RET-01`, `DG-RET-04`: keep a completion record proving a scheduled
    /// deletion actually ran. Legal obligation, not a business use.
    case retention = "P-RETENTION"
}

/// A retention policy key from `data-map.yaml` `retention_policies`.
/// `DG-RET-01`, and `P10`: no persisted field without one.
public enum RetentionRef: String, Codable, Sendable, CaseIterable {
    case deviceLocalUserContent = "device_local_user_content"
    case deviceLocalBoardLayout = "device_local_board_layout"
    case deviceLocalRetentionAudit = "device_local_retention_audit"
    case audioAsset = "audio_asset"
    case applicationLogs = "application_logs"
}

/// The declared handling of one persisted field.
public struct FieldSpec: Sendable, Equatable {
    public let dataClass: DataClass
    public let purposes: [Purpose]
    public let retention: RetentionRef
    /// Included in a consumer access request (`DG-USER-06`).
    public let exportable: Bool
    /// Removed on a deletion request (`DG-RET-03`).
    public let deletable: Bool

    public init(
        dataClass: DataClass,
        purposes: [Purpose],
        retention: RetentionRef,
        exportable: Bool = true,
        deletable: Bool = true
    ) {
        self.dataClass = dataClass
        self.purposes = purposes
        self.retention = retention
        self.exportable = exportable
        self.deletable = deletable
    }
}
