#!/usr/bin/env bash
set -euo pipefail

marketplace_name="agent-tooling"
plugin_name="developer-workflows@agent-tooling"
result=0

refresh_codex() {
  if ! command -v codex >/dev/null 2>&1; then
    printf 'Codex: not installed or not on PATH; skipped.\n' >&2
    result=1
    return
  fi

  if codex plugin marketplace upgrade "$marketplace_name"; then
    printf 'Codex: marketplace refreshed. Start a fresh task to use updated skills.\n'
  else
    printf 'Codex: marketplace refresh failed.\n' >&2
    result=1
  fi
}

refresh_claude() {
  if ! command -v claude >/dev/null 2>&1; then
    printf 'Claude Code: not installed or not on PATH; skipped.\n' >&2
    result=1
    return
  fi

  if claude plugin marketplace update "$marketplace_name" \
    && claude plugin update "$plugin_name" --scope user; then
    printf 'Claude Code: marketplace and plugin refreshed. Run /reload-plugins in the active session.\n'
  else
    printf 'Claude Code: marketplace or plugin refresh failed.\n' >&2
    result=1
  fi
}

refresh_codex
refresh_claude

exit "$result"
