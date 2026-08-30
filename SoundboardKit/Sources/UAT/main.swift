import AVFoundation
import Foundation
import GovernanceKit
import ImportPipeline
import MediaStore
import PlaybackEngine
import QuartzCore
import VisualEngine

// soundboard-uat
//
// Hands-on testing for the parts of the app that exist: the verification gate,
// the extractor, and the playback engine. It runs the shipping code rather than
// a mock of it, so what you hear here is what a tile will sound like.
//
// What it cannot tell you: touch latency, scroll performance, or how the grid
// feels. Those are properties of an app that does not exist yet.
//
// Source scope is the same as the app's: a local video file you already own.
// There is no URL input, by design (DG-STOP-01/P1). The tool writes no log
// file and sends nothing anywhere.

setvbuf(stdout, nil, _IONBF, 0)

// MARK: - Arguments

struct Options {
    var sourcePath: String
    var start: TimeInterval = 0
    var duration: TimeInterval = 1.0
    var outputDirectory: URL
    var policy: RetriggerPolicy = .overlap
    var autoFire: Int?
    var interval: TimeInterval = 0.25
    /// How many tiles to build from the clip. More than four is where the
    /// decode cap becomes visible.
    var tiles: Int = 1
}

func printUsage() {
    print("""
    soundboard-uat - hear what a tile will sound like

    USAGE
      swift run soundboard-uat <video-file> [options]

    OPTIONS
      --start <seconds>     where to scrub to in the source   (default 0)
      --duration <seconds>  clip length, capped at 2          (default 1.0)
      --out <directory>     where derivatives are written     (default ./uat-output)
      --policy <p>          overlap | restart                 (default overlap)
      --fire <n>            fire n times and exit, no prompt
      --interval <seconds>  gap between automatic fires       (default 0.25)
      --tiles <n>           build n tiles from the clip       (default 1)
                            more than 4 shows the decode cap at work

    INTERACTIVE KEYS
      return   fire the tile
      8        fire eight times fast, to hear voice stealing
      a        fire every tile at once, to see the decode cap
      p        toggle overlap and restart
      s        engine and cache statistics
      q        quit
    """)
}

func parseOptions() -> Options? {
    var arguments = Array(CommandLine.arguments.dropFirst())
    guard !arguments.isEmpty, arguments[0] != "--help", arguments[0] != "-h" else { return nil }

    let source = arguments.removeFirst()
    guard !source.hasPrefix("--") else { return nil }
    var options = Options(
        sourcePath: source,
        outputDirectory: URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("uat-output")
    )

    var index = 0
    while index < arguments.count {
        let flag = arguments[index]
        let value = index + 1 < arguments.count ? arguments[index + 1] : nil
        switch flag {
        case "--start":     options.start = Double(value ?? "") ?? 0
        case "--duration":  options.duration = Double(value ?? "") ?? 1.0
        case "--out":       options.outputDirectory = URL(fileURLWithPath: value ?? "uat-output")
        case "--policy":    options.policy = RetriggerPolicy(rawValue: value ?? "") ?? .overlap
        case "--fire":      options.autoFire = Int(value ?? "")
        case "--interval":  options.interval = Double(value ?? "") ?? 0.25
        case "--tiles":     options.tiles = max(1, Int(value ?? "") ?? 1)
        default:
            print("unknown option: \(flag)")
            return nil
        }
        index += 2
    }
    return options
}

// MARK: - Reporting

func humanBytes(_ count: Int) -> String {
    count < 1024 ? "\(count) B"
        : count < 1_048_576 ? String(format: "%.1f KB", Double(count) / 1024)
        : String(format: "%.2f MB", Double(count) / 1_048_576)
}

