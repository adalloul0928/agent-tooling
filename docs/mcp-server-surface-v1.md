# MCP server surface v1

Status: implemented.

## Purpose

`AgentToolingMCP` is the MCP server a local coding agent talks to. It exposes
two tiers only: tools that read persisted state, and tools that append one
bounded row to the app's review queue and return a deep link. It can put a
request in front of a person; it cannot answer for them. Everything that would
apply, approve, execute, or disclose a secret is excluded by construction.

## The model

`ToolTier` (`ToolCatalog.swift`) has exactly two cases: `readOnly` (reads
persisted state, writes nothing, spawns nothing) and `queuesReview` (appends one
bounded review row and returns a deep link, changing no client configuration and
building no operation plan). `ToolDefinition` carries a name, tier, title,
description, and input schema; its `descriptor` sets `readOnlyHint` from the
tier and sets `destructiveHint` false and `idempotentHint` true for every tool.

`ToolCatalog.tools` is `readOnlyTools + reviewQueueTools`:

- Read-only (eight): `search_inventory`, `get_component`, `get_client_status`,
  `get_effective_settings`, `list_receipts`, `get_receipt`,
  `list_pending_requests`, `get_request_status`, `open_review_screen` (which
  only builds and validates an `agent-tooling://` link).
- Review-queue (five): `request_add_mcp_server`, `request_create_skill`,
  `request_install_skill`, `request_install_plugin`, `request_remove_component`.
  Each takes exactly one component; none accepts a list, because a bulk form
  would let one injected instruction become many rows.

`UntrustedClientIdentity` (`UntrustedClientIdentity.swift`) is the caller's
self-reported `clientInfo` from `initialize`: display text only, never verified,
never branched on.

## Behaviour

A read-only tool returns persisted state. `get_client_status` reports the
observations the app saved during its last setup check; it starts no scan and
runs no command. A queue tool appends one row and returns a request id and a
link; the plan is composed in-app, from the app's own state, when the person
opens that link. A request stays `pending-review` until a person decides; the
server is never told of an approval and reports none. A repeat collapses into
the existing row. `request_add_mcp_server` validates the endpoint with the same
`MCPDefinitionValidator` the app uses, which refuses an inline API key or token
so a secret never lands in the queue unread.

## Safety boundary

`ExcludedCapabilities.swift` is the security model as assertions:

- No `apply`, `approve`, `deny`, `confirm`, or `execute` tool, and none that
  records an approval, because the recording would be made by the caller rather
  than the person. Consent lives only in the app's review sheet.
- No tool builds an `OperationPlan`; tier-two tools append a request row.
- No `--home` or `--workspace` override and no parameter that relocates the
  workspace or home; the server resolves the one real workspace and accepts no
  argv beyond `--help`/`--version` (`permittedArguments`).
- No `run_command`, `exec`, shell, or file-write tool; this target spawns no
  subprocess.
- No tool returns a secret value; reference names only.
- No tool edits the allowlist, redaction, or this server's registration.
- The elicitation capability is not declared.

`forbiddenToolNameFragments` and `forbiddenParameterNameFragments` fence these
by name (`home` and `workspace` as parameters are the path-confinement bypass).
Every response passes through `ResponseRedaction` before leaving the process, so
a home directory or secret cannot reach an agent transcript even if a field were
selected by mistake.

## What the UI shows

The server has no screen of its own. Its deep links open the Apps review surface
and other screens in the app; queued requests appear there for a person to
review. The in-app MCP test console exercises it.

## Tests

- `ToolCatalogExclusionTests.swift` — walks the whole catalog against
  `ExcludedCapabilities`, so a tool or parameter that reintroduces an exclusion
  fails the build.
- `ReadOnlyDisclosureTests.swift` — read tools never return secrets or paths.
- `ReviewQueueTests.swift` — one row per call, collapse on repeat, endpoint
  refusal.
- `ProtocolTests.swift`, `InventoryAnswerTests.swift` — handshake and answers.

## Not covered

The server reports the app's last persisted scan rather than scanning live. It
targets Codex, Claude Code, and Gemini CLI in its request `targets`. The
request-to-apply handoff is the app's reviewed path, which this doc does not
cover.
