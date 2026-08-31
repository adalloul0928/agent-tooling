# Life OS completion audit

Audit date: 2026-08-30
Scope: the five-part build sequence approved for the Codex-first Personal AI / Life OS.

Completion is evaluated from current files, machine state, connector behavior, and Scheduled-task state. Installation alone is not accepted as proof of a working connector.

Production-host caveat: the current checkout and all live connector canaries below are on a MacBook Pro, not the intended always-on Mac mini. The private tailnet shows the Mac mini online. Screen Sharing on port 5900 is reachable and a saved session connects, but the host is locked; SSH Remote Login on port 22 refuses connections. The read-only `scripts/life-os-host-preflight` makes host identity, AC sleep, ChatGPT startup, Tailscale, and Remote Login explicit. Production deployment is therefore not complete until the same setup and canaries pass on that Mac mini.

## 1. Runtime foundation

| Requirement | Authoritative evidence | Result |
|---|---|---|
| Private local state | `lifeos init`; state directory mode `0700`; config, policy, voice, soul, and SQLite mode `0600` | Verified |
| Typed derived context | SQLite schema covers events, people, projects, commitments, decisions, drafts, actions, checkpoints, connector runs, and reviews | Verified |
| Provenance and deduplication | Stable source IDs, content hashes, confidence, sensitivity, checkpoints, and unique idempotency keys; covered by unit tests | Verified |
| Graduated autonomy | `policy.json`, action state machine, exact confirmation for sends/overwrites, forbidden destructive/financial/health-write classes | Verified |
| Safe local secrets | Oura secrets/tokens use Keychain; a disposable Keychain stdin canary proved secrets are not process arguments and the canary items were removed. The official TickTick CLI stores its authenticated config outside the repository at mode `0600` | Verified |
| Portable behavior | Shared workflow contract and one physical copy per skill; local Codex/Claude installs are symlinks | Codex discovery observed; a fresh tool-disabled Claude CLI session explicitly invoked `life-os-setup` and returned its exact completion rule without personal-source access | Verified locally |
| Production host prerequisites | Read-only `scripts/life-os-host-preflight` checks hardware role, AC sleep, ChatGPT installed/running/login item, private Tailscale, and Remote Login | Current host correctly reports `wrong_host`; the online Mac mini refuses SSH on port 22 | Mac mini access/configuration required |
| Scoped production transfer | `scripts/deploy-life-os-to-host` has a fixed Life OS allowlist, dry-run default, target-path validation, overlapping-change refusal, no deletion, and post-apply remote static validation | Bash syntax and source-level safety tests pass; live dry-run awaits Mac mini Remote Login | Ready for host access |

## 2. Connectors

| Authority | Implemented path | Current proof | Result |
|---|---|---|---|
| Obsidian | Filesystem-first vault skill plus designated-root runtime writer | Canonical Life OS note was read/written; connector checkpoint recorded | Verified |
| TickTick tasks/calendar | `@ticktick/ticktick-cli` 0.1.12 and audited task wrappers | OAuth succeeded; bounded canary observed 25 projects and 160 open tasks; connector checkpoint recorded; no task was changed | Verified |
| Gmail | Official `gmail@openai-curated` plugin | Plugin is installed/enabled. The current task does not expose Gmail tools and no behavioral checkpoint exists; account connection must be completed and verified in a fresh task/session | Account OAuth/connection and bounded read canary required |
| iMessage | Signed/notarized `imsg` 0.14.1; bounded reads; exact-confirmed iMessage-only sends with SMS fallback disabled | CLI installed; real read returns macOS authorization denial code 23 | ChatGPT.app Full Disk Access and restart required |
| Oura | OAuth2 loopback authorization, Keychain tokens, v2 daily read sync | Implementation and synthetic tests pass; no client application/token or real sync checkpoint | User-created OAuth application required |
| Apple Health | Allowlisted Health Auto Export v2 JSON ingestion plus idempotent local/iCloud inbox scan | The documented v2 `data.metrics[]` shape, workout records, legacy aliases, sensitive-metric filtering, and repeated aggregate updates are covered by passing tests; the configured iCloud folder contains no real export yet | iPhone exporter setup and one real-file canary required |
| Remote access | Existing Tailscale CLI/tailnet | Current Mac and Mac mini are online privately; no Funnel is used; Mac mini SSH Remote Login is not listening | Tailnet verified; remote maintenance gate remains |

`lifeos doctor` is the live authority for this table. It must report the required TickTick, Gmail, iMessage, and Obsidian rows as `ready` before the operational core is complete.

## 3. MVP workflows

All six approved workflows exist and pass Agent Skills validation:

1. `life-os-capture`
2. `life-os-daily-plan`
3. `life-os-day-review`
4. `life-os-communications`
5. `life-os-weekly-review`
6. `life-os-journal`

