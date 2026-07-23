---
name: pumpd-plan
description: >-
  Author a consistent PUMPD feature plan from a /pumpd-research note. Produces a
  standard plan note in the Obsidian vault using the canonical 12-section format
  (summary, problem, goals/non-goals, decisions, approach, FILE STRUCTURE,
  data model, DECOMPOSITION, risks, EARS acceptance criteria, milestones, open
  questions). Decides file structure BEFORE cutting tasks. Use after
  /pumpd-research and before /pumpd-decompose. The plan must be approved before
  decomposing to Linear.
---

# /pumpd-plan — author the canonical PUMPD plan

Stage 2 of the pipeline: **research → plan → decompose → Cyrus**.
Turns a research note into the durable, consistent plan that becomes a Linear epic.

## Scope — mobile + backend
Two surfaces of the `pumpd-mobile-app` monorepo: **`apps/mobile`** (React Native / Expo) and **`apps/backend`** (Supabase / Deno — edge functions, migrations, RLS). §6 File Structure and §8 tasks target those (+ shared `packages/*`); set `surface` to `mobile`, `backend`, or both. Don't plan changes to `apps/admin` (Next.js), `apps/website`, `apps/catalog`, or `apps/docs` — flag any such dependency as out-of-scope.

## Inputs
- The research note from `/pumpd-research` (`PUMPD/Research/<Topic>.md`). If none exists, run `/pumpd-research` first.
- The canonical 12-section format below. The workflow owns the format; it does not depend on a vault template.
- Constitution: the repo's `AGENTS.md` + the rules for your surface(s) — **mobile** `.claude/rules/mobile-*.md`, **backend** `.claude/rules/backend-edge-functions.md` + `shared-types.md` (+ `apps/backend/AGENTS.md`). Comply; don't restate.

## The canonical format (12 sections — every plan, every time)
1. Summary · 2. Problem/Context · 3. Goals/**Non-Goals** · 4. Research & **Decisions** (link the research note) · 5. Approach/Architecture · **6. File Structure / Surfaces** · 7. Data Model/Contracts (only if touching Supabase/API) · **8. Decomposition** · 9. Risks/Blockers · 10. **Acceptance Criteria (EARS, testable)** · 11. Rollout/Milestones · 12. Open Questions.

## Rules that make the plan agent-ready
- **§6 File Structure BEFORE §8 Decomposition.** Decide which **`apps/mobile`** and/or **`apps/backend`** files change first, then cut tasks along those seams. This is what produces clean, independently-mergeable issues (= clean Graphite stacks, no overlapping PRs).
- **Each §8 task is a future Linear issue = one Graphite PR.** Give every task: a title, target **Files**, **EARS acceptance** ("WHEN x THE SYSTEM SHALL y"), a **Verify** command (`pnpm …`), **Depends on** (the task below it, or — for the foundational one), `[P]` if parallel, and an **Autonomy** (`ai:1`–`ai:5`). Aim for one coherent change, < ~200 LOC each.
- **Cite the docs (§4 + §5).** Carry the research note's source links into the plan — every decision in §4 and the chosen approach in §5 links to the **official doc / release / reference repo** it's based on, and §4 ends with a consolidated **Sources** list. Anyone (or the Cyrus agent) should be able to click straight to the source. No sourceless claims.

## Steps
1. **Load** the research note + skim the constitution for constraints.
2. **Draft section by section, with incremental approval.** Present §1-5, get a nod; then §6 (file structure) — this is the load-bearing one, confirm it; then §8 decomposition; then risks/acceptance/milestones. Don't dump the whole plan silently.
3. **Decompose** per the rules above. Order bottom-up: the foundational task (branches off `preview`) first; mark `[P]` tasks that can run independently. Map tasks → milestones (phases).
4. **Self-review before finishing** (a quick `/analyze`-style pass): no placeholders/"TBD"; no contradictions; every Goal/§10 criterion has a task; every task names files + a verify command; the dependency chain is linear (A→B→C), not a diamond.
5. **Promote the same topic note.** Move `PUMPD/Research/<Topic>.md` to `PUMPD/Plans/<Topic>.md`, change `type` to `plan`, and retain a concise Research Summary plus the full source list before the 12 plan sections. Do not create a parallel research/plan pair. Set frontmatter `feature`, `surface` (`[mobile]`, `[backend]`, or both), and `autonomy`.
6. **Review gate.** Run **`/pumpd-review`** on the plan — an adversarial red-team panel + completeness critic that returns a punch-list of material holes. Address blockers and re-run until it's **CLEAR** or **PROCEED-WITH-NOTES**. A plan should not reach `/pumpd-decompose` un-reviewed.
7. **Hand off.** Summarize the decomposition (task list + dependency order) and the review verdict, then offer to run `/pumpd-decompose` to create the Linear Project + issues.

## Output
One plan note in `PUMPD/Plans/`. Show `git -C <vault> status --short`. Do not commit unless asked. Leave `linear-project:` blank — `/pumpd-decompose` fills it.

## Gate
Do not proceed to `/pumpd-decompose` until (a) `/pumpd-review` returns CLEAR or PROCEED-WITH-NOTES and (b) the user approves the plan. Decomposition is the expensive, hard-to-undo step.

## Finish — offer the next step
End your reply with a clear handoff:
> ▶ **Next:** `/pumpd-review` — red-team the plan before it goes to Linear. (Then `/pumpd-decompose` once it's CLEAR.)

---
**Log learnings as you go.** If a step here was wrong, ambiguous, slow, or could be better, drop a quick `/log-learning` note (it feeds `/pumpd-retro`) before moving on.
