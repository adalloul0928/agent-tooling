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
`manageMCPServer`, `applyAccountChoices`, `openAccountSite`, `openAccounts`.
`changesFiles` is false only for an inspect, a locate, a check, or opening an
account's page or the Accounts tab.

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
   servers configured several times. A server an app reports through its own
   listing (Codex's `mcp list`) that its configuration also holds is that one
   definition, set up by hand, so it counts toward "configured separately in N
   apps"; a server the library manages, Agent Tooling's own connection among
   them, never does, and that connection is left out of the per-app counts in
   the apps this Mac set it up for. It reads only; it runs the same way every
   time. `AccountAuditor` adds the account findings from a light read of each
   client's sign-in: not signed in with the subscription, a shell variable that
   replaces the sign-in, shared account choices not followed, account
   connectors that need attention, and an account that differs from the one
   another Mac publishes. See
   [account surfaces](account-surfaces-v1.md#checkup-and-home).
2. `SetupReviewService.run` renders a prompt (the findings with their ids and
   offered actions, held counts, and redacted digests), stages a request folder,
   runs one assistant command with the prompt on standard input, and parses one
   JSON document held to `responseSchema`. On parse, a recommendation naming a
   finding or an action index that does not exist is dropped, not guessed.
   Purpose is `checkup` or `clientReview`; only `clientReview` is allowed the
   web. Conversation summaries go with a checkup only while this Mac allows
   the weekly review, asked again once they are read, at most
   `SetupReviewPrompt.maximumDigests` (40).
3. `CheckupTriage` buckets the result. A row's primary button runs its actions,
   or opens a screen, or dismisses. Each file-changing action runs through the
   app's reviewed operation path and is backed up or moved to the trash, never
   deleted.

## When it runs

- **On open.** The shell's launch work runs the audit
  (`WorkspaceSetupSession.runScheduledAudit(allowsScan:)`) unless it opened
  straight from the setup stage, which has just audited, and it may check the
  apps first only when Check my apps on open is on. See
  [Launchpad setup](launchpad-setup-v1.md#what-the-shell-may-start).
- **On the setup stage.** `audit(scansIfUnchecked: false, asksLoginShell:
  false, readsAccounts: false, extraFolders:)`: no scan, no login shell and no
  sign-in read, so it reads nothing the person was not shown; bare commands
  are looked for in the fixed folders every child searches plus the tool
  folders the stage found. It runs after the read is committed, after a join,
  after an install's re-check, and as Done appears when the library, the
  check or the sign-ins moved. A difference from another Mac's accounts is
  never counted there.
- **The weekly review.** `runScheduledReviewIfDue(consent:)` runs when this
  Mac allows the weekly review, an assistant can run it, the last review is
  more than a week old and the last attempt more than a day old
  (`isReviewDue(consent:now:)`), so a failed review is tried again a day
  later. Once started it runs to its answer; turning the review off stops it
  (`cancelScheduledReview`). The audit and the review keep separate
  generations, so a new audit never drops a review under way.

## Safety boundary

The audit never changes a client's file and never runs a client's command; it
reads configuration and the skill folders listed in
`SetupAuditor.standaloneSkillRoots`. The review command is a fixed shape
(`SetupReviewCommandShapes`): Claude Code in `-p` plan mode with Read scoped to
the assistant config folders in the app order (`.codex`, `.agents`, `.claude`,
`.gemini`, and `.kiro`), each
rule anchored at the file system's root (`Read(//…/**)`), and Bash, Edit,
Write, and Task disallowed; Codex in `exec --ephemeral --sandbox read-only`
with plugins, hooks, and apps disabled. Glob and Grep are not allowed bare:
they reach the folders through the Read rules. Deny rules, which Claude Code
applies before any allow rule, withhold every store of what was said, typed,
pasted, dictated or attached inside those folders (`withheldFolders` and
`withheldFiles`: `.claude/projects`, `.codex/sessions` and the rest), and the
apps' sign-in and secret files, settings backups, shell captures and logs
(`secretFolders`, `secretFiles`: `.codex/auth.json`, `.gemini/oauth_creds.json`,
`.claude/ide`, `.kiro/crew` and the rest), plus any `.env*`, `*.key`, `*.pem`,
`*.p12`, `*secret*`, `*credential*` or `.vault` under each readable folder
(`secretPatterns`). The prompt names both lists; for Codex, whose read-only
sandbox reaches the whole disk, the prompt is the only guard. Claude Code runs
in the staged request folder and both run with `HOME` set to this Mac's home
folder.
Codex also loads its installed CLI configuration. Disabling plugins and apps
does not disable independently configured MCP servers; the read-only sandbox
restricts shell commands, not those servers. These reviews therefore require
trust in that CLI configuration.

The web is added only for a client review: Claude Code gets `WebSearch` and
`WebFetch` scoped to the apps' documentation hosts (`documentationHosts`);
Codex gets `--search`. The host allowlist applies only to Claude Code's
`WebFetch`; web searches are not host-limited. Agent Tooling fetches the
release notes itself. The shape carries
one argument per rule, so `OperationCommandPolicy` lets this exact shape alone
past its 64-argument bound. Each command is checked by `OperationCommandPolicy` before launch; a
command that does not validate raises `commandRefused` and does not run. On
apply, `installPlugin` and `disableMCPServer` identifiers are validated by
`OperationCommandPolicy.isSafePluginIdentifier` / `isSafeMCPIdentifier`;
`setSetting` goes through the configuration adapter. Evidence and investigated
sources are redacted through `SensitiveValueRedactor`. The account read runs
`claude --version`, `claude auth status --json`, and `codex app-server` limited
to `initialize`, `account/read` and `config/read`, plus one login-shell probe
that reports variable names only. `applyAccountChoices` is the reviewed edit of
`~/.claude/settings.json` or `~/.codex/config.toml` described there; the other
two account actions open a page.

## What the UI shows

Checkup (`CheckupView.swift`) shows the triaged rows with their buckets, each
with the one thing to do about it behind a disclosure.

## Tests

- `SetupAuditTests.swift` — the deterministic findings and their actions.
- `SetupReviewTests.swift` — command shapes, prompt, and the bounded conversion
  of an answer, including dropping unknown finding and action references.
- `CheckupTriageTests.swift` — bucketing and the primary action per row.
- `CheckupSectionRenderTests.swift` — the rendered screen.
- `AccountSafetyAndAuditTests.swift` and `WorkspaceAccountsSessionTests.swift` —
  the account findings, their rows, and Checkup reusing the account read.

## Not covered

The review supports only Claude Code and Codex. The audit's folder reads are
bounded and skip anything oversized or unreadable. Checkup inspects only the
Mac it runs on; its one comparison with other Macs is the account fingerprint
each publishes in its status file.
