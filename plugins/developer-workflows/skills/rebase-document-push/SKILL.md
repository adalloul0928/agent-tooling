---
name: rebase-document-push
description: >-
  Safely prepare the current Git branch or worktree for handoff by rebasing it
  onto the latest remote preview branch, creating or updating a succinct branch
  document with dated revisions, verifying the rebased result, and pushing to
  the existing upstream branch or a friendly new remote branch. Use when the
  user says "rebase this worktree on preview and push it", "update, document,
  and push this branch", or "prepare this branch for handoff". This workflow
  rewrites and publishes Git history; do not use it for read-only status checks,
  documentation-only edits, or direct work on preview or main.
---

# Rebase, Document, and Push

Bring the current line of work onto the newest remote `preview`, leave a
durable and concise record of what it does, verify it, and publish the exact
rebased commit.

Preserve user work throughout. Never hide unrelated changes in an automatic
stash, discard conflict sides wholesale, use plain `--force`, prune remote
refs, push tags, or push directly to `preview` or `main`.

## Step 1 — establish the repository and push target

Read the applicable repository instructions before changing Git state. Inspect,
at minimum:

```bash
git rev-parse --show-toplevel
git status --short --branch
git remote -v
git branch -vv
git worktree list --porcelain
git symbolic-ref --short -q HEAD
git rev-parse --abbrev-ref --symbolic-full-name '@{upstream}'
```

Resolve two roles separately:

- The **push remote** is the current non-protected upstream's remote. With no
  publishable upstream, follow repository guidance and otherwise prefer
  `origin`; stop if the writable destination is ambiguous.
- The **base remote** supplies `preview`. Prefer the push remote when it has
  that branch; otherwise use the repository's documented integration remote or
  the sole remote that has `preview`. Stop when several qualify or none does.

These remotes are often the same, but a fork may correctly rebase from
`upstream/preview` and push back to `origin/feature`.

Choose the remote push branch before rebasing:

- If the current branch tracks a non-protected feature branch, preserve that
  exact push remote and branch name.
- If it tracks `preview`, `main`, or another integration branch merely
  because the worktree was created from that ref, treat it as having no
  publishable upstream and choose a friendly feature-branch name instead.
- If it has no upstream but an identically named branch exists on the selected
  push remote, treat that as the intended target only after confirming it
  represents this work.
- Otherwise create a friendly branch name from the work's purpose. Follow the
  repository's branch-prefix convention; absent one, use `codex/` plus two to
  six descriptive kebab-case words. Reuse the current local name only when it is
  already friendly and unambiguous.
- If HEAD is detached, create the friendly local branch before making commits.
- Refuse to continue when either the local or remote target is `preview`,
  `main`, or another protected integration branch unless the user explicitly
  changes the scope.

Check the proposed name locally and remotely before creating or renaming
anything. Record the starting local HEAD, fetched
`<base-remote>/preview` commit, and existing push-target commit so the
operation is auditable.

Fetch only the required branches; fetching does not authorize pruning or
deleting anything:

```bash
git fetch --no-tags <base-remote> \
  refs/heads/preview:refs/remotes/<base-remote>/preview
# Include this second refspec only when the push branch already exists.
git fetch --no-tags <push-remote> \
  refs/heads/<push-branch>:refs/remotes/<push-remote>/<push-branch>
git ls-remote --heads <push-remote> refs/heads/<push-branch>
```

Compare local and remote history with:

```bash
git rev-list --left-right --count HEAD...<push-remote>/<push-branch>
```

If the branch is only behind, fast-forward it to the remote target. If it has
diverged, review both sides and replay the local-only commits onto the remote
target before rebasing onto preview. Stop when authorship or conflict intent is
unclear. Never overwrite remote-only commits merely because a lease currently
matches.

## Step 2 — make the current work rebaseable

Review all committed, staged, unstaged, and untracked changes:

```bash
git log --oneline --decorate <base-remote>/preview..HEAD
git diff --stat
git diff
git diff --cached
git status --short
```

Classify every dirty path as part of this branch or unrelated user work. If the
scope is ambiguous, stop and ask. Do not tuck unrelated files into the branch
document or publish them.

When in-scope work is uncommitted:

1. Inspect it for credentials and generated or machine-local files.
2. Run the narrow checks that protect the affected code.
3. Stage exact paths rather than `git add .`.
4. Commit coherent units using the repository's commit convention.

Do not use `--autostash` as a shortcut. A hidden stash makes success difficult
to verify and can leave the worktree in a misleading state.

## Step 3 — rebase onto the fetched preview commit

Reconfirm that `<base-remote>/preview` is the just-fetched commit, then run:

