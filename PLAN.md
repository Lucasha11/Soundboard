# PLAN.md

Build order for **Soundboard**. Binding alongside `DATA_GOVERNANCE.md` v2.0.

**Rule for every phase:** `python3 governance/check.py` is green at the end of every step. A step whose control cannot be met stops and escalates rather than shipping with a TODO (`DG-AGENT-04`).

**What drives this ordering.** v1.0 sequenced everything behind rights clearance, because no audio could exist until a license record existed first. v2.0 dissolves that chain: three of the four content routes (bundled, user recording, user import) need no clearance at all, so the app moves to the front and the rights machinery moves to where it is actually load-bearing. One ordering constraint replaces the old one, and it is not negotiable:

> The DMCA agent registration, the takedown channel, and the moderation gate must be live before the first community submission is served (`DG-TAKE-01`, `DG-TAKE-02`, `DG-RANK-07`).

That is Phase 0 gating Phase 4, and nothing else. Under a reactive rights model the takedown path is the only thing standing between a bad clip and direct liability, so it is built before the feature that needs it, not alongside.

**Legend:** `Gate` = what must be true to exit. `Rules` = governing rule IDs. `Artifacts` = what the step produces.

---

## Phase 0 - Legal foundation (blocks Phase 4, not the app)

Nothing here blocks the app shipping with bundled and user content. All of it blocks accepting a single community submission.

**Step 0.1 - Submission terms and EULA**
The uploader warranty is the whole rights model now. Terms state that the submitter holds the rights or does not need them, grant us a licence to host and distribute, and bind the submitter to the repeat-infringer policy. Accepted at submission time, version recorded.
`Rules` DG-ACQ-02, P3 · `Artifacts` `legal/submission-terms-v1.md`
`Gate` The accepted version string is written with every submission record. A submission cannot exist without one.

**Step 0.2 - DMCA agent and takedown channel**
Register a designated agent with the US Copyright Office. Stand up a public intake covering copyright, voice and likeness, and privacy claims, with a counter-notice path and a strike ledger.
`Rules` DG-TAKE-01, DG-TAKE-02, DG-TAKE-03 · `Artifacts` agent registration, intake address, takedown runbook, repeat-infringer policy
`Gate` Registration confirmed and public. Runbook names an owner and a 48-hour removal target. Safe harbor is unavailable without the registration, so this gate is binary.

**Step 0.3 - Privacy notice and store disclosures**
Notice generated from `governance/purposes.yaml` so it cannot drift from what the code does. Covers the ads and analytics purposes added at v2.0.
`Rules` DG-USER-05, DG-PURP-01 · `Artifacts` `legal/privacy-notice-v2.md`
`Gate` Public and reachable. Every purpose in `purposes.yaml` appears in it, and nothing appears in it that is not in `purposes.yaml`.

**Step 0.4 - Counsel review of the reactive model**
One scoped session, per `DATA_GOVERNANCE.md` Section 17: the safe harbor position, the selection standard for the bundled catalogue, and the residual right-of-publicity exposure on voice clips.
`Rules` DG-TAKE-01, DG-TAKE-06, P3, P5 · `Artifacts` `legal/counsel-memo-2026.md`
`Gate` Written memo on file before the bundled catalogue is finalised. Any counsel instruction conflicting with `DATA_GOVERNANCE.md` triggers a Section 14 amendment rather than a quiet deviation.

**Phase 0 exit:** submission terms, registered DMCA agent, live takedown channel, privacy notice, counsel memo.

---

## Phase 1 - Governance skeleton in code (blocks anything that persists)

Build the enforcement before the thing being enforced. Cheaper than retrofitting, and unchanged in principle from v1.0.

**Step 1.1 - Wire the gate into CI**
`governance/check.py` runs on every PR and push. Branch protection makes it required.
`Rules` DG-PR-01, DG-EX-03 · `Artifacts` `.github/workflows/governance.yml` (present), branch protection rule
`Gate` A PR with an undeclared field is demonstrably blocked. Prove it with a throwaway PR.

