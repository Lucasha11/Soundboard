import Foundation

/// How a retention policy's clock is started, mirroring `basis:` in
/// `governance/data-map.yaml`.
public enum RetentionBasis: String, Codable, Sendable, CaseIterable {
    /// A fixed window from creation. The only basis a scheduled sweeper can
    /// act on by itself.
    case rolling
    /// Deleted when the user deletes the item. Event-driven, not time-driven.
    case onUserDelete = "on_user_delete"
    case onRemovalOrClaim = "on_removal_or_claim"
    case afterAssetRemoval = "after_asset_removal"
    case afterAccountDeletion = "after_account_deletion"
    case rollingOrATTWithdrawal = "rolling_or_att_withdrawal"
    case indefiniteNonPersonal = "indefinite_non_personal"
    case legalRetention = "legal_retention"
    case safeHarborRecord = "safe_harbor_record"
}

/// One entry from `retention_policies` in `governance/data-map.yaml`.
///
/// This table is a mirror, and a mirror that drifts is worse than no mirror.
/// `RetentionChecks` parses the manifest and asserts the two agree exactly, so
/// adding a policy to the YAML without adding it here fails the gate the same
/// way an undeclared field does.
public struct RetentionPolicy: Sendable, Equatable {
    public let ref: RetentionRef
    public let days: Int
    public let basis: RetentionBasis

    public init(ref: RetentionRef, days: Int, basis: RetentionBasis) {
        self.ref = ref
        self.days = days
        self.basis = basis
    }

    /// Whether a scheduled sweeper can act on this policy unprompted.
    ///
    /// `on_user_delete` with `days: 0` is not "delete immediately on a
    /// timer" - it means the clock never runs, and deletion happens when the
    /// user asks. Treating it as time-based would have the worker delete the
    /// user's whole library on first launch.
    public var isTimeDriven: Bool { basis == .rolling && days > 0 }

    /// The policies that apply on device. Server-side policies exist in the
    /// manifest but have no subject in this process.
    public static let deviceLocal: [RetentionPolicy] = [
        RetentionPolicy(ref: .deviceLocalUserContent, days: 0, basis: .onUserDelete),
        RetentionPolicy(ref: .deviceLocalBoardLayout, days: 0, basis: .onUserDelete),
        RetentionPolicy(ref: .deviceLocalRetentionAudit, days: 90, basis: .rolling),
        RetentionPolicy(ref: .applicationLogs, days: 90, basis: .rolling),
    ]
}

/// A store the retention worker can sweep.
///
/// Implementers hard-delete. `DG-RET-04` makes soft delete a non-terminal
/// state, so a subject that only flags rows has not satisfied this protocol
/// regardless of what its type name says.
public protocol RetentionSubject: AnyObject {
    /// Which policy governs this store.
    var retentionRef: RetentionRef { get }
    /// Identifiers of items created before `cutoff`.
    func itemsCreated(before cutoff: Date) throws -> [String]
    /// Hard-deletes the given items.
    func hardDelete(_ ids: [String]) throws
}

/// The completion record a sweep leaves behind.
///
/// `PLAN.md` Step 1.3's gate is not "the row is gone", it is "the row is gone
/// **and** there is a record saying so". Deletion you cannot prove happened is
/// indistinguishable from deletion that did not.
public struct RetentionRun: Codable, Equatable, Sendable, ClassifiedRecord {
    public static let storeName = "retention_run"
    public static let fieldClassifications: [String: FieldSpec] = [
        "id": FieldSpec(dataClass: .c1, purposes: [.retention], retention: .deviceLocalRetentionAudit, exportable: false),
        "ranAt": FieldSpec(dataClass: .c1, purposes: [.retention], retention: .deviceLocalRetentionAudit, exportable: false),
        "policyRef": FieldSpec(dataClass: .c1, purposes: [.retention], retention: .deviceLocalRetentionAudit, exportable: false),
        "deletedCount": FieldSpec(dataClass: .c1, purposes: [.retention], retention: .deviceLocalRetentionAudit, exportable: false),
    ]

    public let id: String
    public let ranAt: Date
    public let policyRef: RetentionRef
    /// A count, never the identifiers. An identifier of a deleted item is a
    /// reference to the thing we just promised to forget.
    public let deletedCount: Int

