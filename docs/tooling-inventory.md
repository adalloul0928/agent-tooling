# Tooling inventory and placement

This document is the canonical map for deciding what tooling exists, who owns
it, where it lives, and how it reaches Claude and Codex. It describes the
desired state as of 2026-07-13. Profiles and `scripts/doctor` turn the locally
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
| `personal` | `obsidian-vault`, `dad-daily-update`, `personal-task`, `personal-task-done`; Life OS: `life-os-setup`, `life-os-capture`, `life-os-daily-plan`, `life-os-day-review`, `life-os-communications`, `life-os-weekly-review`, `life-os-journal`, `life-os-voice`, `life-os-meeting`, `life-os-decision`, `life-os-health-review`, `life-os-relationship-review`, `life-os-strategic-review`, `life-os-chief-of-staff`; bundled local runtime | User/workstation | First-party |
| `developer-workflows` | `thermo-nuclear-code-quality-review`; Doppler-backed `heroui-pro` MCP | User/workstation; reusable across projects | First-party wrapper around the third-party MCP |
| `cyrus-workflows` | `cyrus-setup`, `pumpd-research`, `pumpd-plan`, `pumpd-review`, `pumpd-decompose`, `log-learning`, `pumpd-retro` | PUMPD target; Claude project scope, Codex user install | First-party |
| `pumpd-workflows` | `pumpd-local-cleanup` | PUMPD target; Claude project scope, Codex user install | First-party |
| `wet-in-seattle` | `iawis-weekly-report` | Wet In Seattle target; Claude project scope, Codex user install | First-party |
| `mobile-development` | `ios-session-lanes`; bundled lifecycle/guard hooks and third-party MCPs; separately installed verified command runtime | User/workstation; isolated PUMPD iOS lanes and reusable local mobile tooling | First-party lane runtime plus wrappers around third-party MCPs |
| `pumpd-automations` | `pumpd-sentry-miner`, `pumpd-product-miner`, `pumpd-tool-radar`, `pumpd-ai-tooling-radar`, `pumpd-agent-retro`, `pumpd-appstore-readiness`, `pumpd-docs-freshness`, `pumpd-security-scan`, `pumpd-setup-scout`, `pumpd-haiku-window-starter` | PUMPD target; **user scope** in both clients | First-party |

Installing `mobile-development` registers its skill, hooks, and MCPs. The
`ios-session-*` wrappers are a separate authenticated workstation runtime so
Claude and Codex share stable commands outside a versioned plugin cache. The
base profile installs that runtime and verifies its complete v3 tree and three
wrappers against the current checkout without modifying them.

`pumpd-automations` is user-scoped rather than project-scoped like
`cyrus-workflows` and `pumpd-workflows`: its skills fire unattended from the
scheduler in whatever directory that run uses, so a project-scoped plugin would
not be active. Two dependencies are not satisfied by installing the plugin —
**Linear**, which nearly every automation files Triage suggestions into, is an
account-side connector rather than a local MCP, and **schedules** live in
machine-local `~/.claude/scheduled-tasks/<id>/SKILL.md`. A registered task
carries its own copy of the skill and fires without the plugin; the plugin is
what makes the automations invocable interactively. See
[new-machine-setup.md](new-machine-setup.md).

The `wet-in-seattle` wrapper and reporting skill are first-party. The bundled
`analytics-mcp` executable is Google's third-party server, launched locally
through the third-party Doppler CLI; neither dependency is copied into this
repository.

The `mobile-development` wrapper packages the third-party iOS Simulator,
HeroUI Native, and HeroUI Native Pro MCP connections without copying their
source. The licensed Pro token is read from Doppler at runtime.

The `developer-workflows` wrapper packages the third-party HeroUI Pro React MCP.
It reads the same licensed Pro token from Doppler at runtime, so neither Claude
Code nor Codex needs a raw token in local MCP configuration.

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

### Vendor skills installed with the `skills` CLI