**Step 1.2 - Classification-aware persistence layer**
One data-access module. Every column declares its class at definition time and the module refuses to persist an unclassified field. Redaction filter installed at the logging library boundary, not the call site.
`Rules` DG-CLASS-01, DG-CLASS-02, DG-LOG-01, DG-LOG-02 · `Artifacts` persistence module, logging middleware
`Gate` A unit test proves that writing an unclassified field raises, that a C2 value passed to the logger is redacted, and that a pseudonymous session ID passes through unredacted. That last case is new at v2.0 and is what makes the analytics stack workable.

**Step 1.3 - Retention jobs before retention data**
A scheduled deleter driven by `retention_policies` in `governance/data-map.yaml`. Runs from day one against an empty database.
`Rules` DG-RET-01, DG-RET-02, DG-RET-04 · `Artifacts` retention worker, deletion audit table
`Gate` Integration test: a seeded row past its TTL is hard-deleted and produces a completion record.

**Phase 1 exit:** no field can enter the system undeclared, unclassified, unlogged-safely, or without a TTL.

---

## Phase 2 - The app: personal lane

The buildable core, and under v2.0 it is gated behind nothing but Phase 1. Detailed design lives in `BACKEND_PLAN.md` Phases B0 to B4.

**Step 2.1 - Local media store and schema**
Content-addressed blobs, refcounting, classification-tagged schema, retention worker on device.
`Rules` DG-CLASS-01, DG-CLASS-03, DG-RET-01 · `Gate` `BACKEND_PLAN.md` B1 gate.

**Step 2.2 - Import and recording pipeline**
User recording and user import of a file the user already owns. Hostile-input handling is the real work here.
`Rules` DG-ACQ-01(b)(c), DG-SEC-04 · `Gate` `BACKEND_PLAN.md` B2 gate. Every fixture in the malformed-media corpus is rejected with an enum code and no crash.

**Step 2.3 - Playback engine and grid**
`Rules` DG-ACQ-08 · `Gate` `BACKEND_PLAN.md` B3 and B4 gates, including the network-silence assertion.

**Step 2.4 - The personal lane stays on the device**
Nothing recorded or imported for a user's own board is transmitted, and nothing about it is used to train anything.
`Rules` DG-ACQ-08 · `Gate` Instrumented test: a personal-lane trigger emits zero outbound packets. This is a promise the privacy notice makes, so it is asserted, not assumed.

**Phase 2 exit:** a working soundboard with no server dependency, no account, and no telemetry.

---

## Phase 3 - Bundled catalogue

The first-party catalogue that ships inside the binary. This is the uninsured lane: safe harbor covers what users submit, not what we choose.

**Step 3.1 - Catalogue selection and review**
A named owner reviews the catalogue before every release. Full or substantially complete commercial recordings are excluded.
`Rules` DG-TAKE-06, P5 · `Artifacts` catalogue manifest with a per-clip source note and reviewer sign-off
`Gate` No release ships a catalogue change without a recorded review. Unlike a user submission, a bundled clip cannot be pulled without shipping a build, which is exactly why a human sits in front of it.

**Step 3.2 - Catalogue delivery and expiry**
Signed manifest, CDN delivery, client-side expiry that fails closed so a clip can be pulled from devices that are offline.
`Rules` DG-ACQ-06, DG-TAKE-02, DG-RET-02 · `Gate` `BACKEND_PLAN.md` B5 gate. Manifest expiry sits inside the 48-hour takedown window with margin.

**Phase 3 exit:** catalogue clips are reviewed before shipping and removable from every device inside the takedown window.

---

## Phase 4 - Community submissions (gated behind Phase 0)

The only route that publishes one user's audio to another. Do not start it until Phase 0 exits.

**Step 4.1 - Accounts and submission**
Verified email or platform sign-in. Channel-ownership OAuth is not required at v2.0.
`Rules` DG-ACQ-04 · `Gate` An unverified account cannot reach the submission endpoint. Enforced server-side, not in the UI.

**Step 4.2 - Submission record**
Submitting account ID, timestamp, accepted terms version, rights warranty, written atomically with the asset. Four fields, no pre-clearance workflow behind them.
`Rules` DG-ACQ-02 · `Gate` Database constraint, not application logic, makes an incomplete submission record impossible.

