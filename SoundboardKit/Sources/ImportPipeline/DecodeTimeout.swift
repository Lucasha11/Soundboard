import Foundation
import GovernanceKit

/// Wall-clock bound on one stage of the import pipeline.
///
/// `BACKEND_PLAN.md` 4.1 sets a 10 second decode timeout **per stage**, and is
/// specific that "a stall is a rejection, not a retry". Imported media is
/// hostile input (`DG-SEC-04`), and a file does not have to crash a decoder to
/// hurt: one that makes `AVFoundation` sit forever is a denial of service on
/// the import queue, and it costs the attacker nothing.
///
/// The bound has to be outside the stage rather than inside it. A deadline
/// checked at the top of a read loop only helps while the loop keeps turning;
/// it does nothing for a track load, an encoder session, or a poster
/// generation that never returns at all. Racing the stage against a sleeping
/// task covers every await, including the ones inside a system framework.
///
/// - Note: the losing task is cancelled, but a system call already blocked
///   inside `AVFoundation` may not observe cancellation promptly. The caller
///   still gets `decodeTimeout` on time, which is what keeps the pipeline
///   responsive and the import queue moving; the abandoned work finishes into
///   a staging directory the launch sweeper deletes.
///
/// Public because it is the sanctioned way to bound *any* stage, including
/// ones added later outside this file, and because the B2 gate asserts that it
/// actually fires rather than taking an unexercised timeout on trust.
public func withDecodeTimeout<T: Sendable>(
    _ timeout: TimeInterval,
    operation: @escaping @Sendable () async throws -> T
) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask { try await operation() }
        group.addTask {
            try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
            throw ImportFailureCode.decodeTimeout
        }
        defer { group.cancelAll() }
        // The first task to finish decides the outcome: the real work if it
        // beat the clock, `decodeTimeout` if it did not.
        guard let first = try await group.next() else {
            throw ImportFailureCode.decodeFailed
        }
        return first
    }
}
