# BACKEND_PLAN.md

Backend build plan for the **Soundboard iOS app** (gif + audio tiles, custom imports).
Subordinate to `DATA_GOVERNANCE.md` and to the phase ordering in `PLAN.md`. Where this
document and either of those disagree, they win.

"Backend" here covers two things, because the app has two of them:

- **On-device backend** - the storage, import/transcode, and playback engine layer beneath the tile grid. This is where almost all the work is.
- **Server backend** - the catalog and revocation services the app talks to. Mostly already specified by `PLAN.md` Phases 2-4; this document specifies only the client-facing contract.

---

## 1. Governance position (Section 15, five questions)

Answered before any design below, per `DG-AGENT-01` and the `CLAUDE.md` PR requirement.

| # | Question | Answer |
|---|---|---|
| 1 | Data class | User-imported audio: **C3** where it contains a voice recording (Section 2 lists biometric-adjacent voice records as C3), **C4** otherwise. User-imported gif/image: **C4**. Board layout and tile metadata: **C2** (relates to an identified device/user). Catalog assets: **C4**. Playback counters for catalog assets: **C1** once aggregated, **C2** as raw events. |
| 2 | Purpose | `P-SERVE` for playback of both lanes. `P-RANK` for catalog engagement only. `P-SAFETY` for takedown propagation. Personal imports are consumed by **no** purpose beyond `P-SERVE` on the user's own device. |
| 3 | Retention | Personal imports: until the user deletes the tile or the app; needs a new `retention_ref` (`device_local_user_content`) before any code persists them, or `P10` is breached. Catalog cache: 24 hours max without a fresh signed manifest. |
| 4 | Who else sees it | Nobody. Personal-lane media **never leaves the device** in v1 (see 2.1). Apple is a platform processor for the app sandbox; any use of iCloud/CloudKit for this content requires a `vendors.yaml` entry first (`DG-VEND-01`, `DG-VEND-03`). |
| 5 | Prohibited patterns | `P3` and `P5` are the live risks and are why the personal lane is local-only and non-distributing. `P7` is why import filenames are never logged (`DG-LOG-01` names upload filenames explicitly). `P12` is why the personal lane emits zero telemetry. |

**Rules governing this plan:** `DG-CLASS-01`, `DG-CLASS-02`, `DG-CLASS-03`, `DG-ACQ-01`, `DG-ACQ-03`, `DG-ACQ-06`, `DG-PURP-02`, `DG-PURP-03`, `DG-RET-01`, `DG-RET-02`, `DG-USER-01`, `DG-USER-02`, `DG-USER-04`, `DG-LOG-01`, `DG-LOG-05`, `DG-SEC-01`, `DG-SEC-04`, `DG-STOP-01` (P3, P5, P7, P10, P12).

### Two flags raised before build, not after

**Flag A - `DG-ACQ-01` versus custom imports.** `DG-ACQ-01` says audio enters *the system* by exactly one route: verified creator upload under license. A user importing a clip for their own board is not that route. The plan resolves this by keeping personal imports **out of the system entirely**: they are written to the app sandbox, never transmitted, never served, never ranked, never indexed, never exported. Under that constraint `DG-ACQ-01` is not engaged, because nothing enters the backend. The moment any sync, backup-to-our-servers, or sharing feature is proposed for the personal lane, `DG-ACQ-01` engages in full and that feature must go through Phase 2's licensing pipeline. This reading needs the governance owner's confirmation before Step B1 starts (`DG-AGENT-07`).

**Flag B - phase ordering.** `PLAN.md` places the mobile app at Step 5.3, gated behind Phases 0-4. That gating exists because the app would serve catalog audio. A personal-lane-only build consumes no catalog asset and no ranking output, so it is genuinely independent of those gates. Recommendation: split Step 5.3 into **5.3a (personal lane, buildable now)** and **5.3b (catalog lane, still gated behind Phase 3)**. This is a change to a binding plan and needs the governance owner to approve it, not an implementer.

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
everything governance cares about: origin, telemetry, retention, and revocation.

| | Personal lane | Catalog lane |
|---|---|---|
| Origin | User's own file, recording, or gif | Phase 2/3 published asset |
| Leaves device | Never | n/a (arrives, never returns) |
| Telemetry | None, ever | `P-RANK` counters, `P-PRODUCT-ANALYTICS` on consent |
| Retention | Until user deletes | 24h without a fresh manifest |
| Revocation | n/a | Mandatory, fail closed (`DG-ACQ-06`) |
| Restricted Mode | Open question, see 8.1 | Curated subset only (`DG-USER-02`) |

