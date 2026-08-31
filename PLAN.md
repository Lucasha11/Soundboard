# PLAN.md

> **Not yet realigned to DATA_GOVERNANCE.md v2.0.** This plan is written to the
> v1.0 pre-clearance model. Where a step here enforces a control that v2.0
> Section 0.1 relaxed or removed (creator licensing and verification, quarantine
> as default state, the music-detection gate, the ranking feature allowlist and
> human publish step, Restricted Mode, the five questions), the governance
> document wins and the step is optional. The takedown and moderation ordering
> in v2.0 Section 12 is not optional. Ask before treating this file as current.

Build order for **Soundboard**. Binding alongside `DATA_GOVERNANCE.md`.

**Rule for every phase:** do not start a phase until the previous phase's exit criteria all pass. `python3 governance/check.py` must be green at the end of every step. A step that cannot meet its control fails closed - stop and escalate, do not proceed with a TODO (`DG-AGENT-04`).

The ordering is chosen for efficiency in one specific sense: it puts every irreversible decision (rights, identity, classification, retention) before the code that would have to be rewritten if that decision changed. Nothing here is sequenced for ceremony.

**Legend:** `Gate` = what must be true to exit. `Rules` = governing rule IDs. `Artifacts` = what the step produces.

---

## Phase 0 - Legal foundation (no application code)

Nothing is built until the rights model exists on paper. Every downstream schema depends on it.

**Step 0.1 - Draft the Creator Distribution License**
Non-exclusive, worldwide, revocable-on-request license to host, transcode, distribute, and display the uploaded audio, plus an uploader warranty of rights and an indemnity. Include the speaker-identity representation and the revocation mechanism.
`Rules` DG-ACQ-01, DG-ACQ-06 · `Artifacts` `legal/creator-license-v1.md`
`Gate` Reviewed by outside counsel. Counsel confirms the license text supports the ingestion model as coded.

**Step 0.2 - Confirm the acquisition model with counsel**
One hour, scoped to: creator-licensed upload only, US launch, state right-of-publicity exposure, third-party-speaker rule (`DG-ACQ-05`), music-in-clip exposure, repeat-infringer policy.
`Rules` DG-ACQ-05, DG-STOP-01/P3, DG-STOP-01/P5 · `Artifacts` `legal/counsel-memo-2026.md`
`Gate` Written memo on file. Any counsel instruction that conflicts with `DATA_GOVERNANCE.md` triggers a Section 14 amendment before coding.

**Step 0.3 - Publish the privacy notice and takedown channel**
Notice generated from `governance/purposes.yaml`, so it cannot drift from what the code does. Takedown intake live before any public asset exists.
`Rules` DG-TAKE-01, DG-USER-05, DG-PURP-01 · `Artifacts` `legal/privacy-notice-v1.md`, takedown intake address and runbook
`Gate` Both public and reachable. Runbook names an owner and a 24-hour response target.

**Phase 0 exit:** license, counsel memo, privacy notice, takedown channel. No code before this.

---

## Phase 1 - Governance skeleton in code

Build the enforcement before the thing being enforced. This is the cheapest possible ordering: every later schema lands into a validated manifest instead of being retrofitted.

**Step 1.1 - Wire the gate into CI**
`governance/check.py` runs on every PR and push. Branch protection makes it required.
`Rules` DG-PR-01, DG-EX-03 · `Artifacts` `.github/workflows/governance.yml` (present), branch protection rule
`Gate` A PR with an undeclared field is demonstrably blocked. Prove it with a throwaway PR.

**Step 1.2 - Classification-aware persistence layer**
One data-access module. Every column declares its class at definition time and the module refuses to persist an unclassified field. Redaction filter installed at the logging library boundary, not the call site.
`Rules` DG-CLASS-01, DG-CLASS-02, DG-LOG-01, DG-LOG-02 · `Artifacts` persistence module, logging middleware
`Gate` A unit test proves that writing an unclassified field raises, and that a C2 value passed to the logger is redacted.

**Step 1.3 - Retention jobs before retention data**
A scheduled deleter driven by `retention_policies` in `governance/data-map.yaml`. It runs from day one against an empty database.
`Rules` DG-RET-01, DG-RET-02, DG-RET-04 · `Artifacts` retention worker, deletion audit table
`Gate` Integration test: a seeded row past its TTL is hard-deleted and produces a completion record.

