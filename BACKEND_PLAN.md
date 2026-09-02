# BACKEND_PLAN.md

Backend build plan for the **Soundboard iOS app** (gif + audio tiles, custom imports).
Subordinate to `DATA_GOVERNANCE.md` v2.0 and to the phase ordering in `PLAN.md`. Where this
document and either of those disagree, they win.

"Backend" here covers two things, because the app has two of them:

- **On-device backend** - the storage, import/transcode, and playback engine layer beneath the tile grid. This is where almost all the work is.
- **Server backend** - the catalog, submission, and takedown services the app talks to. Mostly already specified by `PLAN.md` Phases 3-5; this document specifies only the client-facing contract.

---

## 1. Governance position (Section 15, three questions)

Answered before any design below, per `DG-AGENT-01`.

| # | Question | Answer |
|---|---|---|
| 1 | Data class and declaration | User-recorded and user-imported media: **C4** by the v2.0 definition, stored and handled as **C3** by the choice recorded below. Board layout and tile metadata: **C2**. Catalog assets: **C4**. Playback counters: **C1**. Every one of these is declared in `governance/data-map.yaml` with a `retention_ref` before the migration that creates it merges. |
| 2 | Purpose and third parties | `P-SERVE` for playback of both lanes. `P-RANK` and `P-PRODUCT-ANALYTICS` for the catalog lane only. `P-SAFETY` for takedown propagation. **Nobody else sees the personal lane**: it never leaves the device (`DG-ACQ-08`). Apple is a platform processor for the app sandbox; any use of iCloud or CloudKit for this content needs a `vendors.yaml` entry first (`DG-VEND-01`, `DG-VEND-03`). |
| 3 | Anything prohibited | No. `P4` voice cloning is not built and is not proposed. `P7` is why import filenames never reach a log or a schema column. `P9` is why the hostile-media corpus is synthetic. `P10` is met by `device_local_user_content`. `P1` permits user-initiated import of a file the user already owns, which is the only ingestion route here. |

**A deliberate conservatism.** v2.0 no longer classes a voice recording as C3, so the personal lane could be downgraded. It is not. The blobs are already encrypted with `NSFileProtectionComplete` and never leave the device, so C3 handling costs nothing here and keeps the strictest treatment on the one lane holding a user's own voice. Recorded as a choice, not an oversight, so nobody removes it later thinking it was v1.0 residue.

**Rules governing this plan:** `DG-CLASS-01`, `DG-CLASS-02`, `DG-CLASS-03`, `DG-ACQ-01`, `DG-ACQ-06`, `DG-ACQ-08`, `DG-PURP-02`, `DG-PURP-03`, `DG-RET-01`, `DG-RET-02`, `DG-USER-04`, `DG-USER-05`, `DG-LOG-01`, `DG-LOG-05`, `DG-SEC-01`, `DG-SEC-04`, `DG-TAKE-02`, `DG-STOP-01` (P1, P7, P9, P10).

### Two flags from v1.0, both now closed

**Flag A - `DG-ACQ-01` versus custom imports. Closed by v2.0.** v1.0 said audio entered the system by exactly one route, verified creator upload under licence, which a personal import plainly was not. The plan resolved that by keeping personal imports out of the system entirely. v2.0 `DG-ACQ-01` now names four routes and two of them are user recording and user import, so the question the flag raised no longer exists. The architecture it produced is kept anyway: the two-lane split in 2.1 is good design independent of the rule that prompted it, and `DG-ACQ-08` now requires it directly.

**Flag B - phase ordering. Closed by v2.0.** v1.0 gated the mobile app behind Phases 0-4 because the app would serve catalog audio. v2.0 puts the personal-lane app at `PLAN.md` Phase 2, gated behind the governance skeleton only. The catalog lane remains gated, behind `PLAN.md` Phase 3, and community submissions behind Phase 0. No approval is outstanding.

---

## 2. Architecture

### 2.1 Two asset lanes, one playback path

```
        PERSONAL LANE                          CATALOG LANE
  user file / recording / gif            published server asset
             |                                      |
      import + transcode                    signed manifest fetch
       (on device, sandboxed)                       |
             |                                 CDN download
      local media store  <-------------------------- 
             |                                      |
             +------------ tile registry -----------+
                                |
                    playback engine (shared)
```

Both lanes converge on one local media store and one playback engine. They diverge on
everything governance cares about: origin, telemetry, retention, and removal.

