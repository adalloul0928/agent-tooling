# Checkup and setup review v1

Status: implemented.

## Purpose

Checkup looks at how this Mac's AI assistants are set up, has the person's own
assistant read that audit, and presents the result as reviewed actions a person
takes one at a time. The audit is deterministic facts; the review is the
assistant's reading of those facts. Nothing is a free-form command, and nothing
changes a client's files without going through the app's reviewed operation
path.

## The model

`SetupAuditor.audit` (`SetupAudit.swift`) turns the device scan plus a bounded
look at the folders it named into a `SetupAuditReport`: `SetupFinding` rows and
per-client `HeldCounts`. A `SetupFinding` has a stable id (a hash of kind,
client, and subject so a dismissed finding stays dismissed), a `Kind`, a
`Severity`, redacted `evidence`, and a list of `SetupAction`. Every `SetupAction`
maps to an existing reviewed path: `adoptSkill`, `removeSkillCopy`,
`removeBrokenLink`, `reinstallPlugin`, `pruneStalePluginCache`,
`inspectMCPServer`, `disableMCPServer`, `locateTool`, `checkClient`,
`manageMCPServer`. `changesFiles` is false only for an inspect, a locate, or a
check.

`SetupReviewService.run` (`SetupReview.swift`) runs the assistant pass over an
audit and returns a `SetupReview`: a `summary` and prioritized
`SetupRecommendation` rows. Each recommendation carries a
`SetupRecommendationProvenance` (`audit` by finding id, `investigated` with the
source read, or `opinion`) and a `SetupRecommendationAction` (`take` an audit
action by index, `setSetting`, `installPlugin`, `disableMCPServer`, or
`readOnly`).

`CheckupItem` (`CheckupTriage.swift`) is one row on the screen, sorted into three
buckets: `fix` (audit and assistant agree and the app can do it), `decide`
(needs a person or opens a screen), and `fine` (leave alone). Grouping collapses
many findings into few decisions.

## Behaviour

The pipeline is audit then review then one reviewed action at a time:

1. `SetupAuditor.audit` reads the scan observations and the named folders. It is
   deterministic: broken skill links, missing plugin installs, duplicate skills
   in a client, unmanaged skills, unreachable MCP commands, stale plugin caches,
   unavailable tools, never-checked clients, skills without a `SKILL.md`, and
   servers configured several times. It reads only; it runs the same way every
   time.
2. `SetupReviewService.run` renders a prompt (the findings with their ids and
   offered actions, held counts, and redacted digests), stages a request folder,
   runs one assistant command with the prompt on standard input, and parses one
   JSON document held to `responseSchema`. On parse, a recommendation naming a
   finding or an action index that does not exist is dropped, not guessed.
   Purpose is `setup`, `checkup`, or `clientReview`; only `clientReview` is
   allowed the web.
3. `CheckupTriage` buckets the result. A row's primary button runs its actions,
   or opens a screen, or dismisses. Each file-changing action runs through the
   app's reviewed operation path and is backed up or moved to the trash, never
   deleted.

## Safety boundary

The audit never changes a client's file and never runs a client's command; it
reads configuration and the skill folders listed in
`SetupAuditor.standaloneSkillRoots`. The review command is a fixed shape
(`SetupReviewCommandShapes`): Claude Code in `-p` plan mode with Read scoped to
the assistant config folders (`.claude`, `.codex`, `.agents`, `.kiro`,
`.gemini`, `.aim`) and Bash, Edit, Write, and Task disallowed; Codex in
`exec --ephemeral --sandbox read-only` with plugins, hooks, and apps disabled.
The web (`WebSearch`/`WebFetch`, Codex `--search`) is added only for a client
review. Each command is checked by `OperationCommandPolicy` before launch; a
command that does not validate raises `commandRefused` and does not run. On
apply, `installPlugin` and `disableMCPServer` identifiers are validated by
`OperationCommandPolicy.isSafePluginIdentifier` / `isSafeMCPIdentifier`;
`setSetting` goes through the configuration adapter. Evidence and investigated
sources are redacted through `SensitiveValueRedactor`.

## What the UI shows

Checkup (`CheckupView.swift`) shows the triaged rows with their buckets, each
with the one thing to do about it behind a disclosure.

## Tests

- `SetupAuditTests.swift` — the deterministic findings and their actions.
- `SetupReviewTests.swift` — command shapes, prompt, and the bounded conversion
  of an answer, including dropping unknown finding and action references.
- `CheckupTriageTests.swift` — bucketing and the primary action per row.
- `CheckupSectionRenderTests.swift` — the rendered screen.

## Not covered

The review supports only Claude Code and Codex. The audit's folder reads are
bounded and skip anything oversized or unreadable. No cross-Mac audit: Checkup
inspects only the Mac it runs on.
