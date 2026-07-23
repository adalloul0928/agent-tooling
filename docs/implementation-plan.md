# Agent Tooling Implementation Plan

Current working plan for turning this repository into the reliable control plane for Arend's Claude and Codex setup.

## Success criteria

- Shared skills have one physical source.
- Claude and Codex install the same owned bundles through native adapters.
- Release refs are immutable and rollback is documented.
- Isolated install tests cover both clients.
- Desired-state profiles can explain what should be installed without conflating account authorization.
- `doctor` can attribute visible capabilities to their real source.
- PUMPD project workflows do not depend on editable vault templates or plugin caches.

## Current baseline

- Owned bundles include `personal`, `pumpd-workflows`, `cyrus-workflows`, and `wet-in-seattle`.
- Claude and Codex marketplace adapters are committed.
- Validation and isolated installation are part of the release bar.
- PUMPD project instructions are repo-owned through `AGENTS.md` plus native client adapters.
- Standalone local skill cleanup has reduced user-scoped duplication.
- The Obsidian workflow is packaged in `personal` and uses filesystem or connector capabilities according to availability.

## Remaining work

1. **Finish desired-state profiles.** Model owned bundles, client adapters, and manual account surfaces without pretending every surface is remotely configurable.
2. **Add `doctor`.** Report installed source, active revision, stale caches, duplicate standalone copies, and missing runtime prerequisites.
3. **Add `account-check`.** Produce a manual checklist for hosted connectors and account-owned capabilities that local installers cannot control.
4. **Expand canaries.** Keep explicit and implicit invocation tests for each owned bundle and record rollback steps.
5. **Remove legacy workflow assumptions.** Keep PUMPD research and plans in the simplified vault model; keep task state in Linear.
6. **Keep release pins current.** Refresh profiles only after validation and both-client smoke tests pass.

## Stop conditions

- A change requires storing credentials or OAuth state in the repository.
- A shared abstraction removes a client-native capability without an equivalent outcome.
- A package cannot install in isolated Claude and Codex environments.
- Validation depends on editing generated cache content.
- A migration would overwrite unrelated user-local configuration or a dirty checkout.

## Release checklist

1. Review the intended package scope.
2. Run `./scripts/validate`.
3. Run focused tests for edited scripts.
4. Install into isolated client homes.
5. Run behavioral canaries.
6. Review for secrets and absolute machine paths.
7. Commit, tag an immutable release, and update profiles.
8. Refresh real clients and verify source attribution before removing rollback copies.

