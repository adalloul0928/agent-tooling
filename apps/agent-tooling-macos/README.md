# Agent Tooling for macOS

Native SwiftUI control center for local Agent Skills, MCP servers, plugins,
desired-state profiles, connectors, marketplace sources, and operation
receipts. The interface uses real behind-window Liquid Glass with native SF
Symbols and macOS materials rather than an opaque dashboard theme.

## Install

The release workflow publishes signed alpha builds as versioned DMGs on the
repository's [Releases page](https://github.com/adalloul0928/agent-tooling/releases).
After the first release is available, download the newest
`Agent-Tooling-*-arm64.dmg`, open it, and drag **Agent Tooling** into
**Applications**. The destination Mac does not need Xcode, Swift, or a local
clone of this repository.

Because the repository is currently private, the downloader must have GitHub
access to it. See [the release runbook](../../docs/macos-app-release.md) for the
signing, notarization, and publishing setup.

## Local-first architecture

The app's source of truth is a SQLite workspace plus a managed portable package
library at `~/Library/Application Support/Agent Tooling/`. A Git repository is
optional: it can be imported as a catalog source or prepared as a local backup,
but no GitHub account, remote, commit, or push is needed to create or install a
skill.

- **Claude Code:** user/project/local MCP plans use Claude's native CLI.
- **Codex:** user MCP plans use `codex mcp add`; project-scoped MCP placement is
  deliberately shown as a manual review because the current CLI exposes no
  scope selector.
- **Gemini CLI:** a created skill is packaged as a valid `gemini-extension.json`
  extension and live-linked with `gemini extensions link`; Gemini owns its
  extension directory and loads the change in a new CLI session.
- **Kiro CLI:** skills are standard SKILL.md folders under `~/.kiro/skills`,
  and MCP servers are managed through verified `kiro-cli mcp add`/`remove`
  commands; Amazon Toolbox's `~/.toolbox/bin` is one of the fixed install
  roots the locator checks.
- **Marketplace:** local folders, checked-out Git repositories, and Agent
  Plugins packages are inspected locally. The official MCP Registry is queried
  through its documented API. Claude and Codex listings are read from their
  respective machine-readable native catalog commands. Gemini's gallery
  remains a native source rather than an undocumented scraped API. Adding an
  MCP Registry server to the library goes through the same reviewed intake as
  pasting one by hand: Discover builds the connection from the listing's
  reviewed transport, records one connection, and starts or contacts nothing.
- **Connections:** the app records ownership, expected surfaces, and optional
  secret *reference names* only. OAuth tokens, API keys, and cloud connectors
  remain in their owning client, account, keychain, provider, or admin system.

Every client-affecting operation is first presented as a plan. The operation
engine has a fixed executable allowlist, restricts file writes to managed or
supported locations, moves replaced files to a rollback area, redacts receipts,
and records partial per-target outcomes.

## What the Library holds

The Library is a record of tools, not a mirror of any one app. The first run
writes down what a scan of this Mac found; after that, **Check apps** (and the
automatic check on open, when it is on) compares what it finds with what the
Library holds and adds the difference under the first run's own rules: a
package a client installed is that client's, its skills belong to it, and
everything else is only tracked. Rows already in the Library are never changed
by a check, and nothing is removed because a scan did not see it this time —
taking something out is a choice a person makes. When a check adds anything,
the Apps screen says how much.

`1 mine · 33 unclassified` counts ownership, not installation. *Mine* is a
skill whose source lives in this library; *tracked* is one the app knows about
and can find, but whose files belong to the app or folder that has them. Both
are installed wherever their row's marks say they were found.

## Set up your existing tools

Home shows a **Set up your library** card while a new workspace holds discovered
tools that have not been assigned anywhere yet. The card opens the Skills
screen, where the setup wizard runs. Skipping it never deletes tools, and it
reappears from Home until you assign something.

The wizard has three steps, **Found → Apps → Assign**:

- **Found** shows what the first run already discovered on this Mac and placed
  in your library. Nothing has been installed or assigned; this step is a
  read-only summary of what is there.
- **Apps** chooses which local clients this Mac keeps in sync. This only sets
  Agent Tooling's client visibility preference; what is already installed in
  each app does not change.
- **Assign** records where you want a tool. Choosing tools here writes down the
  intent only — putting a tool into an app stays a separate, reviewed step on
  the Apps screen. You can finish without assigning anything.

