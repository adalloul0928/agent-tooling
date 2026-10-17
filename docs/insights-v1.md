# Insights v1

Status: implemented.

## Purpose

Insights reads this Mac's own AI-assistant chat history to find recurring work
that no skill yet captures, skills the person has but is not using, and skills
worth improving. A keyword pass runs on the Mac and keeps nothing off it. A
deep dive sends bounded, redacted digests to the person's own signed-in
assistant and asks it for conclusions.

## The model

`LocalConversationScanner` (`LocalConversationScanner.swift`) reads conversation
history for the clients in `InsightScanOptions.clients` and produces a
`ConversationScanArtifact`: per-client `coverage`, `evidence` (skill-usage
attribution), tokenized `messages`, and `digests`. A `ConversationDigest`
(built by `ConversationDigestBuilder`) holds the first few redacted user
messages, the tools and skills that answered, and the project name, every field
bounded and redacted.

`InsightsDeepDive` (`InsightsDeepDive.swift`) is the deep dive's result:
`summary`, `themes`, and `recommendations`. `ToolingInsightsService`
(`ToolingInsightsService.swift`) orchestrates the keyword pass and returns the
report; `scanWithDigests` returns the digests separately because they carry
redacted text the saved report never does.

## Behaviour

The scanner reads, per client, only these paths under the home directory:

- Codex: `.codex/thread_history_1.sqlite`, opened read-only.
- Claude Code: `.claude/projects/**.jsonl` first; when no transcript is
  observable it falls back to `.claude/__store.db`, opened read-only.
- Kiro CLI: `.kiro/sessions/cli/*.jsonl` (or `$KIRO_HOME`), with the sibling
  `.json` for the session title and working directory.

Every read is bounded: a lookback window, a per-client conversation cap, a
per-conversation item cap, a per-item byte cap, a per-file byte cap, and a
total transcript byte budget. Files are enumerated newest first; symlinks are
rejected and every resolved path is confirmed inside the home directory.
`SKILL.md` references and `skill`/slash/`$name` tool calls become usage
evidence. User-message text is tokenized for the keyword recommendations;
digest text is redacted through `sanitizeConversationText` (strips known
container tags, `SensitiveValueRedactor`, and local paths, then caps length).
Trivial conversations (a few words, no tool or skill) are dropped.

The deep dive (`InsightsDeepDiveService.run`) supports Claude Code and Codex
only. It renders a prompt (the task, the person's skills, the digests newest
first within a byte budget), stages a request folder, runs one command with the
prompt on standard input, and parses one JSON document held to
`responseSchema`. Every answer string is re-bounded on parse, so a client that
ignored the schema is still constrained. The run is refused if the command does
not match a known shape.

## Safety boundary

The keyword pass sends nothing off the Mac. Databases are opened
`SQLITE_OPEN_READONLY` with `query_only`; the scanner writes nothing to any
history store. The deep dive is the only path that leaves the Mac, and it sends
only redacted digests to the person's own assistant, never raw transcripts and
never the saved report. The assistant commands are fixed shapes
(`InsightsDeepDiveCommandShapes`): Claude Code in `-p` plan mode with every tool
disallowed; Codex in `exec --ephemeral --sandbox read-only` with plugins,
hooks, and apps disabled, confined to the staged request folder. Each is checked
by `OperationCommandPolicy` before launch; a command that does not validate
raises `commandRefused` and does not run. The request folder is removed when the
run ends. Diagnostics are redacted through `SensitiveValueRedactor`.

## What the UI shows

Insights (`InsightsView.swift`) shows coverage, recommendations, and, after a
deep dive, its summary and themes.

## Tests

- `ToolingInsightsTests.swift` — the scanner's reads, bounds, attribution, and
  keyword recommendations.
- `InsightsDeepDiveTests.swift` — prompt rendering, command shapes, parsing, and
  the bounded conversion of an answer.

## Not covered

Gemini CLI has no scanner or deep dive. The deep dive supports only Claude Code
and Codex. Attribution is a lower bound where a client's history does not record
skill activation. No cross-Mac aggregation: Insights reads only the Mac it runs
on.
