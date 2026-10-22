# Documentation

Start with the [app guide](../apps/agent-tooling-macos/README.md) for installation,
setup, and development. This index covers the implementation contracts and
supporting engineering notes.

## Distribution and compatibility

- [macOS release guide](macos-app-release.md) — signing, notarization, and DMG publishing
- [Client compatibility](compatibility.md) — tested interfaces and verification limits
- [Third-party components](third-party-reuse-2026-09.md) — dependencies and artwork attribution
- [Documentation site](architecture-site/README.md) — static product guide

## Library and installation

- [Workspace documents](workspace-contracts-v1.md) — portable and device types
- [Workspace authority](workspace-authority-v1.md) — store selection and first launch
- [Revision store](workspace-store-v1.md) — persistence and command transactions
- [Package content store](package-tree-content-store-v1.md) — complete trees and digests
- [Skill intake](central-skill-intake-v1.md) — authored and upstream content
- [Versioned commands](versioned-commands-v1.md) — validated workspace mutations
- [Assignment commands](workspace-assignment-commands-v1.md) — assignment and install batches
- [Deployment](workspace-deployment-v1.md) — plans, staging, and execution
- [Native plugin commands](workspace-native-plugin-command-v1.md) — plugin installation admission
- [MCP definitions](workspace-mcp-definitions-v3.md) — managed connection schema
- [Linked destinations](linked-destinations-v1.md) — explicit external deployment folders
- [Project declarations](project-declaration-v1.md) — repository-level configuration

## Clients and app features

- [Setup](launchpad-setup-v1.md) — first run, consent, resuming, and re-entry

- [Settings](effective-settings-v1.md) — native configuration layers and editing
- [Standing instructions](standing-instructions-v1.md) — read-only instruction inventory
- [Accounts](account-surfaces-v1.md) — account observations and local preferences
- [Updates](updates-and-policy-v1.md) — cadence and review policies
- [Checkup](checkup-and-review-v1.md) — configuration audit and proposed fixes
- [Skill creator](skill-creator-v1.md) — bounded assistant-driven authoring
- [Insights](insights-v1.md) — recurring-work analysis
- [ToolHive inspection](toolhive-runtime-inspection-v1.md) — read-only runtime adapter
- [MCP server](mcp-server-surface-v1.md) — read and review-request tools
- [Content and secrets](content-risk-and-secrets-v1.md) — validation and redaction

## Sync and recovery

- [Multi-Mac sync](multi-mac-sync-v1.md) — peer sync, devices, and conflict resolution
- [Encrypted folder sync](encrypted-folder-sync-v1.md) — experimental record transport
- [Migration design](workspace-migration-design-v1.md)
- [Migration intake](workspace-migration-intake-v1.md)
- [Migration assembly](workspace-migration-assembly-v1.md)
- [Migration journal](workspace-migration-journal-v1.md)
- [Skill-assignment migration](workspace-skill-assignment-migration-v1.md)
- [Legacy checkpoints](workspace-legacy-checkpoints-v1.md)

Migration documents describe compatibility paths for older workspace formats,
not the normal first-run flow.

## Staged and historical notes

[Portable MCP delivery](portable-mcp-delivery-v1.md) and
[source recognition](source-recognition-contracts-v1.md) describe staged
components. Their status sections identify the remaining integration work.

The following documents preserve prior design decisions and should not be used
as current product instructions:

- [Merge engine](workspace-merge-engine-v1.md) and [export runtime](sync-export-runtime-v1.md), superseded in part by multi-Mac sync
- [Library session](workspace-library-session-v1.md)
- [Onboarding roadmap](onboarding-feature-roadmap.md)
- [UX review](ux-review-2026-09.md)
- [Performance review](performance-review-2026-09.md)
- [Related projects](competitor-review-2026-09.md)
