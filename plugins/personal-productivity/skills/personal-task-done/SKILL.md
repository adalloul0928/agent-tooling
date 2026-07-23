---
name: personal-task-done
description: >-
  Mark a personal PUMPD task complete by setting its Linear issue to Done and
  moving its Obsidian note or folder to PUMPD/Tasks/Completed with status done.
  Use when Aren says a personal task is finished, completed, or ready to
  archive, referring to it by name or Linear id. Companion to personal-task.
---

# Personal Task — Done

Close out a personal task in both places: flip the **Linear** issue to **Done**, and archive the **Obsidian** doc from `PUMPD/Tasks/Active/` → `PUMPD/Tasks/Completed/` with `status: done`.

## When to use

- "mark Sentry setup done", "I finished the cert renewal", "complete PUM-337", "archive that task".

## Inputs

A way to identify the task — either:
- a **name** (the note/folder name, e.g. `Sentry Setup`), or
- a **Linear id** (e.g. `PUM-337`).

If the user is vague ("mark my task done") and more than one thing is open, ask which one (the script lists what's in `Todo/` + `Active/`).

## Workflow

1. **Move + flip status in Obsidian** — run the script with whichever identifier the user gave:
   ```bash
   python3 scripts/complete_task.py --name "<name>"
   # or
   python3 scripts/complete_task.py --linear-id PUM-###
   ```
   It locates the item in `PUMPD/Tasks/Todo/` or `PUMPD/Tasks/Active/` (standalone note **or** feature folder), moves it to `PUMPD/Tasks/Completed/`, sets `status: done` + bumps `updated`, and prints:
   - `LINEAR_ID=…`, `LINEAR_URL=…`, `MOVED_FROM=…`, `MOVED_TO=…`
   - or `ALREADY_DONE=…` if it's already in `Completed/` (then just confirm — nothing else to do).
   - Preview first with `--dry-run` if unsure. If it reports an ambiguous or no match, surface the candidate list and ask which one.

2. **Set the Linear issue to Done** — using `LINEAR_ID` from step 1:
   `save_issue id=<LINEAR_ID> state="Done"`.
   - If `LINEAR_ID` came back empty (a note created without a Linear link), search Linear by name to find it, or skip the Linear step and say so.

3. **Report** what moved (`MOVED_FROM` → `MOVED_TO`) and that the Linear issue is now Done. Do **not** commit the vault — leave that to the user.

## Notes

- This is the inverse of the `personal-task` skill; it does **not** reopen items (Completed → Active) — do that by hand if needed.
- Moving a note via the filesystem won't auto-update Obsidian backlinks from other notes (fine for this archive workflow). The feature folder's internal relative links survive the move.
- Conventions (vault paths, statuses, frontmatter) match the companion `personal-task` skill and its bundled `references/conventions.md`.
