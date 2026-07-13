# Compatibility matrix

This matrix records the minimum client builds exercised by the current release
gate. Newer builds still require a canary when they change plugin, skill, MCP,
hook, or marketplace behavior.

| Surface | Minimum tested version | Required gate |
|---|---:|---|
| Claude Code CLI | 2.1.207 | `claude plugin validate`, isolated marketplace add/install |
| Claude Desktop Code | Same bundled Code generation as CLI | normal-use Obsidian canary |
| Codex CLI | 0.144.0-alpha.4 | isolated marketplace add/install |
| Codex Desktop | Bundled Codex CLI generation above | normal-use Obsidian canary |
| Agent Skills spec | `skills-ref` package 0.1.1 | `agentskills validate` |
| Microsoft APM | 0.25.0 | informational spike only; not a release dependency |

Hosted Claude and ChatGPT surfaces do not share a meaningful local client
version. Record their verification date and installed marketplace revision in
the account checklist once hosted canaries begin.
