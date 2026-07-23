---
name: worktree-bootstrap
description: "Bring a fresh git worktree to a runnable state — detect the package manager per directory, run the right install, and materialize env vars from their real source instead of copying a .env. Use when a new or existing worktree fails with missing modules, an undefined env var, a wrong Supabase target, or right after creating a worktree with git worktree add or wtp. Covers npm, pnpm, and deno surfaces in one checkout."
---

# Worktree bootstrap

A fresh worktree has source but no `node_modules` and no env. Bootstrapping it
means answering two questions **per directory**: which package manager, and where
does env actually come from.

**Anti-goal — never copy a `.env` between worktrees.** It looks like it works and
then wastes hours: the copied file encodes another worktree's local state (its
Supabase ports, its stale keys, its toggles), and it silently detaches from the
real source of truth. Materialize from source every time. If a value cannot be
materialized, report it as missing — never invent one, never copy one over.

Read [`env-topology`](../env-topology/SKILL.md) for *why* each surface gets its
env from where it does; this skill is the *how*.

## Step 1 — detect per directory, not per repo

One worktree can hold several surfaces with different managers. Resolve each
directory independently.

Worktree trees are also not flat — they are often grouped (e.g. a `codex/`
directory holding several worktrees rather than being one). A directory with no
`package.json` is usually a grouping level, not a broken worktree. Resolve from
the directory you are actually working in and descend to the nearest
`package.json`; do not infer state by listing siblings one level down.

**The rule: `packageManager` in the nearest `package.json` is authoritative.
Lockfiles are a fallback, and a lockfile can lie.**

This is not hypothetical. PUMPD mobile declares `npm@10.9.3` yet also has a
`pnpm-lock.yaml` sitting next to `package-lock.json` — untracked and gitignored
local cruft. Detect by lockfile and you will confidently run `pnpm install` in an
npm project.

```bash
# authoritative
rg -n '"packageManager"' package.json

# if you must fall back to a lockfile, prove it is real first
git ls-files --error-unmatch pnpm-lock.yaml   # tracked?
git check-ignore -v pnpm-lock.yaml            # ignored? then it is cruft
```

A lockfile that is untracked or gitignored is **not** a signal. When the field
and a tracked lockfile genuinely disagree, stop and ask rather than guessing.

## Step 2 — install

| Surface | Directory | Manager | Install |
|---|---|---|---|
| PUMPD mobile | `pumpd-mobile-app/` | `npm@10.9.3` | `npm ci` |
| PUMPD backend | `pumpd-backend/` | `pnpm@10.4.1` | `pnpm install` |
| Edge functions + e2e | `pumpd-backend/supabase/functions/`, `e2e/` | deno | **nothing to install** |

- Prefer `npm ci` / `pnpm install --frozen-lockfile` in a fresh worktree — they
  install exactly the lockfile. Fall back to `npm install` / `pnpm install` only
  when the lockfile is genuinely out of sync, and say so.
- **deno needs no install step.** Dependencies resolve from imports; `deno check`
  populates the cache as a side effect. Do not look for a `node_modules` there.
- **Do not run `patch-package` yourself.** Mobile wires it as `"postinstall"`, so
  the install command already runs it. A separate invocation is redundant.

## Step 3 — materialize env from its real source

Each surface has exactly one correct source:

**Mobile** — pull from EAS, mapping the variant to its environment:

```bash
# from pumpd-mobile-app/
eas env:pull --environment development   # APP_VARIANT=dev
eas env:pull --environment preview       # APP_VARIANT=staging
```

Needs EAS auth. Only `EXPO_PUBLIC_*` values are meaningful to the client bundle.

**Backend** — the local `.env` is a *generated artifact*, not a stored file:

```bash
# from pumpd-backend/ — requires the local Supabase stack to be running
pnpm run init
```

That regenerates `.env` from `supabase status`. Never hand-edit it and never copy
it; re-run `init` instead. If it fails, the stack is almost certainly not up.

> Doppler is **not** the source for the backend's local `.env`. The Doppler
> `pumpd-backend` project holds *remote* configuration. Reaching for
> `doppler run` here produces a file that looks right and points at the wrong
> stack.

**Edge functions** — nothing to materialize. `SUPABASE_URL` and
`SUPABASE_ANON_KEY` are injected at runtime.

## Step 4 — verify, do not assume

```bash
# deps landed
ls node_modules >/dev/null && echo deps ok

# env has the names you expect — NAMES ONLY, never print values
rg -o '^[A-Z_][A-Z0-9_]*' .env | sort

# the real test: does the toolchain agree?
npm run typecheck        # or pnpm typecheck
deno check supabase/functions/**/index.ts   # backend/edge
```

Report what actually happened — which manager ran where, which env source was
used, and anything still missing.

## Known gaps — surface these, do not paper over them

- **`EXPO_PUBLIC_SECURE_STORAGE_KEY`** is consumed in mobile `src` but has no EAS
  or Doppler home. After `eas env:pull` it is still absent. Say so; do not
  fabricate a value or copy one from another worktree.
- A worktree on a branch whose lockfile differs from the one you last installed
  needs a re-install, not a partial patch.
- `wtp`- and `git worktree add`-created worktrees get no bootstrap of their own,
  which is why this runs as an explicit step rather than something automatic.
