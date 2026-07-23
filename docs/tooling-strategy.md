# Claude and Codex Tooling Strategy

This is the source-of-truth strategy for shared personal agent tooling. PUMPD's Obsidian vault keeps only project-specific operating notes and links back here.

## Goals

- Author reusable behavior once.
- Preserve native Claude and Codex capabilities where their contracts differ.
- Make installs versioned, reviewable, testable, and reversible.
- Keep local, hosted, cloud, and account-owned state explicit.
- Avoid personal one-off copies that drift from package-owned skills.

## Ownership

| Concern | Owner |
| --- | --- |
| Portable skill instructions and assets | `plugins/<bundle>/skills/<skill>/` |
| Claude manifests and marketplaces | Claude-native adapters in this repository |
| Codex manifests and marketplaces | Codex-native adapters in this repository |
| Shared repo behavior | The target repo's `AGENTS.md` |
| Client-specific repo behavior | `.claude/`, `.codex/`, and native config files |
| Credentials and account authorization | The owning client or service; never this repository |
| PUMPD workflow notes | Obsidian `PUMPD/AI Tooling/` |
| PUMPD technical documentation | The PUMPD monorepo documentation |

## Four rules

1. **One authored core, native adapters.** Share portable skill content; do not force incompatible clients into one manifest or configuration shape.
2. **Capability parity over configuration identity.** The outcome should match even when the installation or authorization mechanism differs.
3. **Separate state by surface.** Local CLI, desktop, hosted chat, cloud execution, connector authorization, and cached plugin state are distinct systems.
4. **Release and verify.** Use immutable refs, isolated install smoke tests, explicit canaries, and a known rollback revision.

## Placement

- Put reusable cross-project workflows in this repository.
- Put project-specific engineering rules in the project repository.
- Put current technical runbooks beside the code they describe.
- Put personal project thinking and operator notes in Obsidian.
- Put task status, assignment, and checklists in Linear.
- Never treat a plugin cache or generated install directory as an editable source.

## Distribution model

Each bundle is self-contained under `plugins/`. Claude and Codex catalogs point at the same package content through their native adapters. Profiles describe desired bundles, while installation and authorization remain client-specific.

Hosted or account connectors are not implied by a successful local install. They require their own authorization and should be checked separately.

## Validation

Before release:

1. Run `./scripts/validate`.
2. Review the diff and scan for secrets or machine-specific paths.
3. Install the affected bundles into isolated Claude and Codex homes.
4. Test explicit invocation and at least one implicit trigger.
5. Verify referenced scripts and assets resolve relative to the installed skill.
6. Run the live canary appropriate to the changed capability.
7. Record the rollback ref.

## Context budget

Keep always-on instructions small. Load specialized workflows on demand through skills, and keep lengthy implementation history out of active project indexes.

