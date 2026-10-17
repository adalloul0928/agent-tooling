# Account surfaces v1

Status: implemented and fixture-tested. Not verified against a live
subscription sign-in: the Mac it was built on signs both clients in through
Amazon Bedrock, so only the "not signed in with the subscription" path has run
against real clients. The response shapes come from Claude Code 2.1.300 (its
own binary) and Codex 0.162.1 (`codex app-server`), and every settings key the
app writes is quoted from the vendor's reference.

## What this covers

Two hosted accounts reach this Mac's clients:

- the **claude.ai** account brings connectors, skills and plugins to Claude
  Code in the terminal and to the Claude desktop app;
- the **ChatGPT** account brings apps (connectors) to Codex, including the Codex
  mode inside the ChatGPT desktop app.

The account is where those are added, connected and removed. Agent Tooling:

1. reads what each account gives each client on this Mac and shows it under
   **Apps › Accounts**, read-only;
2. records the person's choices about the local switches once, in the portable
   document, and makes each Mac follow them through a reviewed plan;
3. reports sign-in problems and mismatches between Macs in Checkup and on Home;
4. keeps what the account downloads out of everything that treats files on
   disk as this Mac's own tools.

It never adds, removes, connects or signs in to anything on an account. Those
buttons open the vendor's page.

## Model

| Record | Where it lives | Travels to other Macs |
|---|---|---|
| `AccountObservation`: sign-in, items, switch values, notes | this Mac's memory, read live | no |
| `AccountPreferences`: the person's choices | portable document, schema 6 | yes, merged |
| `AccountPreferencePlan`: what this Mac must change to follow them | recomputed on this Mac | no |
| `PublishedAccountSummary`: method, plan, fingerprint, counts | `status/<deviceID>.json` | yes, read-only to others |

What the account holds is never copied into the portable document. The account
syncs itself, so each Mac reads its own copy, and the portable contract
excludes scan and runtime data.

## Reading

`AccountSurfaceProbe.live` reads both providers. It has two depths:
`signInOnly`, which Checkup uses, and `contents`, which the Accounts tab uses.
A read that finds another one in flight waits for it, so the tab's first visit
still reads contents after Checkup's light read.

### Claude Code

Every command runs the client's own executable and is admitted by
`OperationCommandPolicy`. Runs are bounded at 90 seconds.

| Command | Depth | What it gives |
|---|---|---|
| `claude --version` | both | the version |
| `claude auth status --json` | both | `loggedIn`, `authMethod`, `apiProvider`, `configDirectory`; for a claude.ai sign-in also `email`, `orgId`, `orgName`, `subscriptionType`; for an API key `apiKeySource` |
| `claude plugin list --json` | contents | rows with `scope "synced"` and `id "<name>@synced"`: `version`, `enabled`, `installPath`, `mcpServers`, `errors`, `notes` |
| `claude mcp list` | contents | connector lines `claude.ai <Name>: <url> - <status>`, with ` (n)` appended on a name collision |

`claude mcp list` connects to each server to report its status. Files read:

- `~/.claude/settings.json`, the user settings file this app edits;
- `/Library/Application Support/ClaudeCode/managed-settings.json`, the policy;
- `~/.claude/skills/synced/`, where Claude Code downloads the account's skills.

| `authMethod` | Shown as |
|---|---|
| `claude.ai` | the subscription, with its plan and organization |
| `oauth_token`, `api_key`, `api_key_helper` | a token, an API key (with its source), a key helper |
| `third_party` | the provider, for example Amazon Bedrock |
| `none`, or `loggedIn` false | signed out |

Only a `claude.ai` sign-in reaches the account. Account skills and plugins
sync to the terminal from Claude Code 2.1.273.

| `claude mcp list` status | Shown as |
|---|---|
| `✔ Connected` | Connected |
| `! Needs authentication` | Needs sign-in on claude.ai |
| `✘ Failed to connect`, `✘ Connection error` | Failed to connect |
| `⏸ Pending approval…` | Waiting for approval |
| `⊘ Disabled for this project…` | Off for one project |
| `- Not configured` | Not connected on claude.ai |
| named by a `deniedMcpServers` entry | Off in Claude Code |

