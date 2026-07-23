---
name: obsidian-vault
description: Safely read, search, create, update, organize, and commit notes in Arend's Obsidian vault. Uses direct filesystem and Git access when available and a remote Obsidian connector when filesystem access is unavailable. Use when working with Obsidian, vault folders, Markdown notes, wikilinks, tags, frontmatter, note templates, vault taxonomy, PUMPD idea capture/intake/organization, PUMPD/Harstem/Personal/Work notes, or vault Git hygiene.
---

# Obsidian Vault

## Operating Model

There are two ways to reach the vault. Which one to use depends on **which capabilities are available in the current session** — check that first, do not assume.

**If filesystem tools are available** on the Mac with access to the vault path: use the filesystem as the default. This is the local, Git-tracked working copy.
- Search with `rg`, use the available file-reading tool, make targeted edits with the client's file-edit primitive, create with a file-creation tool or the bundled `scripts/new_note.py`, and review with `git`. For example, Codex normally uses `apply_patch`; Claude Code normally uses `Edit`. Commit only when asked.

**If filesystem tools are NOT available, but a remote `obsidian` connector is**: use the connector's search, read, list, write, edit, and move capabilities. It is a full read/write path to the same vault and syncs to every device within minutes. Connector tool names can vary by client; discover the available capabilities instead of requiring a fixed prefix.

This capability-based discovery is deliberate: it keeps the same authored skill portable across Claude and Codex.
- There is no Git or bash here, so the Git steps in the Workflow section do not apply — skip them.
- Prefer writing new generated content into `00 Inbox/` rather than directly into project folders, since there is no Git review gate and writes sync immediately. Promote to a final location only when the user confirms.
- This remote-only staging rule overrides the normal taxonomy and PUMPD idea destinations below until the user confirms promotion.
- Do NOT treat the MCP connector as a last resort; when it is the only path to the vault, it is the correct primary tool.

**If both are available**, prefer the filesystem (faster, supports Git review). **If neither is available**, say so plainly rather than guessing or fabricating vault contents.

A small set of MCP tools still pertain to live Obsidian app state when present (active note, opening a note in the app, command-palette templates). Use those only for genuine live-app actions, not as the general read/write path.

Known vault paths on this machine:

- Preferred accessible clone: `$HOME/Obsidian/obsidian-vault`
- User-mentioned path: `$HOME/Documents/obsidian-vault` may require macOS privacy permission
- Older duplicate: `$HOME/obsidian-vault` had no committed baseline when last checked

If the user gives a vault path, use it. If it is blocked, explain the permission issue and avoid guessing unless another clone clearly has the same Git remote.

## Workflow

1. Identify the vault root with `.obsidian/`; run the bundled `scripts/find_vaults.sh` when uncertain.
2. Run `git -C "$VAULT" status --short --branch` before writes.
3. Read narrowly. Use `rg --glob '*.md' --glob '!**/.obsidian/**' --glob '!**/.smart-env/**'`.
4. Do not write until target files and folder placement are clear.
5. For existing notes, preserve current style unless the user asks for cleanup. Do not backfill frontmatter into old docs by default.
6. For new notes, use frontmatter and the templates in `assets/templates/`; `scripts/new_note.py` can create a safe starter note.
7. After edits, show `git diff --stat`, relevant `git diff --name-status`, and current status.
8. Commit only when explicitly requested. Stage only intended files. Never push automatically.

## PUMPD Idea Intake

When the user sends a PUMPD idea, do not dump it blindly into a generic inbox. Convert it into a useful product/work note:

1. Classify the idea: product/UX, stats/analytics, AI Coach, workout/session flow, onboarding/auth, data/backend, deployment/ops, AI tooling/workflow, beta launch, or research.
2. Search active PUMPD notes first, excluding `PUMPD/Research/archive/` unless historical context is needed.
3. If the idea clearly belongs to an active note, append a short dated section there.
4. If it is new, fuzzy, and not ready for investigation, put it in Linear. Use `00 Inbox/` only when the user explicitly wants vault capture or Linear is unavailable.
5. If it mainly requires investigation, create or update `PUMPD/Research/<Topic>.md`.
6. After an approach is approved, promote the same topic note to `PUMPD/Plans/<Topic>.md`; do not create a parallel research/plan pair.
7. If it is about PUMPD-specific Codex/Claude/Cyrus workflow, use `PUMPD/AI Tooling/`.
8. If it is current technical documentation, setup, deployment, or architecture, prefer the relevant code repository documentation.

When capturing an idea, preserve the user's raw wording and add a concise interpretation, affected surfaces, next action, and open questions. New idea notes should use `type: idea`, `status: captured`, and tags including `pumpd` and `idea`. Read `references/pumpd-idea-intake.md` before organizing PUMPD ideas.

