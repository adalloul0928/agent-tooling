# Vault Taxonomy

## Principles

- Organize by active domain first: `PUMPD`, `Harstem`, `Personal`, `Work`.
- Use folder placement for retrieval, not for every possible attribute.
- Use frontmatter and tags for status/type instead of deep folder splits.
- Keep legacy docs stable unless the user asks for a migration.
- Create index notes with a leading underscore when a folder needs a hub: `_PUMPD.md`, `_Personal.md`.

## Folder Intent

`00 Inbox/`
: Capture notes that do not yet have a clear home. Review periodically and move them.

`PUMPD/Tasks/`
: The work-item lifecycle. Three columns — `Todo/` (backlog), `Active/` (in progress), `Completed/` (shipped). One folder per feature or one note per standalone task; see `PUMPD/Tasks/_README.md`.

`PUMPD/Tasks/Todo/`
: Backlog column. Product plans, launch requirements, issue breakdowns, roadmaps, specs, capability docs, and raw/early-stage ideas that aren't started yet. Use this instead of `00 Inbox/` for PUMPD-specific planning and ideas. Pull an item into `Active/` when work begins.

`PUMPD/Research/`
: External research, comparisons, design inspiration, technical investigations, and synthesized findings.

`PUMPD/Operations/AI Tooling/`
: Codex, Claude, MCP, Linear automation, agent setup, workflow guides, and AI tool runbooks.

`PUMPD/Operations/Deployment/`
: EAS, CI/CD, Supabase branching, release, preview, app store, and production operation notes.

`PUMPD/Decisions/`
: Durable decisions with context, options considered, final choice, and review date.

`PUMPD/Assets/`
: Screenshots, app references, exports, and media files used by PUMPD notes.

`PUMPD/Archive/`
: Whole-note archive for inactive PUMPD material. Existing `PUMPD/Research/archive/` content should remain where it is unless the user asks.

`Harstem/`
: Project-specific docs for Harstem. Future additions can use `Planning/`, `Research/`, and `Content/`.

`Personal/`
: Personal material. Search and edit narrowly. Suggested future subfolders: `Life/`, `Career/`, `Systems/`, `Travel/`, `Archive/`.

`Work/`
: Professional or client work that does not belong to a named top-level project.

`_Templates/`
: Vault-local note templates if the user wants them copied into the vault.

`_Attachments/`
: Shared attachments when a project-specific `Assets/` folder is not a better fit.

`99 Archive/`
: Inactive whole projects or cross-project archives.

## Protected Legacy Areas

- `IAWIS/`: leave the existing structure alone.
- `jimmy-wedding/`: leave the existing structure and casing alone.
- `PUMPD/Research/archive/`: leave existing archived docs there.

## New Note Routing

| Request | Default path |
| --- | --- |
| "capture this quickly" | `00 Inbox/` |
| raw PUMPD idea | `PUMPD/Tasks/Todo/` |
| PUMPD plan / roadmap / not-yet-started task | `PUMPD/Tasks/Todo/` |
| PUMPD AI tooling, Codex, Claude, MCP | `PUMPD/Operations/AI Tooling/` |
| PUMPD deployment, CI, Supabase, EAS | `PUMPD/Operations/Deployment/` |
| PUMPD research or comparison | `PUMPD/Research/` |
| PUMPD decision | `PUMPD/Decisions/` |
| Harstem planning | `Harstem/Planning/` |
| Harstem content/copy/creative | `Harstem/Content/` |
| Personal life system | `Personal/Life/` or `Personal/Systems/` |
| Career/interview/job material | `Personal/Career/` |
| Travel idea | `Personal/Travel/` |
| IAWIS note | Existing `IAWIS/` folder only; ask before new folders |
| Wedding note | Existing `jimmy-wedding/` folder only; ask before new folders |