| | Personal lane | Catalog lane |
|---|---|---|
| Origin | User's own file, recording, or gif | Bundled or published catalog asset |
| Leaves device | Never (`DG-ACQ-08`) | n/a (arrives, never returns) |
| Telemetry | None, ever | `P-RANK` counters, `P-PRODUCT-ANALYTICS`, opt-out in settings |
| Retention | Until user deletes | 24h without a fresh manifest |
| Removal | n/a | Mandatory, fail closed, inside the 48h takedown window (`DG-TAKE-02`) |
| Ads | Never rendered over a personal tile | `P-ADS`, ATT-gated (`DG-USER-04`) |

### 2.2 On-device module boundaries

Seven modules, each independently testable, no UI types below the top layer.

1. **MediaStore** - content-addressed blob storage on the file system.
2. **Catalog** - SwiftData/Core Data schema, tile registry, board layout.
3. **ImportPipeline** - type verification, caps enforcement, transcode, derivative generation.
4. **AudioEngine** - `AVAudioEngine` graph, buffer cache, trigger API.
5. **VisualEngine** - poster frames, video decode session pool, animation clock.
6. **CatalogSync** - manifest fetch, signature check, download, purge.
7. **GovernanceKit** - classification-aware persistence wrapper, log redaction, retention worker. Built first, per `PLAN.md` Phase 1 logic applied locally. Its redactor passes pseudonymous session and device IDs through and strips direct identifiers, which is the v2.0 `DG-LOG-01` boundary.

---

## 3. Local storage design

**Metadata in SQLite (via SwiftData), media as files.** Blobs never go in the database:
24 tiles per screen means 24 poster images decoded per scroll page, and the file system
plus `NSCache` handles that far better than row reads.

### 3.1 Blob layout

```
Application Support/
  media/
    audio/<sha256-prefix>/<sha256>.m4a     canonical compressed audio
    video/<sha256-prefix>/<sha256>.mp4     transcoded gif, no audio track
    poster/<sha256-prefix>/<sha256>.heic   first-frame still at tile resolution
```

- Content-addressed by SHA-256 of the **transcoded output**. This dedupes identical bytes, which is what makes storing the same file twice free. It does **not** reliably dedupe a re-import of the same moment: the encoder is not byte-deterministic. Measured, six repeated extractions of one source produced six mostly-distinct digests, two colliding by chance. Making re-import free needs source-keyed dedupe, a fingerprint of the source plus the trim window, which is not built.
- `Application Support`, not `Documents`: the user should not see raw derivative files in the Files app.
- `NSFileProtectionComplete` on every blob (`DG-SEC-01` requires encryption at rest for C2, C3 and C4 alike, so this holds under either classification).
- `isExcludedFromBackup = true` in v1. iCloud backup of user media is a vendor question that is not answered yet (8.2).
- Reference counting on `sha256`, so deleting one tile does not orphan a blob a second tile shares.

### 3.2 Schema

Every field carries a class tag at definition time and the persistence wrapper refuses to
write an unclassified field (`DG-CLASS-01`, `DG-CLASS-02`). Mirrors `PLAN.md` Step 1.2 on device.

| Store | Field | Class | Notes |
|---|---|---|---|
| `sound` | `id`, `lane`, `created_at`, `duration_ms` | C1 | |
| `sound` | `title` | C2 | User free text, never logged, never sent |
| `sound` | `audio_blob_id`, `video_blob_id`, `poster_blob_id` | C1 | |
| `sound` | `catalog_asset_id`, `manifest_expires_at` | C1 | Catalog lane only, null for personal |
| `media_blob` | `sha256`, `kind`, `bytes`, `codec`, `sample_rate`, `channels`, `width`, `height`, `fps`, `refcount` | C1 | |
| `media_blob` | payload on disk | C3 / C4 | C4 by the v2.0 definition; the personal lane keeps C3 handling by choice, see 1. |
| `board` | `id`, `name`, `ordinal` | C2 | |
| `board_tile` | `board_id`, `sound_id`, `row`, `col` | C2 | |
| `import_job` | `id`, `state`, `failure_code` | C1 | `failure_code` is an enum, never a message string |

`import_job` deliberately has no `source_filename` column. `DG-LOG-01` bars upload filenames
from logs, and there is no shipped feature that consumes one (`P12`).