Skill metadata supports standard YAML, including multiline descriptions and
quoted names. Managed copies use the name declared in `SKILL.md`, even when the
source folder has a different name; source files are preserved.

**Make personal copy** is a separate opt-in for a standalone skill that you
want to maintain independently. Bundled skills stay with their plugin. Assigning
a skill records where you want it and never requests a personal copy on its own;
only an explicit copy uses the operation-plan sheet before anything is written.

### Repository-linked skills and native plugin updates

In a standalone skill's details (or its setup row menu), choose **Link
repository** to record its public HTTPS GitHub repository, branch/tag/commit,
and skill subdirectory. An unknown source remains unknown until linked.
Linking records the existing files without moving, editing, or adopting them.
**Check for updates** fetches into an isolated temporary Git cache, compares
the skill bytes, and reports what was checked. **Review update** prepares a
fingerprinted plan for the existing installations. Local edits, changed
installation locations, unsupported links/nested reference folders, and
incomplete content reviews block replacement. A completed update keeps the
repository relationship and native availability settings. Stop following
removes only the relationship; it does not uninstall the skill.
Adding a linked skill to another supported client also keeps the new
installation on that repository's reviewed update path. Shared folders are
updated once, with every affected client named in the plan.

Public GitHub sources are supported in this version; private-repository
authentication and automatic background updates are not configured by setup.
Claude plugins with a confirmed user scope can be updated through a reviewed
native `claude plugin update` operation. Codex and unsupported native scopes
show client-owned update guidance; the app does not emulate updating by
reinstalling or extracting their skills.

This is local setup capture and reviewed source management. Claude Desktop-only
configuration is not yet fully inventoried. Hook/agent editors and broader
configuration management are documented as follow-up work in the
[feature roadmap](../../docs/onboarding-feature-roadmap.md).

## Choose clients

Open **Clients → Choose Clients…** or **Settings → General → Clients you use**
and check the clients you want Agent Tooling to manage. Unchecking a client
immediately removes it from navigation, inventory badges, account checks,
marketplace routes, project configuration, search, and operation destinations.
Setup, marketplace, history, and drift scans skip unchecked clients. You can
uncheck every client and continue using the local library.

This is a preference for this Mac. Existing workspaces start with all clients
selected. Selection survives relaunch and is not imported from another Mac's
backup. Unchecking does not uninstall a client, delete its configuration, or
remove saved desired state; checking it again restores its saved state. Run
Check Clients to refresh its current installation. Historical records involving
unchecked clients are hidden, while their original receipts remain on disk.
Client selection is locked while an operation is running or awaiting review.

## Apps, health, and why an install waits

The Apps screen states each managed client's health from its last check. A
client is only healthy when its command-line tool both answered and reported a
version: that pair is what tells an install the client will accept what it is
given. A client whose command ran but did not report a version shows **Found,
version unknown**, because it has not confirmed what it accepts — a tool asked
for in that client waits rather than installing until the client answers with a
version. A client whose files are present but whose command-line tool is missing
shows **Command unavailable**.

The launch-time check is a preference. **Settings → General → Check health
automatically** decides whether this Mac's apps are checked when Agent Tooling
opens; with it off, health is refreshed only when you run **Check apps**. The
manual button is unaffected by the setting.

## Projects and project folders

A project can be given a folder on this Mac from the Projects screen with
**Choose folder…**. Until it has one, a project-scoped install has nowhere to
write, so it waits: the plan names the project and points you at the Projects
screen to choose a folder rather than failing silently. Choosing a folder never
moves or rewrites what is already in it.

## Presets

The Presets tab manages named sets of library items. **New preset…** creates one
from items already in your library; each preset can be renamed and deleted from
its row menu. Deleting a preset leaves its items in the library. A preset can
also arrive with a workspace — restored from a backup, synced from another Mac,
or shared with you.

## Activity

The Activity screen is this Mac's journal. It lists the operation receipts a
real install, update, or removal wrote, alongside the drift the app has
recorded, reading the same receipts and journal the rest of the app writes.

## Create a skill with Claude Code or Codex

**New skill…** (⌘N) asks how the skill should be written: **Create with
Claude Code**, **Create with Codex**, or **Write it yourself**. The first two
open a conversation inside the app; the third opens the form.