```bash
git rebase <base-remote>/preview
```

Resolve conflicts by understanding both changes and preserving the current
repository contract. Do not resolve a file with blanket `ours` or `theirs`
unless the file's ownership rules make that resolution objectively correct.
After each resolution, inspect the resulting diff, stage only the resolved
paths, and continue the rebase.

If a correct resolution cannot be established, abort the rebase, verify that
the pre-rebase branch state is restored, do not push, and report the conflict.

## Step 4 — create or update the branch document

Derive the document from the final rebased commits and diff—not from memory or
the original request:

```bash
git log --reverse --format='%h %s' <base-remote>/preview..HEAD
git diff --stat <base-remote>/preview...HEAD
git diff <base-remote>/preview...HEAD
```

Choose the document location in this order:

1. A location required by repository instructions or contribution guidance.
2. An existing document clearly associated with the current branch or worktree.
3. `docs/branches/<friendly-branch-slug>.md`.

Do not turn the root README into a branch journal unless the repository already
uses it that way. Preserve an existing document's established structure and
manual content. For a new document, use this compact shape:

```markdown
# <Human-readable purpose>

- Status: In progress | Ready for review | Blocked
- Branch: `<push-remote>/<branch>`
- Base: `<base-remote>/preview` at `<short-sha>`
- Updated: YYYY-MM-DD

## Purpose

<One short paragraph describing the outcome and why it exists.>

## Changes

- <Specific user-visible, architectural, or operational change>

## Verification

- `<command>` — passed

## Open items

- None.

## Revisions

| Date | Revision |
| --- | --- |
| YYYY-MM-DD | <Concise summary of this revision> |
```

Use an ISO date from the user's current timezone. Append a revision for each
material skill run; when correcting the document again on the same date, update
that row rather than manufacturing a noisy duplicate. State only tests actually
run and results actually observed. Keep the document succinct, remove vague
phrases and process narration, and surface real open items instead of declaring
them complete.

Commit the document with a focused documentation commit unless repository
conventions require it to be folded into another commit.

## Step 5 — verify the rebased result

Run the narrowest relevant checks plus the repository's required quality gate.
At minimum:

```bash
git diff --check <base-remote>/preview...HEAD
git status --short --branch
git log --oneline --decorate <base-remote>/preview..HEAD
```

Then:

- Run the affected tests, lint, typecheck, build, or other documented quality
  command after the rebase.
- Review the complete final diff for unintended paths, generated-file drift,
  credentials, debug output, placeholder prose, unsupported claims, and
  duplicated or over-engineered changes.
- Reconcile the verification section of the branch document with what actually
  ran. Amend the documentation commit if needed, then rerun `git diff --check`.
- Require a clean worktree before pushing. If intentionally uncommitted work
  remains, do not push a partial history without explicit user direction.

## Step 6 — push with a lease and prove the remote result

Fetch the existing push target once more immediately before pushing. Compare
its current object ID with the recorded value and inspect any movement. Any
movement invalidates the prior history review, documentation, and verification;
reconcile it and repeat those gates before pushing.

For an existing remote branch, use an explicit lease tied to the fetched object
ID:

```bash
git push --force-with-lease=refs/heads/<branch>:<expected-remote-oid> \
  <push-remote> HEAD:refs/heads/<branch>
```

For a genuinely new branch, first prove the remote ref is absent, then publish
without force:

```bash
git push --set-upstream <push-remote> HEAD:refs/heads/<friendly-branch>
```

If either push is rejected, fetch and investigate. Never retry with plain
`--force` or weaken the lease. After success, require the remote branch object
ID to equal local HEAD:

```bash
git rev-parse HEAD
git ls-remote --heads <push-remote> refs/heads/<branch>
git status --short --branch
```

If the repository already has a pull request for the branch, report its current
URL and status. Do not create, merge, retarget, or mark a pull request ready
unless the user requested that additional action.

## Step 7 — hand off exact evidence

Report:

- local branch and worktree;
- base remote and fetched preview commit;
- remote push target and verified remote commit;
- branch-document path;
- commits created or rewritten;
- checks run and their outcomes;
- conflicts resolved, remaining open items, or external gates.

Do not describe the branch as current, pushed, or ready unless the corresponding
fetch, remote-object comparison, and verification completed successfully.

## Stop conditions

Stop before mutation or publication when:

- the working tree contains changes whose ownership or scope is unclear;
- the remote or preview branch is ambiguous;
- the selected target is protected;
- remote-only commits would be lost;
- conflict resolution requires product or security judgment not present in the
  repository;
- required checks fail;
- the document would disclose secrets, customer data, or machine-local details.

Report the precise blocker and preserve all recoverable state.