Every one of these rows needs a `governance/data-map.yaml` entry with a `retention_ref`
before the migration that creates it merges. CI fails otherwise.

---

## 4. Import pipeline

Uploaded media is hostile input (`DG-SEC-04`). The pipeline is a state machine, and every
transition is a fail-closed gate.

```
received -> verified -> transcoded -> derived -> committed
                \-> rejected(code)
```

### 4.1 Verification gate

Runs before a single byte is decoded for real.

- **Type**: sniff by content, never by extension or UTI claim. Audio accepted: `m4a/aac`, `mp3`, `wav`, `aiff`, `caf`. Visual accepted: `gif`, `png`, `jpeg`, `heic`.
- **Size caps**: audio 25 MB, visual 25 MB.
- **Duration caps**: audio input 60 s (trimmed later), gif input 15 s.
- **Dimension caps**: 4096 x 4096, frame count 600.
- **Decode timeout**: 10 s wall clock per stage; a stall is a rejection, not a retry.
- Rejections produce an enum code and a neutral user-facing message. No decoder text is surfaced or logged.

### 4.2 Audio transcode

Every import is normalised to one canonical form so playback never branches on codec.

- Decode to 48 kHz float PCM, preserve mono if mono (halves both file size and the in-memory buffer).
- **Trim to the clip window.** Clips are 0-2 s. The user picks the window; the pipeline stores only the trimmed region, not the source. Default window if the user skips: first 2 s from the first sample above -40 dBFS, so leading silence does not eat the clip.
- **Loudness normalise to -16 LUFS integrated with a -1 dBTP ceiling.** This is the difference between a board that feels designed and one where every third tile is deafening. Measure with a real ITU-R BS.1770 implementation, not peak normalisation.
- 4 ms fade in and out to kill import clicks.
- Encode canonical AAC-LC 128 kbps `.m4a` for storage. Decoded PCM is a cache, not the source of truth.

### 4.3 Visual transcode - the important one

**GIFs are not played as GIFs.** 24 animated GIFs on screen means 24 independent
`CGImageSource` decode loops and a memory profile that will not survive a scroll on older
devices. At import, every gif is converted once:

- **GIF -> H.264 `.mp4`**, no audio track, 30 fps cap, capped at 2 s (looped if the source is shorter than the audio), scaled to 2x tile size (720 x 720 for a 360 pt tile at the largest supported layout), `AVAssetWriter` + VideoToolbox.
- **Poster frame** at the same resolution, HEIC, from the frame with the highest visual energy rather than frame 0, since many gifs open on black.
- Static image imports (png/jpeg/heic) produce a poster only and no video blob. The tile then pulses on trigger rather than animating.

The result: the idle grid is 24 static HEIC posters, which is cheap and scrolls at 120 Hz.
Only tiles that are currently firing hold a video decode session.

### 4.4 Where it runs

Off the main thread on a serial queue with a concurrency limit of 2, in a background task
so a lock screen does not kill a half-written blob. Commit is atomic: write blobs to a
staging directory, `fsync`, then insert the metadata row and move blobs in one transaction-like
step. A crash mid-import leaves staging garbage, which the launch sweeper deletes, and never
a metadata row pointing at a missing file.

---

## 5. Playback engine

Target: **under 30 ms from touch-down to first audible sample**, measured, not assumed.
A soundboard that feels laggy is a broken soundboard.

- **`AVAudioEngine` stays running.** Started once, never stopped between taps. Starting an engine on tap costs 100 ms or more.
- **Voice pool**: 8 pre-attached `AVAudioPlayerNode`s into a single `AVAudioMixerNode`. Trigger takes the least-recently-used free node. 8 concurrent voices covers rapid multi-finger drumming on the grid.
- **Preloaded `AVAudioPCMBuffer`s** for every tile in the visible board, so a trigger is `scheduleBuffer` + `play` with no file I/O.
- **Fire on touch-down**, not touch-up, and not on gesture recognition. Every millisecond of recogniser delay is audible here.
- **Retrigger policy**: overlap by default (tap twice fast, hear two voices), with a per-sound "restart instead" option. Overlap is what people expect from a soundboard.
- **Two defects found by running this end to end (2026-09-01).** The app never wired an audio session at all - `PlaybackEngine` defaults to `NullAudioSession`, so the category and buffer duration below were specified and never applied - and the graph was built synchronously during composition, blocking launch on IPC with the audio server. Both fixed. A third is environmental and recorded rather than worked around: `AVAudioEngine` output-node creation intermittently aborts in the simulator with `Cleanup: RPC timeout`, which an `abort()` inside AudioToolbox makes uncatchable. UI tests pass `--uitest-silent-audio`, since they assert what is on screen; the engine itself is covered by the offline render mode in `PlaybackChecks`.
- `AVAudioSession` category `.playback`, `.mixWithOthers` off by default so the app owns the output, preferred IO buffer duration 5 ms. Handle interruption, route change, and media services reset by rebuilding the graph and re-priming buffers.
- **Audio/visual sync**: both are triggered from the same touch event; the video layer's start is scheduled against the audio node's `lastRenderTime` so animation and sound line up rather than drifting by a frame or two.

