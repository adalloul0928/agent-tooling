# Tooling inventory and placement

This document is the canonical map for deciding what tooling exists, who owns
it, where it lives, and how it reaches Claude and Codex. It describes the
desired state as of 2026-07-17. Profiles and `scripts/doctor` turn the locally
observable parts of this model into checks; hosted account state and live
authentication still require manual verification.

## The operating model

Treat a capability as five separate layers:

1. **Source**: the repository or vendor that owns the implementation.
2. **Catalog**: the marketplace or directory that advertises it.
3. **Installation**: the client and scope where it is enabled.
4. **Authentication**: the local client, environment, or hosted account that
   holds permission to use an external service.
5. **Project configuration**: committed instructions, skills, and MCP
   declarations required for reliable work in a particular repository.

Publishing a plugin does not install it. Installing a plugin does not
authenticate its MCP. Authenticating a local MCP does not authenticate a
hosted connector, and none of those operations prove that cloud sessions have
the same capability.

The strategy is therefore **one owned source where content is portable, with
thin native adapters and explicit placement by surface**. It is capability
parity, not configuration identity: Claude and Codex can use the same authored
skill core, but they retain separate catalogs, plugin manifests, settings, MCP
configuration, and account state.

## Surface map

| Surface | Receives owned plugins | Receives project files | Uses hosted connectors | Authentication home |
| --- | --- | --- | --- | --- |
| Claude Code CLI | Claude marketplace install | Local checkout | Optional unless disabled | Local Claude config, OAuth, and environment |
| Claude Desktop Code | Same local Claude Code installation state | Local checkout | Optional unless disabled | Same local Claude Code state |
| Claude Code cloud | Only what the remote checkout and supported cloud settings expose | Committed revision | Claude.ai connectors may be available | Cloud/project environment plus Claude account |
| Claude.ai chat | Personal marketplace/account skills where supported | No implicit local checkout | Yes | Claude account |
| Codex CLI | Codex marketplace install | Local checkout | No implicit ChatGPT app sync | Local Codex config, OAuth, and environment |
| Codex desktop | Same Codex host installation state | Local checkout | Account apps are a separate layer | Local Codex state for MCPs; account state for apps |
| Codex cloud | Only committed and supported remote configuration | Committed revision | Supported account integrations are separate | Cloud environment plus account state |
| ChatGPT | Account/workspace plugins and apps | No implicit local checkout | Yes | OpenAI account/workspace |

Claude Desktop's general chat MCP configuration is separate from the Claude
Code runtime embedded in the desktop app. Do not assume adding an MCP to one
adds it to the other.

## Catalogs and marketplaces

### Local Claude Code

- `claude-plugins-official`: Anthropic-maintained plugins.
- `callstack-agent-skills`: third-party React Native capabilities when needed.
- `agent-tooling`: the private catalog from this repository.

Anthropic's official catalog is built in. Add third-party or private catalogs
once, then install and update their plugins through Claude Code. Do not mirror
official or third-party plugin source into this repository.

### Local Codex

- `openai-primary-runtime`: OpenAI runtime artifact capabilities.
- `openai-bundled`: built-in Codex capabilities.
- `openai-curated`: curated vendor plugins.
- `agent-tooling`: the private catalog from this repository.

OpenAI's catalogs are provided by Codex. Add the private `agent-tooling`
catalog once. Vendor packages remain vendor-managed even when an owned skill
has a related workflow.

### Hosted accounts

Claude.ai's official directory and personal marketplace are account-side.
ChatGPT's plugin/app directory and personal or workspace installations are
also account-side. Neither store is a dependable mirror of local Claude Code
or Codex configuration. Use the same repository as a supported publishing
source when possible, but verify refresh, installation, and authentication on
each hosted surface separately.

Enabled Claude.ai account skills may also be exposed to Claude Code cloud. Do
not use that implicit path as the source of truth for coding workflows and do
not assume a chat skill is isolated from cloud coding sessions. Keep required
Code skills in Git-backed plugins or the project repository. Add a skill to the
Claude.ai account only when its possible presence in Claude Code cloud is
acceptable; otherwise keep the capability on a more isolated hosted connector
or local Code path.

