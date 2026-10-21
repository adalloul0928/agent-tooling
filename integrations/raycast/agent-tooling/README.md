# Agent Tooling for Raycast

Search your Agent Tooling library, check client setup, and open reviews from
Raycast. The desktop app handles installation and client configuration changes.

This companion is available as source. A Raycast Store release requires a
registered publisher account and the signing identity of the released macOS
app. The checked-in publisher name is a placeholder, and packaged-app execution
is disabled until the extension's signing identity is configured at build time.

## Commands

| Command                 | Action                                                             |
| ----------------------- | ------------------------------------------------------------------ |
| Search Agent Tooling    | Search skills, MCP servers, and plugins; open a result in the app. |
| Create Skill Draft      | Ask Codex or Claude Code to draft a skill for review.              |
| Check Setup             | Run the read-only client health check.                             |
| Review Tooling Insights | Open Insights in the app.                                          |
| Review Sync             | Open the app's sync review.                                        |
| Open Agent Tooling      | Open or focus the app.                                             |

Assign hotkeys in Raycast Settings after importing the extension.

## Development

Requires Raycast on macOS and Node.js 22.22.2 or later.

```sh
npm ci
npm run verify-source
npm run dev
```

For a local app build, enable **Allow Development Helper** in the extension's
preferences and select `Agent Tooling.app/Contents/Helpers/agent-tooling`.
Both the preference and Raycast development mode are required. Published builds
reject this override.

Raycast's full manifest validation also requires a developer account. Sign in
with `npx ray login`, then replace `author` in `package.json` with the handle
reported by `npx ray profile`. `npm run verify-source` runs local type, source,
test, and build checks; `npm run check` also runs Raycast's manifest validator.

## Configure a release

Use the same Team ID as the signed desktop release:

```sh
MACOS_SIGNING_TEAM_ID=YOURTEAMID npm run configure:release
npm run check
```

The configuration command writes a fixed Team ID into
`src/lib/signing-team.ts` before compilation. The installed extension does not
read a Team ID from the environment or user preferences. Missing or malformed
configuration fails closed. Keep publisher-specific configuration out of the
shared source; restore the empty Team ID after preparing the release.

Before publishing, verify the extension with the notarized app installed in
Applications. The app must use `dev.agenttooling.app`, its CLI helper must use
`dev.agenttooling.app.cli`, and both must be signed by the configured team.
Publishing to the Raycast Store is a separate step.
`npm run publish` checks that the team and publisher are configured before
opening the publishing flow.

## CLI contract

Responses are UTF-8 JSON, capped at 1 MiB, with `schemaVersion: 1`.

```sh
agent-tooling search --query QUERY --json
agent-tooling request create-skill --provider codex --scope global \
  --targets codex --instruction-stdin --json
```

Search returns at most 100 results and sets `truncated` when more match. Skill
instructions travel over stdin. The request response contains an opaque ID and
`pending-review` state; the desktop app handles generation and review. The
provider is `codex` or `claude`; installation targets are chosen separately.
`doctor` accepts exit codes `0` (healthy) and `2` (needs attention).

## Process safety

- The app and CLI helper must satisfy exact bundle IDs, the configured Team ID,
  Apple's Developer ID certificate requirements, and the same signing authority.
- The canonical helper path must stay inside the app bundle.
- Processes use executable paths and argument arrays with `shell: false`.
- Output and runtime are bounded. Skill instructions are redacted from errors.
- Deep links contain navigation state or an opaque request ID.
- The extension does not read credentials or install packages in the background.

The extension is licensed under [MIT](LICENSE).
