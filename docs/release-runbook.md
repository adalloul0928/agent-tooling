# Release runbook

`main` is the rolling release channel. Native plugin manifests and catalog
entries intentionally omit `version`; each client receives the newest merged
revision when its `agent-tooling` marketplace is refreshed.

## Before publishing

1. Start from a clean branch based on `main`.
2. Review every executable script, hook, MCP declaration, and manifest change.
3. Run `./scripts/release-check`.
4. Run `./scripts/validate` with the supported Claude and Codex clients.
5. Review the diff and confirm no secret, OAuth state, certificate, cache,
   absolute installation path, or licensed vendor source is present.

## Publish the release

1. Merge the approved change to `main`.
2. Refresh the already registered `agent-tooling` catalog in Claude and Codex.
3. Install newly added plugins and update existing plugins in both clients:
   - `personal@agent-tooling`
   - `developer-workflows@agent-tooling`
   - `pumpd-workflows@agent-tooling`
   - `cyrus-workflows@agent-tooling`
   - `wet-in-seattle@agent-tooling`
   - `mobile-development@agent-tooling`
4. Start fresh Claude Code and Codex sessions before testing discovery or
   invocation.

This release replaces `obsidian`, `agent-ops`, and `personal-productivity`.
Install and validate their replacements before uninstalling the superseded
plugins; plugin renames do not migrate existing installations automatically.

The private catalog is added once per client. Official Anthropic and OpenAI
catalogs are built in and should not be copied into this repository. A catalog
refresh does not install a newly published plugin automatically.

## Distribution canary

1. Create temporary Claude and Codex homes.
2. Add the GitHub marketplace, not the local path.
3. Install every owned plugin listed in both repository catalogs.
4. Install the `mobile-development` iOS lane runtime from the same tested
   revision, then require `install-runtime.mjs --check` to report `status=ok`.
5. Confirm that each plugin exposes its expected skills.
6. Run the cases in `docs/obsidian-canary.md` for the `personal` bundle,
   explicit/implicit/non-trigger cases for skill bundles, hook registration for
   hook-bearing bundles, and an MCP startup check for bundles that include MCPs.
   For `mobile-development`, prove SessionStart context, UserPromptSubmit
   heartbeat, PreToolUse denial, and exact SessionEnd cleanup without touching
   a live device.
7. Publish a harmless update and prove both native refresh paths receive it.
8. Refresh the separate iOS lane runtime from that same revision, re-run its
   read-only check, and retain every reported recovery backup until the canary
   passes.
9. Record the tested commit and client versions in the PR.

Installation and authentication are different gates. Authenticate any new MCP
through the local client that will use it, configure non-OAuth secrets outside
Git, and verify hosted connectors or apps independently. A local canary does
not prove Claude Code cloud, Codex cloud, Claude.ai, or ChatGPT account state.

## Rollback

1. Revert the problematic commit on `main`, merge the revert, and refresh both
   marketplaces. Record the previous known-good commit before publishing so the
   rollback target is unambiguous. For an emergency Claude rollback before a
   revert merges, create a temporary branch at that commit because Claude's
   marketplace source accepts a branch but not a raw commit SHA.
2. Start fresh client sessions and verify the previous canary string.
3. If native plugin recovery fails, remove the plugin and restore the retained
   standalone skill directory.
4. Do not delete standalone rollback copies until the following release has
   passed normal work in both clients.

Hosted account marketplaces are verified separately. A Git push does not prove
that claude.ai or ChatGPT account state changed.

See [tooling-inventory.md](tooling-inventory.md) for the complete ownership,
placement, and authentication model.