func byteCount(_ url: URL) -> Int {
    (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
}

/// Reads a rendered file back and measures it, so the report states what the
/// clip actually is rather than what the pipeline intended.
func measureLoudness(of url: URL) -> Double? {
    guard let file = try? AVAudioFile(forReading: url) else { return nil }
    let frames = AVAudioFrameCount(file.length)
    guard frames > 0,
          let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: frames),
          (try? file.read(into: buffer)) != nil,
          let data = buffer.floatChannelData else { return nil }

    let channels = (0..<Int(buffer.format.channelCount)).map { channel in
        Array(UnsafeBufferPointer(start: data[channel], count: Int(buffer.frameLength)))
    }
    return LoudnessMeter().integratedLoudness(channels: channels, sampleRate: file.processingFormat.sampleRate)
}

func describe(_ code: ImportFailureCode) -> String {
    switch code {
    case .unsupportedContainer: return "that file format is not supported"
    case .unreadableFile:       return "the file looks damaged or truncated"
    case .fileTooLarge:         return "the file is over the size cap"
    case .sourceTooLong:        return "the source video is longer than the cap"
    case .dimensionsTooLarge:   return "the video dimensions are over the cap"
    case .frameCountTooHigh:    return "the file declares more frames than the cap allows"
    case .noAudioTrack:         return "there is no audio track to take a sound from"
    case .noVideoTrack:         return "there is no video track to take a tile picture from"
    case .decodeTimeout:        return "decoding stalled past the timeout"
    case .decodeFailed:         return "the file could not be decoded"
    case .silentSelection:      return "the selected window is silent, pick a different moment"
    case .audioEncodeFailed:    return "the clip audio could not be encoded"
    case .animationEncodeFailed:return "the tile animation could not be encoded"
    case .posterEncodeFailed:   return "the tile poster could not be written"
    case .encodeFailed:         return "encoding failed"
    case .storageFull:          return "there is no room left to store the clip"
    }
}

// MARK: - Run

guard let options = parseOptions() else {
    printUsage()
    exit(1)
}

let sourceURL = URL(fileURLWithPath: options.sourcePath)
guard FileManager.default.fileExists(atPath: sourceURL.path) else {
    print("no file at \(sourceURL.path)")
    exit(1)
}

print("\nSOURCE")
print("  file        \(sourceURL.lastPathComponent)")
print("  size        \(humanBytes(byteCount(sourceURL)))")

// 1. The verification gate, exactly as the app runs it.
let verifier = MediaVerifier()
let verified: MediaVerifier.Verified
do {
    verified = try verifier.verify(fileAt: sourceURL)
    print("  container   \(verified.container.rawValue)  (sniffed from bytes, not the extension)")
} catch let code as ImportFailureCode {
    print("\n  REJECTED at the verification gate: \(describe(code))  [\(code.rawValue)]")
    exit(1)
}

// 2. Extraction: trim, normalise, transcode.
print("\nEXTRACTING  \(String(format: "%.2f", options.duration))s from \(String(format: "%.2f", options.start))s")
let started = Date()
let artifacts: ClipArtifacts
do {
    artifacts = try await ClipExtractor().extract(
        from: sourceURL,
        start: options.start,
        duration: options.duration,
        into: options.outputDirectory
    )
} catch let code as ImportFailureCode {
    print("  FAILED: \(describe(code))  [\(code.rawValue)]")
    exit(1)
}
let elapsed = Date().timeIntervalSince(started)

let audioBytes = byteCount(artifacts.audioURL)
let animationBytes = artifacts.animationURL.map(byteCount) ?? 0
let posterBytes = byteCount(artifacts.posterURL)

print("  took        \(String(format: "%.2f", elapsed))s")
print("\nDERIVATIVES")
print("  audio       \(humanBytes(audioBytes))   \(artifacts.audioURL.lastPathComponent)")
if let animation = artifacts.animationURL {
    print("  animation   \(humanBytes(animationBytes))   \(animation.lastPathComponent)")
}
print("  poster      \(humanBytes(posterBytes))   \(artifacts.posterURL.lastPathComponent)")
print("  per tile    \(humanBytes(audioBytes + animationBytes + posterBytes))")
print("  written to  \(options.outputDirectory.path)")