**Phase 1 exit:** no field can enter the system undeclared, unclassified, unlogged-safely, or without a TTL.

---

## Phase 2 - Identity and licensed supply

The only route audio enters. Build it whole; a partial version of this phase is the failure mode the whole plan exists to prevent.

**Step 2.1 - Creator accounts with platform OAuth verification**
Verification is OAuth to the creator's own channel. Self-declared identity is rejected.
`Rules` DG-ACQ-04, DG-SEC-03 · `Gate` An unverified account cannot reach the upload endpoint. Enforced server-side, not in the UI.

**Step 2.2 - Upload with license acceptance in the same transaction**
Acceptance timestamp, license version, declared speaker, declared source, and rights attestation are written atomically with the asset. No asset row can exist without them.
`Rules` DG-ACQ-01, DG-ACQ-02 · `Gate` Database constraint, not application logic, makes an incomplete provenance record impossible.

**Step 2.3 - Quarantine as the default state**
Every asset lands `quarantined`. Nothing serves, ranks, indexes, or exports a quarantined asset.
`Rules` DG-ACQ-03 · `Gate` Test proves each of the four surfaces excludes quarantined assets independently.

**Step 2.4 - Third-party speaker hold**
If declared speaker is not the uploader, the asset stays quarantined pending a countersigned release. No public-figure carve-out.
`Rules` DG-ACQ-05 · `Gate` Test covers the public-figure case explicitly.

**Step 2.5 - Provenance vault**
License and provenance chain written to a store separate from the operational database, 7-year retention, survives asset deletion.
`Rules` DG-ACQ-07 · `Gate` Deleting an asset leaves the chain intact and queryable.

**Step 2.6 - Revocation path**
Self-service revocation propagating to database, object store, CDN, search index, and client prefetch within 24 hours.
`Rules` DG-ACQ-06, DG-RET-02 · `Gate` Timed end-to-end test: revoke, then confirm every surface returns nothing inside the window.

**Phase 2 exit:** the only audio in the system is licensed, attributed, revocable, and quarantined until cleared.

---

## Phase 3 - Publication gates

Three automated gates decide whether a quarantined asset becomes public. Built before ranking, because ranking must never see an ungated asset.

**Step 3.1 - Music detection**
Fingerprint or classifier gate rejecting third-party commercial music. Result recorded on the asset.
`Rules` DG-STOP-01/P5, DG-RANK-07 · `Gate` A known music-bearing fixture is blocked. False-negative rate measured and recorded, not assumed.

**Step 3.2 - Speech content moderation**
Automated review for slurs, harassment, sexual content involving minors, and doxxing. Escalation path to a human.
`Rules` DG-RANK-07, DG-PURP-02 (`P-SAFETY`) · `Gate` Failing assets stay quarantined and generate a moderation record.

**Step 3.3 - Provenance completeness check**
Re-verify `DG-ACQ-02` completeness at publish time, not only at upload.
`Rules` DG-ACQ-03, DG-RANK-07 · `Gate` A missing or errored gate result is treated as failure, never as pass. Test the missing-result case specifically.

**Phase 3 exit:** publication is impossible without three recorded passes.

---

## Phase 4 - Engagement and the ranking agent

**Step 4.1 - Declare events before emitting them**
Every analytics event registered in `governance/data-map.yaml` first. The pipeline drops undeclared events rather than ignoring them.
`Rules` DG-LOG-05, DG-PURP-03 · `Gate` An undeclared event is dropped and counted in a metric.

**Step 4.2 - Aggregation boundary**
Raw events are pseudonymous and short-lived; the agent reads only aggregated counters. No account identifiers, no per-user streams, no free text cross the boundary.
`Rules` DG-RANK-01, DG-RANK-02, DG-RANK-06 · `Gate` The agent's input contract is typed and contains no C2 or C3 field. Enforced by a schema test.

**Step 4.3 - Feature allowlist**
Ranking features limited to the seven permitted signals. Adding a feature requires a governance amendment.
`Rules` DG-RANK-04 · `Gate` A test asserts the feature set equals the allowlist exactly.

**Step 4.4 - Ranking audit trail**
Every placement-affecting decision writes inputs, ruleset version, score, timestamp. 24-month retention.
`Rules` DG-RANK-03 · `Gate` Any live ranking can be reconstructed from the audit record alone.

