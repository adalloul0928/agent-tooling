# Agent Tooling docs index

This index groups the `docs/*.md` files so a reader can tell a live behavioral
contract from a frozen plan. Current contracts track the shipped code. Design
notes record background and lower-churn rationale. Historical files are frozen
and should not be read as current behavior.

## Current contracts (behavioral, maintained)

- multi-mac-sync-v1.md — peer sync, device registry, join, scope (authoritative)
- encrypted-folder-sync-v1.md — sealed second transport over a synced folder
- project-declaration-v1.md — project.json and lock contract with a Projects surface
- linked-destinations-v1.md — installing into a folder outside a client's own
- portable-mcp-delivery-v1.md — per-app MCP route resolution and mapping
- package-tree-content-store-v1.md — content-addressed package store with digests
- workspace-contracts-v1.md — portable and device document types and invariants
- workspace-authority-v1.md — selects which store is authoritative
- workspace-mcp-definitions-v3.md — managed MCP definition schema, version 3
- source-recognition-contracts-v1.md — read-only interpretation of foreign source locks
- standing-instructions-v1.md — read-only inventory of instructions and agents
- central-skill-intake-v1.md — personal and upstream skill intake plus content updates
- versioned-commands-v1.md — the four versioned workspace commands
- effective-settings-v1.md — resolver and read-only inspector for native settings
- workspace-deployment-v1.md — intent to reviewable plan, staging, execution
- workspace-store-v1.md — versioned revision store and application service writer
- workspace-assignment-commands-v1.md — shared assign/apply batch and one-step install
- toolhive-runtime-inspection-v1.md — read-only, bounded adapter for the thv CLI
- compatibility.md — minimum client builds exercised by the current release
- profiles-and-doctor.md — desired-state profiles and the read-only doctor
- tooling-inventory.md — canonical map for where a capability belongs
- new-machine-setup.md — ordered runbook to set up a fresh Mac
- macos-app-release.md — signed, notarized DMG release workflow
- release-runbook.md — rolling-channel release procedure

New contracts under authoring now, listed here from the feature:

- updates-and-policy-v1.md — update availability, cadence, per-kind auto/ask policy
- insights-v1.md — recurring-work detection from local chat history and deep dive
- checkup-and-review-v1.md — audit to assistant to one-reviewed-action-at-a-time
- account-surfaces-v1.md — claude.ai and ChatGPT account contents, shared switches, sign-in checks
- skill-creator-v1.md — assistant-driven skill authoring under a bounded command policy
- content-risk-and-secrets-v1.md — content-risk scan and the portable-document secrets boundary
- mcp-server-surface-v1.md — the read-only and request-only MCP tool catalog

## Design notes (background, lower churn)

- tooling-strategy.md — Claude and Codex tooling strategy
- tooling-rollout-plan.md — phased tooling rollout plan
- onboarding-feature-roadmap.md — onboarding and configuration roadmap
- apm-spike.md — Microsoft APM compiler spike result
- public-release-boundary.md — public application extraction boundary
- third-party-reuse-2026-09.md — register of reused third-party components
- life-os.md — Personal AI / Life OS implementation notes
- life-os-completion-audit.md — Life OS completion audit

## Historical (frozen; do not treat as current)

- implementation-plan.md — older plugin-catalog-only plan
- implementation-plan-2026-09.md — dated app implementation plan
- implementation-progress-2026-09.md — dated app implementation progress log
- implementation-delivery-2026-09.md — dated delivery record
- implementation-baseline-2026-09.md — dated implementation baseline
- implementation-performance-baseline-2026-09.md — dated performance baseline
- ui-restoration-plan-2026-09.md — dated plan for views that now exist
- ux-review-2026-09.md — dated UX review
- performance-review-2026-09.md — dated performance review
- competitor-review-2026-09.md — dated competitor review
- tooling-discovery-2026-07.md — early tooling discovery notes
- workspace-merge-engine-v1.md — merge rules; superseded by multi-mac-sync for sync
- sync-export-runtime-v1.md — export and ToolHive; sync half superseded by multi-mac-sync
- workspace-migration-design-v1.md — legacy-to-versioned migration design
- workspace-migration-intake-v1.md — migration intake stage
- workspace-migration-assembly-v1.md — migration candidate assembly
- workspace-migration-journal-v1.md — migration journal and recovery
- workspace-skill-assignment-migration-v1.md — one-time skill-assignment migration
- workspace-legacy-checkpoints-v1.md — raw legacy checkpoints and archive
- workspace-library-session-v1.md — earlier library session notes
- obsidian-canary.md — Obsidian vault canary notes
