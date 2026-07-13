---
name: pumpd-retro
description: >-
  Review accumulated learnings (bugs, errors, friction, surprises logged during
  the pumpd-* skills, agents, and Cyrus runs) and propose concrete improvements
  — edit a skill, add a skill/agent, add a durable rule, or fix a recurring
  error — gated on human approval before any edit. Reads the append-only
  "Agent Learnings" log in Obsidian; optionally enriches from recent
  session transcripts. Use for "run the retro / review learnings / what should
  we fix / improve the workflow", or on a schedule. Learnings-driven; complements
  usage-recommender (usage-driven).
---

# /pumpd-retro — review learnings, improve the system

Closes the self-improvement loop: turns the raw learnings log into concrete, **approved** improvements to the skills / agents / rules.

## Inputs
- The learnings log: vault `PUMPD/Operations/AI Tooling/Agent Learnings.md` (or the existing legacy `Claude Code Learnings.md`) — only entries **not** yet marked `✅ promoted`.
- Any raw tool-failure log exposed by the active client — noisy; mine it for **recurring-error tallies** (same tool/error repeated), not individual entries.
- The inventory of targets: the canonical `agent-tooling` plugins, project `.agents/skills`, project client adapters, project instructions, hooks, and any client-owned memory that is available.
- _Optional:_ recent session transcripts exposed by the active client — read **only** to enrich a vague learning, never as the primary signal (transcript-frequency analysis belongs to `usage-recommender`).

## Steps
1. **Gather & cluster.** Read the un-promoted learnings. Group by `tags` / `source` / `kind`; collapse duplicates; rank by **frequency × pain**. Surface **recurring** items (same `what` ≥2×) first — highest ROI.
2. **Diagnose each cluster → a fix type:**
   - **edit a skill** — tighten ambiguous instructions / add a missing step (e.g. "pumpd-plan must require a migrations line in §6").
   - **add a skill/agent** — a recurring multi-step workaround deserves its own tool.
   - **durable rule** — a one-liner gotcha → a memory file or `.claude/rules/`.
   - **fix a recurring error** — a hook, an allowlist entry, a config change.
   Pull in transcript context only if a cluster is too vague to action.
3. **Propose — a filtered punch-list.** Each item: **observation** (cite the log entries / counts / dates) → **proposed change** → **exact target file** → **diff preview**. Material only (borrow `/pumpd-review`'s discipline) — don't bury the user in nitpicks.
4. **Approval gate (hard).** Present the punch-list and **stop**. Nothing is edited until the user approves, **item by item**. For each approved item, use `add-tool` for a new capability, the active client's config workflow for hooks/settings, the Obsidian workflow for vault writes, or a direct edit for an existing skill.
5. **Apply & prune.** Make the approved edits. Move consumed entries to the log's `## Promoted / archived` section with a date + what changed. Write a short dated "retro summary" block (what changed + why — itself a learning). Update the `last-retro` marker.

## Relation to `usage-recommender`
Siblings, not duplicates. **This** is *qualitative* — "from what *hurt*, what should we *fix/improve*?" (from the learnings log). **`usage-recommender`** is *quantitative* — "from how you *work*, what's *missing*?" (from transcript frequencies). When a learning looks frequency-shaped ("re-ran tests by hand 4×"), **hand it off** — suggest running `usage-recommender` to quantify and propose the automation.

## Rules
- **Never edit without approval** — the whole point is human-in-the-loop improvement.
- **Material only** — cluster and filter; recurring pain first.
- **Cite the evidence** — every proposal points to the log entries that justify it.
- **Close the loop** — always archive/mark promoted entries so the inbox stays a true backlog.

## Finish — offer the next step
End by summarizing what changed, then:
> ▶ **Next:** loop closed — re-run `/pumpd-retro` when the log fills again, or run `usage-recommender` for any frequency-shaped gaps you surfaced.
