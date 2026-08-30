import Foundation
import GovernanceKit

/// A record that declares every field it stores.
private struct WellFormedRecord: ClassifiedRecord {
    static let storeName = "board_tile"
    static let fieldClassifications: [String: FieldSpec] = [
        "boardID": FieldSpec(dataClass: .c2, purposes: [.serve], retention: .deviceLocalBoardLayout),
        "soundID": FieldSpec(dataClass: .c1, purposes: [.serve], retention: .deviceLocalBoardLayout),
    ]
    let boardID: String
    let soundID: String
}

/// A record with a field somebody added without touching the classification
/// map. This is the exact drift the guard exists to catch, and the field chosen
/// is the one DG-LOG-01 names explicitly.
private struct DriftedRecord: ClassifiedRecord {
    static let storeName = "import_job"
    static let fieldClassifications: [String: FieldSpec] = [
        "jobID": FieldSpec(dataClass: .c1, purposes: [.serve], retention: .deviceLocalUserContent)
    ]
    let jobID: String
    let sourceFilename: String
}

/// A record with no purpose consuming one of its fields (P12).
private struct PurposelessRecord: ClassifiedRecord {
    static let storeName = "telemetry_draft"
    static let fieldClassifications: [String: FieldSpec] = [
        "deviceHint": FieldSpec(dataClass: .c2, purposes: [], retention: .applicationLogs)
    ]
    let deviceHint: String
}

private final class CollectingSink: LogSink {
    var lines: [String] = []
    func write(_ line: String) { lines.append(line) }
}

enum GovernanceChecks {
    static func run() {
        Check.suite("PersistenceGuard - PLAN.md Step 1.2 gate") {
            try PersistenceGuard.validate(
                WellFormedRecord(boardID: "b1", soundID: "s1"),
                encryptionAvailable: true
            )
            Check.expect(true, "a fully declared record persists")

            // DG-CLASS-01: a stored property absent from the map is refused, not defaulted.
            Check.expectThrows(
                GovernanceError.undeclaredProperty(store: "import_job", field: "sourceFilename"),
                "an undeclared stored property is refused"
            ) {
                try PersistenceGuard.validate(
                    DriftedRecord(jobID: "j1", sourceFilename: "anything"),
                    encryptionAvailable: true
                )
            }

            // DG-SEC-01: C2 and C3 cannot land on an unencrypted destination.
            Check.expectThrows(
                GovernanceError.missingEncryption(store: "board_tile", field: "boardID", dataClass: .c2),
                "C2 refuses to write without encryption at rest"
            ) {
                try PersistenceGuard.validate(
                    WellFormedRecord(boardID: "b1", soundID: "s1"),
                    encryptionAvailable: false
                )
            }

            // DG-PURP-03 and P12: nothing persists that no shipped feature consumes.
            Check.expectThrows(
                GovernanceError.noConsumingPurpose(store: "telemetry_draft", field: "deviceHint"),
                "a field with no consuming purpose is refused"
            ) {
                try PersistenceGuard.validate(PurposelessRecord(deviceHint: "x"), encryptionAvailable: true)
            }

            Check.expectEqual(PersistenceGuard.peakClass(of: WellFormedRecord.self), .c2, "peak class drives handling")
            Check.expect(DataClass.c3.requiresEncryptionAtRest, "C3 requires encryption at rest")
            Check.expect(!DataClass.c3.isLoggable, "C3 is never loggable")
        }

        Check.suite("RedactingLogger - DG-LOG-01, DG-LOG-02") {
            let sink = CollectingSink()
            let logger = RedactingLogger(subsystem: "import", sink: sink)
            let personal = "someone@example.com"

            logger.log("import_finished", [
                "code": .operational("ok"),
                "contact": LogValue(personal, .c2),
            ])
            let line = sink.lines.first ?? ""
            Check.expect(line.contains("<redacted:C2>"), "a C2 value reaching the logger is redacted")
            Check.expect(!line.contains(personal), "the C2 value never reaches the sink")
            Check.expect(line.contains("code=ok"), "C1 fields survive alongside it")

            // Second line of defence: a value mislabelled C1 that still looks
            // personal is scrubbed by shape, because callers get this wrong.
            let shapeSink = CollectingSink()
            let shapeLogger = RedactingLogger(subsystem: "import", sink: shapeSink)
            shapeLogger.log("source_selected", ["where": .operational("/Users/someone/Movies/clip.mov")])
            let shapeLine = shapeSink.lines.first ?? ""
            Check.expect(!shapeLine.contains("someone"), "a device path mislabelled C1 is still scrubbed")
            Check.expect(shapeLine.contains("<redacted:shape>"), "shape redaction marker present")

            let codeSink = CollectingSink()
            let codeLogger = RedactingLogger(subsystem: "import", sink: codeSink)
            codeLogger.log("import_rejected", ["reason": ImportFailureCode.frameCountTooHigh.logValue])
            Check.expectEqual(
                codeSink.lines.first ?? "",
                "[import] import_rejected reason=frameCountTooHigh",
                "failure codes log intact, since an enum case says nothing about the user"
            )
        }
    }
}
