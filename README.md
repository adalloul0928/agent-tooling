# Agent Tooling

Private, cross-client tooling for Claude Code and Codex.

This repository is the source of truth for portable Agent Skills and the thin,
platform-native manifests that package them. It does not contain machine-local
settings, OAuth state, secrets, or project-critical instructions that belong in
an application repository.

## macOS app

The repository also contains the native [Agent Tooling macOS app](apps/agent-tooling-macos/README.md),
a local-first control center for Codex, Claude Code, Gemini CLI, and Kiro CLI.

The app holds a library of skills, plugins, and connections. Install opens one
picker that assigns an item, plans what that means for this Mac, and applies it,
showing the plan inline for review when it would do more than the button said;
every client write runs through an allowlisted executor. Updates run by a
per-kind policy of install automatically or ask first. Projects are keyed by
repository, so a project set up on one Mac finds its folder on the next.
Checkup audits each client and walks proposed fixes one reviewed action at a
time. Insights reads local chat history to find recurring work that has no
skill yet. Macs sync through a private Git repository where every Mac is a full
peer: content and published status travel, and nothing runs on another Mac from
this one. See the [app README](apps/agent-tooling-macos/README.md) and the
[docs index](docs/README.md).

Versioned `agent-tooling-app-v*` tags build a Developer ID-signed and notarized
DMG through GitHub Actions. The one-time credential setup and release procedure
are documented in [docs/macos-app-release.md](docs/macos-app-release.md).

## Status

The dual catalogs publish seven focused native plugins from shared skill cores
and native MCP adapters:

- `personal`: local-first Personal AI / Life OS, Obsidian vault, communication,
  planning/review, family check-in, and personal task workflows;
- `developer-workflows`: reusable cross-project development quality workflows;
- `cyrus-workflows`: PUMPD research, planning, review, delegation, learning,
  and retrospective workflows for Cyrus;
- `pumpd-workflows`: small local PUMPD maintenance workflows outside Cyrus;
- `pumpd-automations`: scheduled PUMPD scans that report and file Linear
  Triage suggestions;
- `wet-in-seattle`: IAWIS workflows with a Doppler-backed Analytics MCP.
- `mobile-development`: reusable iOS Simulator and HeroUI Native MCPs, with
  HeroUI Native Pro authentication injected by Doppler.

These plugins and their bundled skills are first-party creations. Vendor
plugins, MCP servers, and CLIs remain with their publishers and are referenced
through desired-state profiles rather than copied into this repository.

Existing standalone installations remain the rollback path until Git-backed
install, update, and normal-use canaries pass.

## Repository contract

```text
agent-tooling/
  .claude-plugin/marketplace.json
  .agents/plugins/marketplace.json
  plugins/
    <plugin>/
      .claude-plugin/plugin.json
      .codex-plugin/plugin.json
      skills/<skill>/SKILL.md
      .mcp.json
```

- Keep one physical skill core under its plugin directory.
- Keep Claude and Codex manifests as separate adapters.
- Share scripts, references, assets, and tool-neutral workflow guidance.
- Keep MCP authentication, client settings, and hosted-environment configuration
  outside this repository.
- Keep application-critical skills committed in the application repository.

## Version policy

- `main` is the rolling release channel for both native marketplaces. A native
  marketplace refresh resolves the newest merged commit from that branch.
- Omit Claude and Codex plugin `version` fields unless a future compatibility
  requirement changes the policy.
- Historical tags may remain as repository history, but workstation profiles do
  not pin to them.

Microsoft APM was tested as a possible compiler. The result was a partial adopt:
native manifests remain authoritative, while APM's lockfile and audit features
remain candidates for a later optional layer. See [docs/apm-spike.md](docs/apm-spike.md).

## Rollout

1. Validate the repository contract and each plugin package.
2. Test local path installation in isolated client homes.
3. Test private GitHub marketplace installation and refresh behavior.
4. Run explicit invocation, implicit invocation, non-trigger, read, write, and
   Git-review canaries.
5. Remove the matching standalone copies only after the relevant canaries pass.

## Setting up a new machine

[docs/new-machine-setup.md](docs/new-machine-setup.md) is the ordered runbook:
prerequisites, `doppler login`, marketplace and plugin installs,
`./scripts/setup <profile> --apply`, MCP OAuth, the automations, and the
account-side steps that cannot be automated.

## Validation

Run the cross-client validation and isolated Claude/Codex install smoke tests:

```bash
./scripts/validate
```

Claude's validator reports the intentionally omitted Claude plugin version as a
warning. The warning is expected while the rolling Git branch is the release
mechanism.

## Desired-state profiles

Composable profiles record what a workstation or project should contain without
storing secrets or pretending hosted account state is synchronized. The
read-only doctor compares those profiles with native local configuration:

```bash
./scripts/doctor
./scripts/doctor pumpd-project --json
./scripts/doctor pumpd-workstation --project-root /path/to/pumpd-mobile-app
```

See [docs/profiles-and-doctor.md](docs/profiles-and-doctor.md) for the profile
model, status meanings, and safety boundary.

## Inventory and placement

[docs/tooling-inventory.md](docs/tooling-inventory.md) is the canonical map of
owned skills, vendor plugins, project tooling, MCPs, hosted connectors, and
authentication across Claude Code, Claude.ai, Codex, and ChatGPT. Use it before
adding a capability or deciding whether it belongs in this repository, an
application repository, a vendor marketplace, local configuration, or a hosted
account.
