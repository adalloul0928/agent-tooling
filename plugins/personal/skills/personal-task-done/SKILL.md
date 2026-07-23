---
name: personal-task-done
description: Mark a personal PUMPD task complete in Linear. Linear owns task state. If the issue has a linked Obsidian plan and the work shipped, archive that plan without creating a Completed task mirror.
---

# Personal Task — Done

Close a personal task in the system that owns its state: Linear.

## Workflow

1. Resolve the Linear issue by id or title. Ask only when multiple open issues match.
2. Set the issue state to `Done`.
3. Check its links for an Obsidian plan. If a linked `PUMPD/Plans/<Topic>.md` exists and the work shipped, move it to `PUMPD/Archive/Plans/<Topic>.md` and update its frontmatter to `status: done`. Preserve the note; do not delete it.
4. Report the Linear URL and any archived plan path. Do not commit the vault unless asked.

There is no `PUMPD/Tasks/Completed/` mirror.
