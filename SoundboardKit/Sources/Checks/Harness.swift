import Foundation

/// Minimal assertion harness.
///
/// XCTest and Swift Testing both require a full Xcode install. This runs the
/// same assertions as an executable so the plan's gates are verifiable now
/// rather than deferred. Each `expect` maps one-to-one onto an `#expect`.
enum Check {
    nonisolated(unsafe) static var failures: [String] = []
    nonisolated(unsafe) static var passes = 0
    nonisolated(unsafe) static var currentSuite = ""

    static func suite(_ name: String, _ body: () throws -> Void) {
        currentSuite = name
        print("\n\(name)")
        do {
            try body()
        } catch {
            record(false, "suite threw: \(error)")
        }
    }

    static func suite(_ name: String, _ body: () async throws -> Void) async {
        currentSuite = name
        print("\n\(name)")
        do {
            try await body()
        } catch {
            record(false, "suite threw: \(error)")
        }
    }

    static func expect(_ condition: Bool, _ label: String) {
        record(condition, label)
    }

    static func expectEqual<T: Equatable>(_ lhs: T, _ rhs: T, _ label: String) {
        record(lhs == rhs, lhs == rhs ? label : "\(label) [got \(lhs), wanted \(rhs)]")
    }

    static func expectClose(_ lhs: Double, _ rhs: Double, tolerance: Double, _ label: String) {
        let ok = abs(lhs - rhs) <= tolerance
        record(ok, ok ? label : "\(label) [got \(lhs), wanted \(rhs) +/- \(tolerance)]")
    }

    /// Asserts the closure throws, and that the thrown value matches if given.
    static func expectThrows<E: Error & Equatable>(_ expected: E?, _ label: String, _ body: () throws -> Void) {
        do {
            try body()
            record(false, "\(label) [did not throw]")
        } catch let error as E {
            guard let expected else { return record(true, label) }
            record(error == expected, error == expected ? label : "\(label) [threw \(error), wanted \(expected)]")
        } catch {
            record(false, "\(label) [threw unexpected \(error)]")
        }
    }

    private static func record(_ ok: Bool, _ label: String) {
        if ok {
            passes += 1
            print("  pass  \(label)")
        } else {
            failures.append("\(currentSuite): \(label)")
            print("  FAIL  \(label)")
        }
    }

    static func report() -> Never {
        print("\n\(passes) passed, \(failures.count) failed")
        if !failures.isEmpty {
            print("\nFailures:")
            failures.forEach { print("  \($0)") }
            exit(1)
        }
        exit(0)
    }
}

/// Scratch directory for checks that touch the file system. Never the user's
/// real container, and torn down after every run.
func withTemporaryDirectory(_ body: (URL) async throws -> Void) async rethrows {
    let root = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("soundboard-checks-\(UUID().uuidString)")
    try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    try await body(root)
}

func withTemporaryDirectory(_ body: (URL) throws -> Void) rethrows {
    let root = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("soundboard-checks-\(UUID().uuidString)")
    try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    try body(root)
}