    public init(id: String = UUID().uuidString, ranAt: Date, policyRef: RetentionRef, deletedCount: Int) {
        self.id = id
        self.ranAt = ranAt
        self.policyRef = policyRef
        self.deletedCount = deletedCount
    }
}

/// Scheduled deleter, driven by the retention policies rather than by
/// hand-written rules per store.
///
/// `PLAN.md` Step 1.3 - "retention jobs before retention data" - is the reason
/// this exists before there is much to delete: a deleter written after the data
/// arrives is a deleter written against whatever shape the data happened to
/// take. It runs from day one against a store that is mostly empty, and today
/// its only real subject is its own audit log, which is the honest state of a
/// device-local personal lane where everything else is deleted when the user
/// says so.
public final class RetentionWorker {
    private let policies: [RetentionPolicy]
    private let subjects: [RetentionSubject]
    private let auditLog: RetentionAuditLog

    public init(
        auditURL: URL,
        subjects: [RetentionSubject] = [],
        policies: [RetentionPolicy] = RetentionPolicy.deviceLocal
    ) {
        self.policies = policies
        self.auditLog = RetentionAuditLog(fileURL: auditURL)
        // The audit log is itself retained data, so it sweeps itself rather
        // than growing without bound (P10: no persisted data with no declared
        // retention, including our own bookkeeping).
        self.subjects = subjects + [auditLog]
    }

    /// Sweeps every time-driven policy that has a subject, and records what it
    /// did. Safe and meaningful on an empty store: it writes a run of zero,
    /// which is the evidence that the job is alive.
    @discardableResult
    public func run(now: Date = Date()) throws -> [RetentionRun] {
        var completed: [RetentionRun] = []

        for policy in policies where policy.isTimeDriven {
            let matching = subjects.filter { $0.retentionRef == policy.ref }
            guard !matching.isEmpty else { continue }

            let cutoff = Calendar(identifier: .gregorian)
                .date(byAdding: .day, value: -policy.days, to: now) ?? now
            var deleted = 0
            for subject in matching {
                let expired = try subject.itemsCreated(before: cutoff)
                guard !expired.isEmpty else { continue }
                try subject.hardDelete(expired)
                deleted += expired.count
            }

            let run = RetentionRun(ranAt: now, policyRef: policy.ref, deletedCount: deleted)
            try PersistenceGuard.validate(run, encryptionAvailable: true)
            completed.append(run)
        }

        try auditLog.append(completed)
        return completed
    }

    /// Every run recorded so far, oldest first. Phase 7's quarterly retention
    /// verification reads this.
    public func auditTrail() -> [RetentionRun] {
        auditLog.load()
    }
}

/// The audit log: a subject of the worker as well as its output.
final class RetentionAuditLog: RetentionSubject {
    let retentionRef: RetentionRef = .deviceLocalRetentionAudit
    private let fileURL: URL
    private let lock = NSLock()

    init(fileURL: URL) {
        self.fileURL = fileURL
    }

    func load() -> [RetentionRun] {
        lock.lock()
        defer { lock.unlock() }
        return loadLocked()
    }

    private func loadLocked() -> [RetentionRun] {
        guard let data = try? Data(contentsOf: fileURL) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode([RetentionRun].self, from: data)) ?? []
    }

    func append(_ runs: [RetentionRun]) throws {
        guard !runs.isEmpty else { return }
        lock.lock()
        defer { lock.unlock() }
        try writeLocked(loadLocked() + runs)
    }

    func itemsCreated(before cutoff: Date) throws -> [String] {
        lock.lock()
        defer { lock.unlock() }
        return loadLocked().filter { $0.ranAt < cutoff }.map(\.id)
    }

    func hardDelete(_ ids: [String]) throws {
        lock.lock()
        defer { lock.unlock() }
        let doomed = Set(ids)
        try writeLocked(loadLocked().filter { !doomed.contains($0.id) })
    }

    private func writeLocked(_ runs: [RetentionRun]) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(runs).write(to: fileURL, options: .atomic)
        FileProtection.apply(to: fileURL)
    }
}
