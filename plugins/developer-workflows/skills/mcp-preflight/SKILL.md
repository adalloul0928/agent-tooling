---
name: mcp-preflight
description: "Triage MCP servers that are configured but not usable, and emit the exact command to fix each one. Use at the start of a session, when an MCP tool is unexpectedly missing, when a server reports needing authentication or fails to start, after adding a server, or before relying on a connector in a scheduled or headless run. Distinguishes needs-authentication from pending-approval from a broken launch wrapper, because the fixes are unrelated."
---

# MCP preflight

A server being *configured* does not mean it is *usable*. This skill turns a
listing into a per-server verdict and the exact command that fixes it.

Start here:

```bash
claude mcp list
```

That health-checks each approved server. Read the trailing state on each line —
**do not key off the exit code.** It reports `0` when everything is healthy, and
the unhealthy case is not reliably signalled there. There is also **no `--json`**
flag; parse the text.

## The three states, and why they are not interchangeable

| State | What it means | Fix |
|---|---|---|
| `✔ Connected` | Healthy and health-checked. | none |
| `! Needs authentication` | Registered, but OAuth was never completed or has lapsed. | `claude mcp login <name>` |
| `⏸ Pending approval` | A project-scoped `.mcp.json` server you have not approved. **Claude does not connect to it at all.** | Approve it when prompted; `claude mcp reset-project-choices` to redo earlier choices in this project |

The last two look alike in a listing and have nothing to do with each other — one
is an **auth** problem, the other a **trust** problem. Running `login` against a
pending-approval server does not help.

## Fixing authentication

```bash
claude mcp login <name>                # HTTP, SSE, and claude.ai connectors
claude mcp login <name> --no-browser   # SSH/headless: prints the URL to paste back
claude mcp logout <name>               # clear stored OAuth, then log in again
```

- Reach for `logout` then `login` when a server *claims* to be authenticated but
  behaves as if it is not — that is the stale-credential shape.
- `/mcp` in an interactive session does the same thing through the UI.
- OAuth needs a human. In a scheduled or non-interactive run you cannot complete
  it — report the exact command and stop rather than looping.

## Check the launch wrapper before blaming the MCP

Several servers here are stdio processes launched **through the Doppler CLI**
(`heroui-pro`, `heroui-native-pro`, `analytics-mcp`). When one of those fails to
start, the MCP is usually fine and Doppler is the cause — a missing CLI, an
expired login, or a secret absent from the referenced project/config, which
`--no-fallback` turns into a hard failure by design.

Check that first, and note it needs no MCP changes at all:

```bash
doppler me            # identity and scope — no secrets
```

See [`doppler-cli-skill`](../doppler-cli-skill/SKILL.md) for names-only queries
that confirm the referenced secret actually exists. Never print secret values
while debugging.

## What the listing cannot tell you

- **Account/claude.ai connectors may not appear**, even though `claude mcp login`
  can authenticate them. A clean listing is therefore *not* proof that every tool
  you expect is available — check the account's connector settings when a tool is
  missing but absent from the listing entirely.
- **Plugin-provided servers are prefixed** — `plugin:<plugin>:<server>`. Their
  fix is usually at the plugin level (installed? enabled?), not the server level.
- **A healthy listing is a point-in-time check.** OAuth lapses later; re-run
  before depending on a connector for unattended work.

## Codex — unverified

The Codex CLI is not installed on this machine, so its MCP auth-state output and
reconnect commands could not be observed. **Do not assert Codex commands from
memory.** Inspect `codex mcp --help` (or the current Codex docs) on a machine
that has it, confirm the real state vocabulary, then record it here. Until then,
treat this skill as Claude-verified only and say so rather than guessing.

## Reporting

Give a per-server verdict, grouped by state, with the exact command beside each
one — not a narrative. Call out which fixes need a human (OAuth, approval
prompts) and which you can run. If everything is `✔ Connected`, say so plainly
instead of manufacturing work.
