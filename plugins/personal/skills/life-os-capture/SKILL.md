---
name: life-os-capture
description: >-
  Route Aren's natural-language personal capture into TickTick, Obsidian, a commitment record, a decision note, or a calendar proposal while preserving the original wording and preventing duplicates. Use for "remember this", "capture this", "task: ...", "I promised ...", "journal this", or "save this decision". Do not use for bulk inbox processing or a full daily review.
---

# Life OS Capture

Turn one piece of input into the smallest correct source-of-truth update. Do not create a note and task merely because both are available.

Read `../../runtime/references/workflow-contract.md` before acting.

## Step 1 — classify the input

| Input means | Destination |
|---|---|
| Action, reminder, or routine | TickTick |
| Thought, reflection, reference, idea, or goal context | Obsidian |
| Promise Aren made | Commitment ledger plus TickTick task when warranted |
| Promise made to Aren | Waiting-on commitment plus optional follow-up task |
| Time-specific commitment | TickTick calendar proposal; confirm before creating or moving time |
| Meaningful decision | Obsidian decision note and decision record |
| Person update | Person context with source reference; no unsolicited outreach |

Ask one focused question only when the destination or required timing truly changes the result. Otherwise make a conservative, reversible choice.

## Step 2 — preserve provenance

Retain the raw wording in the authoritative destination when appropriate. Record a normalized event containing source, source ID, event type, timestamp, source reference, sensitivity, confidence, and a stable idempotency key. Do not put private raw communication into the ledger.

## Step 3 — write narrowly

- For an explicitly requested task, discover TickTick projects and tags; use `lifeos ticktick-create-task --confirmed` with a stable idempotency key derived from the request and intended due date.
- For a high-confidence inferred follow-up, record the commitment, then use `lifeos ticktick-create-followup`. Below the automatic threshold, leave it as a candidate.
- For an Obsidian capture, use the vault skill's taxonomy. Create a new note only when there is no appropriate existing note.
- For a decision, use the decision workflow and template.
- For a calendar change, show the proposed time and receive confirmation first.

Never invent a due date. If the user says "tomorrow" or another relative time, resolve it to an explicit date in the configured timezone.

## Step 4 — verify

Read back the created source item and inspect the ledger/action record. Report one destination, the resolved date if any, and whether any candidate remains awaiting review.
