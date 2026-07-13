#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 1 ]]; then
  printf 'usage: %s /path/to/vault\n' "$0" >&2
  exit 64
fi

VAULT="$1"

if [[ ! -d "$VAULT/.obsidian" ]]; then
  printf 'not an Obsidian vault: %s\n' "$VAULT" >&2
  exit 65
fi

if ! git -C "$VAULT" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  printf 'not a Git repo: %s\n' "$VAULT" >&2
  exit 66
fi

printf 'vault: %s\n\n' "$VAULT"
git -C "$VAULT" status --short --branch

GIT_DIR="$(git -C "$VAULT" rev-parse --absolute-git-dir)"
for marker in MERGE_HEAD rebase-merge rebase-apply CHERRY_PICK_HEAD REVERT_HEAD; do
  if [[ -e "$GIT_DIR/$marker" ]]; then
    printf '\nwarning: Git operation in progress: %s\n' "$marker"
  fi
done

printf '\ntracked plugin/local data files to review before sharing:\n'
git -C "$VAULT" ls-files \
  '.obsidian/plugins/*/data.json' \
  '.obsidian/todoist-token' \
  '.smart-env/**' |
  sed 's/^/  /' || true

printf '\nignored local REST API data:\n'
git -C "$VAULT" check-ignore -v '.obsidian/plugins/obsidian-local-rest-api/data.json' || true