---

## 6. Scaling 25 to 100+

The grid is paged at 24 tiles. Nothing about the design changes at 100; the budgets do.

| Resource | Per clip | 25 clips | 120 clips | Strategy |
|---|---|---|---|---|
| Decoded PCM (2 s, 48 kHz, stereo, f32) | 768 KB | 19 MB | 92 MB | LRU cache, ceiling 48 clips (~37 MB) |
| Compressed audio on disk | ~32 KB | 800 KB | 3.8 MB | Keep all |
| Video blob on disk | ~250 KB | 6 MB | 30 MB | Keep all |
| Poster in memory | ~180 KB | 4.5 MB | 21 MB | `NSCache`, evicted under pressure |
| Video decode sessions | 1 | - | - | Hard cap of 4 concurrent, others fall back to poster |

- **Preload horizon**: the visible page plus one page either side. Page change kicks a prefetch and an LRU eviction on the far side.
- **Decode session cap of 4** is the real constraint. VideoToolbox will not give you 24. Firing a fifth tile while four animate degrades the fifth to a poster flash rather than dropping frames across all of them.
- **Memory ceiling 150 MB** for the media layer, enforced by the LRU, with a `didReceiveMemoryWarning` path that drops to posters-only and re-primes lazily.
- Total on-disk footprint at 120 clips is under 40 MB, so disk is never the constraint. Memory and decode sessions are.

---

## 7. Server backend (catalog lane)

Phases 2-4 of `PLAN.md` own the ingest, gating, and ranking services. What this plan adds is
the **client contract**, because two of its requirements are easy to miss and expensive to retrofit.

### 7.1 Endpoints

| Endpoint | Purpose | Notes |
|---|---|---|
| `GET /v1/catalog/manifest?cursor=` | `P-SERVE` | Signed, carries `expires_at` no more than 24 h out |
| `GET /v1/catalog/assets/{id}/media` | `P-SERVE` | 302 to a short-TTL signed CDN URL |
| `POST /v1/events` | `P-RANK`, `P-PRODUCT-ANALYTICS` | Catalog lane only, declared events only, dropped if undeclared (`DG-LOG-05`) |
| `POST /v1/submissions` | `P-SAFETY` | Gated behind `PLAN.md` Phase 0. Writes the four-field submission record atomically with the asset (`DG-ACQ-02`) |
| `POST /v1/reports` | `P-SAFETY` | In-app route into the takedown channel (`DG-TAKE-01`) |

There is no age gate at v2.0. What replaces it is narrower and enforced in a different place: no
request carries a tracking identifier, and no SDK that reads one is initialised, before ATT
resolves (`DG-USER-04`). Playback and catalog requests are unaffected and may run immediately.

### 7.2 Removal on the client, fail closed

The binding window changed at v2.0 and got shorter in the case that matters. `DG-ACQ-06` gives a
submitter 7 days for their own removal request, but `DG-TAKE-02` gives a rights claim **48 hours**
to reach every surface, and a surface includes a phone in a pocket with no signal. The 24-hour
manifest expiry below was designed against the old rule and happens to sit inside the new one with
a full day of margin, so the number stays and only its justification changes. Polling alone is not
sufficient, because a device can be offline. So:

- The manifest is signed and carries `expires_at`.
- A catalog tile whose manifest has expired **refuses to play** and renders as unavailable. It does not play optimistically and reconcile later.
- Manifest refresh on launch, on foreground, and every 6 hours, giving four attempts inside the 24 h window and eight inside the 48 h takedown window.
- A removed asset id in a fresh manifest triggers immediate blob deletion plus row deletion, not a soft flag (`DG-RET-04`).