## Owned plugins in `agent-tooling`

Installing one of these plugins installs all of its bundled skills; individual
skill installation is not required.

| Plugin | Skills | Intended scope | Ownership |
| --- | --- | --- | --- |
| `personal` | `obsidian-vault`, `dad-daily-update`, `personal-task`, `personal-task-done` | User/workstation | First-party |
| `developer-workflows` | `thermo-nuclear-code-quality-review` | User/workstation; reusable across projects | First-party |
| `cyrus-workflows` | `cyrus-setup`, `pumpd-research`, `pumpd-plan`, `pumpd-review`, `pumpd-decompose`, `log-learning`, `pumpd-retro` | PUMPD target; Claude project scope, Codex user install | First-party |
| `pumpd-workflows` | `pumpd-local-cleanup` | PUMPD target; Claude project scope, Codex user install | First-party |
| `wet-in-seattle` | `iawis-weekly-report` | Wet In Seattle target; Claude project scope, Codex user install | First-party |
| `mobile-development` | None; MCP-only | User/workstation; reusable local mobile tooling | First-party wrapper around third-party MCPs |

The `wet-in-seattle` wrapper and reporting skill are first-party. The bundled
`analytics-mcp` executable is Google's third-party server, launched locally
through the third-party Doppler CLI; neither dependency is copied into this
repository.

The `mobile-development` wrapper packages the third-party iOS Simulator,
HeroUI Native, and HeroUI Native Pro MCP connections without copying their
source. The licensed Pro token is read from Doppler at runtime.

The intentionally small catalog omits generic research, Git, PR, worktree,
documentation-sync, and tooling-recommendation skills. Those capabilities are
deferred until repeated use justifies a custom workflow; vendor or native
equivalents should be preferred in the meantime. `developer-workflows` contains
the deliberately retained thermo-nuclear review because it is a custom,
cross-project workflow with repeated use. Git history retains other removed
implementations without publishing a misleading `deferred` bundle.

Every owned plugin has one physical skill core under `plugins/<plugin>/skills`
and separate Claude and Codex manifests. Keep shared workflow logic portable;
put client-specific declarations in the native adapters.

As of Codex CLI 0.145.0-alpha.18, plugin installation and enablement are
user-scoped. Fresh-process canaries confirmed that plugin declarations in a
project `.codex/config.toml` do not activate those plugins. Profiles therefore
record the intended project audience for Codex, but do not claim native project
plugin isolation. Project-critical Codex behavior must remain in committed
project skills/MCPs, or the user plugin must stay enabled globally until Codex
adds a supported project scope.

## Current workstation cheat sheet

This is the verified local snapshot as of 2026-07-17. It is intentionally
grouped by source and scope: a plugin may contribute many skills or MCPs, and a
project-scoped Claude plugin appears inactive when Claude is opened outside its
matching checkout. Claude.ai and ChatGPT account apps/connectors are separate
hosted inventories and are not counted here.

### Claude Code

| Type | Source/scope | Current items |
| --- | --- | --- |
| Owned plugins | `agent-tooling`, user | `personal`, `developer-workflows`, `mobile-development` |
| Owned plugins | `agent-tooling`, project | `cyrus-workflows`, `pumpd-workflows`, `wet-in-seattle` |
| Official plugin | Anthropic, user | `skill-creator` |
| Official plugin records | Anthropic, matching PUMPD/IAWIS checkout or worktree | `code-review`, `code-simplifier`, `context7`, `frontend-design`, `linear`, `playwright`, `security-guidance`, `sentry`, `shopify-ai-toolkit`, `supabase` |
| Third-party plugin | Callstack, project | `react-native-best-practices` |
| Base MCPs | User/plugin | `supabase`, `ios-simulator-mcp`, `heroui-native`, `heroui-native-pro` |
| PUMPD MCPs | Plugin/project | `context7`, `linear`, `playwright`, `sentry`, `supabase_local` |
| IAWIS MCPs | Plugin/project | `analytics-mcp`, `shadcn` |

