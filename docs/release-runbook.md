# Release runbook

The first release uses Git revisions rather than plugin semver. Both native
plugin manifests and Claude catalog entries intentionally omit `version`.

## Before publishing

1. Start from a clean branch based on `main`.
2. Review every executable script, hook, MCP declaration, and manifest change.
3. Run `./scripts/release-check`.
4. Run `./scripts/validate` with the supported Claude and Codex clients.
5. Review the diff and confirm no secret, OAuth state, certificate, cache,
   absolute installation path, or licensed vendor source is present.

## Distribution canary

1. Create temporary Claude and Codex homes.
2. Add the GitHub marketplace, not the local path.
3. Install `obsidian@agent-tooling` in both clients.
4. Run the cases in `docs/obsidian-canary.md`.
5. Publish a harmless update and prove both native refresh paths receive it.
6. Record the tested commit and client versions in the PR.

## Rollback

1. Reinstall the previous known-good Git revision or revert the marketplace
   commit.
2. Start fresh client sessions and verify the previous canary string.
3. If native plugin recovery fails, remove the plugin and restore the retained
   standalone skill directory.
4. Do not delete standalone rollback copies until the following release has
   passed normal work in both clients.

Hosted account marketplaces are verified separately. A Git push does not prove
that claude.ai or ChatGPT account state changed.