Personal-lane tiles are untouched by all of this and keep working offline forever. That is
the practical payoff of the two-lane split.

### 7.3 Stack

Postgres and object storage, CDN with signed URLs, transcode workers in network-isolated
containers (`DG-SEC-04`), secrets from a managed store (`DG-SEC-02`). v2.0 withdrew the US-only
restriction, so any region a major provider operates is available; the region is still declared in
the vendor entry, because the privacy notice states where data is processed (`DG-VEND-04`). Each of
these is a `vendors.yaml` entry with a DPA before any integration code (`DG-VEND-01`, `DG-VEND-02`).

Ads, analytics, attribution, and crash SDKs fall in the `DG-VEND-03` pre-approved categories, so
they need a manifest entry rather than a review cycle. The entry is still mandatory: `P8` did not
relax, and the App Store privacy label is generated from what is declared.

---

## 8. Open questions - answer before the phase that needs them

### 8.1 Where ads render (blocks Phase B6 exit)
`P-ADS` is approved at v2.0, which makes placement a design question rather than a governance
one, with a single hard edge: no personalised ad to a user known to be under 13 (`P6`), and no
tracking identifier before ATT (`DG-USER-04`). The proposal is that ads never render over or
inside a personal-lane tile, so the lane the user filled with their own voice stays uncommercial.
That is a product call, not a rule. **Open, needs a decision before B6.**

### 8.2 iCloud backup of user media (blocks Phase B1 exit)
Backing up user media to iCloud makes Apple a processor for it and needs a `vendors.yaml` entry.
v1 sets `isExcludedFromBackup = true` and ships without cross-device sync. Reversing it is a
vendor entry plus a privacy-label change, not a build flag. Unchanged by v2.0.

### 8.3 Board sharing (unblocked by v2.0, deliberately not scheduled)
Under v1.0 this was a hard stop: sharing a board of personal imports redistributed unlicensed
third-party voice content and hit `P3` directly. v2.0 reclassifies the same feature as a
community submission, `DG-ACQ-01` route (d), which is permitted under notice-and-takedown. It is
therefore buildable, and it inherits the full Phase 4 apparatus: submission record, moderation
gate, 48-hour takedown, strike ledger. It is not scheduled, because it would take the one lane
that currently transmits nothing and make it a publishing surface, and `DG-ACQ-08` is a promise
the privacy notice makes today. Scheduling it means changing that promise first.

---

## 9. Build order

Gated the same way as `PLAN.md`: no phase starts until the previous phase's exit criteria pass,
and `python3 governance/check.py` is green at every step.

### Phase B0 - Governance foundation on device (blocks everything)
- **B0.1** Classification-aware persistence wrapper. A write of an unclassified field raises. `DG-CLASS-01`, `DG-CLASS-02`
- **B0.2** Log redaction at the logging library boundary, not the call site. `DG-LOG-01`, `DG-LOG-02`
- **B0.3** `data-map.yaml` entries for every field in 3.2, including the new `device_local_user_content` retention policy. `DG-CLASS-03`, `DG-RET-01`
- **B0.4** ATT gate: no tracking identifier read and no SDK that reads one initialised before the prompt resolves. No age gate at v2.0; the app is rated 12+ and is not child-directed. `DG-USER-04`, `DG-USER-01`
- **Gate**: instrumented test proves zero reads of a tracking identifier before ATT resolves. Unit test proves an unclassified write raises, a C2 value reaching the logger is redacted, and a pseudonymous session ID is not. Flags A and B in Section 1 are closed, so nothing is outstanding here.
- **Gate met 2026-09-01.** `TrackingAndLaunchUITests` asserts an empty ledger on a simulator, before and after the app is used; `TrackingChecks` proves the instrument catches a real read and a real SDK initialisation, so an empty ledger cannot mean a broken instrument; `GovernanceChecks` covers the persistence guard and the redactor, and `SessionIdentifier` covers the pseudonymous half. `IdentifierVault` is the chokepoint - it refuses before ATT resolves and under any status but `.authorized`, and never calls the platform when refusing, so a refused read generates no identifier.

