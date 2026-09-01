import AVFoundation
import CoreGraphics
import CoreVideo
import Foundation
import GovernanceKit
import ImageIO
import ImportPipeline
import QuartzCore
import UniformTypeIdentifiers
import VisualEngine

private func writePoster(_ url: URL, side: Int, shade: CGFloat) throws {
    let context = CGContext(
        data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
    )!
    context.setFillColor(CGColor(red: shade, green: 0.3, blue: 0.5, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: side, height: side))
    let image = context.makeImage()!
    try? FileManager.default.removeItem(at: url)
    let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.heic.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else { throw ImportFailureCode.posterEncodeFailed }
}

enum VisualChecks {
    static func run() async {
        scheduleChecks()
        posterChecks()
        await sessionAndPoolChecks()
    }

    // MARK: - Sync arithmetic

    private static func scheduleChecks() {
        Check.suite("FrameSchedule - picture against the audio clock") {
            // The tile is scheduled against when the sound will be audible, not
            // when the finger went down. Those differ by output latency, and
            // driving the picture from the touch puts it ahead on every fire.
            let schedule = FrameSchedule(audioStart: 100.0, audioDuration: 2.0, animationDuration: 1.0)

            Check.expectClose(schedule.deadline(forFrameAt: 0), 100.0, tolerance: 0.0001, "the first frame is due when the sound starts")
            Check.expectClose(schedule.deadline(forFrameAt: 0.5), 100.5, tolerance: 0.0001, "frames are offset from the audio start")

            // A one second picture under a two second sound loops rather than
            // freezing on its last frame for half the clip.
            Check.expectEqual(schedule.loopCount, 2, "a short animation loops to cover the sound")
            Check.expectClose(schedule.deadline(forFrameAt: 0, loop: 1), 101.0, tolerance: 0.0001, "the second pass starts one animation later")

            let longer = FrameSchedule(audioStart: 0, audioDuration: 0.5, animationDuration: 2.0)
            Check.expectEqual(longer.loopCount, 1, "an animation longer than the sound plays once")

            Check.expect(schedule.isWithinClip(101.9), "a frame before the sound ends is still wanted")
            Check.expect(!schedule.isWithinClip(102.1), "the picture stops when the sound does")

            Check.expectClose(schedule.drift(presented: 100.02, forFrameAt: 0), 0.02, tolerance: 0.0001, "late frames report positive drift")
            Check.expectClose(schedule.drift(presented: 99.99, forFrameAt: 0), -0.01, tolerance: 0.0001, "early frames report negative drift")

            let degenerate = FrameSchedule(audioStart: 0, audioDuration: 1.0, animationDuration: 0)
            Check.expectEqual(degenerate.loopCount, 0, "a tile with no animation asks for no loops rather than dividing by zero")
        }
    }

    // MARK: - Posters

    private static func posterChecks() {
        Check.suite("PosterStore - the idle grid") {
            try withTemporaryDirectory { root in
                var urls: [URL] = []
                for index in 0..<6 {
                    let url = root.appendingPathComponent("poster\(index).heic")
                    try writePoster(url, side: 720, shade: CGFloat(index) / 6)
                    urls.append(url)
                }

                let store = PosterStore(byteBudget: 3 * 720 * 720 * 4, targetPixelSize: 720)
                let first = try store.poster(for: "t0", at: urls[0])
                Check.expectEqual(first.width, 720, "a poster decodes at tile size")
                Check.expectEqual(store.statistics().decodes, 1, "the first request decodes")

                _ = try store.poster(for: "t0", at: urls[0])
                Check.expectEqual(store.statistics().decodes, 1, "a resident poster is not decoded twice")
                Check.expect(store.statistics().hits > 0, "the second request is a cache hit")

                // Budget is in bytes, because a poster costs its pixels: about
                // 2 MB each at tile size.
                for index in 1..<6 { _ = try store.poster(for: "t\(index)", at: urls[index]) }
                Check.expect(store.statistics().residentBytes <= 4 * 720 * 720 * 4, "the store stays within its byte budget")
                Check.expect(store.statistics().evictions > 0, "eviction happened")

                // A poster on screen is never the victim. Evicting one leaves a
                // hole in the grid the user is looking at.
                let visibleStore = PosterStore(byteBudget: 2 * 720 * 720 * 4, targetPixelSize: 720)
                _ = try visibleStore.poster(for: "onscreen", at: urls[0])
                visibleStore.setVisible(true, for: ["onscreen"])
                for index in 1..<5 { _ = try visibleStore.poster(for: "t\(index)", at: urls[index]) }
                Check.expect(visibleStore.contains("onscreen"), "a visible poster survives eviction")

                visibleStore.evictOffscreen()
                Check.expect(visibleStore.contains("onscreen"), "memory pressure keeps what is on screen")
                Check.expectEqual(visibleStore.statistics().residentCount, 1, "memory pressure drops everything off screen")

                Check.expectThrows(ImportFailureCode.unreadableFile, "a missing poster fails closed as a typed code") {
                    _ = try store.poster(for: "absent", at: root.appendingPathComponent("nothing.heic"))
                }
            }
        }
    }

