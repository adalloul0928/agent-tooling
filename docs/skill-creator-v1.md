# Skill creator v1

Status: implemented.

## Purpose

The skill creator runs the person's own signed-in Claude Code or Codex to draft
an Agent Skill through a conversation, one turn at a time, inside an isolated
staging folder. It produces a review-only package. It never installs: the
drafted skill is adopted into the managed library through the normal reviewed
path.

## The model

`SkillCreatorClients.swift` holds the client adapters and command shapes.
`SkillCreatorClientAdapter` has one implementation per driveable client:
`ClaudeSkillCreatorAdapter` and `CodexSkillCreatorAdapter`. Gemini CLI and Kiro
CLI have no adapter (`unsupportedClient`). Each adapter builds its start and
continue argument lists and parses one turn's output into a
`SkillCreatorParsedTurn` (reply, session id, notes, failed).

`SkillCreatorCommandShapes` is the single source of the exact argument lists, so
the adapters that build them and the policy that admits them cannot drift:

- `claude(sessionID:resuming:)`: `-p --output-format json`, a session id,
  `--permission-mode acceptEdits`, `--strict-mcp-config`,
  `--setting-sources user`, with Bash, WebFetch, WebSearch, Task, and
  NotebookEdit disallowed.
- `codexStart(requestDirectory:)` / `codexResume(threadID:)`: `exec --json`,
  plugins, hooks, apps, and remote plugins disabled, sandbox `workspace-write`
  confined to the request folder, keeping the person's Codex config for its
  sign-in.

`SkillCreatorLocator` reports `SkillCreatorAvailability` per client by reading
Claude Code's installed-plugin and known-marketplace files or checking Codex's
built-in skill creator, with a `missing` case carrying the exact install
sequence as `SkillCreatorInstallCommand` values.

`SkillDraftService` (`SkillDraftService.swift`) is the actor that drives a
conversation. `SkillDraftConversation` keeps the exchange beside the staged
draft (its `sessionID` is the resume handle, not a credential), and
`SkillDraftResult` is the drafted package: name, description, package and skill
URLs, manifest, markdown, files, and a `fingerprint`.

## Behaviour

A conversation runs one turn at a time. `SkillDraftService` picks the adapter
for the client, stages a request folder, writes the prompt to standard input,
runs one fixed-shape command, and reads the draft back from the folder. A turn
that only clarifies writes no package, so `draft` is nil; a half-written package
reports a `draftIssue` rather than failing. Later turns resume by the reported
session or thread id. Claude Code's refused-tool denials and Codex's own
configuration warnings are surfaced as notes, so a reply that claims a change
the sandbox refused is not taken at face value.

The service has no install or apply operation. The caller shows the returned
`SkillDraftResult` and uses the reviewed operation path to adopt it into the
library.

## Safety boundary

Every command the creator runs is one of the fixed `SkillCreatorCommandShapes`,
checked against `OperationCommandPolicy` before launch; a command that does not
validate does not run. Prompts travel on standard input, never on the command
line, because argv is visible to every process and the prompt is the person's
words. Writes are confined to the staged request folder: Claude Code's
`acceptEdits` applies only inside the working directory and Bash and the web are
off; Codex's `workspace-write` sandbox is confined to the folder and plugins,
hooks, and apps are disabled, and a resumed thread restates the sandbox so it
cannot gain what the first turn lacked. The request folder path is validated
(`isRequestDirectoryPath`: absolute, normalized, under home, last component a
`request-<uuid>`). The service writes no client file and installs nothing.

## What the UI shows

The creator opens from a sheet; a draft, once adopted, appears in Library.
Insights recommendations can start a draft.

## Tests

- `SkillDraftServiceTests.swift` — turns, draft read-back, session resume, and
  the no-install contract.
- `SkillDraftLiveTests.swift` — against a real client when available.
- `SkillCreatorRenderTests.swift` and `Fixture+SkillDraft.swift` — the sheet.

## Not covered

Only Claude Code and Codex can drive the creator. The service drafts and reads
back; adoption into the library is a separate reviewed step. No cross-Mac
drafting.
