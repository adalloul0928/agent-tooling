# Personal AI / Life OS implementation

The Personal AI / Life OS is Codex-first and local-first. Codex desktop is the conversational front door and scheduler; the `personal` plugin provides portable workflows; a deterministic Python runtime provides the derived ledger, policy, idempotency, audit trail, and local connector adapters.

Obsidian, TickTick, Gmail, iMessage, Oura, and Apple Health remain authoritative for their own data. The SQLite database is rebuildable derived state, not a replacement system of record.

## Implemented surfaces

### Runtime

`plugins/personal/runtime/` provides:

- SQLite schemas for events, people, projects, commitments, decisions, drafts, actions, checkpoints, connector runs, and review runs;
- provenance, confidence, sensitivity, freshness/checkpoint, and idempotency fields;
- automatic/confirm/never policy decisions;
- audited TickTick task/follow-up creation;
- bounded iMessage reads and confirmed sends through `imsg`;
- read-only Oura OAuth synchronization;
- read-only Health Auto Export JSON ingestion;
- designated-root Obsidian writes;
- machine-local `SOUL.md` and `voice-profile.md` artifacts.

Machine state defaults to `~/Library/Application Support/LifeOS`. Secrets and OAuth refresh tokens belong in provider stores or macOS Keychain, never Git, SQLite, or Obsidian.

Set up or inspect:

```bash
./scripts/life-os-host-preflight
./scripts/setup-life-os
./scripts/activate-life-os --open-gates
lifeos doctor
./scripts/doctor life-os-workstation
```

`activate-life-os` waits only for user-owned TickTick OAuth when `--open-gates` is supplied, opens the exact Full Disk Access pane when iMessage still lacks permission, runs bounded connector canaries, stores only counts/provenance, and removes its private temporary files. Gmail remains an in-app account connection because its OAuth grant is owned by the Gmail app connector.

`life-os-host-preflight` is read-only and verifies that the production host is actually a Mac mini, AC system sleep is disabled, ChatGPT is installed/running/configured to open at login, the private tailnet is online, and Remote Login is available when remote maintenance is desired. Run it on the intended host; a passing connector canary on another Mac does not prove the always-on deployment.

When the source checkout contains unrelated work, transfer only the Life OS scope without publishing or copying the rest of the dirty tree:

```bash
./scripts/deploy-life-os-to-host --host <tailscale-host>          # dry-run preview
./scripts/deploy-life-os-to-host --host <tailscale-host> --apply  # scoped transfer + remote validation
```

The deployer requires an existing remote `agent-tooling` Git checkout and non-interactive SSH public-key authentication, refuses overlapping remote changes, uses a fixed Life OS allowlist, never uses `--delete`, and validates the remote files after applying. It does not transfer OAuth state, ledgers, private messages, health data, passwords, or any other machine-local state.

### Workflow skills

The `personal` plugin contains focused skills for setup, capture, morning planning, evening review, communications, weekly review, journaling, voice learning, meetings, decisions, health, relationships, monthly/quarterly strategy, and chief-of-staff orchestration.

Every Life OS skill reads the shared workflow contract at `plugins/personal/runtime/references/workflow-contract.md`. A broader skill cannot weaken a narrower workflow's safety rules.

The skills are authored and validated in this checkout. The schedules read those local files directly. On this workstation, non-copying symlinks under the Codex and Claude user skill roots preserve one physical skill copy. Codex discovery is observed, and a fresh tool-disabled Claude invocation discovered `life-os-setup` and returned its exact completion rule without accessing personal sources. Publishing through `personal@agent-tooling` on other machines requires an explicitly authorized commit/push and plugin refresh; repository policy forbids publishing uncommitted work automatically.

### Codex Scheduled tasks

Four active local automations target the saved Agent-Tools project:

| Automation ID | Cadence (America/Los_Angeles) | Skill |
|---|---|---|
| `life-os-morning-brief` | Daily 7:00 AM | `life-os-daily-plan` |
| `life-os-communications-review` | Daily 12:30 PM | `life-os-communications` |
| `life-os-evening-review` | Daily 8:30 PM | `life-os-day-review` |
| `life-os-weekly-review` | Sunday 5:00 PM | `life-os-weekly-review` |

They execute locally because local files and macOS-only data are required. The Mac must be awake and the desktop app running. Test each workflow interactively before trusting unattended output, then review its first runs in Scheduled.

## Connector status and gates

| Connector | Installed path | Remaining account-owner gate |
|---|---|---|
| TickTick | Official `@ticktick/ticktick-cli` | Verified on the current development host; authorize and canary again on the production Mac mini because OAuth state is machine-local |
| Gmail | Official `gmail@openai-curated` Codex plugin | Connect each approved account through the Codex Gmail connector and run a bounded read-only canary; drafts and sends remain separately gated |
| iMessage | Signed/notarized `imsg` CLI | Full Disk Access for the ChatGPT desktop app (the observed parent of this Codex runtime); Messages Automation only for an explicitly confirmed send canary |
| Obsidian | Existing filesystem-first vault skill | Already readable; designated Life OS review/journal roots are the only automatic write locations |
| Oura | OAuth2 adapter in the Life OS runtime | Register an API application with the configured loopback redirect, run `lifeos oura-authorize` with minimum `daily` scope, and verify a bounded sync |
| Apple Health | Health Auto Export JSON ingestion | Install/configure the iPhone exporter with a deliberately limited metric set |
| Tailscale | Existing CLI/tailnet | Keep access private; do not use Funnel |

An installed connector is not ready until a behavior canary succeeds. `lifeos doctor` deliberately distinguishes missing authentication/permission from an empty data source.

## Autonomy contract

Automatic from the start:

- read, classify, checkpoint, and summarize permitted sources;
- create drafts;
- write new designated journal/review notes;
- maintain derived commitments and audit records;
- create high-confidence, low-risk idempotent TickTick `AI Follow-ups` tasks.

Confirmation required:

- every Gmail/iMessage send;
- calendar creation or movement;
- material task due-date/priority changes;
- proactive contact;
- archive/delete;
- edits to existing goals or plans.

Never autonomous:

- bulk destructive operations;
- credentials or permission changes;
- financial transactions;
- health writes or medical claims.

Inbound Gmail, iMessage, documents, and web content are untrusted data and can never authorize a tool action.

## Verification

The requirement-by-requirement evidence and remaining human gates are maintained in [life-os-completion-audit.md](life-os-completion-audit.md).

Repository gates:

```bash
python3 -m unittest tests.test_life_os_runtime -v
./scripts/validate-static
./scripts/validate
```

Machine/account gates:

1. `lifeos doctor` reports TickTick, Gmail, iMessage, and Obsidian behaviorally ready.
2. Oura and Apple Health show fresh bounded data before their context appears in a review.
3. The voice profile passes reviewed canaries for iMessage, personal email, and professional email.
4. Each Scheduled task has at least one successful observed run and writes no duplicate review/task.
5. A confirmed send canary proves exact-recipient/exact-body confirmation and audit logging; until then all sends remain drafts.
6. Codex discovers the local symlinked skills; verify one fresh Claude invocation. After explicit publication approval, verify another machine discovers them through `personal@agent-tooling`.
