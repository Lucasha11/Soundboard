import AVFoundation
import Foundation
import PlaybackEngine
import VisualEngine

/// `BACKEND_PLAN.md` B3.3 and B3.4, and the harness for B3's measured gate.
///
/// B3.3's handlers were already covered in isolation. What was not covered,
/// and turned out not to exist, was anything that *calls* them: the engine
/// could survive an interruption but nothing told it one had happened.
enum SessionResilienceChecks {
    private static func makeBuffer(seconds: Double, frequency: Double = 440) -> AVAudioPCMBuffer {
        let format = BufferCache.format
        let frames = AVAudioFrameCount(Double(format.sampleRate) * seconds)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
        buffer.frameLength = frames
        for channel in 0..<Int(format.channelCount) {
            let data = buffer.floatChannelData![channel]
            for frame in 0..<Int(frames) {
                data[frame] = Float(sin(2 * .pi * frequency * Double(frame) / format.sampleRate)) * 0.5
            }
        }
        return buffer
    }

    static func run() {
        // The wiring, not the handlers. Every event has to reach the engine,
        // and reach it without throwing out of a system callback.
        Check.suite("AudioSessionObserver - B3.3: the handlers are actually called") {
            let engine = PlaybackEngine(
                cache: BufferCache(capacity: 4),
                voiceCount: 4,
                renderMode: .offline(maximumFrameCount: 4096)
            )
            try engine.prepare()
            engine.cache.admit(makeBuffer(seconds: 1.0), for: "tile")
            let observer = AudioSessionObserver(engine: engine)

            _ = try engine.trigger("tile")
            observer.apply(.interruptionBegan)
            Check.expectEqual(engine.activeVoiceCount, 0, "an interruption stops the voices")

            observer.apply(.interruptionEnded(shouldResume: true))
            engine.stopAll()
            _ = try engine.trigger("tile")
            let resumed = try engine.renderOffline(frameCount: AVAudioFrameCount(OutputFormatBridge.sampleRate * 0.5))
            Check.expect(peak(of: resumed) > 0.1, "and the board makes sound again once it ends")

            observer.apply(.routeChanged)
            engine.stopAll()
            _ = try engine.trigger("tile")
            let rerouted = try engine.renderOffline(frameCount: AVAudioFrameCount(OutputFormatBridge.sampleRate * 0.5))
            Check.expect(peak(of: rerouted) > 0.1, "a headphone unplug does not leave the board silent")

            observer.apply(.mediaServicesReset)
            Check.expect(engine.cache.contains("tile"), "a graph rebuild keeps the preloaded buffers")
            _ = try engine.trigger("tile")
            let rebuilt = try engine.renderOffline(frameCount: AVAudioFrameCount(OutputFormatBridge.sampleRate * 0.5))
            Check.expect(peak(of: rebuilt) > 0.1, "and the board works after the audio server restarts")

            Check.expect(observer.lastFailure == nil, "none of that failed")
        }

        // Reading the interruption userInfo is the error-prone part of the iOS
        // plumbing, so it is factored out and driven by raw value here - on a
        // platform where AVAudioSession does not exist at all.
        Check.suite("AudioSessionObserver - interruption userInfo, by raw value") {
            Check.expectEqual(
                AudioSessionObserver.interruptionEvent(typeRawValue: 0, optionsRawValue: nil),
                .interruptionBegan, "type 0 began"
            )
            Check.expectEqual(
                AudioSessionObserver.interruptionEvent(typeRawValue: 1, optionsRawValue: 1),
                .interruptionEnded(shouldResume: true), "type 1 with the resume bit set"
            )
            Check.expectEqual(
                AudioSessionObserver.interruptionEvent(typeRawValue: 1, optionsRawValue: 0),
                .interruptionEnded(shouldResume: false), "type 1 without it"
            )
            // Resuming uninvited is how an app ends up fighting whatever took
            // the session, so an absent options key must not read as "resume".
            Check.expectEqual(
                AudioSessionObserver.interruptionEvent(typeRawValue: 1, optionsRawValue: nil),
                .interruptionEnded(shouldResume: false), "absent options means do not resume"
            )
            Check.expect(
                AudioSessionObserver.interruptionEvent(typeRawValue: 99, optionsRawValue: nil) == nil,
                "an unknown type is ignored rather than guessed at"
            )
        }

        // B3.4. The picture is scheduled against the instant the audio will
        // actually start, not against the tap - otherwise the two drift apart
        // by exactly the hardware latency on every press.
        Check.suite("Trigger sync - B3.4: the picture follows the sound, not the tap") {
            let engine = PlaybackEngine(
                cache: BufferCache(capacity: 4),
                voiceCount: 4,
                renderMode: .offline(maximumFrameCount: 4096)
            )
            try engine.prepare()
            engine.cache.admit(makeBuffer(seconds: 1.0), for: "tile")

            let tap = ProcessInfo.processInfo.systemUptime
            let result = try engine.trigger("tile")
            let schedule = FrameSchedule(audioStart: result.expectedStart, audioDuration: 1.0, animationDuration: 1.0)

            Check.expectEqual(
                schedule.audioStart, result.expectedStart,
                "the frame schedule is anchored to the reported audio start"
            )
            Check.expect(
                schedule.audioStart >= tap,
                "which is at or after the tap, never before it"
            )
            Check.expect(
                schedule.audioStart - tap < 1.0,
                "and on the same host clock as the tap, so the two are comparable [delta \(schedule.audioStart - tap)s]"
            )
        }

        // The statistics behind the B3 gate. A p99 computed wrongly is worse
        // than no measurement, because it reads as evidence.
        Check.suite("LatencyHarness - the arithmetic behind the B3 number") {
            let samples = LatencySamples((1...100).map { Double($0) / 1000 })
            Check.expectClose(samples.median, 0.050, tolerance: 0.0011, "median of 1...100 ms")
            Check.expectClose(samples.p99, 0.099, tolerance: 0.0001, "p99 is nearest-rank, not interpolated")
            Check.expectClose(samples.worst, 0.100, tolerance: 0.0001, "worst is the maximum")
            Check.expectEqual(samples.count, 100, "every trial counts")

            // Where the tail actually sits, which is easy to get wrong in both
            // directions. p99 over 100 samples is the 99th value by
            // nearest-rank, so exactly one catastrophic tap is the 100th and
            // does *not* move it - that is what "99 taps in 100" means, not a
            // bug. It does move the worst case, which is why the report
            // carries both.
            var oneOutlier = (1...99).map { Double($0) / 1000 }
            oneOutlier.append(2.0)
            Check.expectClose(
                LatencySamples(oneOutlier).p99, 0.099, tolerance: 0.0001,
                "one bad tap in 100 sits above p99, by definition"
            )
            Check.expectClose(
                LatencySamples(oneOutlier).worst, 2.0, tolerance: 0.0001,
                "but it is visible as the worst case, so it cannot hide"
            )

            // Two in a hundred is 2% of taps, which p99 must show.
            var twoOutliers = (1...98).map { Double($0) / 1000 }
            twoOutliers += [2.0, 2.0]
            Check.expectClose(
                LatencySamples(twoOutliers).p99, 2.0, tolerance: 0.0001,
                "two bad taps in 100 do move p99, which is the metric earning its place"
            )

            Check.expectEqual(LatencySamples([]).p99, 0, "an empty run reports zero rather than trapping")

            // The gate is not satisfied by a fast number alone: it has to come
            // from a device, over enough trials.
            let fastButNotADevice = LatencyReport(
                samples: LatencySamples(Array(repeating: 0.005, count: 100)), isDeviceMeasurement: false
            )
            Check.expect(fastButNotADevice.meetsBudget, "5 ms is inside the 30 ms budget")
            Check.expect(
                !fastButNotADevice.satisfiesB3Gate,
                "but a non-device run cannot satisfy the B3 gate, however fast it looks"
            )

            let tooFewTrials = LatencyReport(
                samples: LatencySamples(Array(repeating: 0.005, count: 10)), isDeviceMeasurement: true
            )
            Check.expect(!tooFewTrials.satisfiesB3Gate, "nor can ten trials")

            let real = LatencyReport(
                samples: LatencySamples(Array(repeating: 0.005, count: 100)), isDeviceMeasurement: true
            )
            Check.expect(real.satisfiesB3Gate, "a device run of 100 trials inside budget does")

            let slow = LatencyReport(
                samples: LatencySamples(Array(repeating: 0.045, count: 100)), isDeviceMeasurement: true
            )
            Check.expect(!slow.satisfiesB3Gate, "and 45 ms fails it, which is the point of the number")

            Check.expect(
                !LatencyHarness.isDeviceRun,
                "this run is not on a device, so it cannot close the B3 gate - stated, not assumed"
            )
        }
    }

    private static func peak(of buffer: AVAudioPCMBuffer) -> Float {
        guard let data = buffer.floatChannelData else { return 0 }
        var maximum: Float = 0
        for channel in 0..<Int(buffer.format.channelCount) {
            for frame in 0..<Int(buffer.frameLength) {
                maximum = max(maximum, abs(data[channel][frame]))
            }
        }
        return maximum
    }
}
