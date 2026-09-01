import Foundation
import ImportPipeline

private func sine(frequency: Double, amplitude: Float, seconds: Double, channels: Int = 2) -> [[Float]] {
    let frames = Int(OutputFormat.sampleRate * seconds)
    let channel = (0..<frames).map { index in
        amplitude * Float(sin(2 * Double.pi * frequency * Double(index) / OutputFormat.sampleRate))
    }
    return [[Float]](repeating: channel, count: channels)
}

enum AudioChecks {
    static func run() {
        let meter = LoudnessMeter()

        Check.suite("LoudnessMeter - BS.1770 integrated loudness") {
            let silence = [[Float]](repeating: [Float](repeating: 0, count: 48_000), count: 2)
            Check.expect(
                meter.integratedLoudness(channels: silence) == nil,
                "silence measures as nothing to normalise rather than negative infinity"
            )

            let loud = meter.integratedLoudness(channels: sine(frequency: 997, amplitude: 0.1, seconds: 1.0))
            Check.expect(loud != nil, "a one second tone measures")
            if let loud {
                Check.expect(loud > -30 && loud < -10, "a 0.1 amplitude tone lands in a sane LUFS range")
            }

            // Halving amplitude is exactly 6.02 dB. This is the check that
            // catches a broken filter or a mis-scaled mean square.
            let quiet = meter.integratedLoudness(channels: sine(frequency: 997, amplitude: 0.05, seconds: 1.0))
            if let loud, let quiet {
                Check.expectClose(loud - quiet, 6.02, tolerance: 0.15, "halving amplitude drops loudness by 6.02 dB")
            }

            // A clip shorter than one 400 ms gating block still has to measure,
            // because plenty of soundboard clips are 200 ms.
            let short = meter.integratedLoudness(channels: sine(frequency: 997, amplitude: 0.1, seconds: 0.2))
            Check.expect(short != nil, "a 200 ms clip still measures, shorter than one gating block")
        }

        Check.suite("LoudnessMeter - normalisation gain") {
            let quiet = sine(frequency: 997, amplitude: 0.05, seconds: 1.0)
            let gain = meter.normalisationGain(channels: quiet)
            Check.expect(gain > 1.0, "a quiet clip is brought up")

            var lifted = quiet
            for index in lifted.indices { ClipExtractor.applyGain(gain, to: &lifted[index]) }
            if let result = meter.integratedLoudness(channels: lifted) {
                Check.expectClose(result, OutputFormat.targetLoudness, tolerance: 0.5, "normalised output lands on the target")
            }

            // Peak normalisation is the tempting shortcut and this is why it is
            // wrong: a quiet clip with one transient must not be amplified into
            // clipping just because its perceived level is low.
            var spiky = sine(frequency: 997, amplitude: 0.02, seconds: 1.0)
            for index in spiky.indices { spiky[index][100] = 0.99 }
            let limited = meter.normalisationGain(channels: spiky)
            let peakAfter = spiky.flatMap { $0 }.map { abs($0 * limited) }.max() ?? 0
            let ceiling = Float(pow(10.0, OutputFormat.peakCeiling / 20.0))
            Check.expect(peakAfter <= ceiling + 0.0001, "the true peak ceiling wins over the loudness target")

            let silence = [[Float]](repeating: [Float](repeating: 0, count: 48_000), count: 2)
            Check.expectEqual(meter.normalisationGain(channels: silence), 1.0, "silence is left alone rather than amplified")
        }

        Check.suite("ClipExtractor - sample plumbing") {
            let channels: [[Float]] = [[1, 2, 3], [4, 5, 6]]
            let interleaved = ClipExtractor.interleave(channels)
            Check.expectEqual(interleaved, [1, 4, 2, 5, 3, 6], "interleave writes frame-major order")
            Check.expectEqual(
                ClipExtractor.deinterleave(interleaved, channelCount: 2).description,
                channels.description,
                "deinterleave round-trips"
            )
            Check.expectEqual(
                ClipExtractor.deinterleave([1, 2, 3], channelCount: 1).description,
                [[1, 2, 3] as [Float]].description,
                "mono passes through untouched"
            )

            // A trim boundary landing mid-waveform clicks on every single fire,
            // which is unbearable on a soundboard.
            var block = [Float](repeating: 1.0, count: 4800)
            ClipExtractor.applyEdgeFades(&block)
            Check.expectEqual(block.first ?? -1, 0, "the first sample is faded to zero")
            Check.expectEqual(block.last ?? -1, 0, "the last sample is faded to zero")
            Check.expectEqual(block[2400], 1.0, "the body of the clip is untouched")

            // A clip shorter than two fade lengths must not have its fades overlap
            // into negative gain or index out of range.
            var tiny = [Float](repeating: 1.0, count: 6)
            ClipExtractor.applyEdgeFades(&tiny)
            Check.expect(tiny.allSatisfy { $0 >= 0 && $0 <= 1 }, "fades stay in range on a very short clip")
        }
    }
}
