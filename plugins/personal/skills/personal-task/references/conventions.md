# Conventions — personal-task

## Vault
- Root: resolve from `--vault`, `$OBSIDIAN_VAULT`, or the connected Obsidian capability.
- New work lands in `PUMPD/Tasks/Todo/`, moves to `PUMPD/Tasks/Active/` when started, then `PUMPD/Tasks/Completed/` when Done.
- Templates (the script reads these — single source of truth):
  - `PUMPD/_Templates/Standalone Task Template.md`
  - `PUMPD/_Templates/Feature/` (`_index.md`, `plan.md`, `research.md`, `checklist.md`)
- Full system doc: `PUMPD/Tasks/_README.md`.

## Linear
- One team: **PUMPD** (key `PUM`). Assign personal work to **me** (Aren, aren@getpumpd.com).
- **`personal`** label = Aren's hands-on work; it powers the personal board (filter `assignee:me` + `label:personal`, **Board** layout grouped by **Status**).
- Statuses: Triage · Backlog · **Todo** (default for new) · In Progress · In Review · Blocked · Plan Requested · Plan Review · Ready for Implementation · Ready to Merge · Done · Canceled.
- Surface labels: `mobile`, `backend`, `admin`, `website`, `catalog`, `docs`.
- **AI-driven work is the opposite of personal** — it carries a `delegate` (Codex/Cyrus) and/or labels `codex-intake` / `ai:1`–`ai:5` / `orchestrator` / `pumpd-agent` / `cyrus-stage` / `stacked` / `ai-scan`. Never tag those `personal`.

## Frontmatter (filled by `scripts/new_task_docs.py`)
Standalone task note:
```yaml
title, created, updated, type: task, status, tags, aliases,
linear-issue (URL), linear-id (PUM-…), surface: [..], execution
```
Feature `_index.md` additionally carries `feature` (slug), `linear-project` (URL), `autonomy`.

## `execution` — how the work is driven
`manual` (by hand) · `claude` (Claude Code, steered) · `codex` · `cyrus` (autonomous AI flow, overnight stacked PRs) · `mixed`. Default **claude**. Orthogonal to the `personal` label: `manual`/`claude` ≈ personal; `codex`/`cyrus` ≈ AI-driven.

## Ownership rule (avoid drift)
- **Linear** = task **state** (status, assignee, sub-issues, PRD)
- **Obsidian** = the **thinking** (plan, research, checklist, scratch)
- **GitHub** = the **code**

Never hand-copy Linear status into notes. The only Obsidian-side state is which folder you're in (`status: active | done`).