### Phase B1 - Local media store
- **B1.1** Content-addressed blob store with refcounting, file protection, backup exclusion.
- **B1.2** Schema and migrations for `sound`, `media_blob`, `board`, `board_tile`, `import_job`.
- **B1.3** Launch sweeper: orphaned blobs deleted, rows pointing at missing files repaired.
- **B1.4** Retention worker running against an empty store from day one, mirroring `PLAN.md` Step 1.3.
- **Gate**: kill the process at every point in a commit and prove no metadata row ever references a missing blob. Deleting a tile decrements refcount and deletes the blob only at zero.
- **Gate met 2026-09-01.** A process cannot be killed mid-call from a test, but only the blobs and `catalogue.json` are durable, so the container states a kill can produce are enumerable. `CrashSafetyChecks` replays all six and asserts the invariant after each. `RetentionChecks` covers B1.4, including a seeded row past its TTL being hard-deleted with a completion record.

### Phase B2 - Import pipeline
- **B2.1** Verification gate and caps (4.1), with a malformed-input fixture corpus: truncated gifs, gifs with absurd frame counts, audio with lying headers, zip bombs renamed to `.m4a`.
- **B2.2** Audio transcode, trim, loudness normalisation, fades (4.2).
- **B2.3** GIF to mp4 plus poster generation (4.3).
- **B2.4** Atomic commit and background task handling (4.4).
- **Gate**: every fixture in the corpus is rejected with an enum code and no crash, no hang past the timeout, and no partial row. `DG-SEC-04`
- **Gate met 2026-09-01.** `HostileCorpus` is the checked-in, synthetic-only corpus (`P9`); `VerifierChecks` asserts the codes the gate can settle from bytes alone, and `ImportPipelineChecks` drives every entry through `SoundLibrary.importClip` and asserts no record, no bytes and no staging survive. Two defects the gate caught rather than confirmed: the decode timeout was applied inside one read loop rather than per stage, so a stalled track load or encode hung the import queue unbounded; and raw `AVFoundation` errors escaped the pipeline carrying the source `NSURL` and decoder text in `userInfo`, which is the `DG-LOG-01` leak the closed enum exists to prevent. Only an `ImportFailureCode` can now leave `extract` or `importClip`.

### Phase B3 - Playback engine
- **B3.1** Engine graph, voice pool, buffer cache.
- **B3.2** Trigger API, retrigger policy, touch-down firing.
- **B3.3** Session handling: interruption, route change, media services reset.
- **B3.4** Audio and visual trigger synchronisation.
- **Gate**: measured tap-to-sound latency under 30 ms on the oldest supported device, over 100 trials, p99. Eight concurrent voices without dropout. Engine survives a call interrupting playback and a headphone unplug mid-clip.
- **Partly met 2026-09-01. The latency half is blocked on hardware and is not claimed.**
  - B3.3 is met, and building it found the defect: the interruption, route-change and media-services handlers existed and were covered, but nothing in the app ever called them. No observer was registered, so on a device a single incoming call would have stopped the player nodes and left every later tap silent until the app was force quit. `AudioSessionObserver` is the missing wire; `SessionResilienceChecks` drives every event through it, and the interruption `userInfo` parsing is factored to a pure function so it is tested by raw value on macOS too.
  - B3.4 is met: the frame schedule is asserted to be anchored to the reported audio start rather than to the tap.
  - Eight concurrent voices without dropout is covered by `PlaybackChecks`.
  - **The measured p99 is outstanding.** `LatencyHarness` is built and its arithmetic is covered - including that a non-device run cannot satisfy the gate however fast it looks - but the number itself needs a physical device. A simulator has no audio hardware and an emulated output route, so a figure from one would be evidence of nothing. Section 10 is explicit that a flaky latency test gets a wider threshold with a recorded justification or gets fixed, never a retry loop; inventing a simulator number would be worse than either. `LatencyReport.satisfiesB3Gate` refuses a non-device run by construction, so this cannot be closed by accident.

