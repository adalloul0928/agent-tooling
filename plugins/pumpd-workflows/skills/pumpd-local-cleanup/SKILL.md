---
name: pumpd-local-cleanup
description: Clean local PUMPD agent branches and worktrees. Use when the user asks to clear, prune, reset, or clean up local Claude/Codex branches or worktrees in pumpd-mobile-app, while leaving remote branches alone, and optionally fast-forwarding local main and preview afterward.
---

# PUMPD Local Cleanup

## Overview

Use this skill for the recurring PUMPD repo cleanup loop: remove local `claude/*` and `codex/*` branches, remove linked agent worktrees, preserve recoverability, and update local `main` and `preview`.

The cleanup is intentionally local-only. Do not delete remote branches, do not push, and do not reset uncommitted user work.

## Default Workflow

1. Read the repo's current `AGENTS.md` if it is available.
2. Run the bundled script in dry-run mode first:

Resolve `scripts/cleanup_pumpd_local.py` relative to this `SKILL.md`, then run:

```bash
python3 <skill-directory>/scripts/cleanup_pumpd_local.py --repo /path/to/pumpd-mobile-app
```

3. Check the dry-run output for:
   - local branches to delete
   - linked worktrees to remove
   - dirty worktrees that will be stashed
   - the branch the root checkout will end on

4. If the user explicitly asked to clean up, run the script with `--execute`:

```bash
python3 <skill-directory>/scripts/cleanup_pumpd_local.py --repo /path/to/pumpd-mobile-app --execute
```

5. Verify the result:

```bash
git status --short --branch
git worktree list --porcelain
git branch --list 'claude/*' 'codex/*' 'worktree-*' --format='%(refname:short)'
git branch -vv --list main preview
```

Report the final branch, the updated `main` and `preview` commits, the number of removed worktrees and branches, and any backup bundle or stashes created.

## Safety Rules

- Leave remote branches alone. The script does not run `git push` or `git push --delete`.
- Create a local bundle backup before deleting local branches.
- Stash dirty linked worktrees before removal with a `pre-local-worktree-cleanup` message.
- Remove only linked worktrees whose branch is `claude/*`, `codex/*`, or whose path is under `.claude/worktrees`.
- Delete only local `claude/*`, `codex/*`, and local branches that were attached to `.claude/worktrees`.
- Use fast-forward-only pulls for `main` and `preview`.
- Leave the root checkout on `preview` unless the user asks for a different final branch.
- If a project hook blocks a combined destructive command, split the operation into smaller commands rather than bypassing the hook.

## Script Notes

The script defaults to dry-run mode. It mutates the repo only with `--execute`.

Useful options:

```bash
--repo PATH              repo path; defaults to the current directory
--backup-dir PATH        bundle backup directory
--remote origin          remote to fetch from
--final-branch preview   branch to leave checked out
--skip-update            cleanup without pulling main/preview
```