**Step 4.3 - Moderation gate**
Automated review for sexual content involving minors, doxxing, and targeted harassment, with a human escalation path. This is the one publication gate v2.0 retains in full; music detection and provenance completeness are gone.
`Rules` DG-RANK-07, DG-PURP-02 (`P-SAFETY`) · `Gate` A failing asset is not served and generates a moderation record. A missing or errored gate result is treated as a failure, never as a pass. Test the missing-result case specifically.

**Step 4.4 - Takedown execution path**
The Phase 0 runbook wired to code: remove from database, object store, CDN, search index, and client caches inside 48 hours, with the strike ledger updated.
`Rules` DG-TAKE-02, DG-TAKE-03, DG-TAKE-04, DG-RET-02 · `Gate` Timed end-to-end test: file a claim, then confirm every surface returns nothing inside the window, including a client that was offline when the claim landed.

**Step 4.5 - Submitter removal and record retention**
Self-service removal within 7 days. Submission and takedown records retained 3 years after removal.
`Rules` DG-ACQ-06, DG-ACQ-07 · `Gate` Removing an asset leaves the submission record intact and queryable. That record is the safe harbor evidence, so it outlives the asset deliberately.

**Phase 4 exit:** submissions are attributable, moderated, removable inside 48 hours, and evidenced for 3 years.

---

## Phase 5 - Ranking and discovery

**Step 5.1 - Declare events before emitting them**
Every analytics event registered in `governance/data-map.yaml` first. The pipeline drops undeclared events rather than ignoring them, because the App Store privacy label is generated from that file.
`Rules` DG-LOG-05, DG-CLASS-03 · `Gate` An undeclared event is dropped and counted in a metric.

**Step 5.2 - Ranking**
First-party engagement signals, plus third-party signals only where an official API permits them. Aggregated by default; per-user personalisation is permitted where the privacy notice discloses it.
`Rules` DG-RANK-01, DG-RANK-02 · `Gate` The privacy notice and the implemented personalisation agree. Check both directions.

**Step 5.3 - Sensitive-attribute exclusion**
The seven-feature allowlist is gone. The prohibition that replaced it is narrower and absolute: no C3 attribute and no proxy for a protected characteristic enters the ranker.
`Rules` DG-RANK-04 · `Gate` A test asserts the feature set contains no C3 field and no listed proxy. This is the one ranking control that did not relax, so it gets a real test rather than a review note.

**Step 5.4 - Sampled audit**
Ruleset version plus a sampled input snapshot, enough to reconstruct why something ranked where it did. The per-decision audit record is no longer required.
`Rules` DG-RANK-03 · `Gate` A sampled decision can be reconstructed from the record alone.

**Step 5.5 - Automated promotion**
Promotion into discovery surfaces is automated. Human review is required only for a surface presented editorially as a staff pick.
`Rules` DG-RANK-05 · `Gate` A staff-pick surface cannot be populated without a recorded human approval. Every other surface can.

**Phase 5 exit:** ranking is declared, disclosed, free of sensitive attributes, and reconstructible.

---

## Phase 6 - Monetisation

Approved at v2.0, and the phase where the non-negotiable platform controls concentrate.

**Step 6.1 - ATT before any tracking identifier**
No SDK that reads the IDFA initialises before the ATT prompt resolves. Apple enforces this at review, so a miss here is a rejected build rather than a governance finding.
`Rules` DG-USER-04, P6 · `Gate` Instrumented test proves zero reads of a tracking identifier, and zero initialisations of an SDK that reads one, before the prompt resolves.

**Step 6.2 - Ads and attribution SDKs**
Pre-approved categories under `DG-VEND-03`, so this is a manifest entry rather than a review cycle. No personalised ads to a user known to be under 13.
`Rules` DG-VEND-01, DG-VEND-03, P6, P8 · `Gate` Every SDK in the binary has a `vendors.yaml` entry with a declared region. Diff the built binary against the manifest, do not trust the dependency file.

**Step 6.3 - CCPA sale and share opt-out**
Reachable from the settings screen, effective within 30 days, recorded with purpose ID and timestamp.
`Rules` DG-USER-06, DG-USER-07 · `Gate` Opting out measurably stops the sharing inside the window. Required the moment `P-ADS` ships, not later.

