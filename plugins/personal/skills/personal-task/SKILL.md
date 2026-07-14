---
name: personal-task
description: Create a personal (non-AI) PUMPD task — a Linear issue assigned to Aren and labeled `personal`, plus the matching Obsidian doc(s) in `PUMPD/Tasks/Todo/`, linked both ways. Use when Aren wants to add or track a personal task / to-do, capture work he'll drive himself (by hand or steered with Claude/Codex), or spin up the Linear + Obsidian scaffold for a new piece of personal work. If no plan/detail is given, leave the Obsidian body as the template to fill later. Not for AI-delegated agent work (use the pumpd-* pipeline / `codex-intake` / `ai:*` labels) or full feature decomposition (use /pumpd-plan → /pumpd-decompose).
---

# Personal Task

Create a personal task in two places at once and link them:

1. **Linear** — a PUMPD issue assigned to Aren, labeled `personal` (the label that powers his personal board).
2. **Obsidian** — the doc scaffold under `PUMPD/Tasks/Todo/` (the Todo column; pass `--status active` to start it in `Active/`), with frontmatter filled and the body left as template placeholders unless content is provided.

Default shape is a **standalone task** (one issue + one note). The **feature** shape (a 4-file folder) is for when a folder is explicitly requested.

## When to use

- "make me a personal task to …", "add a personal to-do …", "track this for me", "set up a task + Obsidian docs for …".

## When NOT to use

- **AI-/agent-driven work** (Codex/Cyrus delegations, daily-scan items): that's the pumpd-* pipeline and the `codex-intake` / `ai:*` labels — not `personal`.
- **A real feature** needing a plan + decomposition into a Linear Project + sub-issues: run `/pumpd-plan` → `/pumpd-review` → `/pumpd-decompose`. This skill's `feature` mode only scaffolds the *Obsidian folder*; it does not create a Linear Project or sub-issues.

## Inputs

Only a **title** is required. Apply defaults for the rest — do not interrogate; ask only if the title is missing or the request is genuinely ambiguous.

- `priority` (Urgent/High/Medium/Low), `due` date, `status` (default **Todo**), `surface` (`mobile`/`backend`/…)
- `execution` — how the work is driven: `manual | claude | codex | cyrus | mixed` (default **claude**)
- `type` — `task` (default) or `feature`
- goal / checklist / plan content — **if given, fill it in; if not, leave the template placeholders**

See `references/conventions.md` for the full schema, label taxonomy, `execution` values, and the ownership rule.

## Workflow

1. **Create the Linear issue** with the Linear MCP `save_issue`:
   - `team: "PUMPD"`, `assignee: "me"`, `labels: ["personal"]` (add the surface label too if a surface is given, e.g. `["personal", "mobile"]`), `state` (default `"Todo"`), plus `priority` / `dueDate` if provided.
   - `description`: a concise version of the goal/checklist if provided; otherwise a one-line summary.
   - Capture the returned identifier (e.g. `PUM-341`) and `url`.
   - The `personal` label already exists. If `save_issue` ever fails because it's missing, create it with `create_issue_label name=personal` and retry.

2. **Scaffold the Obsidian doc(s)** — run the script with the values from step 1:
   ```bash
   python3 scripts/new_task_docs.py --title "<title>" --type task \
     --linear-id <PUM-id> --linear-url "<url>" \
     --execution <mode> --surface "<csv-or-empty>"
   ```
   - Use `--type feature` to scaffold the 4-file folder instead of a single note.
   - The script fills frontmatter (dates, status, Linear links, surface, execution), sets the title, leaves the body as template, refuses to overwrite, and prints `OBSIDIAN_URL=…` and `CREATED=…`.
   - On anything unusual, preview first with `--dry-run` (prints the filled files, writes nothing).

3. **Fill provided content (only if given).** If the user provided a goal/plan/checklist, Edit the created file(s) to fill the matching sections (Goal · Checklist · Notes for a task; `plan.md` / `research.md` for a feature). If nothing was provided, leave the placeholders untouched.

4. **Add the Linear back-link.** Take `OBSIDIAN_URL` from step 2 and attach it to the issue:
   `save_issue id=<PUM-id> links=[{ url: "<OBSIDIAN_URL>", title: "Obsidian — <title> note" }]`.

5. **Report** the Linear URL and the created path(s); state the `execution` value used. Do **not** commit the vault — leave that to the user (mention they can).

## Notes

- The `obsidian://` link resolves only on Aren's machine — expected for a personal system.
- Lifecycle: `Tasks/Todo/` → `Tasks/Active/` (when you start) → `Tasks/Completed/` (when the Linear issue is **Done**, set `status: done`). Completion is handled by the `/personal-task-done` skill.
