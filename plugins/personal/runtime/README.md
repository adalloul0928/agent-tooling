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
lifeos draft-save ...
lifeos drafts
lifeos decision-record ...
lifeos decisions
lifeos ticktick-create-followup ...
lifeos imessage-recent
lifeos imessage-send ...
lifeos health-ingest <export.json>
lifeos oura-authorize --client-id ...
lifeos oura-sync
lifeos context
lifeos obsidian-write ...
lifeos review-record ...
lifeos reviews ...
```

All command output is JSON so Codex, Claude, and unattended tasks can consume it without scraping prose.
