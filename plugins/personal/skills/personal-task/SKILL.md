---
name: personal-task
description: Create a personal PUMPD task in Linear, assigned to Aren and labeled `personal`. Linear is the task source of truth; create an Obsidian plan only when the user explicitly wants durable reasoning beyond the issue description. Use for personal to-dos or hands-on work, not AI-delegated work or full feature decomposition.
---

# Personal Task

Create a PUMPD Linear issue assigned to Aren and labeled `personal`.

## Ownership

- **Linear** owns backlog, status, assignee, priority, due date, and checklist.
- **Obsidian** is optional and holds substantial research or planning only.
- **GitHub** owns code and current technical documentation.

Do not create `PUMPD/Tasks/` notes or mirror Linear status in the vault.

## Workflow

1. Create the Linear issue with team `PUMPD`, assignee `me`, label `personal`, and any supplied surface, priority, due date, goal, or checklist.
2. Default to Linear only. Do not create an empty Obsidian scaffold.
3. If the user explicitly wants durable planning, or the supplied reasoning is too substantial for an issue description, create one `PUMPD/Plans/<Topic>.md` note with a Linear link and attach its `obsidian://` URL to the issue.
4. Report the Linear URL and, when created, the plan-note path. Do not commit the vault unless asked.

## Boundaries

- AI-delegated work uses the pumpd planning/delegation workflow and agent labels, not `personal`.
- A feature needing research and decomposition uses `/pumpd-research` → `/pumpd-plan` → `/pumpd-review` → `/pumpd-decompose`.
- A routine task should remain Linear-only.
