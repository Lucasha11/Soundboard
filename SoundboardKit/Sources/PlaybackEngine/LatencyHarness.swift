import Foundation

/// Tap-to-sound latency, measured rather than asserted.
///
/// `BACKEND_PLAN.md` Section 5 puts the budget at **under 30 ms from
/// touch-down to first audible sample**, and Section 10 calls this "the number
/// the product lives or dies by". The B3 gate wants it over 100 trials at p99
/// on the oldest supported device.
///
/// This type is the harness for that measurement. It deliberately does two
/// separable things:
///
/// - ``LatencySamples`` is pure arithmetic over a list of durations, so the
///   statistics are covered by the checks on any machine. A p99 computed
///   wrongly would be worse than no measurement, because it would read as
///   evidence.
/// - ``measure(trials:body:)`` times a real trigger. On a simulator that number
///   is meaningless - there is no audio hardware and the output route is
///   emulated - so the gate's verdict is only meaningful from a device run.
///
/// What the harness cannot do is make a simulator measurement stand in for a
/// device one, and it does not pretend to: ``LatencyReport/isDeviceMeasurement``
/// records which kind of run produced the numbers, and the gate check refuses
/// to pass a simulator run.
public struct LatencySamples: Equatable, Sendable {
    /// Seconds, one per trial.
    public let durations: [TimeInterval]

    public init(_ durations: [TimeInterval]) {
        self.durations = durations
    }

    public var count: Int { durations.count }

    public var mean: TimeInterval {
        guard !durations.isEmpty else { return 0 }
        return durations.reduce(0, +) / Double(durations.count)
    }

    /// Nearest-rank percentile: the smallest value at or below which at least
    /// `p` of the samples fall.
    ///
    /// Nearest-rank rather than interpolation on purpose. An interpolated p99
    /// invents a number that no trial produced, and the claim being made here
    /// is "99 taps in 100 were at least this fast", which is a claim about
    /// observed taps.
    public func percentile(_ p: Double) -> TimeInterval {
        guard !durations.isEmpty else { return 0 }
        let clamped = min(max(p, 0), 1)
        let sorted = durations.sorted()
        // Rank is 1-based, so index is rank - 1.
        let rank = Int((clamped * Double(sorted.count)).rounded(.up))
        return sorted[max(0, min(sorted.count - 1, rank - 1))]
    }

    public var p99: TimeInterval { percentile(0.99) }
    public var median: TimeInterval { percentile(0.5) }
    public var worst: TimeInterval { durations.max() ?? 0 }
}

/// One run of the harness, with enough context to say whether its verdict counts.
public struct LatencyReport: Sendable {
    public let samples: LatencySamples
    /// False for a simulator or offline run. The B3 gate is only satisfied by
    /// a device measurement, and a report that cannot say which it was is a
    /// report that will eventually be quoted as if it were the other.
    public let isDeviceMeasurement: Bool
    /// The budget this run was measured against, in seconds.
    public let budget: TimeInterval

    public init(samples: LatencySamples, isDeviceMeasurement: Bool, budget: TimeInterval = 0.030) {
        self.samples = samples
        self.isDeviceMeasurement = isDeviceMeasurement
        self.budget = budget
    }

    /// Whether the run clears the budget at p99. Says nothing about whether the
    /// run was the right kind - see ``satisfiesB3Gate``.
    public var meetsBudget: Bool { samples.p99 <= budget }

    /// The B3 gate proper: a device run, at least 100 trials, p99 inside budget.
    public var satisfiesB3Gate: Bool {
        isDeviceMeasurement && samples.count >= 100 && meetsBudget
    }

    public var summary: String {
        let kind = isDeviceMeasurement ? "device" : "non-device (indicative only)"
        return String(
            format: "%@ run, %d trials: median %.2f ms, p99 %.2f ms, worst %.2f ms, budget %.0f ms",
            kind, samples.count, samples.median * 1000, samples.p99 * 1000,
            samples.worst * 1000, budget * 1000
        )
    }
}

public enum LatencyHarness {
    /// Whether this process can produce a measurement the B3 gate accepts.
    public static var isDeviceRun: Bool {
        #if targetEnvironment(simulator)
        return false
        #elseif os(iOS)
        return true
        #else
        return false
        #endif
    }

    /// Runs `body` `trials` times and reports the distribution.
    ///
    /// `body` should perform exactly the work on the tap path and return the
    /// instant the first sample is expected at, so what is measured is
    /// touch-down to audible rather than the cost of the call.
    public static func measure(
        trials: Int = 100,
        budget: TimeInterval = 0.030,
        body: () throws -> TimeInterval
    ) rethrows -> LatencyReport {
        var durations: [TimeInterval] = []
        durations.reserveCapacity(trials)
        for _ in 0..<trials {
            let tap = ProcessInfo.processInfo.systemUptime
            let expectedStart = try body()
            // The engine reports the expected start on the host clock, so the
            // difference is the real touch-down-to-audible figure including
            // hardware latency - not just how long `trigger` took to return.
            durations.append(max(0, expectedStart - tap))
        }
        return LatencyReport(
            samples: LatencySamples(durations),
            isDeviceMeasurement: isDeviceRun,
            budget: budget
        )
    }
}