Claude first-party skills are the 14 skills listed in the owned-plugin table
above. PUMPD adds the nine committed project skills listed below. There are no
active standalone skills under `~/.claude/skills`; owned skills arrive through
plugins. Current vendor skill suites are:

- `skill-creator`: 1 skill;
- `frontend-design`: 1 skill;
- `supabase`: 2 skills;
- `sentry`: 10 skills;
- Callstack `react-native-best-practices`: 14 skills;
- `shopify-ai-toolkit`: 20 skills in its IAWIS worktree record.

### Codex

| Type | Source/scope | Current items |
| --- | --- | --- |
| Owned plugins | `agent-tooling`, user-wide | `personal`, `developer-workflows`, `mobile-development`, `pumpd-workflows`, `cyrus-workflows`, `wet-in-seattle` |
| Runtime/bundled plugins | OpenAI-managed | `documents`, `pdf`, `spreadsheets`, `presentations`, `template-creator`, `sites`, `browser`, `chrome`, `visualize` |
| Curated plugins | OpenAI-managed | `linear`, `vercel`, `github`, `sentry`, `build-ios-apps`, `expo`, `supabase` |
| Owned MCPs | Plugin-provided, user-wide | `analytics-mcp`, `ios-simulator-mcp`, `heroui-native`, `heroui-native-pro` |
| Runtime/vendor MCPs | Bundled or curated | `node_repl`, `sites-design-picker`, `xcodebuildmcp`, `github`, `linear` |
| Direct user MCPs | Local config | `figma`, retained legacy `heroui-pro`, disabled `computer-use` |
| PUMPD MCPs | Committed project config | `context7`, `playwright` |
| Standalone authored skills | `~/.codex/skills` | `chronicle`, `figma` |

Codex also receives the same 14 first-party skills from `agent-tooling` and the
nine PUMPD project skills from the checkout. OpenAI runtime and curated plugins
currently contribute these skill suites:

- artifact/runtime: `documents`, `pdf`, `spreadsheets`, `presentations`,
  `template-creator`, `sites`, `browser`, `chrome`, and `visualize`;
- service workflows: `linear`, `github`, `sentry`, and `supabase`;
- larger vendor suites: `build-ios-apps` (9 skills), `expo` (13 skills), and
  `vercel` (47 skills).

The HTML Atlas expands every current vendor/runtime skill name while keeping
the large suites collapsed by default. In current Codex, `analytics-mcp` and
the PUMPD/IAWIS-targeted owned skills are globally visible because installed
plugins are user-scoped; committed project skills and MCPs remain the reliable
project boundary.

## Role of Microsoft APM

APM is an optional management layer, not the distribution source or a universal
installer. Its useful ideas are a declarative dependency manifest, lockfile,
auditable resolution, and repeatable bootstrap. It cannot eliminate the native
Claude/Codex catalogs, synchronize hosted account stores, or complete OAuth on
the user's behalf.

The current policy is therefore a partial adoption:

- native Claude and Codex manifests remain authoritative;
- profiles and `scripts/doctor` provide the desired-state and audit layer;
- APM can be reconsidered if its lockfile and bootstrap benefits exceed the
  cost of a third abstraction;
- no workflow should depend on APM until it passes the compatibility spike and
  preserves both native install paths.

See [apm-spike.md](apm-spike.md) for the detailed evaluation.

## Vendor plugins

Vendor capabilities should be installed from their official or maintained
catalogs. `agent-tooling` may record their desired presence in a profile, but
does not redistribute them or attempt to install them as transitive
dependencies. Native plugin marketplaces do not provide a reliable,
cross-client dependency mechanism for silently installing another publisher's
plugins.

### Claude target

Generally useful or user-scoped plugins:

- `skill-creator`, when skill authoring is active;
- `sentry`, only when its cross-project availability justifies its global
  skill metadata.

Project-specific or on-demand plugins:

- `code-review`, `code-simplifier`, `context7`, `frontend-design`, `linear`,
  `playwright`, `security-guidance`, and `supabase`;
- `upgrading-react-native`, enabled for an upgrade and removed or disabled
  afterward.

### Codex target

OpenAI runtime and bundled capabilities:

- `documents`, `pdf`, `spreadsheets`, `presentations`, `template-creator`;
- `sites`, `browser`, `chrome`, `visualize`.

Curated vendor capabilities:

- `linear`, `github`, `sentry`, `supabase`, `expo`, `vercel`,
  `build-ios-apps`.

These lists are the intended inventory, not a claim that every item is enabled
or authenticated on every machine. Profiles should require only the stable
subset that is genuinely expected.

## PUMPD project-owned skills

Skills required to work correctly in PUMPD live in the PUMPD repository, not
in this user-tooling repository. Their canonical copies are under
`.agents/skills`; Claude receives relative adapters under `.claude/skills`.
That write-once arrangement is repository-local and committed, so local and
cloud agents can receive the same project contract.

Current project skills:

- `backend-review`
- `fix-review`
- `pumpd-architecture`
- `pumpd-ios-simulator`
- `pumpd-supabase-patterns`
- `pumpd-testing`
- `pumpd-ui-patterns`
- `quality`
- `sync-types`

The following former candidates are intentionally excluded from the desired
state:

- `test-runner`
- `generate-unit-tests`
- `generate-e2e-tests`
- `react-native-debugger`
- `pumpd-figma-implement`

Project instructions follow the same ownership rule: `AGENTS.md` is the shared
canonical instruction layer and `CLAUDE.md` is the Claude entry point. Claude-
only path rules may remain under `.claude/rules`.

## Special local skills

The active standalone Codex skill directory intentionally contains only:

- `figma`, paired with the authenticated Figma MCP;
- `chronicle`, which depends on machine-specific history and permissions.

Former standalone HeroUI, discovery, review, Git, and project workflow skills
are archived for rollback and are not part of the active inventory. Licensed
HeroUI credentials remain machine-local; the active HeroUI Native Pro MCP reads
its token from Doppler rather than publishing licensed skill content.

## MCP placement

MCP definitions should be placed at the narrowest scope that needs them. A
plugin-provided MCP is preferable to a duplicate raw definition when the
plugin owns the full integration.

| Scope | Claude | Codex |
| --- | --- | --- |
| User raw MCPs | Authenticated remote `supabase` | Figma, HeroUI Pro, Node REPL, and disabled Computer Use runtime entry |
| Wet In Seattle plugin | Doppler-backed `analytics-mcp` | Doppler-backed `analytics-mcp` |
| Mobile Development plugin | `ios-simulator-mcp`, `heroui-native`, Doppler-backed `heroui-native-pro` | Same three plugin-provided MCPs |
| Other plugin-provided | Context7, Linear, Playwright, and Sentry MCPs; Supabase skills paired with the user MCP | Curated/runtime equivalents such as Linear, GitHub, Sentry, Supabase, Expo, Vercel, and XcodeBuildMCP |
| PUMPD project | `.mcp.json`: `supabase_local` | `.codex/config.toml`: `context7`, `playwright` |
| Other intentional local capabilities | Supplied by the applicable plugin or local config | Figma, GitHub, Node REPL, Xcode tooling, and Sites design tooling where needed |

Project definitions may intentionally specialize or override user defaults.
Avoid defining the same server twice at user scope and through a plugin. In
particular, raw definitions for Analytics, HeroUI, or iOS Simulator are not
part of the desired state once their owned plugin replacement is installed and
verified. The current Codex `heroui-pro` remote entry is a deliberate legacy
exception retained by user choice; the Doppler-backed
`mobile-development:heroui-native-pro` MCP is the managed replacement.