A synced plugin is "Loads in Claude Code" when it has an install path and is
enabled, "Off in Claude Code" when `enabled` is false, "Did not load" when it
reports errors, and "Not loaded" when its install path is empty. The last
covers a copy another plugin shadows; see [Publishing](#publishing-this-repositorys-plugins-to-claudeai).

### Codex

The reader starts `codex app-server` and speaks newline-delimited JSON-RPC over
its standard input and output. Answers carry no `jsonrpc` field, the server
sends notifications between answers, and it exits when its input closes, so
the input stays open until the last answer arrives. Each request times out
after 30 seconds, and a timeout closes the session.

`CodexAppServerSession` sends only these methods; anything else fails before a
byte is written:

| Request | Parameters | When |
|---|---|---|
| `initialize` | `clientInfo {name: "agent_tooling", title: "Agent Tooling", version}` | always |
| `initialized` (notification) | none | always |
| `account/read` | `refreshToken: false` | always |
| `config/read` | `includeLayers: true` | always |
| `app/list` | `cursor`, `limit: 100`, `forceRefetch: false`, up to 10 pages | contents, ChatGPT sign-in only |
| `app/installed` | `forceRefresh: false` | contents, ChatGPT sign-in only |

`account.type` `chatgpt` is the subscription, `apiKey` an API key, and
`amazonBedrock` or any other type a third-party provider. No account with
`requiresOpenaiAuth` true is signed out. Only apps marked `isAccessible` become
items; the rest are counted as the directory. Configuration changes never go
through app-server: `config/value/write` and `config/batchWrite` are refused by
the session, and edits go through the reviewed path below.

`plugin/list` is not called, because Codex documents it as "under
development; don't call from production clients yet". ChatGPT remote plugins
are therefore not shown.

### Shell overrides

A variable in the login shell can replace a client's sign-in when it runs in a
terminal. `AccountShellEnvironmentProbe` runs one fixed script with
`/bin/zsh -l -i -c`, bounded at 20 seconds, and reads back the **names** of the
variables that are set. It never reads a value.

| Variable | Account | Effect |
|---|---|---|
| `ANTHROPIC_API_KEY`, `ANTHROPIC_AUTH_TOKEN`, `CLAUDE_CODE_OAUTH_TOKEN`, `ANTHROPIC_PROFILE` | claude.ai | replaces the subscription sign-in |
| `CLAUDE_CODE_USE_BEDROCK`, `CLAUDE_CODE_USE_VERTEX`, `CLAUDE_CODE_USE_FOUNDRY` | claude.ai | sends requests to another provider |
| `CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC` | claude.ai | stops account skill and plugin sync, even when set to `0` or `false` |
| `ENABLE_CLAUDEAI_MCP_SERVERS`, only when `false` or `0` | claude.ai | turns account connectors off |
| `CLAUDE_CONFIG_DIR` | claude.ai | moves the settings folder this app edits |
| `CODEX_HOME` | ChatGPT | moves the configuration folder this app edits |
| `CODEX_ACCESS_TOKEN` | ChatGPT | replaces the ChatGPT sign-in |

## Shared choices

### The switches

Each choice names a switch and, for some, one item. A choice not recorded
means "each Mac decides". The values are On and Off, except approval mode.

| Choice | Item | File | Off writes | On writes | Unset means |
|---|---|---|---|---|---|
| Account skills in Claude Code | none | `~/.claude/settings.json` | `syncClaudeAiSkills: false` | removes the key | on |
| Account plugins in Claude Code | none | same | `syncClaudeAiPlugins: false` | removes the key | on |
| Account connectors in Claude Code | none | same | `disableClaudeAiConnectors: true` | removes the key | on |
| One account plugin | plugin name | same | `enabledPlugins["<name>@synced"]: false` | `enabledPlugins["<name>@synced"]: true` | on |
| One account connector | connector name | same | adds `{"serverName": "claude.ai <Name>"}` to `deniedMcpServers` | removes that entry | on |
| ChatGPT apps in Codex | none | `~/.codex/config.toml` | `[features] apps = false` | `[features] apps = true` | on |
| One app | app ID | same | `[apps.<id>] enabled = false` | `enabled = true` | on |
| Destructive app tools | app ID or every app | same | `destructive_enabled = false` | `destructive_enabled = true` | not documented |
| Open-world app tools | app ID or every app | same | `open_world_enabled = false` | `open_world_enabled = true` | not documented |
| Approval mode for app tools | app ID or every app | same | `default_tools_approval_mode = "auto" \| "prompt" \| "writes" \| "approve"` | | not documented |

Turning account skills off has a side effect Claude Code documents: at its next
start it moves the skills it already synced to `~/.claude/skills/.trash/` and
stops loading them. The scan and Checkup skip hidden folders, so that folder is
not reported.

"Every app" writes to `[apps._default]`. Turning an account-wide Claude switch
back on removes the key only if this file set it; `true` and unset mean the
same, so nothing else needs writing. A connector is turned off through
`deniedMcpServers` rather than `disabledMcpServers` because the denylist lives
in user settings and covers every project, while `disabledMcpServers` is kept
per project in `~/.claude.json`. Where the reference gives no default, the
planner writes the chosen value explicitly.

The Claude desktop app's Code tab gets account connectors in-process and does
not read these settings. Only claude.ai controls connectors there.

### In the portable document

Schema 6 adds `accountPreferences`. It is required at schema 6 and above and
forbidden below. It holds at most 512 entries, one per switch, sorted by
provider (Claude first), then setting, then item. Validation refuses:

- an item where the switch has none, or none where it needs one;
- a value the switch does not take;
- a plugin name that contains `@` or that the command policy would refuse;
- a connector name with a quote, a backslash, a control character or
  surrounding spaces, or longer than 200 characters;
- an app ID that is not a bare TOML key (ASCII letters, digits, `_`, `-`, up to
  128 characters), or `_default`.

Each switch has one object ID, a UUIDv8 from SHA-256 in the domain
`agent-tooling.account-preference-key.v1` over the provider, the setting and the
item (with its presence, so "no item" and an empty name differ). Merge conflicts
are keyed by it.

The field is left out of the digest when absent, so an older document's digest
is unchanged. New workspaces start at schema 6. An existing schema-5 workspace
stays at 5 until its first account choice is saved, and that save raises it to
6 in the same revision.

**Compatibility:** a build older than this change cannot read schema 6. Update
the app on every Mac before anyone saves an account choice.

`SetAccountPreferencesCommand(expectedRevisionID, idempotencyKey, changes)` is
the only writer. A change with no value lets the choice go. Its input digest
domain is `agent-tooling.set-account-preferences.v1`; repeating a command is
answered from its receipt. An empty or invalid command writes nothing and does
not raise the schema.

### Merging

Choices merge per switch:

| Base | This Mac | Other Mac | Result |
|---|---|---|---|
| any | changed | unchanged | this Mac's |
| any | changed | changed the same way | that value |
| any | changed | changed differently | conflict; this Mac's kept meanwhile |
| set | removed | unchanged | removed |
| set | removed | changed | conflict |

A conflict is `accountPreference`, titled "Two different account choices"
under Settings › Sync, and is settled by choosing a side. A schema-5 revision
merges with a schema-6 one into schema 6.

## Following the choices on a Mac

`AccountPreferencePlanner.plan(preferences:observation:configurationText:)`
compares each choice for the provider with the value the client uses now: the
read value, else the documented default. A choice this Mac already follows
needs nothing. Otherwise the planner either proposes edits or holds the choice
with a reason. It holds when:

- the client could not be read;
- the client reads its settings from another folder (`configDirectory` for
  Claude Code, the user layer of `config/read` for Codex), so editing the usual
  file would change nothing;
- managed settings or the runtime decide the switch;
- the choice turns something back on that another settings file turned off;
- the Codex file already defines the key in a form the line editor would
  duplicate: a dotted key elsewhere, an inline table, an array of tables, a
  header spelling the editor does not match, a quoted key, or a value spanning
  lines;
- the editor refuses the edit, or the file cannot be parsed;
- the edit would leave the file unchanged.

The edits are rehearsed in order against the file's current text, so the plan
on screen is what the engine will write.

Applying is a reviewed plan. The review sheet lists each edit. **Apply** plans
again against the file as it is now and refuses if the edits differ from the
ones reviewed. The plan is an `OperationPlan` of kind `configureMCP` with one
`editClientConfiguration` step per edit. Each step copies the file into the
workspace trash, writes the new text atomically, and checks that the file did
not change in between. The app then reads that account again and rescans. Open
sessions pick up the change after a restart.

"Share this Mac's settings" records the switches this Mac's own file sets as
choices for every Mac, for setting up the first Mac by hand.

## Other Macs

`PublishedDeviceStatus.accounts` carries one `PublishedAccountSummary` per
account this Mac could read: the sign-in method, the plan name, a fingerprint,
item counts per kind (only after a contents read), how many choices are not
followed, and the names of shell overrides. It carries no address,
organization name or item list. The status file's `formatVersion` stays 1;
older readers ignore the field.

The fingerprint is a SHA-256 over the workspace ID, the provider, the
trimmed and lowercased email and the organization ID. It exists only for a
subscription sign-in with an email, and it is only ever compared for equality.

## Checkup and Home

| Finding | Severity | Raised when | Row |
|---|---|---|---|
| `accountSignIn` | medium | the client is not signed in with the subscription | opens Accounts |
| `accountShellOverride` | medium if it replaces the sign-in, else low | once per variable | opens Accounts |
| `accountChoicesNotFollowed` | low | the plan has changes or holds | **Apply** when there are changes, else opens Accounts |
| `accountConnectorNeedsSignIn` | low | a contents read found a connector needing attention | opens Accounts |
| `accountDiffersFromOtherMacs` | high | another Mac's fingerprint for the account differs | opens Accounts |

Checkup reads sign-in only, once, and reuses a reading the tab already has. An
account whose client this Mac does not manage, or that could not be read, has
no finding. Home shows a line when a finding is medium or higher, or when
choices are not followed.

## What the account owns on disk

Claude Code downloads the account's skills to `~/.claude/skills/synced/`
(namespace `anthropic-skills`) and its plugins to `~/.claude/plugins/synced/`,
listed as `<name>@synced`. Plugin origins `synced`, `inline` and `skills-dir`
are reserved. Account plugins are not scoped to a project: they load in every
project Claude Code opens with that sign-in.

The app treats these as the account's:

- the scan leaves them out of the inventory;
- Checkup does not report the synced folder as an empty skill folder;
- the engine refuses to move anything inside it;
- no skill is placed under a reserved name;
- no `claude plugin install`, `uninstall` or `update` is built for a reserved
  origin;
- the Library lists them in an account strip, and the plugin detail disables
  Assign and Remove for an `@synced` row.

## Where it shows

- **Apps › Accounts**: one card per account with its sign-in, banners for
  overrides, another settings folder and choices not followed, an "On every
  Mac" card with the switches, and lists of connectors, skills, plugins and
  apps. Each item row has a choice menu and a link to the vendor's page.
  **Check accounts** reads again.
- **Library**: Skills, Plugins and Connections each show what the accounts add.
- **Checkup** and **Home**: the findings above.

## Publishing this repository's plugins to claude.ai

1. On claude.ai or in the Claude desktop app, open **Customize › Plugins ›
   Add › Add marketplace** and enter this repository. A private GitHub
   repository needs your GitHub account connected and the Claude GitHub App
   given access to it.
2. Turn on **Sync automatically** for the marketplace, so each merge to `main`
   reaches the account.
3. Add only the user-scoped plugins: `personal`, `developer-workflows`,
   `mobile-development` and `pumpd-automations`. Leave `cyrus-workflows`,
   `pumpd-workflows` and `wet-in-seattle` off the account; they are assigned to
   projects, and an account plugin loads in every project.
4. Claude Code downloads each one as `<name>@synced` at its next session start;
   `/reload-plugins` loads it into a running session.

Codex keeps its local marketplace install. In Claude Code, a local plugin with
the same name takes precedence: Claude Code 2.1.300 reports `"<name>" from
claude.ai not loaded — "<local>" on this machine has the same name and takes
precedence`, and suggests running `claude plugin enable <name>@synced` and then
disabling or removing the local copy to use the account's. Keeping both is
harmless: Claude Code runs the local copy, and the account's copy serves chat,
Cowork and the desktop app. The Accounts tab's publishing card lists which of
the library's `agent-tooling` plugins the account carries.

## Not covered

- No reading has been checked against a live subscription sign-in.
- Only `managed-settings.json` is read. The MDM domain
  `com.anthropic.claudecode`, `managed-settings.d/` and server-managed settings
  are not, so a switch they decide is planned and then held with "another
  settings layer decides it".
- A plugin an organization requires is not recognised as such; a choice to
  turn it off is held the same way after the first apply.
- Not read: per-tool app settings (`apps.<id>.tools.*`),
  `approvals_reviewer`, `app/read`, the Claude desktop app's in-process
  connectors, and ChatGPT remote plugins.
- The shell probe runs an interactive login shell, so a profile that waits for
  input costs the 20-second bound.

## Tests

- `AccountSurfaceParsingTests.swift`: every Claude and Codex answer shape,
  connector lines and the shell probe.
- `AccountReaderTests.swift`: the app-server session's allowlist, handshake,
  timeouts and redaction, and both readers against scripted clients.
- `AccountPreferencesDocumentTests.swift`: validation, schema 6 gating,
  digests, the command through a real store, merging, conflict resolution and
  the published summary.
- `AccountPreferencePlannerTests.swift`: every switch, each hold, the Codex
  shapes, object-list edits, and applying through `OperationExecutor`.
- `AccountSafetyAndAuditTests.swift`: the reserved names across scan, audit,
  engine, placement and commands, and every finding.
- `WorkspaceAccountsSessionTests.swift`: the app session, Checkup rows,
  overlapping reads, and the rendered screen.
