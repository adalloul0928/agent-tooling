#!/bin/zsh
# Launches Agent Tooling against a disposable testbed: a scratch HOME and a
# scratch workspace, so nothing it reads, writes, plans, or installs can touch
# this Mac's real client configuration or real Agent Tooling library.
#
# The app already supports this isolation natively:
#   --home      every config read, skill write, and scan happens under here,
#               and every client CLI the app launches gets HOME=<testbed home>
#   --workspace the SQLite store and managed library live under here
#
# The `claude` inside the testbed is the REAL Claude Code binary behind a
# shim, but because the app rewrites HOME for children, it reads and writes
# the testbed's .claude — never ~/.claude.
#
# Usage: scripts/testbed.sh [--fresh]
set -euo pipefail

TESTBED="${TMPDIR:-/tmp}/agent-tooling-testbed"
HOME_DIR="$TESTBED/home"
WORKSPACE_DIR="$TESTBED/workspace"
APP="$(cd "$(dirname "$0")/.." && pwd)/.build/Agent Tooling.app"

if [[ "${1:-}" == "--fresh" ]]; then rm -rf "$TESTBED"; fi
mkdir -p "$HOME_DIR/.local/bin" "$WORKSPACE_DIR"

# Real Claude Code, testbed-homed. The shim just execs the real binary; the
# app's child environment already scopes HOME, and CLAUDE_CONFIG_DIR makes the
# isolation explicit even if this shim is ever run by hand.
REAL_CLAUDE="$(command -v claude || true)"
if [[ -n "$REAL_CLAUDE" && ! -e "$HOME_DIR/.local/bin/claude" ]]; then
  cat > "$HOME_DIR/.local/bin/claude" <<SHIM
#!/bin/zsh
export CLAUDE_CONFIG_DIR="$HOME_DIR/.claude"
exec "$REAL_CLAUDE" "\$@"
SHIM
  chmod +x "$HOME_DIR/.local/bin/claude"
fi

# A believable, harmless Claude Code setup: two skills and an MCP server.
mkdir -p "$HOME_DIR/.claude/skills/testbed-hello" "$HOME_DIR/.claude/skills/testbed-notes"
cat > "$HOME_DIR/.claude/skills/testbed-hello/SKILL.md" <<'EOF'
---
name: testbed-hello
description: A harmless testbed skill for exercising Agent Tooling end to end.
---
# Testbed Hello
Say hello. That is all.
EOF
cat > "$HOME_DIR/.claude/skills/testbed-notes/SKILL.md" <<'EOF'
---
name: testbed-notes
description: A second testbed skill so lists, groups, and filters have company.
---
# Testbed Notes
Take a note. Put it down. Done.
EOF
cat > "$HOME_DIR/.claude/settings.json" <<'EOF'
{ "mcpServers": { "testbed-echo": { "command": "/bin/echo", "args": ["mcp"] } } }
EOF

# A minimal Kiro presence too, so the multi-client paths light up.
mkdir -p "$HOME_DIR/.kiro/skills/testbed-hello" "$HOME_DIR/.kiro/settings"
cp "$HOME_DIR/.claude/skills/testbed-hello/SKILL.md" "$HOME_DIR/.kiro/skills/testbed-hello/SKILL.md"
echo '{ "mcpServers": {} }' > "$HOME_DIR/.kiro/settings/mcp.json"

echo "Testbed home:      $HOME_DIR"
echo "Testbed workspace: $WORKSPACE_DIR"
echo "Real ~/.claude, ~/.codex, ~/.kiro and your real library are not touched."
# Launched directly rather than through `open -n`: argument passing is exact,
# and startup output lands in a log you can read when something refuses.
"$APP/Contents/MacOS/AgentTooling" \
  --home "$HOME_DIR" --workspace "$WORKSPACE_DIR" \
  > "$TESTBED/run.log" 2>&1 &
echo "Launched (log: $TESTBED/run.log)"