`expo/skills` (MIT, <https://github.com/expo/skills>) is **installed, not
mirrored**. A deliberate 9-skill subset of the 23 it ships is tracked as `path`
checks in `base-workstation`, each carrying its own
`npx skills@1.5.18 add expo/skills -g -y --agent claude-code --skill <name>`
recipe:

`eas-app-stores`, `eas-workflows`, `expo-dev-client`, `expo-examples`,
`expo-module`, `expo-project-structure`, `expo-router`, `expo-tailwind-setup`,
`expo-upgrade`.

Subset size is deliberate: every installed skill's description is loaded for
trigger matching, so unused skills are a standing context cost. Two skills the
July discovery had listed were dropped at install time — `eas-simulator` (its own
guidance tells macOS users with local simulators not to auto-trigger it, and
`ios-simulator-mcp` covers that need) and `eas-observe` (paid EAS APM that
overlaps the Sentry MCP). `expo-project-structure` and `expo-dev-client` were
added in their place.

Installed for **both clients** as of 2026-07-23. Claude gets the full set via
`--agent claude-code`; Codex gets 38 of them via `--agent codex`, which installs
to **`~/.agents/skills/<name>/SKILL.md`** — *not* `~/.codex/skills/`. Two are
excluded from Codex on content grounds rather than collision:
`web-artifacts-builder` (specific to claude.ai artifacts) and `brand-guidelines`
(applies Anthropic's brand). Nothing about these skills is client-specific — they
are portable `SKILL.md` files, and which client has them is purely a function of
the `--agent` flag used at install time. Two CLI details worth remembering: `skills add` defaults to *project*
scope, so `-g` is required for a user-level install, and `--skill` accepts one
skill per flag (repeat the flag to batch). Skills land at
`~/.claude/skills/<name>/SKILL.md`.

Four further collections were adopted 2026-07-23 on the same terms — installed,
never mirrored, tracked as `path` checks with per-skill recipes in
`base-workstation`. **Everything each collection ships is installed except where
a skill name collides** with something already registered:

| Source | License | Installed | Excluded |
| --- | --- | --- | --- |
| `software-mansion-labs/skills` | MIT — **stated in the README only; no LICENSE file**, which is why license APIs report none | all 8 | — |
| `callstackincubator/agent-skills` | MIT (LICENSE file) | 9 of 10 | `react-native-best-practices` |
| `supabase/agent-skills` | MIT (LICENSE file) | both | — |
| `anthropics/skills` | **Unstated** — no LICENSE file and no README license section, only `THIRD_PARTY_NOTICES.md`. Recorded as observed rather than assumed | 12 of 18 | `docx`, `pdf`, `pptx`, `xlsx`, `skill-creator`, `claude-api` |

Both exclusions are **name collisions, not judgments about usefulness**:

- `react-native-best-practices` ships in **both** Software Mansion's and
  Callstack's collections under the same directory name, and `skills add` has no
  rename option — installing both silently overwrites one. Software Mansion's
  wins because it covers Reanimated 4, Gesture Handler, `react-native-svg`, and
  worklets bundle mode, the libraries PUMPD actually depends on. The cost is
  Callstack's performance material (FPS, TTI, bundle size, Hermes, FlashList),
  which is not installed anywhere; re-evaluate if performance work becomes a
  focus.
- The six `anthropics/skills` entries are already registered by the installed
  `anthropic-skills` and `skill-creator` plugins. Installing file copies would
  register a second skill of the same name and make triggering ambiguous.

No `.agents` adapter is hand-authored for any of these. `skills add` takes an
`--agent` flag, so Codex support is an install-time argument rather than mirrored
files — which also keeps the no-redistribution rule intact.

## PUMPD project instructions and config

**PUMPD no longer carries its own skills.** They were added in #939/#941 and
**removed in #959 (`chore(agent): remove project skills`)**; `origin/main` and
`origin/preview` both carry zero. Every profile check asserting them has been
deleted — the model where PUMPD ships project-scoped skills is over. Capability
that PUMPD needs from an agent now comes from this repo's plugins or from vendor
collections, not from files in the app repo.

What PUMPD **does** still own, and what the profile still asserts (all verified
present on `origin/main`): `AGENTS.md` as the shared canonical instruction layer
with `CLAUDE.md` as the Claude entry point, `.codex/config.toml` and
`.codex/hooks.json`, and `.mcp.json` supplying `supabase_local`. Claude-only path
rules may remain under `.claude/rules`.

> **Verification warning, learned the hard way.** Two rounds of conclusions about
> this section were wrong because they were drawn from a local checkout **999
> commits behind `origin/main`** — first "these skills are committed" (they had
> been deleted), then "the `.agents` layout was never adopted" (it was adopted,
> then removed, and `AGENTS.md`/`.codex/` were never removed at all). **Check
> project claims against a freshly fetched `origin/<branch>`, never a working
> tree**, and re-run `git fetch` before reading `git ls-tree origin/...` — a stale
> remote ref reports the old world with total confidence.

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
| User raw MCPs | Authenticated remote `supabase`, `sentry` (project-scoped `avad-technologies-llc/pumpd`), and `expo` — all hosted, browser-OAuth, registered at **user** scope with `install` recipes in `base-workstation`. `expo` is OAuth-only with no PAT/CI fallback | Figma, Node REPL, authenticated remote `sentry`, and disabled Computer Use runtime entry |
| Developer Workflows plugin | Doppler-backed `heroui-pro` | Doppler-backed `heroui-pro` |
| Wet In Seattle plugin | Doppler-backed `analytics-mcp` | Doppler-backed `analytics-mcp` |
| Mobile Development plugin | `ios-simulator-mcp`, `heroui-native`, Doppler-backed `heroui-native-pro` | Same three plugin-provided MCPs |
| Other plugin-provided | Context7, Linear, and Playwright MCPs; Supabase skills paired with the user MCP | Curated/runtime equivalents such as Linear, GitHub, Sentry, Supabase, Expo, Vercel, and XcodeBuildMCP |
| PUMPD project | `.mcp.json`: `supabase_local` | `.codex/config.toml`: `context7`, `playwright` |
| Other intentional local capabilities | Supplied by the applicable plugin or local config | Figma, GitHub, Node REPL, Xcode tooling, and Sites design tooling where needed |

**Codex takes hosted vendor MCPs from the curated catalog, never as raw MCPs.**
`sentry`, `expo`, `linear`, `supabase`, and `github` are supplied by
`@openai-curated` plugins; the `codex.duplicate-*-mcp` checks assert the raw
equivalents stay **absent** so the two cannot both be enabled. This resolved the
long-standing curated-vs-raw question on 2026-07-23 by observation — the curated
plugins were already installed and enabled, and no raw twins existed.

Project definitions may intentionally specialize or override user defaults.
Avoid defining the same server twice at user scope and through a plugin. In
particular, raw definitions for Analytics, HeroUI, or iOS Simulator are not
part of the desired state once their owned plugin replacement is installed and
verified. `developer-workflows:heroui-pro` and
`mobile-development:heroui-native-pro` are the managed HeroUI Pro connections.

No MCP secret belongs in this repository. The `wet-in-seattle`,
`developer-workflows`, and `mobile-development` plugins commit only Doppler
project/config identifiers and environment-variable allowlists. The Doppler CLI
fetches values when an MCP starts. Local Doppler login, service tokens, Google
ADC files, HeroUI Pro tokens, and other credential material remain outside Git.

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
