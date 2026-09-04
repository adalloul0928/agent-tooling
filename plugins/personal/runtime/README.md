# Life OS runtime

This directory contains the deterministic, local-first state and connector layer used by the personal workflow skills. It is intentionally separate from model reasoning: skills decide what a message means; the runtime records provenance, applies policy, prevents duplicate side effects, and calls bounded local connectors.

## State

Run `python3 runtime/lifeos_cli.py init` from the personal plugin root. Machine-local state defaults to `~/Library/Application Support/LifeOS` and can be overridden with `LIFE_OS_HOME`. The state directory contains:

- `life-os.sqlite3`: derived events, commitments, checkpoints, actions, drafts, decisions, and reviews;
- `config.json`: non-secret local connector and schedule configuration;
- `policy.json`: automatic, confirmation-required, and forbidden action classes;
- `voice-profile.md`: bounded rules for writing as the user;
- `SOUL.md`: the assistant's operating character;
- `health-inbox/`: local JSON exports from Apple Health tooling.

The ledger is a derived index, never a competing source of truth. Gmail, iMessage, TickTick, Obsidian, Oura, and Apple Health remain authoritative for their own data.

## Safety guarantees

- Gmail and iMessage sends require confirmation.
- Calendar changes and material task changes require confirmation.
- Confirmation is a durable, single-use grant for one action ID and the exact
  recipient/target and request body. A caller-provided boolean is never an
  approval; grants expire after ten minutes, and a changed or replayed action is
  rejected.
- High-confidence TickTick follow-ups may be created automatically at or above the configured threshold.
- Idempotency keys prevent repeated scheduled runs from duplicating the same external action.
- Raw iMessage bodies are returned transiently for classification but are not stored in the ledger.
- Secrets belong in OAuth stores or macOS Keychain, never config, SQLite, Obsidian, or this repository.
- Health sources are read-only and may inform workload suggestions, not medical conclusions.

## Commands

```text
lifeos init
lifeos doctor
lifeos connector-verify <connector> ...
lifeos policy <action-type>
lifeos event-record ...
lifeos commitment-upsert ...
lifeos commitments
lifeos action-request ...
lifeos actions
lifeos action-confirm <action-id>
lifeos draft-save ...
lifeos drafts
lifeos decision-record ...
lifeos decisions
lifeos ticktick-create-followup ...
lifeos imessage-recent
lifeos imessage-send ...
lifeos health-ingest <export.json>
lifeos health-scan
lifeos oura-authorize --client-id ...
lifeos oura-sync
lifeos context
lifeos obsidian-write ...
lifeos review-record ...
lifeos reviews ...
```

All command output is JSON so Codex, Claude, and unattended tasks can consume it without scraping prose.

For a confirmation-required command, run it once to create a proposal. In a
human-operated terminal, run `lifeos action-confirm <action-id>`, review the
displayed action type, recipient/target, complete request, and digest, then type
the exact confirmation phrase. Re-run the original command with the same
arguments and idempotency key to consume that one approval and execute it.
`action-confirm` refuses non-interactive input. Any payload change creates a
digest mismatch, an unused grant expires after ten minutes, and an approval
cannot be replayed after an execution attempt.
Automatic policy actions retain their existing idempotent execution path and do
not accept or require confirmation grants.

`health-scan` reads JSON files from the private health inbox and the configured Health Auto Export iCloud Drive folder. The default allowlist accepts only sleep analysis, step count, active energy, resting heart rate, HRV SDNN, and workouts. Other exported health categories are filtered rather than persisted. Input must be a regular, non-symlink, non-sparse file. Parsing is capped at 16 MiB and 25,000 extracted records per file; a scan is capped at 100 selected files, 2,000 discovered candidates, 64 MiB, and 50,000 records. JSON nesting, node/container counts, individual strings, and cumulative string content are bounded before records are persisted.
