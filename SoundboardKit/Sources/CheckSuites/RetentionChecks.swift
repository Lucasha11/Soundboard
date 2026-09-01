import Foundation
import GovernanceKit

/// `PLAN.md` Step 1.3 and `BACKEND_PLAN.md` B1.4: retention jobs before
/// retention data.
enum RetentionChecks {
    /// Locates `governance/data-map.yaml` from this source file's own path, so
    /// the check reads the real manifest rather than a copy that can drift.
    private static var dataMapURL: URL {
        URL(fileURLWithPath: #filePath)          // .../Sources/Checks/RetentionChecks.swift
            .deletingLastPathComponent()          // .../Sources/Checks
            .deletingLastPathComponent()          // .../Sources
            .deletingLastPathComponent()          // .../SoundboardKit
            .deletingLastPathComponent()          // repo root
            .appendingPathComponent("governance/data-map.yaml")
    }

    /// Parses the `retention_policies:` block. The entries are one line each in
    /// a fixed shape, so a regex is enough and avoids taking a YAML dependency
    /// into a target that ships no parsing of its own.
    private static func manifestPolicies() throws -> [String: (days: Int, basis: String)] {
        let text = try String(contentsOf: dataMapURL, encoding: .utf8)
        guard let start = text.range(of: "retention_policies:") else { return [:] }
        let block = text[start.upperBound...].prefix(while: { _ in true })

        var found: [String: (days: Int, basis: String)] = [:]
        let pattern = #"^\s{2}([a-z0-9_]+):\s*\{\s*days:\s*(\d+),\s*basis:\s*([a-z_]+)\s*\}"#
        let regex = try NSRegularExpression(pattern: pattern, options: [.anchorsMatchLines])
        let scope = String(block)
        // Stop at the next top-level key, so only the policy block is read.
        let limited = scope.range(of: "\n# ---- Persisted fields").map { String(scope[..<$0.lowerBound]) } ?? scope

        for match in regex.matches(in: limited, range: NSRange(limited.startIndex..., in: limited)) {
            guard let name = Range(match.range(at: 1), in: limited),
                  let days = Range(match.range(at: 2), in: limited),
                  let basis = Range(match.range(at: 3), in: limited) else { continue }
            found[String(limited[name])] = (Int(limited[days]) ?? -1, String(limited[basis]))
        }
        return found
    }

    static func run() {
        // A mirror that drifts is worse than no mirror: the worker would sweep
        // on a schedule nobody declared, or fail to sweep one that was.
        Check.suite("RetentionPolicy - the Swift table mirrors data-map.yaml") {
            let manifest = try manifestPolicies()
            Check.expect(!manifest.isEmpty, "the manifest's retention_policies block parsed")

            for policy in RetentionPolicy.deviceLocal {
                guard let declared = manifest[policy.ref.rawValue] else {
                    Check.expect(false, "\(policy.ref.rawValue) is in the Swift table but not in data-map.yaml")
                    continue
                }
                Check.expectEqual(policy.days, declared.days, "\(policy.ref.rawValue) days match the manifest")
                Check.expectEqual(policy.basis.rawValue, declared.basis, "\(policy.ref.rawValue) basis matches the manifest")
            }

            // Every RetentionRef the code can name must exist in the manifest,
            // including the ones with no device-local subject yet.
            for ref in RetentionRef.allCases {
                Check.expect(manifest[ref.rawValue] != nil, "\(ref.rawValue) is declared in data-map.yaml")
            }
        }

        // The bug this prevents is not subtle: reading `days: 0` as "expires
        // immediately" would have the worker delete the user's entire library
        // on first launch. `on_user_delete` means the clock never runs.
        Check.suite("RetentionPolicy - an event-driven policy is never swept on a timer") {
            for policy in RetentionPolicy.deviceLocal where policy.basis == .onUserDelete {
                Check.expect(
                    !policy.isTimeDriven,
                    "\(policy.ref.rawValue) is deleted when the user asks, never on a schedule"
                )
            }
            Check.expect(
                RetentionPolicy(ref: .deviceLocalRetentionAudit, days: 90, basis: .rolling).isTimeDriven,
                "a rolling window with a positive TTL is swept"
            )
            Check.expect(
                !RetentionPolicy(ref: .audioAsset, days: 0, basis: .onRemovalOrClaim).isTimeDriven,
                "removal-driven retention is not a timer either"
            )
        }

        Check.suite("RetentionWorker - PLAN.md Step 1.3 gate") {
            // "Runs from day one against an empty database." A run of zero is
            // not a no-op: it is the evidence that the job is alive, which is
            // the difference between deletion that works and deletion nobody
            // has noticed is broken.
            try withTemporaryDirectory { root in
                let worker = RetentionWorker(auditURL: root.appendingPathComponent("retention.json"))
                let runs = try worker.run()
                Check.expectEqual(runs.count, 1, "one sweep for the one time-driven policy with a subject")
                Check.expectEqual(runs.first?.policyRef, .deviceLocalRetentionAudit, "and it is the audit log's own policy")
                Check.expectEqual(runs.first?.deletedCount, 0, "an empty store deletes nothing")
                Check.expectEqual(worker.auditTrail().count, 1, "the completion record is persisted")
            }

            // The gate proper: a seeded row past its TTL is hard-deleted and
            // produces a completion record.
            try withTemporaryDirectory { root in
                let auditURL = root.appendingPathComponent("retention.json")
                let now = Date(timeIntervalSince1970: 1_800_000_000)
                let ancient = now.addingTimeInterval(-91 * 86_400)
                let recent = now.addingTimeInterval(-10 * 86_400)

                let seeded = [
                    RetentionRun(id: "expired", ranAt: ancient, policyRef: .deviceLocalRetentionAudit, deletedCount: 0),
                    RetentionRun(id: "fresh", ranAt: recent, policyRef: .deviceLocalRetentionAudit, deletedCount: 0),
                ]
                let encoder = JSONEncoder()
                encoder.dateEncodingStrategy = .iso8601
                try encoder.encode(seeded).write(to: auditURL)

                let worker = RetentionWorker(auditURL: auditURL)
                let runs = try worker.run(now: now)

                Check.expectEqual(runs.first?.deletedCount, 1, "the row past its 90-day TTL is swept")
                let remaining = worker.auditTrail().map(\.id)
                Check.expect(!remaining.contains("expired"), "and is hard-deleted, not flagged (DG-RET-04)")
                Check.expect(remaining.contains("fresh"), "a row inside its window is untouched")
                Check.expect(remaining.count == 2, "the sweep itself leaves a completion record behind")
            }

            // A retention record must not become a way to keep what it deleted.
            Check.expect(
                RetentionRun.fieldClassifications.values.allSatisfy { $0.dataClass == .c1 },
                "the audit trail is C1 throughout - counts and policy names, never item identifiers"
            )
            Check.expect(
                PersistenceGuard.exportableFields(of: RetentionRun.self).isEmpty,
                "and none of it is user data, so none of it appears in an access request"
            )
        }
    }
}
