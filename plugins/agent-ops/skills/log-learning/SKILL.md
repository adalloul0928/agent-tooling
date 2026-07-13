---
name: log-learning
description: >-
  Append a structured learning (bug, error, friction, surprise, or improvement
  idea) to the PUMPD "Agent Learnings" log in Obsidian. Use mid-workflow
  the moment something is wrong, ambiguous, slow, or could be better in a
  skill/agent/pipeline — or when the user says "log that / note that learning /
  capture this for the retro". Quick append only; /pumpd-retro reviews these
  later and turns them into improvements.
---

# /log-learning — capture a learning

Append one dated block to the learnings log so `/pumpd-retro` can act on it later. Fast and low-ceremony — the point is to capture friction the *moment* it happens, not to fix it now.

## Where
`PUMPD/Operations/AI Tooling/Agent Learnings.md` in the Obsidian vault. If the legacy `Claude Code Learnings.md` already exists, keep using it until it is deliberately renamed. Locate the vault through the connected Obsidian capability or `$OBSIDIAN_VAULT`; ask once if neither is available. Append under the `## Inbox` heading (newest near the top, above `<!-- new entries go here -->`).

## Format — append exactly one block
```
## <YYYY-MM-DD HH:MM> · <source> · <bug|error|friction|surprise|improvement>
- what: <what happened, concretely>
- signal: <how it was noticed / how often / impact>
- idea: <proposed fix — which skill/agent/rule to change, or "open">
- tags: #skill/<name> [#recurring]
```
- `<source>` = the skill/agent/step you were in (`pumpd-research`, `pumpd-plan`, `pumpd-review`, `pumpd-decompose`, `cyrus`, `manual`).
- Use a real timestamp. Keep it ~4 lines.

## Rules
- **Append only** — never edit or delete existing entries (that's `/pumpd-retro`'s job).
- One learning per block; three issues → three blocks.
- **Don't fix it here** — just capture and carry on. (If it blocks the current task, handle that separately.)
- This is interactive-session capture; Cyrus headless runs use the repo-side log when that's wired.
