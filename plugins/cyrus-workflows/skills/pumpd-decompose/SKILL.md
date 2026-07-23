---
name: pumpd-decompose
description: >-
  Turn an APPROVED PUMPD plan into Linear for HANDS-OFF Cyrus execution. Creates
  the Linear Project (the "epic"), attaches the PRD as a Linear Document, and
  creates ONE orchestrator parent issue (labeled orchestrator + stacked +
  pumpd-agent) whose body carries the approved decomposition. You delegate that
  parent ONCE; Cyrus self-creates the stacked sub-issues and builds the PR stack
  overnight (auto-Done cascade). Use after /pumpd-plan once the plan passed
  /pumpd-review. Hard-to-undo — gate on approval first.
---

# /pumpd-decompose — ship a plan to Linear (orchestrator-parent mode)

Stage 4 of the pipeline. Reads an approved plan and creates the Linear structure for **hands-off** execution: a Project + PRD doc + **one orchestrator parent** carrying the approved breakdown. You delegate the parent **once** → Cyrus turns it into a stacked-PR build.

## How the hands-off cascade actually works (don't fight it)
- Cyrus's **orchestrator** role (the `orchestrator` label) self-creates sub-issues from the parent's body, **writing the explicit branch-from-parent + `gh stack` submission steps into each** (a sub-issue's base = its dependency's branch, **NOT** `preview`).
- Each **stacked**-labeled sub-agent builds its stacked PR, then **moves its own issue to Done** — which **releases the next stacked sub-issue** (per the repo's `appendInstruction`). ~20 min/layer. Validated on PUM-286 (under Graphite; the cascade is unchanged, the submit commands are new).
- **⇒ Create ONE parent and delegate ONCE.** Do **not** pre-create leaf issues — they won't cascade (no stacking steps in their bodies, and each would need its own delegate).

## Inputs
- The approved plan note (`PUMPD/Tasks/Todo/<Feature> — Plan.md`) — must have passed `/pumpd-review`. §8 = the breakdown; §10 = acceptance; §11 = phases.
- Linear MCP (`mcp__claude_ai_Linear` / `mcp__linear`). Team **PUMPD** (`84eaed25-6d3b-40a1-82b5-5c8e8e10b64d`). Surfaces in scope: `mobile`, `backend`.

## Pre-flight: the consistency gate (`/analyze`)
The plan should already have passed `/pumpd-review`. As a final check, verify it's agent-ready — refuse and report gaps if not:
- [ ] Every Goal / §10 criterion maps to a §8 task.
- [ ] Every task has: target **files**, **EARS acceptance**, a **verify command**, a **Depends on**, an **autonomy** (`ai:N`), and a **surface** (`mobile`/`backend`).
- [ ] The dependency chain is **linear** (A→B→C), not a diamond — diamonds don't map to a PR stack.
- [ ] Tasks are one-coherent-change / < ~200 LOC. Flag any too big to split.

## Steps
1. **Confirm the Initiative** (theme). Reuse (`list_initiatives`) or create (`save_initiative`) — keep few. Ask if ambiguous.
2. **Create the Project** (`save_project`) = the epic. `addTeams:["PUMPD"]`, `addInitiatives:[<theme>]`, short summary + a description brief pointing to the PRD doc.
3. **Create the PRD Document** (`save_document`, linked to the project) — paste the durable plan sections (Problem, Goals/Non-Goals, Approach, Data model, Acceptance, Sources).
4. *(Optional)* **Create Milestones** (`save_milestone`, one per §11 phase) so the orchestrator can file sub-issues into phases.
5. **Create the ONE orchestrator parent issue** (`save_issue` / `create_issue`) inside the project, using the **template below**:
   - **Title:** e.g. `Build: <Feature>`.
   - **Labels:** `orchestrator` + `stacked` + `pumpd-agent` — **no surface label** (Surface is a single-select group, so a parent spanning surfaces can't carry one; surfaces go on each sub-issue the orchestrator creates).
   - **Body:** the full §8 task list (each task: surface, files, EARS acceptance, verify command, dependency, autonomy) in dependency order, **plus explicit instructions** to create one stacked sub-issue per task and **follow the breakdown exactly — not re-plan**. `@`-link the PRD doc.
6. **Write back** the Project + parent issue URLs into the plan note's `linear-project:` frontmatter + a "Shipped to Linear" line.
7. **Summarize + hand off.** Show the project, PRD, parent, and the ordered task list the orchestrator will build. Then the kickoff (see Finish).

## Orchestrator parent body — template
```
# <Feature> — orchestrated stacked build

**PRD:** @<PRD document>   ·   **Surfaces:** mobile / backend
**This is a human-approved decomposition (/pumpd-plan + /pumpd-review). Build it EXACTLY as written — do NOT re-plan, re-scope, add, or drop tasks.**

## Instructions (orchestrator)
Create one **stacked sub-issue per task below, in this exact order**. For each sub-issue:
- Label it `stacked` + `pumpd-agent` + the task's surface + Type + `ai:N`.
- Its branch **stacks on the previous task's branch** — write the explicit steps into the sub-issue body: start from the parent (`git fetch origin && git reset --hard origin/<prev-branch>` in the fresh worktree, BEFORE implementing), implement + push, then register the PR **ready-for-review**: task 1 = plain `gh pr create --base preview` (a stack needs **2+ PRs**, so no stack yet); task 2 = `gh stack link <task1-branch> <task2-branch> --base preview --open` (creates the stack, bottom→top); task 3+ = `gh stack link <stack-number> <branch> --open` (stack number via `gh stack checkout <prev-branch>` + `gh stack view --json`). gh-stack-created PRs default to **draft** — always pass `--open`. If linking fails, fall back to `gh pr create --base <prev-branch>` and flag that a human must attach it to the stack from the PR page. State "base = <prev-branch>, NOT preview". The FIRST task bases on `preview`.
- After the stacked PR is open and registered in the stack, move the sub-issue to **Done** (auto-Done convention → releases the next).
- `[P]` tasks have no dependency — base them on `preview` (independent stacks).
- Keep each sub-issue **self-contained** (the builder reads only that issue).

## Tasks (in order)
### T1 — <title>   [foundational · base = preview]
- surface: mobile|backend · autonomy: ai:N · type: Feature|Improvement|Bug|Chore
- files: apps/<surface>/...
- acceptance (EARS): WHEN … THE SYSTEM SHALL …
- verify: pnpm --dir apps/<surface> …
### T2 — <title>   [depends on T1 · base = T1's branch]
...
```

## Guardrails
- **Gate on approval** — never run on an unapproved / un-reviewed plan.
- **One parent, not N leaves.** Pre-creating leaf issues breaks the cascade (the whole point of this rewrite).
- Show the parent body + task list **before** creating; don't silently create.
- **Native-stack prereqs:** the repo must be enabled for GitHub's Stacked-PRs private preview, and the runner needs `gh` ≥ 2.0 with the `gh-stack` extension (`gh extension install github/gh-stack`). `gh stack` exit code 9 = repo not enabled — stop and surface it.
- **Do not delegate yourself** (no delegation via tools) — tell the user to delegate the parent. Surface, don't trigger.
- If the orchestrator later drifts from the approved breakdown, log it (`/log-learning`) — we'll harden the parent body / `appendInstruction`.

## Finish — offer the next step
End with the kickoff handoff:
> ▶ **Next:** in Linear, **delegate** the parent issue to the Cyrus agent (one action). It self-creates the stacked sub-issues and builds the PR stack (~20 min/layer) — watch via `pm2 logs cyrus` + the issue feed. Then review + merge the stack. (Delegate is the only trigger — you do it.)

---
**Log learnings as you go.** If a step here was wrong, ambiguous, slow, or could be better, drop a quick `/log-learning` note (it feeds `/pumpd-retro`) before moving on.
