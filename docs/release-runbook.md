# Release runbook

Releases use immutable Git tags rather than plugin semver. Native plugin
manifests and catalog entries intentionally omit `version`, so the catalog Git
revision is the release unit for all four owned plugins.

## Before publishing

1. Start from a clean branch based on `main`.
2. Review every executable script, hook, MCP declaration, and manifest change.
3. Run `./scripts/release-check`.
4. Run `./scripts/validate` with the supported Claude and Codex clients.
5. Review the diff and confirm no secret, OAuth state, certificate, cache,
   absolute installation path, or licensed vendor source is present.

## Publish the release

1. Merge the approved change to `main`.
2. Create and push an immutable tag for the merged commit. Use a repository-wide
   release name because the revision may contain more than one plugin.
3. Update the release variable in `profiles/base-workstation.json` to the new
   tag in a follow-up source change if it was not part of the release commit.
4. Refresh the already registered `agent-tooling` catalog in Claude and Codex.
5. Install or update the following in both clients:
   - `obsidian@agent-tooling`
   - `pumpd-workflows@agent-tooling`
   - `agent-ops@agent-tooling`
   - `personal-productivity@agent-tooling`
6. Start fresh Claude Code and Codex sessions before testing discovery or
   invocation.

The private catalog is added once per client. Official Anthropic and OpenAI
catalogs are built in and should not be copied into this repository. A catalog
refresh does not install a newly published plugin automatically.

## Distribution canary

1. Create temporary Claude and Codex homes.
2. Add the GitHub marketplace, not the local path.
3. Install all four owned plugins in both clients.
4. Confirm that each plugin exposes its expected skills.
5. Run the cases in `docs/obsidian-canary.md` for the Obsidian bundle and an
   explicit, implicit, and non-trigger case for each other bundle.
6. Publish a harmless update and prove both native refresh paths receive it.
7. Record the tested tag, commit, and client versions in the PR.

Installation and authentication are different gates. Authenticate any new MCP
through the local client that will use it, configure non-OAuth secrets outside
Git, and verify hosted connectors or apps independently. A local canary does
not prove Claude Code cloud, Codex cloud, Claude.ai, or ChatGPT account state.

## Rollback

1. Reinstall the previous known-good release ref or revert the marketplace
   commit. Keep an immutable Git tag for every live release even though plugin
   manifests omit semver; Claude Code 2.1.207 accepts a branch or tag in the
   marketplace URL fragment but not an arbitrary commit SHA. Codex can use the
   same tag with `--ref` and also accepts a commit SHA.
2. Start fresh client sessions and verify the previous canary string.
3. If native plugin recovery fails, remove the plugin and restore the retained
   standalone skill directory.
4. Do not delete standalone rollback copies until the following release has
   passed normal work in both clients.

Hosted account marketplaces are verified separately. A Git push does not prove
that claude.ai or ChatGPT account state changed.

See [tooling-inventory.md](tooling-inventory.md) for the complete ownership,
placement, and authentication model.