print("\nLOUDNESS")
print("  gain        x\(String(format: "%.3f", artifacts.appliedGain))")
if let measured = measureLoudness(of: artifacts.audioURL) {
    let delta = measured - OutputFormat.targetLoudness
    print("  measured    \(String(format: "%.2f", measured)) LUFS  (target \(String(format: "%.1f", OutputFormat.targetLoudness)), off by \(String(format: "%.2f", abs(delta))))")
} else {
    print("  measured    below the gate, nothing to normalise")
}

// 3. The engines, in realtime, through your speakers and against the host clock.
let engine = PlaybackEngine(cache: BufferCache(capacity: 8), voiceCount: 8, renderMode: .realtime)
let visual = VisualEngine(
    posters: PosterStore(byteBudget: 48 * 1024 * 1024, targetPixelSize: OutputFormat.tilePixelSize),
    sessions: DecodeSessionPool(capacity: 4)
)

// Every tile is the same clip under a different id. That is enough to exercise
// the decode cap, the voice pool, and the poster fallback, which are the things
// a single tile cannot show.
let tileIDs = (0..<options.tiles).map { "tile-\($0)" }

let animationDuration: TimeInterval
if let animationURL = artifacts.animationURL {
    animationDuration = (try? await AVURLAsset(url: animationURL).load(.duration).seconds) ?? artifacts.duration
} else {
    animationDuration = 0
}

do {
    try engine.prepare()
    for id in tileIDs { try engine.preload(id, from: artifacts.audioURL) }
} catch {
    print("\ncould not start the audio engine: \(error)")
    exit(1)
}

let posterFailures = visual.prepare(page: tileIDs.map { (id: $0, posterURL: artifacts.posterURL) })
visual.setVisible(true, for: tileIDs)
if !posterFailures.isEmpty {
    print("\n  posters failed to decode: \(posterFailures.count)")
}

print("\nVISUAL")
print("  tiles       \(tileIDs.count)")
print("  animation   \(String(format: "%.2f", animationDuration))s per pass, decode cap \(visual.sessions.capacity) concurrent")
print("  posters     \(humanBytes(visual.residentBytes)) resident")

var policy = options.policy

/// One tile's picture, pumped against the audio's own start time.
///
/// This is the measurement worth having from a terminal: how far each frame
/// lands from where the audio clock says it should. Everything else about the
/// visual layer needs a screen.
struct PumpResult {
    var tileID: String
    var animated: Bool
    var frames = 0
    var late = 0
    var meanDriftMS = 0.0
    var maxDriftMS = 0.0
}

func pump(tileID: String, session: AnimationSession?, schedule: FrameSchedule) async -> PumpResult {
    var result = PumpResult(tileID: tileID, animated: session != nil)
    guard let session else { return result }

    var drifts: [Double] = []
    for loop in 0..<max(1, schedule.loopCount) {
        if loop > 0 { try? await session.restart() }
        while let frame = session.nextFrame() {
            let deadline = schedule.deadline(forFrameAt: frame.offset, loop: loop)
            guard schedule.isWithinClip(deadline) else { break }
            let now = CACurrentMediaTime()
            if deadline > now { try? await Task.sleep(for: .seconds(deadline - now)) }
            let drift = (CACurrentMediaTime() - deadline) * 1000
            drifts.append(drift)
            result.frames += 1
            // A frame more than one frame interval late would have been
            // presented after its successor was already due.
            if drift > 1000.0 / 30.0 { result.late += 1 }
        }
    }
    if !drifts.isEmpty {
        result.meanDriftMS = drifts.reduce(0, +) / Double(drifts.count)
        result.maxDriftMS = drifts.map(abs).max() ?? 0
    }
    return result
}

