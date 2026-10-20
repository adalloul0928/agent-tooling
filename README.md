# Agent Tooling

A native macOS app for managing skills, plugins, and MCP connections across
**Codex, Claude Code, Gemini CLI, and Kiro CLI**.

Keep a local library, choose which apps and projects use each tool, and review
changes before they affect your setup.

![Agent Tooling Home with a sample library](docs/images/app-home.png)

## Install

**Requires macOS 26 or later and an Apple Silicon Mac.**

Packaged builds will be available on the [Releases page](https://github.com/adalloul0928/agent-tooling/releases).
The first public DMG has not been published yet. When available, download
`Agent-Tooling-arm64.dmg`, open it, and drag **Agent Tooling** into
**Applications**. Eject the DMG and open the app from Applications. Updates use
the same process; quit the app before replacing it.

You can [build from source](#build-from-source) now. Agent Tooling manages
existing client installations; install and sign in to the clients you want to
use separately.

## First launch

Choose which apps to manage, review what Agent Tooling will read, and approve
each installation. Setup can be resumed later from the Home screen.

![Agent Tooling guided setup with sample data](docs/images/app-setup.png)

## What it does

- **See your tools in one place.** Browse skills, plugins, and MCP connections
  discovered in supported clients, with their sources and installation status.
- **Install where you need them.** Assign tools to apps or projects, keep native
  plugins together, and review conflicts or changes to existing files.
- **Follow updates.** Track repository sources, check for new versions, and
  choose whether to review or automatically install updates by tool type.
- **Create and maintain skills.** Edit a local skill or draft one with an
  installed Claude Code or Codex client.
- **Check your setup.** Inspect configuration and proposed fixes, with receipts
  and backups for changes made through the app.
- **Use more than one Mac.** Optionally sync your library through a Git repository
  you control. Each Mac applies its own changes.

![Agent Tooling skill library using sample content](docs/images/app-library.png)

Screenshots show the app’s SwiftUI views rendered with synthetic test data.

## Your data

The app stores its workspace in
`~/Library/Application Support/Agent Tooling/`. A GitHub account or sync
repository is not required for local use.

Credentials remain with their owning client, account, or keychain. The portable
workspace stores secret reference names rather than credential values. Client
installs use a restricted command policy, and the app keeps records of its
changes.

Discovery, update checks, optional sync, and assistant features contact the
services you choose. Assistant features use your installed client and its
account. See the [app guide](apps/agent-tooling-macos/README.md) for details and
limits.

## Build from source

Install Xcode with the macOS 26 SDK and Swift 6.2 or later, then run:

```sh
git clone https://github.com/adalloul0928/agent-tooling.git
cd agent-tooling/apps/agent-tooling-macos
./scripts/package-app.sh
open '.build/Agent Tooling.app'
```

The packaging script builds the app and checks that its bundled dependency
notices are present.
Local builds use ad hoc signing; public distribution uses a separate signed
and notarized [release workflow](docs/macos-app-release.md).

To run the Swift tests from the same directory:

```sh
swift test --disable-sandbox --no-parallel
```

## Documentation

- [App guide and development](apps/agent-tooling-macos/README.md)
- [Architecture and behavioral contracts](docs/README.md)
- [Release instructions](docs/macos-app-release.md)
- [Third-party components](docs/third-party-reuse-2026-09.md)

Report bugs or request features in [GitHub Issues](https://github.com/adalloul0928/agent-tooling/issues).
Include the app version, macOS version, and steps to reproduce. Remove secrets,
account details, and private paths from logs before sharing them.

## License

Agent Tooling is licensed under the [MIT License](LICENSE).
Copyright © 2026 Agent Tooling contributors.

Third-party dependencies retain their own licenses and notices. The macOS app
includes its MIT license and [third-party notices](apps/agent-tooling-macos/Sources/AgentToolingApp/Resources/ThirdPartyNotices.txt).