**Step 6.4 - Privacy labels generated, not written**
Apple Privacy Nutrition Label regenerated from `governance/data-map.yaml` in any release that changes collection.
`Rules` DG-USER-05 · `Gate` Declaration diff reviewed in the release PR. An inaccurate label is both a store rejection and an FTC Section 5 exposure.

**Step 6.5 - In-app purchases**
StoreKit, no card data in our systems. Vendor entry before integration code.
`Rules` DG-VEND-01, DG-VEND-02, DG-CLASS-01 · `Gate` No C3 payment field appears in `governance/data-map.yaml` under our own stores.

**Phase 6 exit:** the app monetises with ATT honoured, every SDK declared, and the label matching the code.

---

## Phase 7 - Consumer rights

**Step 7.1 - Rights request endpoints**
Know, access, delete, correct, portability, opt out of sale/share. Identity verification step, 45-day SLA, completion record. Built with the account system in Phase 4, not after it.
`Rules` DG-USER-06, DG-RET-03 · `Gate` End-to-end test from request through hard delete through audit record.

**Step 7.2 - Under-13 handling**
No age gate is required at v2.0, because the app is rated 12+ and is not child-directed. What is required is a path for actual knowledge: when we learn a user is under 13, collection stops and what we hold is deleted.
`Rules` DG-USER-01, DG-USER-02, P6 · `Gate` The runbook exists and the deletion path is tested. The app is never submitted to the Kids Category.

**Phase 7 exit:** every applicable right is servable inside its statutory window.

---

## Phase 8 - Standing operations

Continuous, not a phase that ends.

| Cadence | Activity | Rules |
|---|---|---|
| Every PR | Governance gate; Compliance Block where DG-AGENT-06 applies | DG-PR-01 |
| Every release | Bundled catalogue review | DG-TAKE-06 |
| Every release | Privacy label diff | DG-USER-05 |
| Weekly | Exception expiry review | DG-EX-03 |
| Monthly | SDK diff of the built binary against `vendors.yaml` | DG-VEND-01, DG-VEND-03 |
| Monthly | Takedown response-time audit | DG-TAKE-04 |
| Quarterly | C2/C3 access log review | DG-LOG-04 |
| Quarterly | Retention job verification against `data-map.yaml` | DG-RET-01 |
| On detection | Incident report within 24 hours | DG-SEC-06 |

The takedown audit moved from quarterly to monthly. Under a reactive rights model the response time is the control, so measuring it four times a year is not enough.

---

## What this plan deliberately does not build

Listed so that no one has to re-litigate it mid-sprint. Each needs a Section 14 amendment, not a product decision.

- Voice cloning, synthesis, or style transfer of a real person (`P4`)
- Automated or bulk retrieval of platform media in breach of a platform's terms (`P1`)
- A Kids Category submission, or knowing collection from a user under 13 (`P6`)
- Personalised advertising to a user known to be under 13 (`P6`)
- Any transmission of the personal lane off the device (`DG-ACQ-08`)

## What v1.0 planned and v2.0 dropped

Recorded so the absence reads as a decision rather than an oversight. All follow from `DATA_GOVERNANCE.md` Section 0.1.

| Dropped | Was, in v1.0 numbering |
|---|---|
| Creator Distribution License and counsel sign-off on it | Phase 0 Steps 0.1, 0.2 |
| Platform OAuth channel verification | Phase 2 Step 2.1 |
| Quarantine as default asset state | Phase 2 Step 2.3 |
| Third-party speaker hold and countersigned releases | Phase 2 Step 2.4 |
| Provenance vault with 7-year chain | Phase 2 Step 2.5 |
| Music-detection publication gate | Phase 3 Step 3.1 |
| Provenance-completeness publication gate | Phase 3 Step 3.3 |
| Ranking feature allowlist | Phase 4 Step 4.3 |
| Human approval before any promotion | Phase 4 Step 4.5 |
| Age gate before any identifier, and Restricted Mode | Phase 5 Step 5.3 |
| Consent ledger with opt-in for product analytics | Phase 6 Step 6.2 |
