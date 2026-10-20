# Compatibility

Agent Tooling requires macOS 26 or later. The public release target is Apple
Silicon. Install each client separately; the app checks available executables
and supported operations before preparing an install.

The versions below identify interfaces used during development. They are not
a guarantee that every feature works on every newer client build.

| Client or interface | Recorded version | Coverage |
|---|---|---|
| Claude Code CLI | 2.1.207 | Plugin validation and isolated marketplace add/install |
| Codex CLI | 0.144.0-alpha.4 | Isolated marketplace add/install |
| Claude Code account reader | 2.1.300; account skill and plugin sync needs 2.1.273 | `auth status --json`, `plugin list --json`, and `mcp list` fixtures |
| Codex account reader | 0.162.1 (`codex app-server`) | Account/configuration/app response fixtures |
| Agent Skills validation | `skills-ref` 0.1.1 | `agentskills validate` |

Gemini CLI and Kiro CLI adapters have fixture coverage for their supported
skill and MCP formats. No minimum live-tested version is recorded here.
Unsupported operations remain available for manual review.

Hosted accounts have separate installation and authentication state. The account
readers have not been verified against live claude.ai or ChatGPT subscription
sign-in. See [account surfaces](account-surfaces-v1.md) for their exact scope.

Recheck native commands and configuration schemas when a client changes its
plugin, skill, MCP, hook, or marketplace behavior.
