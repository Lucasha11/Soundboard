import Foundation

/// ITU-R BS.1770-4 integrated loudness.
///
/// Peak normalisation is the tempting shortcut here and it is the wrong one: a
/// clip with one transient spike and a quiet body normalises to nothing useful,
/// which is exactly the case a soundboard is full of. Gated loudness measures
/// what a listener perceives, so tiles end up at a consistent level.
///
/// Coefficients are the standard 48 kHz set. Input is resampled to 48 kHz
/// upstream, which is the canonical rate anyway, so no other rate is supported
/// rather than silently mismeasured.
public struct LoudnessMeter {
    /// Absolute gate. Below this a block contributes nothing.
    private static let absoluteGate = -70.0
    /// Relative gate below the ungated mean.
    private static let relativeGateOffset = -10.0
    private static let blockDuration = 0.400
    private static let overlap = 0.75

    public init() {}

    /// - Parameter channels: non-interleaved samples, one array per channel.
    /// - Returns: integrated loudness in LUFS, or nil if the signal is entirely
    ///   below the absolute gate, which means there is nothing to normalise.
    public func integratedLoudness(channels: [[Float]], sampleRate: Double = OutputFormat.sampleRate) -> Double? {
        guard !channels.isEmpty, let frameCount = channels.first?.count, frameCount > 0 else { return nil }

        let weighted = channels.map { Self.kWeight($0, sampleRate: sampleRate) }
        let blockSize = Int(Self.blockDuration * sampleRate)
        let hop = Int(Double(blockSize) * (1.0 - Self.overlap))
        guard blockSize > 0, hop > 0, frameCount >= blockSize else {
            // Shorter than one gating block. Fall back to a single block over
            // whatever is there, which is the honest answer for a 0.2 s clip.
            let power = Self.meanSquarePower(weighted, from: 0, count: frameCount)
            return power > 0 ? -0.691 + 10 * log10(power) : nil
        }

        var blockPowers: [Double] = []
        var start = 0
        while start + blockSize <= frameCount {
            blockPowers.append(Self.meanSquarePower(weighted, from: start, count: blockSize))
            start += hop
        }

        // First gate: drop blocks below the absolute threshold.
        let aboveAbsolute = blockPowers.filter { $0 > 0 && (-0.691 + 10 * log10($0)) > Self.absoluteGate }
        guard !aboveAbsolute.isEmpty else { return nil }

        // Second gate: relative to the mean of what survived the first.
        let ungatedMean = aboveAbsolute.reduce(0, +) / Double(aboveAbsolute.count)
        let relativeThreshold = -0.691 + 10 * log10(ungatedMean) + Self.relativeGateOffset
        let gated = aboveAbsolute.filter { (-0.691 + 10 * log10($0)) > relativeThreshold }
        guard !gated.isEmpty else { return nil }

        let mean = gated.reduce(0, +) / Double(gated.count)
        return -0.691 + 10 * log10(mean)
    }

    /// Linear gain that brings `channels` to `target` LUFS without letting the
    /// sample peak exceed `ceiling` dBFS. The peak constraint wins, because
    /// clipping is worse than being a little quiet.
    public func normalisationGain(
        channels: [[Float]],
        target: Double = OutputFormat.targetLoudness,
        ceiling: Double = OutputFormat.peakCeiling,
        sampleRate: Double = OutputFormat.sampleRate
    ) -> Float {
        guard let loudness = integratedLoudness(channels: channels, sampleRate: sampleRate) else { return 1.0 }
        let desired = pow(10.0, (target - loudness) / 20.0)

        let peak = channels.reduce(0.0) { partial, channel in
            max(partial, Double(channel.reduce(0) { max($0, abs($1)) }))
        }
        guard peak > 0 else { return 1.0 }
        let peakLimited = pow(10.0, ceiling / 20.0) / peak
        return Float(min(desired, peakLimited))
    }

    // MARK: - K-weighting

    /// Stage 1 high shelf plus stage 2 high pass, the BS.1770 pre-filter pair.
    static func kWeight(_ samples: [Float], sampleRate: Double) -> [Double] {
        let shelf = Biquad(
            b: (1.53512485958697, -2.69169618940638, 1.19839281085285),
            a: (-1.69065929318241, 0.73248077421585)
        )
        let highPass = Biquad(
            b: (1.0, -2.0, 1.0),
            a: (-1.99004745483398, 0.99007225036621)
        )
        return highPass.apply(shelf.apply(samples.map(Double.init)))
    }

    private static func meanSquarePower(_ channels: [[Double]], from start: Int, count: Int) -> Double {
        // Channel weights are 1.0 for left and right. Surround weights are not
        // implemented because no import path produces more than stereo.
        channels.reduce(0.0) { total, channel in
            var sum = 0.0
            for index in start..<(start + count) {
                sum += channel[index] * channel[index]
            }
            return total + sum / Double(count)
        }
    }
}

/// Direct form I biquad, double precision. The filters are run once per import,
/// so clarity beats a vectorised version here.
struct Biquad {
    let b: (Double, Double, Double)
    let a: (Double, Double)

    func apply(_ input: [Double]) -> [Double] {
        var output = [Double](repeating: 0, count: input.count)
        var x1 = 0.0, x2 = 0.0, y1 = 0.0, y2 = 0.0
        for index in 0..<input.count {
            let x0 = input[index]
            let y0 = b.0 * x0 + b.1 * x1 + b.2 * x2 - a.0 * y1 - a.1 * y2
            output[index] = y0
            x2 = x1; x1 = x0
            y2 = y1; y1 = y0
        }
        return output
    }
}
