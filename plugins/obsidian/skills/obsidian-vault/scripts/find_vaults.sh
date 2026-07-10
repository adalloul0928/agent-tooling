#!/usr/bin/env bash
set -euo pipefail

ROOT="${1:-$HOME}"

find "$ROOT" -maxdepth 5 -type d -name .obsidian -prune 2>/dev/null |
  sed 's#/.obsidian$##' |
  while IFS= read -r vault; do
    printf '%s\n' "$vault"
    if git -C "$vault" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
      branch="$(git -C "$vault" symbolic-ref --quiet --short HEAD 2>/dev/null || git -C "$vault" rev-parse --short HEAD 2>/dev/null || printf 'unknown')"
      change_count="$(git -C "$vault" status --porcelain=v1 2>/dev/null | awk 'END {print NR + 0}')"
      remotes="$(git -C "$vault" remote 2>/dev/null | awk 'BEGIN {first = 1} {printf "%s%s", first ? "" : ",", $0; first = 0} END {if (first) printf "none"}')"
      printf '  branch: %s\n' "$branch"
      printf '  working tree changes: %s\n' "$change_count"
      printf '  remotes: %s\n' "$remotes"
    else
      printf '  not a git repo\n'
    fi
  done