**Step 4.5 - Human publish step**
The agent proposes promotion into discovery surfaces; a person approves. No auto-promotion.
`Rules` DG-RANK-05 · `Gate` No code path promotes without a recorded human approval.

**Phase 4 exit:** ranking is first-party, pseudonymous, allowlisted, auditable, and human-gated.

---

## Phase 5 - Distribution surfaces

Order chosen by where sounds are actually played, which is also the order of least data risk.

**Step 5.1 - Discord bot**
Server-side playback of published assets only. Store guild and channel identifiers as C2 with a declared TTL.
`Rules` DG-CLASS-01, DG-RET-01 · `Gate` The bot cannot resolve a quarantined or revoked asset.

**Step 5.2 - Desktop client**
Local playback and virtual audio device. Local cache honours revocation on next launch and on a 24-hour refresh.
`Rules` DG-ACQ-06 · `Gate` A revoked asset is unplayable offline after the refresh window.

**Step 5.3 - Mobile app, age gate first**
Neutral age gate renders before any identifier is generated and before any data-collecting SDK initialises. Under-13 goes to Restricted Mode: no account, no identifiers, no analytics, no ads, curated catalogue. On iOS, no tracking identifier is read before ATT authorisation.
`Rules` DG-USER-01, DG-USER-02, DG-USER-03, DG-USER-04 · `Gate` Instrumented test proves zero network calls carrying an identifier before the gate resolves. If Restricted Mode cannot ship for a surface, that surface denies access.

**Step 5.4 - Store privacy declarations generated, not written**
Apple Privacy Nutrition Label and Google Play Data Safety generated from `governance/data-map.yaml`.
`Rules` DG-USER-05 · `Gate` Declaration diff is reviewed in any release that changes collection.

**Phase 5 exit:** every surface enforces licensing, revocation, and the age gate independently.

---

## Phase 6 - Consumer rights and monetisation

**Step 6.1 - Rights request endpoints**
Know, access, delete, correct, portability, opt out of sale/share, limit sensitive use. Identity verification step. 45-day SLA with a completion record. Built with the account system, not after it.
`Rules` DG-USER-06, DG-RET-03 · `Gate` End-to-end test from request through hard delete through audit record.

**Step 6.2 - Consent ledger**
Consent recorded as an event with string, purpose IDs, version, timestamp, surface. Withdrawal is as easy as granting and stops processing within 24 hours.
`Rules` DG-USER-07 · `Gate` Withdrawing `P-PRODUCT-ANALYTICS` measurably stops those events inside the window.

**Step 6.3 - Payments through a tokenising processor**
No card data touches our systems. Vendor entry with an executed DPA before any integration code.
`Rules` DG-VEND-01, DG-VEND-02, DG-CLASS-01 (C3) · `Gate` No C3 payment field appears in `governance/data-map.yaml` under our own stores.

**Step 6.4 - Paid triggers and creator payouts**
Creator keeps the majority. Payout records under `P-PAYMENT` with 7-year retention.
`Rules` DG-PURP-02, DG-RET-01 · `Gate` Financial records are complete and immutable.

**Phase 6 exit:** users can exercise every applicable right, and money moves without us holding card data.

---

## Phase 7 - Standing operations

Continuous, not a phase that ends.

| Cadence | Activity | Rules |
|---|---|---|
| Every PR | Governance gate and Compliance Block | DG-PR-01 |
| Weekly | Exception expiry review | DG-EX-03 |
| Monthly | Vendor and SDK diff against `vendors.yaml` | DG-VEND-01, DG-VEND-03 |
| Quarterly | C2/C3 access log review | DG-LOG-04 |
| Quarterly | Retention job verification against `data-map.yaml` | DG-RET-01 |
| Quarterly | Takedown response-time audit | DG-TAKE-04 |
| Per release | Store privacy declaration diff | DG-USER-05 |
| On detection | Incident report within 24 hours | DG-SEC-06 |

---

## What this plan deliberately does not build

Listed so that no one has to re-litigate it mid-sprint:

- Any ingestion of third-party platform media (`P1`, `P2`)
- Any voice synthesis or cloning (`P4`)
- Ad targeting, audience export, or data sale (`DG-PURP-04`)
- A non-US launch without a scope amendment (`DG-VEND-04`, Section 14)

Each of these requires a governance amendment before it can appear in a sprint plan, not a product decision.
