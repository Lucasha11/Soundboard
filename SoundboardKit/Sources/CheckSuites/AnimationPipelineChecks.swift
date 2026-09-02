import AVFoundation
import Foundation
import GovernanceKit
import ImportPipeline
import VisualEngine

/// The gif half of a tile, end to end: decode a gif, transcode it, and pull
/// frames back out of the result.
///
/// This covers the seam that was missing rather than broken. Every piece here
/// existed and was tested in isolation - `AnimationSession` could read an mp4,
/// `DecodeSessionPool` could hand out four - but nothing produced an mp4 from a
/// gif in the first place (`AVFoundation` cannot read an animated gif at all),
/// and nothing ever called `nextFrame()`. So the tiles showed a still poster and
/// the gif never moved.
enum AnimationPipelineChecks {
    static func run() async {
        await Check.suite("GIFTranscoder - a gif becomes a tile animation and a poster") {
            try await withTemporaryDirectory { root in
                // 12 frames, the same shape as a real reaction gif, and with
                // 0x2C bytes in the pixel data so this also exercises the frame
                // counter that used to miscount commas as frames.
                let gif = root.appendingPathComponent("source.gif")
                try HostileCorpus.gifWithCommasInPixelData.write(to: gif)

                let artifacts = try await GIFTranscoder().transcode(
                    gifAt: gif, duration: 2.0, into: root
                )

                let poster = try require(try? Data(contentsOf: artifacts.posterURL))
                Check.expect(poster.count > 0, "a poster still is written")

                let animation = try require(try? Data(contentsOf: artifacts.animationURL))
                Check.expect(animation.count > 0, "an animation is written")

                // The tile visual must carry no audio track: the sound comes
                // from the audio blob, and a second copy would double-trigger.
                let asset = AVURLAsset(url: artifacts.animationURL)
                let audioTracks = try await asset.loadTracks(withMediaType: .audio)
                Check.expect(audioTracks.isEmpty, "the tile visual has no audio track")

                let videoTracks = try await asset.loadTracks(withMediaType: .video)
                Check.expectEqual(videoTracks.count, 1, "and exactly one video track")

                let size = try await require(videoTracks.first).load(.naturalSize)
                Check.expectEqual(
                    Int(size.width), OutputFormat.tilePixelSize,
                    "encoded at tile size, so the grid never scales up"
                )
                Check.expectEqual(Int(size.height), Int(size.width), "and square, so a vertical gif fills the tile")
            }
        }

        // The half that was never called. A session that yields no frames is
        // indistinguishable from a tile that does not animate, which is exactly
        // the state the app shipped in.
        await Check.suite("AnimationSession - frames actually come out") {
            try await withTemporaryDirectory { root in
                let gif = root.appendingPathComponent("source.gif")
                try HostileCorpus.gif(width: 120, height: 200, frames: 8).write(to: gif)
                let artifacts = try await GIFTranscoder().transcode(gifAt: gif, duration: 1.0, into: root)

                let session = AnimationSession(tileID: "tile", url: artifacts.animationURL)
                try await session.start()

                var frames = 0
                while session.nextFrame() != nil { frames += 1 }

                // A one second clip at 30 fps. Exactness is not the claim - the
                // claim is that the decoder produces a moving picture rather
                // than one frame or none.
                Check.expect(frames > 10, "a one second animation yields a stream of frames [\(frames)]")
                Check.expectEqual(session.framesDelivered, frames, "the session counts what it delivered")
                Check.expect(session.isFinished, "and reports itself finished at the end of the clip")
            }
        }

        // The pacing bug this suite exists to prevent a second time. Frames
        // carry their own presentation offsets, and the renderer is required
        // to honour them: pulling one frame per display tick looks right on a
        // 60 Hz simulator and runs a 30 fps clip at four times speed on a
        // 120 Hz phone, while the audio plays at normal speed.
        await Check.suite("AnimationSession - frames carry the offsets that pace them") {
            try await withTemporaryDirectory { root in
                let gif = root.appendingPathComponent("source.gif")
                try HostileCorpus.gif(width: 100, height: 100, frames: 6).write(to: gif)
                let artifacts = try await GIFTranscoder().transcode(gifAt: gif, duration: 1.0, into: root)

                let session = AnimationSession(tileID: "tile", url: artifacts.animationURL)
                try await session.start()

                var offsets: [TimeInterval] = []
                while let frame = session.nextFrame() { offsets.append(frame.offset) }

                Check.expect(offsets.count > 10, "the clip yields a stream of frames [\(offsets.count)]")
                Check.expectClose(offsets.first ?? -1, 0, tolerance: 0.001, "the first frame is due at the start")
                Check.expect(
                    offsets == offsets.sorted(),
                    "offsets increase, so a renderer can wait on them"
                )
                Check.expect(
                    (offsets.last ?? 0) > 0.9,
                    "and the last frame is due about a second in, not immediately [\(offsets.last ?? 0)]"
                )

                // The gap between frames is the encoded frame rate. A renderer
                // that ignores these would finish the clip in one tick per
                // frame instead of one thirtieth of a second per frame.
                let gaps = zip(offsets.dropFirst(), offsets).map { $0 - $1 }
                let mean = gaps.reduce(0, +) / Double(max(1, gaps.count))
                Check.expectClose(
                    mean, 1.0 / 30.0, tolerance: 0.005,
                    "consecutive frames are one thirtieth of a second apart"
                )
            }
        }

        // The decoder is held for the length of the clip and then given back.
        // Without the release, the pool leaks one decoder per fire and only
        // reclaims one when the cap forces it out - four concurrent animations
        // becomes four animations ever.
        await Check.suite("VisualEngine - a fired tile takes a decoder and gives it back") {
            try await withTemporaryDirectory { root in
                let gif = root.appendingPathComponent("source.gif")
                try HostileCorpus.gif(width: 100, height: 100, frames: 6).write(to: gif)
                let artifacts = try await GIFTranscoder().transcode(gifAt: gif, duration: 1.0, into: root)

                let engine = VisualEngine()
                let fired = await engine.fire(
                    tileID: "tile",
                    animationURL: artifacts.animationURL,
                    audioStart: ProcessInfo.processInfo.systemUptime,
                    audioDuration: 1.0,
                    animationDuration: 1.0
                )

                Check.expectEqual(fired.visual, .animating(tileID: "tile"), "the tile animates rather than falling back")
                Check.expect(fired.session != nil, "and a decoder session comes back with it")
                Check.expect(fired.session?.nextFrame() != nil, "which yields a frame when asked")

                engine.endAnimation(tileID: "tile")
                let second = await engine.fire(
                    tileID: "other",
                    animationURL: artifacts.animationURL,
                    audioStart: ProcessInfo.processInfo.systemUptime,
                    audioDuration: 1.0,
                    animationDuration: 1.0
                )
                Check.expectEqual(
                    second.visual, .animating(tileID: "other"),
                    "and the decoder is available again for the next tile"
                )
                engine.endAnimation(tileID: "other")
            }
        }
    }
}
