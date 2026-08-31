# Agent Tooling for Raycast

This macOS-only Raycast extension is a keyboard-first companion for the Agent Tooling desktop app. It searches the local library, checks client health, opens tooling insights, prepares sync review, and submits Codex-only skill-creation requests. The desktop app remains the only component allowed to install packages or change client configuration.

## Requirements

- Raycast on macOS
- A signed Agent Tooling app with bundle identifier `com.arendalloul.agent-tooling`
- The packaged helper at `Agent Tooling.app/Contents/Helpers/agent-tooling`

The extension discovers the app by bundle identifier. Developers can choose a different helper in the extension preferences; the override must be an executable file.

## Commands

- **Search Agent Tooling** searches skills, MCP servers, and plugins and opens the matching app destination.
- **Create Skill Draft** sends an instruction over stdin to the Codex-backed Skill Creator workflow. It opens an opaque request identifier in the app for review. Claude and Gemini are optional install destinations only; neither is used to generate the draft.
- **Check Setup** runs the read-only doctor and accepts both healthy exit code `0` and attention exit code `2`.
- **Review Tooling Insights** opens the app's Insights screen to scan recent Codex or Claude Code work, review skill usage and quality findings, and consider skill, MCP server, or plugin recommendations. The scan and every install review remain in the desktop app.
- **Review Sync** opens the app's Sync screen. The desktop app performs scanning, preview, approval, and execution.
- **Open Agent Tooling** opens or focuses the app's single main window.

Assign global hotkeys in Raycast Settings after importing the extension.

## Local development

1. Sign in to the Raycast developer CLI with `npx ray login`.
2. Replace the `author` field in `package.json` with the handle shown by `npx ray profile`.
3. Install the locked dependencies with `npm ci`.
4. Run `npm run dev` to import the extension and watch for changes.
5. Run `npm run check` before publishing.

The checked-in author is the intended product handle. Raycast's manifest validator will reject it until that Raycast account exists or the field is changed to the signed-in developer's handle.

## CLI contract

All responses are UTF-8 JSON no larger than 1 MiB. Versioned responses use `schemaVersion: 1`.

Search:

```console
agent-tooling search --query QUERY --json
```

```json
{
  "schemaVersion": 1,
  "results": [
    {
      "id": "skill-forge",
      "kind": "skill",
      "name": "Skill Forge",
      "description": "Creates portable skills",
      "source": "developer-workflows",
      "scope": "global",
      "targets": ["codex"],
      "status": "installed"
    }
  ],
  "totalResults": 1,
  "truncated": false
}
```

Search returns at most 100 deterministic results. When more components match, `truncated` is `true` and Raycast asks the user to narrow the query instead of accepting an unbounded response.

Create a skill draft:

```console
agent-tooling request create-skill --provider codex --scope global \
  --targets codex --instruction-stdin --json
```

The instruction is supplied on stdin—not in argv, logs, or a deep link. A project-scoped request also passes `--project PATH`.

The skill-creation request returns:

```json
{
  "schemaVersion": 1,
  "request": {
    "id": "a82c55d2-5454-4bde-8b91-32b934667871",
    "state": "pending-review"
  }
}
```

The helper stores only a bounded pending request. It must not create a package or mutate client state while the UI is running. Agent Tooling resolves the opaque request and performs generation, review, planning, and approved execution through its single operation engine.

## Security model

- Child processes use an executable plus argument array with `shell: false`.
- The helper is resolved inside the installed app bundle unless the user explicitly configures an override.
- Output, runtime, and error size are bounded; timed-out process groups are terminated.
- Skill instructions travel over stdin and are explicitly redacted from failures.
- Deep links contain navigation state or an opaque UUID only.
- The Insights shortcut contains no chat content, search terms, or analysis data; it opens `agent-tooling://insights` and leaves scanning controls in the app.
- The extension does not access the Keychain, provider tokens, or package credentials.
- Raycast background work never installs, syncs, or generates content.

Publishing is a separate, explicit action. The extension is licensed under MIT as required by the public Raycast Store; the desktop app may use a different license.
