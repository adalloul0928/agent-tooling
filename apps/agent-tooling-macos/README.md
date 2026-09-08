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
- **Marketplace:** local folders, checked-out Git repositories, and Agent
  Plugins packages are inspected locally. The official MCP Registry is queried
  through its documented API. Claude and Codex listings are read from their
  respective machine-readable native catalog commands. Gemini's gallery
  remains a native source rather than an undocumented scraped API.
- **Connections:** the app records ownership, expected surfaces, and optional
  secret *reference names* only. OAuth tokens, API keys, and cloud connectors
  remain in their owning client, account, keychain, provider, or admin system.

Every client-affecting operation is first presented as a plan. The operation
engine has a fixed executable allowlist, restricts file writes to managed or
supported locations, moves replaced files to a rollback area, redacts receipts,
and records partial per-target outcomes.

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

## Create a skill with Codex

The **New skill** action uses the locally installed Codex CLI and its bundled
Skill Creator. It uses the account already reported by `codex login status`;
the desktop app does not request, copy, or store an OpenAI API key. Claude is
not configured or invoked as a generation provider.

Codex writes only into a private staging directory. The app validates the
canonical Agent Plugins package, shows every generated file, and requires each
file to be opened before the package can be saved. Saving creates a separate
installation plan; it still does not change Codex, Claude Code, or Gemini until
that plan is approved. Codex is the default destination, while the other
clients remain optional destinations for the same portable skill.

Requirements:

```sh
codex login status
test -f "${CODEX_HOME:-$HOME/.codex}/skills/.system/skill-creator/SKILL.md"
```

The generator uses `codex exec` with argv-only invocation, bounded stdin,
workspace-write isolation, timeout/cancellation, redacted diagnostics, and a
review-only output contract.

## Raycast shortcuts

The companion extension lives at
[`integrations/raycast/agent-tooling`](../../integrations/raycast/agent-tooling).
It can search the local inventory, queue a Codex skill request, check setup,
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
application bundle. Its default output is ignored under
`.build/Agent Tooling.app`.

```sh
./scripts/package-app.sh
open '.build/Agent Tooling.app'
```

Pass a destination as the first argument when you want the bundle elsewhere:

```sh
./scripts/package-app.sh '/Applications/Agent Tooling.app'
```

## Verify

```sh
swift test --disable-sandbox
```

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