### 2.2 On-device module boundaries

Seven modules, each independently testable, no UI types below the top layer.

1. **MediaStore** - content-addressed blob storage on the file system.
2. **Catalog** - SwiftData/Core Data schema, tile registry, board layout.
3. **ImportPipeline** - type verification, caps enforcement, transcode, derivative generation.
4. **AudioEngine** - `AVAudioEngine` graph, buffer cache, trigger API.
5. **VisualEngine** - poster frames, video decode session pool, animation clock.
6. **CatalogSync** - manifest fetch, signature check, download, purge.
7. **GovernanceKit** - classification-aware persistence wrapper, log redaction, retention worker. Built first, per `PLAN.md` Phase 1 logic applied locally.

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

- Content-addressed by SHA-256 of the **transcoded output**, which gives free dedupe when a user imports the same clip twice.
- `Application Support`, not `Documents`: the user should not see raw derivative files in the Files app.
- `NSFileProtectionComplete` on every blob (`DG-SEC-01`, and C3 voice content requires encryption at rest).
- `isExcludedFromBackup = true` in v1. iCloud backup of C3 voice content is a vendor question that is not answered yet (Flag in 8.2).
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
| `media_blob` | payload on disk | C3 / C4 | Class depends on lane and content, see 1. |
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

No endpoint is called at all before the age gate resolves, and none in Restricted Mode.

### 7.2 Revocation on the client, fail closed

`DG-ACQ-06` requires revocation to reach client-side prefetch within 24 hours. Polling is not
sufficient on its own, because a device can be offline. So:

- The manifest is signed and carries `expires_at`.
- A catalog tile whose manifest has expired **refuses to play** and renders as unavailable. It does not play optimistically and reconcile later.
- Manifest refresh on launch, on foreground, and every 6 hours, giving four attempts inside the 24 h window.
- A revoked asset id in a fresh manifest triggers immediate blob deletion plus row deletion, not a soft flag (`DG-RET-04`).

Personal-lane tiles are untouched by all of this and keep working offline forever. That is
the practical payoff of the two-lane split.

### 7.3 Stack

Postgres and object storage in us-only regions (`DG-VEND-04`), CDN with signed URLs,
transcode workers in network-isolated containers (`DG-SEC-04`), secrets from a managed
store (`DG-SEC-02`). Each of these is a `vendors.yaml` entry with an executed DPA before
any integration code (`DG-VEND-01`, `DG-VEND-02`).

---

## 8. Open questions - answer before the phase that needs them

### 8.1 Restricted Mode and personal imports (blocks Phase B0 exit)
`DG-USER-02` gives under-13 users "curated catalogue only". A local-only personal import
collects no personal data and transmits nothing, so it arguably belongs in Restricted Mode.
But `DG-AGENT-07` says an unclear case defaults to no. **Escalated, not decided.** If the
answer is no, Restricted Mode ships with the curated catalogue and the import button hidden,
which is a UI branch, not an architecture change.

### 8.2 iCloud backup of imported media (blocks Phase B1 exit)
Backing up C3 voice content to iCloud makes Apple a processor for that class and needs a
`vendors.yaml` entry. v1 sets `isExcludedFromBackup = true` and ships without cross-device
sync. Reversing this is a governance decision plus a vendor entry, not a build flag.

### 8.3 Board sharing
Sharing a board containing personal imports is redistribution of unlicensed third-party
voice content and hits `P3` head on. Not in scope. If wanted, it goes through Phase 2's
license pipeline like any other upload, or it ships as catalog-lane-only sharing.

---

## 9. Build order

Gated the same way as `PLAN.md`: no phase starts until the previous phase's exit criteria pass,
and `python3 governance/check.py` is green at every step.

### Phase B0 - Governance foundation on device (blocks everything)
- **B0.1** Classification-aware persistence wrapper. A write of an unclassified field raises. `DG-CLASS-01`, `DG-CLASS-02`
- **B0.2** Log redaction at the logging library boundary, not the call site. `DG-LOG-01`, `DG-LOG-02`
- **B0.3** `data-map.yaml` entries for every field in 3.2, including the new `device_local_user_content` retention policy. `DG-CLASS-03`, `DG-RET-01`
- **B0.4** Age gate before any identifier is generated or any SDK initialises, plus the Restricted Mode branch. `DG-USER-01`, `DG-USER-02`, `DG-USER-04`
- **Gate**: instrumented test proves zero network calls carrying an identifier before the gate resolves. Unit test proves an unclassified write raises and a C2 value reaching the logger is redacted. Flags A and B in Section 1 have written answers.

