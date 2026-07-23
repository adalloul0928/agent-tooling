# Vault Taxonomy

## Principles

- Organize by active domain first: `PUMPD`, `Harstem`, `Personal`, `Work`.
- Give each system one job: Obsidian for thinking, Linear for work state, repositories for current documentation.
- Use shallow folders and short noun-first filenames.
- Promote one topic note through its lifecycle instead of maintaining parallel copies.
- Archive rather than delete.

## PUMPD

```text
PUMPD/
  _PUMPD.md
  Research/
  Plans/
  AI Tooling/
  Archive/
```

`PUMPD/_PUMPD.md`
: The one-screen start page: active research, plans, AI-tooling notes, and links to Linear and repository documentation.

`PUMPD/Research/`
: Active investigation, comparisons, design exploration, and unresolved technical questions. Use one short topic filename such as `Workout Reliability.md`.

`PUMPD/Plans/`
: Approved implementation intent. `/pumpd-plan` moves the same topic note here and retains a concise research summary and sources. Linear owns decomposition and status.

`PUMPD/AI Tooling/`
: PUMPD-specific agent workflow, Cyrus operation, automation portfolio, and the agent learnings log. Shared distribution and setup documentation belongs in the `agent-tooling` repository.

`PUMPD/Archive/`
: Shipped, superseded, or historical thinking. Current technical behavior must be documented in the relevant repository before historical planning material is archived.

## PUMPD routing

| Request | Home |
| --- | --- |
| Raw idea or backlog item | Linear; `00 Inbox/` only for explicit capture when Linear is unavailable |
| Active investigation | `PUMPD/Research/<Topic>.md` |
| Approved implementation plan | Move the same note to `PUMPD/Plans/<Topic>.md` |
| Task status, assignment, checklist | Linear |
| Current architecture, setup, deployment, runbook | Relevant code repository |
| PUMPD-specific agent workflow | `PUMPD/AI Tooling/` |
| Shipped or superseded thinking | `PUMPD/Archive/` |

## Naming

- Two to five words, noun-first, Title Case.
- Folder placement communicates type; omit `Research`, `Investigation`, `Plan`, and `Reference` suffixes.
- Avoid punctuation-heavy names, dates, and revision numbers in active files.
- Use aliases to preserve old names after a rename.
- Use a leading underscore only for a folder's start page.

## Other domains

- Leave `IAWIS/` and `jimmy-wedding/` in their existing structures unless the user asks for a separate migration.
- Route Harstem material to its existing planning, research, or content area.
- Search and edit `Personal/` narrowly.
- Use `00 Inbox/` for genuinely unclear cross-project capture.
- Use `99 Archive/` for inactive whole projects or cross-project material.