/// Fires the given tiles together: audio first, then the picture against the
/// start time the audio reported.
@MainActor
func fireTiles(_ ids: [String]) async {
    var pending: [(id: String, session: AnimationSession?, schedule: FrameSchedule)] = []

    for id in ids {
        do {
            let trigger = try engine.trigger(id, policy: policy)
            let fired = await visual.fire(
                tileID: id,
                animationURL: artifacts.animationURL,
                // The audio's own host-clock start, not the moment of the tap.
                audioStart: trigger.expectedStart,
                audioDuration: artifacts.duration,
                animationDuration: animationDuration
            )
            let mark = fired.session != nil ? "animating" : "poster   "
            let stolenNote = trigger.stoleVoice.map { _ in "  stole a voice" } ?? ""
            print("  \(id)  voice \(trigger.voiceIndex)  \(mark)\(stolenNote)")
            pending.append((id, fired.session, fired.schedule))
        } catch {
            print("  \(id)  trigger failed: \(error)")
        }
    }

    let results = await withTaskGroup(of: PumpResult.self) { group -> [PumpResult] in
        for item in pending {
            group.addTask { await pump(tileID: item.id, session: item.session, schedule: item.schedule) }
        }
        var collected: [PumpResult] = []
        for await result in group { collected.append(result) }
        return collected
    }

    let animated = results.filter(\.animated)
    let posterOnly = results.count - animated.count
    if !animated.isEmpty {
        let frames = animated.reduce(0) { $0 + $1.frames }
        let late = animated.reduce(0) { $0 + $1.late }
        let meanDrift = animated.reduce(0.0) { $0 + $1.meanDriftMS } / Double(animated.count)
        let maxDrift = animated.map(\.maxDriftMS).max() ?? 0
        print("  picture   \(animated.count) animating, \(posterOnly) on poster   \(frames) frames, \(late) late")
        print("  drift     mean \(String(format: "%+.1f", meanDrift)) ms   worst \(String(format: "%.1f", maxDrift)) ms")
    }
    for id in ids { visual.endAnimation(tileID: id) }
}

@MainActor
func fireRepeatedly(times: Int, gap: TimeInterval) async {
    for index in 0..<times {
        await fireTiles([tileIDs[index % tileIDs.count]])
        if index < times - 1 { try? await Task.sleep(for: .seconds(gap)) }
    }
}

if let count = options.autoFire {
    print("\nPLAYING  \(count) time(s), policy \(policy.rawValue)")
    await fireRepeatedly(times: count, gap: options.interval)
    print()
    exit(0)
}

print("""

PLAYING  policy \(policy.rawValue)
  return  fire      8  fire eight fast      a  fire all tiles      p  policy      s  stats      q  quit
""")

await fireTiles([tileIDs[0]])

while let line = readLine() {
    switch line.trimmingCharacters(in: .whitespaces).lowercased() {
    case "":
        await fireTiles([tileIDs[0]])
    case "8":
        // Eight fast fires is where voice stealing becomes audible, and where
        // overlap and restart sound completely different.
        await fireRepeatedly(times: 8, gap: 0.06)
    case "a":
        // Every tile at once. With more than four tiles this is where the
        // decode cap shows itself: four animate, the rest hold on their poster.
        await fireTiles(tileIDs)
    case "p":
        policy = policy == .overlap ? .restart : .overlap
        print("  policy now \(policy.rawValue)")
    case "s":
        let cache = engine.cache.statistics()
        let posters = visual.posters.statistics()
        let sessions = visual.sessions.statistics()
        print("  audio     triggers \(engine.triggerCount)   dropped \(engine.droppedTriggers)   active voices \(engine.activeVoiceCount)")
        print("  buffers   resident \(cache.residentCount)   \(humanBytes(cache.residentBytes))   hits \(cache.hits)   evictions \(cache.evictions)")
        print("  posters   resident \(posters.residentCount)   \(humanBytes(posters.residentBytes))   decodes \(posters.decodes)   evictions \(posters.evictions)")
        print("  decoders  active \(sessions.active) of \(visual.sessions.capacity)   stolen \(sessions.stolen)   sent to poster \(sessions.deniedToPoster)")
    case "q":
        engine.stopAll()
        visual.handleMemoryPressure()
        print()
        exit(0)
    default:
        print("  unknown key. return fires, 8 fires eight, a fires all, p toggles policy, s shows stats, q quits")
    }
}