The creator is a conversation, not a one-shot generator. The exchange is on the
left and the draft folder's files are on the right, re-read after every turn.
The assistant may ask a few questions before it writes anything, and you can
ask for changes after each draft. Each turn runs one fixed command through your
signed-in local client — `claude -p --session-id … / --resume …` or
`codex exec --json … / codex exec resume …` — with the prompt on standard input.
Both commands are checked against the operation policy's allowlist before they
launch; the assistant may write only inside a private staging folder; and
nothing reaches the library until you press **Save**, which runs the same
"choose where it is used" step every other new skill goes through. Closing the
sheet puts the staging folder away. The conversation is kept beside the draft,
so a sheet closed mid-exchange reopens where it stopped.

The assistants are offered only for clients this Mac manages. Each uses its
own skill creator: Claude Code's `skill-creator@claude-plugins-official`
plugin, or the skill creator Codex ships as a system skill. If the chosen
client does not have it, the sheet offers to install it first with the
client's own command (`claude plugin install skill-creator@claude-plugins-official`,
preceded by `claude plugin marketplace add anthropics/claude-plugins-official`
only when Claude Code does not know that marketplace yet), and records a
receipt like any other install. Codex's creator cannot be installed
separately; a Codex too old to have it is reported as such.

Neither assistant is given an API key by this app. Claude Code uses whatever
sign-in `claude` already has, and Codex uses the account `codex login status`
reports; Codex's own configuration is kept so the person's provider and
credentials apply. What is left out is everything that would act beyond the
folder: project rules, plugins, hooks, apps, MCP servers, Bash, and the web.

Requirements, per client:

```sh
claude plugin list | grep skill-creator
codex login status
test -f "${CODEX_HOME:-$HOME/.codex}/skills/.system/skill-creator/SKILL.md"
```

The app validates the canonical Agent Plugins package after every turn, shows
every generated file, and requires each file to be opened before the package
can be saved. A request queued by the CLI helper or the MCP server
(`--provider claude|codex`, or the `assistant` argument) names the assistant
and opens the same creator on the `agent-tooling://skills/create/<id>` route.

## Try a skill in its app