## Safety Rules

- Never modify `.git/`, `.obsidian/`, `.smart-env/`, `.trash/`, plugin configs, workspace files, tokens, certificates, or generated cache files unless the user explicitly asks.
- Keep `.obsidian/plugins/obsidian-local-rest-api/data.json` ignored and untracked; it contains local API/cert material.
- Reject paths outside the vault after resolving symlinks/`..`.
- Prefer targeted edits or appends over whole-file rewrites.
- Do not delete notes unless explicitly requested; archive instead.
- Abort or ask before mixing unrelated dirty files with a requested change.
- Treat `Personal/` as sensitive: search only the requested scope.
- Legacy broken wikilinks and missing top-of-file frontmatter are acceptable unless the user asks to fix them.

Read `references/safety.md` before broad reorganizations, bulk edits, or Git cleanup.

## Taxonomy

Use project-first organization. New notes should go where they will be retrieved during work, not where they were captured.

Default structure for future organization:

```text
00 Inbox/
PUMPD/
  _PUMPD.md
  Research/      (active investigation)
  Plans/         (approved intent; task state stays in Linear)
  AI Tooling/    (PUMPD-specific agent workflow and operation)
  Archive/       (shipped and superseded thinking)
Harstem/
  _Harstem.md
  Planning/
  Research/
  Content/
Personal/
  _Personal.md
  Life/
  Career/
  Systems/
  Travel/
  Archive/
Work/
  _Work.md
_Templates/
_Attachments/
99 Archive/
```

Important current exceptions:

- Leave `IAWIS/` as-is. Do not apply the new taxonomy there unless the user asks.
- Leave `jimmy-wedding/` as-is. Do not rename it or split it into the new taxonomy unless requested.
- Leave docs already under `PUMPD/Research/archive/` alone. Do not move them back out based on taxonomy preferences.

Routing rules for new notes:

- PUMPD backlog, status, assignment, and checklists -> Linear
- PUMPD active investigation -> `PUMPD/Research/<Topic>.md`
- PUMPD approved implementation intent -> promote the same note to `PUMPD/Plans/<Topic>.md`
- PUMPD-specific Codex/Claude/Cyrus workflow -> `PUMPD/AI Tooling/`
- Current deployment/CI/Supabase/EAS/release documentation -> relevant repository docs
- PUMPD external research/comparisons/design briefs -> `PUMPD/Research/`
- PUMPD durable choices -> `PUMPD/Decisions/`
- Harstem project docs -> `Harstem/Planning/`, `Harstem/Research/`, or `Harstem/Content/`
- Personal systems/life/career/travel -> matching `Personal/` subfolder
- IAWIS and jimmy-wedding new notes -> use their existing folders; ask before creating new subfolders
- Unsure/capture-only notes -> `00 Inbox/`

Read `references/taxonomy.md` for examples and folder intent.

## New Note Requirements

New Markdown notes must have top-of-file YAML frontmatter:

```yaml
---
title: "Title"
created: "YYYY-MM-DD"
updated: "YYYY-MM-DD"
type: note
status: draft
tags: []
aliases: []
---
```

Use simple tags without `#` in frontmatter. Prefer `type` values like `note`, `project`, `research`, `meeting`, `decision`, `runbook`, `plan`, or `idea`. Read `references/frontmatter.md` for templates and field conventions.

## Useful Commands

```bash
# Resolve this to the directory containing the active SKILL.md. Do not assume a
# Claude, Codex, or marketplace cache location.
SKILL_DIR="/absolute/path/to/the/active/obsidian-vault-skill"
VAULT="$HOME/Obsidian/obsidian-vault"

# Locate vault candidates
bash "$SKILL_DIR/scripts/find_vaults.sh"

# Review Git state and sensitive tracking risk
bash "$SKILL_DIR/scripts/git_review.sh" "$VAULT"

# Search notes
rg --glob '*.md' --glob '!**/.obsidian/**' --glob '!**/.smart-env/**' 'search term' "$VAULT"

# Create a new note with frontmatter
python3 "$SKILL_DIR/scripts/new_note.py" \
  "$VAULT" \
  'PUMPD/Research/Example Topic.md' \
  --title 'Example Topic' \
  --type research \
  --tags pumpd research

# Capture a structured PUMPD idea (idea notes use status: captured)
python3 "$SKILL_DIR/scripts/new_note.py" \
  "$VAULT" \
  '00 Inbox/Example Idea.md' \
  --title 'Example Idea' \
  --type idea \
  --status captured \
  --tags pumpd idea
```
