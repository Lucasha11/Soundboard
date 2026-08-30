import Foundation

/// Errors raised by the persistence guard. Every one of these is a fail-closed
/// stop, never a warning (`DG-AGENT-04`).
public enum GovernanceError: Error, Equatable, CustomStringConvertible {
    case unclassifiedField(store: String, field: String)
    case undeclaredProperty(store: String, field: String)
    case missingEncryption(store: String, field: String, dataClass: DataClass)
    case noConsumingPurpose(store: String, field: String)

    public var description: String {
        switch self {
        case let .unclassifiedField(store, field):
            return "DG-CLASS-02  \(store).\(field) has no class tag, so it is treated as C3 and refused"
        case let .undeclaredProperty(store, field):
            return "DG-CLASS-01  \(store).\(field) is stored but absent from the classification map"
        case let .missingEncryption(store, field, dataClass):
            return "DG-SEC-01  \(store).\(field) is \(dataClass.rawValue) and must be encrypted at rest"
        case let .noConsumingPurpose(store, field):
            return "DG-PURP-03  \(store).\(field) is consumed by no registered purpose"
        }
    }
}

/// A type that may be persisted.
///
/// `PLAN.md` Step 1.2 applied on device: every column declares its class at
/// definition time and the data-access module refuses to persist an
/// unclassified field. Enforcement is structural, not a convention that a
/// future contributor can forget.
public protocol ClassifiedRecord {
    /// Logical table or collection name, matching `store:` in `data-map.yaml`.
    static var storeName: String { get }
    /// One entry per stored property. A property missing from this map is
    /// a hard error, not a default.
    static var fieldClassifications: [String: FieldSpec] { get }
}

/// The only sanctioned write path. Nothing persists without passing through here.
public enum PersistenceGuard {
    /// Validates that every stored property of `record` is declared, classified,
    /// consumed by a purpose, and encrypted where its class demands it.
    ///
    /// - Parameter encryptionAvailable: whether the destination applies
    ///   at-rest encryption. On iOS this is file protection on the container.
    public static func validate(
        _ record: some ClassifiedRecord,
        encryptionAvailable: Bool
    ) throws {
        let store = type(of: record).storeName
        let specs = type(of: record).fieldClassifications

        for (name, _) in properties(of: record) {
            guard let spec = specs[name] else {
                throw GovernanceError.undeclaredProperty(store: store, field: name)
            }
            if spec.purposes.isEmpty {
                throw GovernanceError.noConsumingPurpose(store: store, field: name)
            }
            if spec.dataClass.requiresEncryptionAtRest && !encryptionAvailable {
                throw GovernanceError.missingEncryption(
                    store: store, field: name, dataClass: spec.dataClass
                )
            }
        }
    }

    /// Fields a consumer access request must include (`DG-USER-06`).
    public static func exportableFields(of type: any ClassifiedRecord.Type) -> [String] {
        type.fieldClassifications.filter { $0.value.exportable }.keys.sorted()
    }

    /// The highest class present in a record, which sets its storage handling.
    public static func peakClass(of type: any ClassifiedRecord.Type) -> DataClass {
        type.fieldClassifications.values
            .map(\.dataClass)
            .max { lhs, rhs in
                DataClass.allCases.firstIndex(of: lhs)! < DataClass.allCases.firstIndex(of: rhs)!
            } ?? .c1
    }

    private static func properties(of record: some ClassifiedRecord) -> [(String, Any)] {
        Mirror(reflecting: record).children.compactMap { child in
            guard let label = child.label else { return nil }
            return (label, child.value)
        }
    }
}
