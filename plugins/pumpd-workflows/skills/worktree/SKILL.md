---
name: worktree
description: Manage git worktrees using wtp (Worktree Plus)
---


# Worktree Management

Manage git worktrees using wtp (Worktree Plus).

## Usage
- `/worktree <branch-name>` - Create worktree for new branch
- `/worktree <existing-branch>` - Create worktree for existing branch
- `/worktree list` - Show all worktrees
- `/worktree remove <branch>` - Remove worktree
- `/worktree remove --with-branch <branch>` - Remove worktree and branch

## Arguments
$ARGUMENTS

## Instructions

Parse arguments and run the appropriate wtp command:

1. **No args or "list"**: Run `wtp list`
2. **"remove ..."**: Run `wtp remove` with the provided arguments (supports `--with-branch`, `--force`, `--force-branch`)
3. **Anything else is a branch name**:
   - Check if branch exists locally: `git show-ref --verify --quiet refs/heads/<branch>`
   - If exists: Run `wtp add <branch>`
   - If doesn't exist: Run `wtp add -b <branch>`

After `wtp add`, the hooks in `.wtp.yml` automatically:
- Copy `.env` to the new worktree
- Copy `.claude` directory to the new worktree
- Run `npm install`

After successful worktree creation, open the new worktree in a new Cursor window:
```bash
cursor <worktree-path>
```
The worktree path follows the pattern: `<repo-root>-worktrees/<branch-name>`

Report the result to the user.
