# Safety And Git Rules

## Before Writes

Run:

```bash
git -C "$VAULT" status --short --branch
```

Stop and inspect if:

- A merge, rebase, cherry-pick, or revert is in progress.
- The target file is already modified for unrelated reasons.
- The requested scope is broad and touches `Personal/`.
- The user asks for deletion or bulk rename.

## Do Not Touch By Default

- `.git/`
- `.obsidian/`
- `.obsidian/plugins/*/data.json`
- `.smart-env/`
- `.trash/`
- `.DS_Store`
- Tokens, certificates, API keys, private keys
- Generated indexes, embeddings, plugin caches

The file `.obsidian/plugins/obsidian-local-rest-api/data.json` must stay untracked and ignored because it contains Local REST API credentials/cert material.

## Write Discipline

- Resolve target paths and ensure they remain inside the vault.
- Read the current file before editing.
- Use the client's targeted file-edit primitive for manual text edits (for example, `apply_patch` in Codex or `Edit` in Claude Code).
- Prefer appending or section replacement over rewriting an entire note.
- Preserve note style unless the user asks for cleanup.
- Do not add frontmatter to old notes unless requested.
- New notes must include top-of-file frontmatter.

## Git Discipline

- After edits, run:

```bash
git -C "$VAULT" diff --stat
git -C "$VAULT" diff --name-status
git -C "$VAULT" status --short
```

- Commit only when explicitly requested.
- Stage only intended files.
- Never auto-push.
- Never run destructive commands such as `git reset --hard` or broad checkout cleanup unless explicitly requested.

## History Cleanup

If sensitive data was tracked, removing it from the index is not the same as removing it from Git history. If the user asks for history removal, use a deliberate history-rewrite plan and confirm the remote/backup implications before running it.
