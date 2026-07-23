---
name: pumpd-review
description: >-
  Adversarially review a PUMPD plan BEFORE it goes to Linear. Spawns a red-team
  panel (assumptions · failure modes · sequencing & the Graphite stack ·
  security/privacy) plus a completeness/consistency critic and a cross-model Codex (gpt-5.5) lens — each told to assume
  the plan is flawed and find what breaks — then synthesizes a filtered
  punch-list of MATERIAL holes and gates handoff to /pumpd-decompose. Use after
  /pumpd-plan, or standalone on any plan note.
---

# /pumpd-review — adversarially red-team a plan

The quality gate between `/pumpd-plan` and `/pumpd-decompose`. A hole caught here costs one edit; the same hole caught after Cyrus has built a stacked-PR series costs a rebuild.

## Principle: adversarial, not agreeable
A single "review this" pass is too soft — it nods along. This spawns **independent skeptics with distinct lenses**, each told to **assume the plan is flawed and find what breaks**, then keeps only **material** findings (would cause a bug, rework, a security issue, or a broken Graphite stack) — not style nits. One lens is **cross-model (Codex / gpt-5.5)** — a skeptic that shares none of Claude's blind spots; where the two models disagree is the highest-signal finding.

## Inputs
- A plan note (`PUMPD/Tasks/Todo/<Feature> — Plan.md`). Also load its [[<Feature> — Research]] note and the constitution (`AGENTS.md` + relevant `.claude/rules/`) for the completeness/coupling lenses.

## Steps
1. **Load** the plan, research note, and constitution. Note the surfaces/files §6 says it touches (drives the repo-grounded lenses).
2. **Spawn the panel in parallel** (Agent tool — `general-purpose`; use `Explore` for the repo-grep lenses). Give each reviewer the **full plan** and this framing: *"Assume this plan is flawed. Find the holes a careful engineer catches before building. Be specific; propose a concrete fix for each. Ignore style/nits — only surface issues that would cause a bug, rework, a security problem, or a broken build/stack."* The five reviewers:
   - **L1 · Assumptions & unknowns** — what does the plan take for granted? what's underspecified, hand-waved, or "TBD"? what external fact must hold that isn't verified?
   - **L2 · Failure modes & edge cases** — error / empty / offline / race / bad-data / partial-failure paths the plan ignores; the rollback story.
   - **L3 · Sequencing & the Graphite stack** *(repo-grounded)* — does §8 build **foundational-first**? Is the dependency chain **linear** (A→B→C, no diamonds)? Do `[P]` "parallel" tasks truly touch **disjoint files** (no hidden coupling)? Any task > ~200 LOC or not one coherent change? Does the repo compile/pass at each step?
   - **L4 · Security / privacy & data** *(repo-grounded)* — secrets handling, PII, Supabase RLS, data egress, third-party data sharing. Especially live for observability/analytics features.
   - **C · Completeness & consistency** — every Goal & §10 criterion maps to a §8 task; every task has target files + EARS acceptance + a verify command + autonomy; §4 sources present; constitution respected (base `preview`, package boundaries, testing bar).
   Each returns findings as a structured list: `{severity: blocker|major|minor, where: <section/task>, hole: <what>, why: <impact>, fix: <concrete suggestion>}`.
2b. **Cross-model lens (Codex / gpt-5.5)** — in parallel with the Claude panel, get an **independent** adversarial read from a *different model* via Bash (shares none of Claude's blind spots). Write the plan to a temp file `$PLAN`, then:
   ```bash
   codex exec --ignore-user-config -m gpt-5.5 --sandbox read-only \
     --skip-git-repo-check --color never -o /tmp/pumpd-codex-review.md \
     "You are an adversarial reviewer. Assume the plan below is flawed. Find MATERIAL holes — wrong assumptions, ignored failure modes, bad task sequencing, security/privacy gaps. Output a prioritized punch-list (Critical/Major/Minor), each with a concrete fix; ignore style nits." \
     < "$PLAN"
   ```
   Then **Read** `/tmp/pumpd-codex-review.md` back. **Best-effort** — if `codex` is missing, errors, or runs >~90s, skip it and note *"cross-model lens unavailable"*; never block on it. (`--ignore-user-config` skips personal MCP servers and the old Linear-stdio collision; auth comes from the ChatGPT login.)
3. **Synthesize & filter.** Fold the **Codex (cross-model)** findings in alongside the five Claude lenses. Dedupe (a hole flagged by ≥2 lenses ranks higher), and **specifically surface where Claude and Codex disagree** — the highest-signal output. **Drop minor/nitpick** items unless they cluster into something real. Keep blockers + majors; rank by severity.
4. **Write the punch-list.** Append a `## Plan Review — YYYY-MM-DD` section to the plan note: the verdict + ranked findings (severity · where · hole · fix). **Don't rewrite the plan** — that's the author's job via `/pumpd-plan`.
5. **Verdict & gate:**
   - **BLOCK** — has blockers → not ready for `/pumpd-decompose`. Name the sections/tasks to patch, then re-run `/pumpd-review`.
   - **PROCEED WITH NOTES** — majors only → list them; the user decides to patch or accept.
   - **CLEAR** — no material holes → green-light `/pumpd-decompose`.

## Rules
- **Material only.** A red-team that flags 40 trivia is noise. Filter hard; cite the exact section/task; always propose a fix.
- **Independent lenses.** Spawn in parallel; one reviewer must not see another's output — diversity catches what redundancy misses.
- **Repo-grounded where it counts.** L3/L4/C should actually read the touched files, not reason in the abstract.
- **Don't edit the plan.** Produce the punch-list; the human (or `/pumpd-plan`) applies fixes, then re-review. Re-runnable until CLEAR.

## Finish — offer the next step
End your reply with the verdict + the matching handoff:
> ▶ **Next (CLEAR):** `/pumpd-decompose` — ship the plan to Linear.
> ▶ **Next (BLOCK / PROCEED-WITH-NOTES):** patch the flagged sections (or re-run `/pumpd-plan`), then re-run `/pumpd-review`.

---
**Log learnings as you go.** If a step here was wrong, ambiguous, slow, or could be better, drop a quick `/log-learning` note (it feeds `/pumpd-retro`) before moving on.
