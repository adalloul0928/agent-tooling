# Agent Tooling for macOS

Agent Tooling manages a local library of skills, plugins, and MCP connections
for Codex, Claude Code, Gemini CLI, and Kiro CLI. It is built with SwiftUI and
stores its workspace in SQLite.

![Agent Tooling Home](../../docs/images/app-home.png)

## Install

Requires macOS 26 or later and Apple Silicon. The first public DMG has not been
published yet; check [Releases](https://github.com/adalloul0928/agent-tooling/releases)
for availability. When available, download `Agent-Tooling-arm64.dmg`, open it, and drag **Agent Tooling** into
**Applications**. Eject the DMG and open the app from Applications. To update,
quit the app and replace it with the new version. Packaged builds do not require
Xcode or a repository checkout.

To use the app before a release is available, [build from source](#build-and-run).
Install and sign in to your chosen clients separately.

## First launch

Setup opens before the main window on a Mac with no library. Choose **Start
here** to select your apps, review the locations and commands Agent Tooling
will read, then create a library from what it finds. Discovery does not
install, move, or take ownership of those files. You can also **Join** an
existing workspace through its Git repository.

Continue through the starter library, app placement, optional Agent Tooling
connections, assistant permissions, and sync. Changes to client installations
are presented for review before they run. Press **⌘Return** to confirm an
installation; ordinary **Return** advances setup.

Leaving before a library is created quits setup. After that, **Go to Home**
saves your place and the **Finish setting up** card lets you resume. **Set Up
This Mac…** in the app menu reopens setup for an existing workspace. App and
behavior preferences are saved as you choose them; installation changes still
require review.

If you open the app from a disk image or another folder, setup can move it to
Applications and reopen it there. See the [setup contract](../../docs/launchpad-setup-v1.md)
for progress records, cancellation, and launch behavior.

## Library and installation

Skills, Plugins, and Connections show each tool's source, ownership, and client
availability. Select a row to see its details. Copies with the same skill name
are grouped, with separate versions shown when their contents differ.

**Install…** selects the destination apps and either this Mac or a project.
The app saves the assignment, prepares a plan, and applies supported changes.
Plans involving removals, existing connection changes, flagged content, or
larger batches require review. Files the app cannot prove it installed are
left for review. Completed operations produce receipts and rollback records.

Native plugins remain whole packages. A standalone skill can be copied into
the library for independent maintenance, or linked to a repository for updates.
An unknown source stays unknown until you link it.

| Client | Delivery |
|---|---|
| Codex | Native plugin commands, supported skill folders, and user-scoped MCP commands. Project MCP placement requires manual review. |
| Claude Code | Native plugin and MCP commands, supported skill folders, and reviewed settings edits. |
| Gemini CLI | Skills packaged as extensions and linked with the native CLI. Restart the client to load changes. |
| Kiro CLI | Standard skill folders and native MCP add/remove commands. |

Availability depends on the installed client and its supported commands. An
installation record does not prove authentication or successful use in a live
session. See [compatibility](../../docs/compatibility.md).

## Updates, projects, and sync

**Settings → General → Updates** controls check frequency and whether each tool
type updates automatically or waits for review. Modified installed copies are
preserved for review. Native plugins use their owning client's update route.

Projects associate assignments with a repository and its local checkout. Presets
apply a saved selection of tools. Neither requires copying project source code
into the library.

Optional Git sync shares library records and app-authored skill content through
a repository you control. Each Mac keeps its own workspace, credentials,
installation observations, and receipts. Conflicts wait for resolution, and each
Mac applies changes locally. See [multi-Mac sync](../../docs/multi-mac-sync-v1.md).

**Prepare backup** creates a local Git export. **Inspect backup** previews a
restore before accepting changes. Encrypted folder sync is an experimental
alternative that carries records only; it has not been verified on two Macs.

## Assistants, accounts, and privacy

The skill creator can use an installed Claude Code or Codex client to draft a
skill. **Insights** analyzes local session history for recurring work, and
**Checkup** inspects configuration and offers fixes. These features use your
chosen client's account and permissions; content submitted to an assistant is
subject to that provider's handling.

The workspace lives in `~/Library/Application Support/Agent Tooling/`. Local
use does not require GitHub or a remote repository. Network features include
catalog discovery, source updates, optional sync, and assistant requests.

Credentials stay in their owning client, account, or keychain. Portable records
contain credential reference names, not secret values. Operation receipts and
MCP responses are redacted. Account views report what local clients expose;
cloud installation and sign-in remain vendor-managed actions. Live subscription
account behavior has not been fully verified; see
[account surfaces](../../docs/account-surfaces-v1.md).

## Build and run

Requirements: macOS 26 or later, Apple Silicon, and Xcode with the macOS 26 SDK
and Swift 6.2 or later. Run these commands in `apps/agent-tooling-macos`:

```sh
./scripts/package-app.sh
open '.build/Agent Tooling.app'
```

The script uses the release configuration, assembles the app bundle, signs it
ad hoc, and runs `--verify-resources` against the packaged app. This check reads
the dependency notices from the app itself, preventing a missing resource bundle
from being hidden by files left in a development directory. Tool and client
icons use native SF Symbols.

To choose another destination or a debug build:

```sh
./scripts/package-app.sh '/Applications/Agent Tooling.app'
AGENT_TOOLING_CONFIGURATION=debug ./scripts/package-app.sh
```

Distribution signing and notarization are covered in the
[release guide](../../docs/macos-app-release.md).

## Development

The package contains `AgentToolingCore`, the SwiftUI app, the
`AgentToolingMCP` server, and the `AgentToolingCLI` helper. The packaged CLI
lives inside the app bundle and is also used by the optional
[Raycast extension](../../integrations/raycast/agent-tooling).

```sh
swift build --disable-sandbox
swift test --disable-sandbox
swift format lint --strict -r Sources Tests Package.swift
```

CI also builds release with warnings treated as errors. Shared test helpers live
in `Tests/AgentToolingTestSupport`; reuse them for temporary workspaces, scripted
clients, and rendering tests.

UI sizes, typography, colors, and motion come from `DesignTokens.swift` and
`Theme.swift`. Use `.wrapsLines()` for multiline text and the shared collection
styles for list/detail screens. Keep user-facing action names in `ActionTitles`.

All client writes go through `OperationEngine` and `OperationCommandPolicy`.
Add a Core API to the public surface only when another target needs it.
`periphery scan` checks for unused code using the package's `.periphery.yml`.

The optional benchmark uses synthetic fixtures. Run it without concurrent
builds or tests and compare the same machine and configuration:

```sh
AGENT_TOOLING_BENCHMARK=1 AGENT_TOOLING_BENCHMARK_LABEL=release \
  swift test --disable-sandbox --configuration release --filter WorkspacePerformanceTests
```

Timings that include a fixed run-loop settling period are not input latency.
See the [documentation index](../../docs/README.md) for storage, migration,
installation, sync, and security contracts.

## Documentation screenshots

Run `./scripts/capture-screenshots.sh` to capture the Home, Library, and setup screens into
`docs/images/`. The app's real SwiftUI views use temporary test workspaces and
stub services, with no real accounts or client commands. The script briefly
opens sample windows and requires Screen Recording access. Captures include
only those windows; image metadata is removed before saving.

## License

Agent Tooling is licensed under [MIT](../../LICENSE). Packaged apps include the
license and [third-party notices](Sources/AgentToolingApp/Resources/ThirdPartyNotices.txt).