No MCP secret belongs in this repository. The `wet-in-seattle` and
`mobile-development` plugins commit only Doppler project/config identifiers
and environment-variable allowlists. The Doppler CLI fetches values when an
MCP starts. Local Doppler login, service tokens, Google ADC files, HeroUI Pro
tokens, and other credential material remain outside Git.

## Hosted connectors and apps

Hosted connectors are intentionally outside Git. Claude chat-oriented
connectors may include Gmail, Google Drive, TickTick, Canva, Raindrop, Linear,
Supabase, Sentry, GitHub, and Obsidian. Developer services can have two
deliberate representations:

- a hosted connector for Claude.ai chat;
- a local plugin or MCP twin for Claude Code.

The same principle applies to ChatGPT account apps and local Codex plugins or
MCPs. Install only the hosted apps that improve the hosted experience; do not
try to mirror every local development tool into chat.

`disableClaudeAiConnectors` is enabled at user scope after validating the local
Linear, Supabase, mobile-development, and project paths. This enforces the
intended separation: hosted connectors for chat and deliberate local
plugins/MCPs for Claude Code.

## Authentication

Authentication is performed after installation and on the surface that will
use the capability:

- For an OAuth MCP in Claude Code, use the MCP management flow in Claude Code
  (for example `/mcp` or the supported login command).
- For an OAuth MCP in Codex, use Codex desktop's MCP server settings and
  **Authenticate**, or the supported Codex MCP login command.
- For API keys or bearer tokens, configure the expected environment variable
  or approved secret manager. A browser OAuth flow does not replace an API-key
  requirement.
- For Claude.ai connectors and ChatGPT apps, authenticate in the corresponding
  hosted account or workspace.
- For cloud coding sessions, configure the supported project/cloud environment
  independently of local desktop credentials.

Successful authentication on one product is not evidence for another. The
doctor can confirm that a declaration exists, but live health and account
permissions remain manual checks.

## Adding or changing a capability

Use this decision sequence:

1. **Who owns it?** Use the official vendor catalog for vendor tooling. Use
   `agent-tooling` only for workflows we author and can redistribute.
2. **Who needs it?** Put application-critical behavior in the application
   repository. Put broadly reusable personal behavior in `agent-tooling`.
3. **Which surfaces need it?** Add Claude and Codex native adapters only for
   supported clients. Treat hosted accounts as separate destinations.
4. **Does it need an MCP?** Prefer the plugin-provided server. Otherwise place
   a raw definition at project scope when project-specific, or user scope when
   genuinely universal.
5. **How is it authenticated?** Document the authentication class and expected
   environment variable names without storing credentials.
6. **How is it verified?** Add structural validation, desired-state profile
   checks, and a manual behavior or cloud canary as appropriate.
7. **What is the rollback?** Record the previous known-good commit and retain a
   standalone copy until both native clients pass normal-use canaries.

## Installation and update workflow

For an `agent-tooling` release:

1. Merge the source change to `main` after `./scripts/validate` passes.
2. Refresh the `agent-tooling` catalog in Claude and Codex; both track `main`.
3. Install or update `personal`, `developer-workflows`, `cyrus-workflows`,
   `pumpd-workflows`, `wet-in-seattle`, and `mobile-development` in the clients
   required by their profiles.
4. Start fresh client sessions and run behavioral canaries.
5. Authenticate new MCPs separately on each required local or hosted surface.
6. Verify Claude Code cloud, Codex cloud, Claude.ai, and ChatGPT account state
   separately when the capability is expected there.
7. Remove a retained standalone copy only after the replacement has passed.

The private catalog only has to be registered once per local client. A new
plugin in an already registered catalog still requires an explicit install;
existing installed plugins require an update or catalog refresh. Official
Anthropic and OpenAI catalogs do not need to be re-added.

See [release-runbook.md](release-runbook.md) for the release gate and
[profiles-and-doctor.md](profiles-and-doctor.md) for desired-state inspection.