    // MARK: - Sessions and the decode cap

    private static func sessionAndPoolChecks() async {
        await Check.suite("AnimationSession and DecodeSessionPool") {
            try await withTemporaryDirectory { root in
                // Real media, produced by the real extractor.
                let source = root.appendingPathComponent("source.mov")
                try await SourceVideo.write(to: source, seconds: 3.0)
                let artifacts = try await ClipExtractor().extract(
                    from: source, start: 1.0, duration: 1.0,
                    into: root.appendingPathComponent("staging")
                )
                guard let animationURL = artifacts.animationURL else {
                    return Check.expect(false, "the extractor produced no animation to decode")
                }

                // --- Streaming decode -------------------------------------
                let session = AnimationSession(tileID: "tile", url: animationURL)
                try await session.start()

                var frames = 0
                var offsets: [TimeInterval] = []
                var dimensions = (width: 0, height: 0)
                while let frame = session.nextFrame() {
                    frames += 1
                    offsets.append(frame.offset)
                    if frames == 1 {
                        dimensions = (
                            CVPixelBufferGetWidth(frame.pixelBuffer),
                            CVPixelBufferGetHeight(frame.pixelBuffer)
                        )
                    }
                }
                Check.expect(frames > 20, "a one second tile at 30 fps decodes about 30 frames [got \(frames)]")
                Check.expectEqual(dimensions.width, OutputFormat.tilePixelSize, "frames arrive at tile width")
                Check.expectEqual(dimensions.height, OutputFormat.tilePixelSize, "frames arrive square")
                Check.expect(offsets == offsets.sorted(), "presentation offsets advance monotonically")
                Check.expect(session.nextFrame() == nil, "the session reports the end of the clip")

                // The number that shapes this whole module: one tile fully
                // decoded is far more memory than the entire media budget, so
                // frames stream and the pool is capped.
                let fullyDecodedBytes = frames * dimensions.width * dimensions.height * 4
                Check.expect(
                    fullyDecodedBytes > 40 * 1024 * 1024,
                    "decoding one tile upfront would cost \(fullyDecodedBytes / 1024 / 1024) MB, which is why frames stream"
                )

                try await session.restart()
                Check.expect(session.nextFrame() != nil, "restart rewinds to the first frame")
                session.stop()
                Check.expect(session.nextFrame() == nil, "a stopped session delivers nothing")

                // --- The cap ----------------------------------------------
                let pool = DecodeSessionPool(capacity: 4)
                let stillPlaying = CACurrentMediaTime() + 60
                for index in 0..<4 {
                    let (visual, opened) = await pool.acquire(
                        tileID: "t\(index)", url: animationURL, activeUntil: stillPlaying
                    )
                    Check.expectEqual(visual, .animating(tileID: "t\(index)"), "tile \(index) animates")
                    Check.expect(opened != nil, "tile \(index) holds a decoder")
                }
                Check.expectEqual(pool.activeCount, 4, "four tiles animate at once")

                // VideoToolbox will not hand out 24 decoders, so a fifth tile
                // fired while four are still animating shows its poster.
                //
                // The alternative, taking a decoder from a live tile, freezes
                // that tile partway through its animation. One still tile reads
                // as a flash; one frozen tile reads as a bug.
                let (denied, deniedSession) = await pool.acquire(
                    tileID: "t4", url: animationURL, activeUntil: stillPlaying
                )
                Check.expectEqual(denied, .poster(tileID: "t4"), "a fifth tile fired mid-animation falls back to its poster")
                Check.expect(deniedSession == nil, "the denied tile holds no decoder")
                Check.expectEqual(pool.activeCount, 4, "the cap is never exceeded")
                Check.expect(pool.isAnimating("t0"), "no live tile lost its decoder")
                Check.expectEqual(pool.statistics().stolen, 0, "nothing was taken from a tile still animating")

                // A tile whose sound has ended is reclaimable, which is how the
                // pool keeps working once clips finish.
                pool.releaseAll()
                let finished = CACurrentMediaTime() - 1
                for index in 0..<4 {
                    _ = await pool.acquire(tileID: "done\(index)", url: animationURL, activeUntil: finished)
                }
                Check.expectEqual(pool.activeCount, 4, "four finished tiles still hold their slots until reclaimed")
                let (reclaimed, reclaimedSession) = await pool.acquire(
                    tileID: "fresh", url: animationURL, activeUntil: stillPlaying
                )
                Check.expectEqual(reclaimed, .animating(tileID: "fresh"), "a finished tile's decoder is reclaimed")
                Check.expect(reclaimedSession != nil, "the new tile holds the reclaimed decoder")
                Check.expect(!pool.isAnimating("done0"), "the oldest finished tile is the one reclaimed")
                Check.expectEqual(pool.activeCount, 4, "the cap holds after a reclaim")

                // Re-firing a tile that is already animating restarts it rather
                // than opening a second decoder for the same tile.
                let before = pool.activeCount
                let (again, _) = await pool.acquire(tileID: "fresh", url: animationURL, activeUntil: stillPlaying)
                Check.expectEqual(again, .animating(tileID: "fresh"), "re-firing an animating tile keeps animating")
                Check.expectEqual(pool.activeCount, before, "re-firing opens no second decoder")

                pool.release(tileID: "fresh")
                Check.expectEqual(pool.activeCount, before - 1, "releasing frees a slot")
                pool.releaseAll()
                Check.expectEqual(pool.activeCount, 0, "releaseAll retires every decoder")

                // A tile whose animation cannot be opened must fall back to its
                // poster and must not leave its reservation behind. A leaked
                // reservation would shrink the cap by one on every failure
                // until nothing could animate at all.
                let broken = root.appendingPathComponent("not-a-video.mp4")
                try Data("nonsense".utf8).write(to: broken)
                for index in 0..<6 {
                    let (visual, opened) = await pool.acquire(
                        tileID: "bad\(index)", url: broken, activeUntil: stillPlaying
                    )
                    Check.expect(visual == .poster(tileID: "bad\(index)") && opened == nil, "an unopenable animation falls back to poster")
                }
                Check.expectEqual(pool.activeCount, 0, "failed opens leak no capacity")

                let (recovered, _) = await pool.acquire(
                    tileID: "good", url: animationURL, activeUntil: stillPlaying
                )
                Check.expectEqual(recovered, .animating(tileID: "good"), "the pool still works after repeated failures")
                pool.releaseAll()

                // --- The coordinator --------------------------------------
                let visual = VisualEngine(
                    posters: PosterStore(byteBudget: 8 * 720 * 720 * 4, targetPixelSize: 720),
                    sessions: DecodeSessionPool(capacity: 4)
                )
                let failures = visual.prepare(page: [(id: "tile", posterURL: artifacts.posterURL)])
                Check.expect(failures.isEmpty, "the page prepares its posters")
                Check.expect(visual.poster(for: "tile") != nil, "a prepared poster is available to the grid")

                // A still import has no animation. That is a legitimate tile:
                // it pulses on fire rather than animating.
                let (stillVisual, stillSession, stillSchedule) = await visual.fire(
                    tileID: "still", animationURL: nil,
                    audioStart: 10, audioDuration: 1.0, animationDuration: 0
                )
                Check.expectEqual(stillVisual, .poster(tileID: "still"), "a tile with no animation shows its poster")
                Check.expect(stillSession == nil, "a still tile holds no decoder")
                Check.expectClose(stillSchedule.audioStart, 10, tolerance: 0.0001, "a still tile still gets a schedule")

                let (firedVisual, _, schedule) = await visual.fire(
                    tileID: "tile", animationURL: animationURL,
                    audioStart: 42.0, audioDuration: 1.0, animationDuration: 1.0
                )
                Check.expectEqual(firedVisual, .animating(tileID: "tile"), "firing a tile animates it")
                Check.expectClose(schedule.deadline(forFrameAt: 0), 42.0, tolerance: 0.0001, "the picture is scheduled on the audio clock")

                visual.setVisible(true, for: ["tile"])
                visual.handleMemoryPressure()
                Check.expectEqual(visual.sessions.activeCount, 0, "memory pressure retires every decoder")
                Check.expect(visual.poster(for: "tile") != nil, "memory pressure keeps the visible poster")
                Check.expect(visual.residentBytes > 0, "the visual layer reports what it is holding")
            }
        }
    }
}