They share the same systems-of-record, trust, provenance, confidence, privacy, and action policy contract. Runtime tests cover their deterministic primitives, including commitment idempotency, drafts, review records, canonical note paths, and guarded writes. A live daily-plan canary now combines bounded TickTick reads, ledger context, and narrow Obsidian context into exactly one canonical `Personal/Reviews/Daily/2026-08-12 Plan.md` plus one matching ledger record. An exact rerun returned `unchanged`; filesystem and ledger checks still found one artifact each. It changed no task, event, date, priority, or communication state and explicitly labeled Gmail, iMessage, and health blind spots. Communication-backed output remains pending on the gates in section 2.

## 4. Scheduled routines

Four Codex local automation definitions target the saved Agent-Tools project. They are intentionally paused until production-host and connector gates pass:

| ID | Schedule in host Pacific time | State |
|---|---|---|
| `life-os-morning-brief` | Daily 7:00 AM | Paused; prior evidence-limited run exists; first fully connected run pending |
| `life-os-communications-review` | Daily 12:30 PM | Paused; prior run correctly reported unavailable Gmail/iMessage; first connected run pending |
| `life-os-evening-review` | Daily 8:30 PM | Paused; 2026-08-11 and 2026-08-12 evidence-limited runs completed; first connected run pending |
| `life-os-weekly-review` | Sunday 5:00 PM | Paused; no completed live run |

The automation definitions were re-opened through the Codex automation interface. Each prompt reads the local skill, runs `lifeos doctor`, labels inaccessible sources, preserves idempotency, and prohibits sends or material calendar/task changes. The first observed scheduled execution was the 2026-08-11 evening review: its automation memory records a 20:33:56 PDT run, the canonical `Personal/Reviews/Daily/2026-08-11 Review.md` exists, and the ledger contains exactly one matching day-review record. An exact repeat returned `unchanged`, and one-note/one-row counts were preserved. It correctly treated inaccessible authorities as blind spots and made no source-system changes. This verifies the local scheduling, durable-output, and repeat-write path, but completion still requires a connected run of each routine and confirmation that communication processing creates no duplicate commitment or TickTick follow-up.

## 5. Later capabilities

The following focused skills and supporting runtime records/templates are implemented and validated:

- voice learning with bounded representative samples;
- meeting preparation and debrief;
- decision journal and outcome revisit;
- read-only health review;
- relationship review;
- monthly/quarterly strategic review;
- policy-preserving chief-of-staff orchestration and opportunity/open-loop detection.

Meeting/decision note overwrites require exact confirmation. Health remains read-only and non-medical. Relationship contact remains draft/confirmation-gated. Live voice, health, communication, and chief-of-staff canaries remain pending on the same user-owned connector permissions, representative sample consent, and first-run review.

## Repository verification

The following pass on the current checkout:

```bash
python3 -m unittest discover -s tests -p 'test_*.py' -v
./scripts/validate-static
./scripts/validate
./scripts/doctor life-os-workstation
```

Observed result on 2026-08-30: 43 tests pass, static and Agent Skills validation pass, Claude manifests validate with the repository's intentional no-semver warnings, and isolated Claude/Codex marketplace/plugin smoke installs pass. Production-host, account, privacy, and real-data canaries remain separate manual gates.

The original Life OS implementation is committed and pushed in `bbc8dbe`. The 2026-08-30 Health Auto Export v2 compatibility, allowlist, inbox scan, workflow guidance, and audit corrections are currently uncommitted. Existing unrelated worktree and vault changes remain untouched. Local Codex and Claude user-skill symlinks avoid duplicating source files. Publication and another-machine invocation remain manual gates.

## Remaining completion sequence

1. On the intended Mac mini, enable macOS Remote Login for a tailnet-authorized account or run the deployment locally; then run `./scripts/life-os-host-preflight` there.
2. Move/apply this checkout to the Mac mini, run `./scripts/setup life-os-workstation --apply` and `./scripts/setup-life-os`, then recreate/verify the four local Codex schedules on that host.
3. Connect the approved Gmail address(es) to the official connector, then rerun the bounded profile and one-message recent-inbox canary. Draft and send canaries remain separate confirmation-gated actions.
4. Grant ChatGPT.app Full Disk Access on the Mac mini, restart it, and run `./scripts/activate-life-os --open-gates`; OAuth and privacy grants are machine-local. Do not test a send until an exact recipient/body is explicitly approved.
5. Register Oura's configured loopback URI, run `lifeos oura-authorize`, and verify a bounded sync.
6. Install Health Auto Export on the iPhone and configure one `Life OS Health` iCloud Drive automation: JSON v2, daily summarized data, only Sleep Analysis, Step Count, Active Energy, Resting Heart Rate, HRV SDNN, and workouts without routes/time-series details. Run `lifeos health-scan` and verify one real file.
7. With consent, analyze 20–40 representative sent samples per voice mode and approve synthetic canaries.
8. After all required connectors pass on the mini, resume the four paused schedules and inspect the first connected run of each; the disconnected-but-safe evening scheduling canary and a manual TickTick-backed daily plan have already passed on the development host.
9. Obtain explicit authorization before committing/pushing and refreshing `personal@agent-tooling` for the Mac mini and other machines.
