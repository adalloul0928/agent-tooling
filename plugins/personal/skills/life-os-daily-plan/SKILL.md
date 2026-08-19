---
name: life-os-daily-plan
description: >-
  Build Aren's concise morning brief and day plan from TickTick tasks/calendar, open commitments, Gmail and iMessage follow-ups, Obsidian goals/context, and available read-only health trends. Use for "plan my day", "morning brief", "what deserves attention today", or the scheduled morning run. Do not use for reviewing how the day went.
---

# Life OS Daily Plan

Synthesize the day into three priorities and the preparation they require. A list of every task or email is not a morning brief.

Read `../../runtime/references/workflow-contract.md`. Use `../../runtime/templates/daily-plan.md` for a durable plan when one is requested or scheduled.

## Step 1 — establish the window

Use the configured timezone and state the exact date. Read today plus tomorrow far enough to expose preparation needs and schedule conflicts.

## Step 2 — gather bounded evidence

1. Run `lifeos doctor` and `lifeos context`.
2. Read TickTick open tasks due/overdue and today's calendar/time blocks.
3. Read open and candidate commitments.
4. Use the official Gmail capability for urgent, needs-reply, and waiting-on threads in a bounded recent window.
5. Use `lifeos imessage-recent` for bounded message context when permission is ready.
6. Search relevant Obsidian goals, plans, recent journal notes, and meeting context narrowly.
7. Include Oura/Apple Health only when fresh enough; describe trends, never diagnoses.

If one source is unavailable, label the brief incomplete and continue with the others.

## Step 3 — rank, do not dump

Select the three items most deserving attention using deadline, consequence, dependency, preparation cost, strategic importance, and relationship impact. Distinguish:

- must happen today;
- should move today;
- can wait or should be removed.

Surface conflicts, travel/preparation gaps, promises due, and one stale item worth deleting, delegating, scheduling, or clarifying.

## Step 4 — propose a realistic day

Compose a short sequence around existing TickTick calendar commitments. Do not silently change events or material task dates. When workload exceeds capacity, say what should move.

Health context may support a lighter/heavier suggestion only as one input. The user’s stated condition outranks a device score.

## Step 5 — write and verify

For a scheduled run, write the daily plan into the configured Obsidian review root and record the review in the Life OS ledger. Do not duplicate an existing note for the same date. Deliver a compact summary in the Codex task with:

1. three priorities;
2. schedule/preparation risks;
3. communication commitments;
4. what to defer or decide.
