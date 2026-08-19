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
  Plugins packages are inspected locally. Claude and Codex listings are read
  from their respective machine-readable native catalog commands. Gemini's
  gallery remains a native source rather than an undocumented scraped API.
- **Connections:** the app records ownership, expected surfaces, and optional
  secret *reference names* only. OAuth tokens, API keys, and cloud connectors
  remain in their owning client, account, keychain, provider, or admin system.

Every client-affecting operation is first presented as a plan. The operation
engine has a fixed executable allowlist, restricts file writes to managed or
supported locations, moves replaced files to a rollback area, redacts receipts,
and records partial per-target outcomes.

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