### Phase B1 - Local media store
- **B1.1** Content-addressed blob store with refcounting, file protection, backup exclusion.
- **B1.2** Schema and migrations for `sound`, `media_blob`, `board`, `board_tile`, `import_job`.
- **B1.3** Launch sweeper: orphaned blobs deleted, rows pointing at missing files repaired.
- **B1.4** Retention worker running against an empty store from day one, mirroring `PLAN.md` Step 1.3.
- **Gate**: kill the process at every point in a commit and prove no metadata row ever references a missing blob. Deleting a tile decrements refcount and deletes the blob only at zero.

### Phase B2 - Import pipeline
- **B2.1** Verification gate and caps (4.1), with a malformed-input fixture corpus: truncated gifs, gifs with absurd frame counts, audio with lying headers, zip bombs renamed to `.m4a`.
- **B2.2** Audio transcode, trim, loudness normalisation, fades (4.2).
- **B2.3** GIF to mp4 plus poster generation (4.3).
- **B2.4** Atomic commit and background task handling (4.4).
- **Gate**: every fixture in the corpus is rejected with an enum code and no crash, no hang past the timeout, and no partial row. `DG-SEC-04`

### Phase B3 - Playback engine
- **B3.1** Engine graph, voice pool, buffer cache.
- **B3.2** Trigger API, retrigger policy, touch-down firing.
- **B3.3** Session handling: interruption, route change, media services reset.
- **B3.4** Audio and visual trigger synchronisation.
- **Gate**: measured tap-to-sound latency under 30 ms on the oldest supported device, over 100 trials, p99. Eight concurrent voices without dropout. Engine survives a call interrupting playback and a headphone unplug mid-clip.

### Phase B4 - Scale to 100+
- **B4.1** LRU buffer cache with the 48-clip ceiling.
- **B4.2** Page-based prefetch horizon.
- **B4.3** Video decode session pool with the cap of 4.
- **B4.4** Memory pressure path.
- **Gate**: 120-tile board scrolls at 120 Hz with no dropped frames, media layer stays under the 150 MB ceiling, and rapid-firing 10 tiles never starves audio. Instruments trace attached to the PR.

### Phase B5 - Catalog lane (gated behind `PLAN.md` Phase 3)
- **B5.1** Signed manifest fetch and signature verification.
- **B5.2** Download, cache, and expiry enforcement with fail-closed playback.
- **B5.3** Revocation purge across blobs, rows, and in-memory caches.
- **B5.4** Declared-events-only telemetry, catalog lane only, personal lane silent.
- **Gate**: timed end-to-end test. Revoke server-side, then confirm the client cannot play the asset inside 24 h, including the offline case where the manifest simply expires. Prove by network trace that a personal-lane trigger emits nothing.

---

## 10. Test strategy

- **Fixture corpus** for hostile media, checked in, synthetic only (`P9` bars production data in tests).
- **Latency harness** measuring tap-to-sample on device, run in CI on a device farm, failing the build on regression. This is the number the product lives or dies by.
- **Memory ceiling test** at 120 tiles, asserted, not eyeballed.
- **Clock-injected retention tests** so a 24 h expiry is testable in milliseconds.
- **Network-silence test**: assert zero outbound packets attributable to a personal-lane trigger, and zero of any kind before the age gate resolves.
- No flaky tests. A flaky latency test gets a wider threshold with a recorded justification or it gets fixed, never a retry loop.

---

## 11. Compliance Block (draft for the first implementing PR)

```
## Compliance Block
Data classes touched:      C1, C2, C3, C4
Purpose IDs:               P-SERVE
Rules applied:             DG-CLASS-01, DG-CLASS-02, DG-CLASS-03, DG-RET-01, DG-RET-04,
                           DG-LOG-01, DG-LOG-02, DG-SEC-01, DG-SEC-04, DG-USER-01,
                           DG-USER-02, DG-USER-04, DG-ACQ-06
data-map.yaml updated:     yes
Retention defined:         yes - new device_local_user_content policy
Consent path:              not required for P-SERVE; personal lane emits no telemetry
Third parties involved:    none in the personal lane
Prohibited patterns check: P1-P12 reviewed. P3 and P5 addressed by keeping personal imports
                           local-only and non-distributing. P7 addressed by omitting source
                           filenames from schema and logs. P10 addressed by the new
                           retention policy. P12 addressed by emitting no personal-lane events.
Residual risk / notes:     Flag A (DG-ACQ-01 scope) and Flag B (PLAN.md 5.3 split) require
                           the governance owner's written answer before Phase B1.
```