### Phase B4 - Scale to 100+
- **B4.1** LRU buffer cache with the 48-clip ceiling.
- **B4.2** Page-based prefetch horizon.
- **B4.3** Video decode session pool with the cap of 4.
- **B4.4** Memory pressure path.
- **Gate**: 120-tile board scrolls at 120 Hz with no dropped frames, media layer stays under the 150 MB ceiling, and rapid-firing 10 tiles never starves audio. Instruments trace attached to the PR.
- **Partly met 2026-09-01. The frame-rate half and the Instruments trace are blocked on hardware and are not claimed.**
  - B4.2 did not exist. "The visible page plus one either side" was a doc comment on `SoundboardController.preload`, which loaded every tile it was handed, and the composition handed it the whole catalogue. `PrefetchHorizon` is the missing behaviour, wired through `BoardModel.tileAppeared(at:)` so a real scroll moves it, with eviction on both caches so scrolling on actually frees memory rather than only adding to it.
  - The memory half of the gate is asserted at 120 tiles, per Section 10's "asserted, not eyeballed". Worth recording accurately: holding all 120 tiles is about 109 MB, which is *inside* the 150 MB ceiling - the honest objection is not that it overflows but that it spends 73% of the media budget on tiles that cannot be on screen, leaving too little for decode sessions, and that it admits 120 clips into a 48-entry LRU so most of the decodes it pays for are immediately evicted.
  - B4.1 (48-clip LRU), B4.3 (decode session cap of 4) and B4.4 (memory pressure) were already built and covered.
  - **Outstanding: 120 Hz with no dropped frames, and the Instruments trace.** Both are device measurements. A simulator renders through the host GPU with an emulated display link, so a frame-rate figure from one would be evidence of nothing.

### Phase B5 - Catalog lane (gated behind `PLAN.md` Phase 3)
- **B5.1** Signed manifest fetch and signature verification.
- **B5.2** Download, cache, and expiry enforcement with fail-closed playback.
- **B5.3** Removal purge across blobs, rows, and in-memory caches.
- **B5.4** Declared-events-only telemetry, catalog lane only, personal lane silent.
- **Gate**: timed end-to-end test. Remove server-side, then confirm the client cannot play the asset inside the 48 h takedown window, including the offline case where the manifest simply expires. Prove by network trace that a personal-lane trigger emits nothing.

### Phase B6 - Monetisation SDKs (gated behind `PLAN.md` Phase 6)
- **B6.1** ATT prompt and the initialisation ordering that depends on it, tested as ordering rather than assumed from SDK docs.
- **B6.2** Ads and attribution SDKs, each with a `vendors.yaml` entry and a declared region.
- **B6.3** Settings opt-outs: CCPA sale and share, plus `P-PRODUCT-ANALYTICS`.
- **B6.4** Privacy label regenerated from `data-map.yaml` and diffed in the release PR.
- **Gate**: binary-level SDK inventory matches `vendors.yaml` exactly, diffed from the built artifact rather than the dependency manifest. Instrumented test proves no tracking identifier is read before ATT resolves. Opting out measurably stops the sharing.

---

## 10. Test strategy

- **Fixture corpus** for hostile media, checked in, synthetic only (`P9` bars production data in tests).
- **Latency harness** measuring tap-to-sample on device, run in CI on a device farm, failing the build on regression. This is the number the product lives or dies by.
- **Memory ceiling test** at 120 tiles, asserted, not eyeballed.
- **Clock-injected retention tests** so a 24 h expiry and a 48 h takedown window are testable in milliseconds.
- **Network-silence test**: assert zero outbound packets attributable to a personal-lane trigger (`DG-ACQ-08`), and zero reads of a tracking identifier before ATT resolves (`DG-USER-04`).
- No flaky tests. A flaky latency test gets a wider threshold with a recorded justification or it gets fixed, never a retry loop.

---

## 11. Compliance Block (draft for the first implementing PR)

Required here because the first implementing PR adds persisted fields. `DG-AGENT-06` scopes the
block to PRs that add a persisted personal field, an analytics event, or a third-party SDK, so
later PRs in Phases B3 and B4 will not need one.

```
## Compliance Block
Data classes touched:   C1, C2, C3, C4
Purpose IDs:            P-SERVE
Rules applied:          DG-CLASS-01, DG-CLASS-02, DG-CLASS-03, DG-RET-01, DG-RET-04,
                        DG-LOG-01, DG-LOG-02, DG-SEC-01, DG-SEC-04, DG-ACQ-01, DG-ACQ-08
data-map.yaml updated:  yes - device_local_user_content and device_local_board_layout
Third parties involved: none in the personal lane
Checks reviewed:        P1-P12 reviewed, none prohibited at v2.0. P1 is satisfied because the
                        only ingestion route is a user-initiated import of a file the user
                        already owns. P7 by omitting source filenames from schema and logs.
                        P9 by a synthetic-only fixture corpus. P10 by the two retention
                        policies above.
```