Each row under **Apps** in a skill's details has a **Try…** button where the
last check found the skill. It opens Terminal.app with that client running
interactively and the skill invoked as the first message — `claude /name`
(`/plugin:name` for a plugin's skill), `codex $name`, or
`kiro-cli chat /name` — so you can watch what the skill does and keep talking
to the client afterwards. Gemini CLI is not offered: this app has no verified
way to call a skill there by name.

The launch is a `.command` file written under the workspace's own cache. It
runs the tool the app located (the same one every other command uses), through
your login shell so your profile applies, from your home directory. The
argument list is checked against the operation policy before the file is
written, and every value in the script is quoted. Nothing in the library or in
any client changes.

## Raycast shortcuts

The companion extension lives at
[`integrations/raycast/agent-tooling`](../../integrations/raycast/agent-tooling).
It can search the local inventory, queue a skill request, check setup,
open Sync, and focus the app. It finds the signed CLI helper inside
`Agent Tooling.app/Contents/Helpers/agent-tooling`; no separate shell setup is
needed for a packaged build.

Until the extension is published in the Raycast Store, import it locally:

```sh
cd integrations/raycast/agent-tooling
npm ci
npx ray login
npx ray profile
npm run dev
```

Set `author` in the extension's `package.json` to the handle returned by
`ray profile`, then assign the five command hotkeys in Raycast Settings. Skill
instructions travel over stdin and the extension can only open review screens;
all installation and sync mutations remain in the desktop app.

## Backup and restore

`Prepare backup` makes a local Git-initialized export containing portable
packages, desired state, and a source lock. It intentionally does not add a
remote. `Inspect backup` compares skills, profiles, and sources before a
restore; conflicting desired state must be explicitly accepted, and the prior
managed library is retained as a rollback artifact.

`Encrypted folder sync` is the separate multi-device option. It writes one
AES-GCM encrypted `agent-tooling.encrypted.json` file to a folder the user
chooses (for example iCloud Drive, a private cloud folder, or a NAS). The
32-byte key lives in the macOS Keychain; the user can copy/import its Base64
recovery key through the UI for a second Mac. The archive contains portable
desired state and managed package files only—never OAuth tokens, client caches,
operation receipts, or observed machine state.

Organizations can also distribute a reviewed local `agent-tooling-policy/v1`
JSON manifest through that folder or a checkout. It is data only: the app can
import managed profiles, required component lists, and named blocked plugins;
it will not execute policy-provided scripts or fetch a policy in the background.

## Development requirements

- macOS 26 or newer
- Xcode 27 or newer
- Swift 6.2 or newer

## Build and open the app

The packaging script compiles the executable and wraps it in a normal macOS
application bundle using the optimized release configuration. Its default output is ignored under
`.build/Agent Tooling.app`.

```sh
./scripts/package-app.sh
open '.build/Agent Tooling.app'
```

Pass a destination as the first argument when you want the bundle elsewhere:

```sh
./scripts/package-app.sh '/Applications/Agent Tooling.app'
```

Set `AGENT_TOOLING_CONFIGURATION=debug` when packaging for debugging.

## Verify

```sh
swift test --disable-sandbox
```

The opt-in inventory benchmark uses an isolated synthetic workspace with 500
skills, 100 plugins, and 100 MCP servers. Run it alone, with no concurrent builds
or tests, and compare the same configuration and machine:

```sh
AGENT_TOOLING_BENCHMARK=1 AGENT_TOOLING_BENCHMARK_LABEL=release \
  swift test --disable-sandbox --configuration release --filter WorkspacePerformanceTests
```

It reports first-run and warm median timings for snapshot validation, encoding,
persistence, model loading, and screen rendering. Metrics named `settle60`
include a fixed 60 ms run-loop window and are not response latency; synchronous
layout and bitmap drawing are reported separately. The fixture does not measure
network activity, real client scans, or filesystem-backed connector discovery.
Add `AGENT_TOOLING_CATALOG_BENCHMARK=1` to include a separate plugin workload
with 500 marketplace listings, or select `WorkspacePerformanceTests/catalogHeavyPlugins`
to run that workload alone.

## Verification contract

“Observed” means a read-only scan found local configuration or a CLI. “Installed”
means a target write or native CLI command has a receipt. “Authenticated” and
“cloud connector verified” require verification in the owning product; the app
will never infer them from a local installation.

## Browse skills by ownership and source

Skills opens on **All skills**, with **My skills** and **Third-party** tabs.
Source, installation type, maintenance location, and client filters are saved
locally between launches. The Source menu lists discovered bundles, including
workflow plugins. Agent Tooling marketplace plugins are classified as My skills automatically;
recognized external publishers are classified as Third-party. Skill details explain
the evidence and allow a saved override or a return to automatic classification.
Unknown publishers and standalone skills without provenance remain unclassified;
standalone overrides apply individually. Classification never changes installed files.

My skills separates **Maintained here** from **Maintained elsewhere**. Skills
created or copied into the library are maintained here. Repository and plugin
skills can remain maintained elsewhere, with a link to reveal their observed
installed source. Copying a discovered skill into the library creates a separately
maintained standalone copy; it does not migrate its plugin dependencies or merge
publisher updates. Existing distinct skill identities are preserved.

The skill list uses the full content width until a row is selected. Selecting a
skill opens a resizable detail pane; its close button or Escape restores the full
list. Tabs and search remain above the list, with source/app menus and a compact
Filters menu for installation, maintenance, and tags.

Skill details offer per-client installation and native user-level availability.
Discovered standalone skills can be copied directly to a supported client without
adoption. Plugin skills use a verified native marketplace installer for the whole
bundle. Codex installed-plugin discovery requests only installed entries; targeted
marketplace lookup avoids truncating a large available catalog during installation.

Codex switches write the documented per-path `skills.config` setting. Claude
standalone switches write `skillOverrides`; Claude plugin switches explicitly
control the whole plugin via `enabledPlugins`. These are user preferences on this
Mac, not effective project/organization policy or live session state. Restart the
client after changes. Config edits preserve unrelated entries, keep private local
backups, and refuse symlinked settings or unsupported configuration syntax.

### Connections and compact browsers

The Connections screen separates account connector declarations discovered in installed Codex plugin manifests from directly configured MCP servers. Connector discovery reads bounded local `.app.json` mappings and display metadata; it does not enumerate cloud accounts or establish authentication. Empty connector results do not mean the user has no cloud connections. Account status remains explicitly unchecked.

Plugins and MCP servers use column tables with client filters. Skills, Plugins, Connections, Collections, Configurations, and Projects open with the browser filling the page; selecting an item reveals details, and Close/Escape restores the browser. Plugin and direct MCP table selections retain their existing multi-selection review actions.
