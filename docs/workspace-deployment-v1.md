# Workspace deployment v1

Status: intent becomes a reviewable plan, approved content is staged, and the
existing reviewed operation path installs it. Verified against a disposable home
in tests. No live client on this machine has been written to, and no packaged
pilot or native consumption check has run.

## Planning

`WorkspaceDeploymentPlanner` turns committed assignment intent into one list of
what would change on this device and an explicit list of what would not. It is
pure: no filesystem, no client, no network. Producing an item is a request for
the reviewed operation path, not evidence of installation.

Nothing is assumed already installed. A destination is skipped as already
present only from an observation that measured matching content; present but
unmeasured becomes an update with an unknown starting point. Content must be
proved held by the caller, so an item whose tree the store cannot read is
excluded rather than planned. A native package needs a reviewed install route
and cannot carry an on/off request, because that belongs to its own app. A
bundled member is never planned on its own, and independent reasons for one
destination all survive.

Every exclusion is named: tracked ownership, missing content, bundled member,
missing native route, unsupported adapter, needs review, already present.

`WorkspaceApplicationService.deploymentPlan` reads the committed snapshot and
counts only content the central store can actually read as held. Planning
changes no revision, assignment or receipt.

### Where capability evidence comes from

A destination is admitted only when this device holds exactly one supported
`TargetCapabilityEvidence` record matching its surface, installed client
version, adapter contract version, component, transport and scope. That record
is **derived from this Mac's own scan** by `TargetCapabilityEvidence.derive`,
and it is written in exactly two places: `WorkspaceFirstRun.prepare` writes it
alongside the first observations, and every "Check apps" writes both
the fresh observations and the freshly derived evidence as one device-only
change. A workspace whose evidence is empty is therefore repaired by its next
check rather than by a migration.

Nothing is probed for it. Each record restates the scan (the client answered
its own `--version`; the adapter declares what it accepts) or something already
written down (the install register's recorded commands, the shapes the two
command planners can express):

- **Skill** — one record, no transport, scopes `user` plus `project` when the
  adapter declares project scope. Supported: placing a skill is a file copy the
  capture layer already resolves a destination for.
- **Package** — one record, no transport, scope `user`, because
  `WorkspaceNativePluginCommandPlanning` builds only the user-scoped command.
  Supported only when the adapter says the client installs packages of its own
  **and** `NativePluginInstallRegister` holds a command for it; otherwise
  unsupported with a reason a screen can show. Gemini is unsupported today: its
  adapter is willing, but nobody has read an install command out of its help.
- **Connection** — one record per transport
  `WorkspaceManagedMCPCommandPlanning` can actually spell for that client, at
  the scopes that client honours. Both `HTTP` and `stdio` for Claude Code,
  Codex CLI and Gemini CLI; scopes `user`, `project`, `local project` and
  `workspace` for Claude and Gemini, and `user` alone for Codex, whose MCP
  command has no scope flag. Managed, account and session appear nowhere: the
  planner produces no working directory for them.
- **Connector** — no record. Nothing here installs one.

A client whose command did not answer, or answered without a version, produces
no record at all. The planner's existing "no dependable record of what the
installed app supports" exclusion is the honest outcome there; inventing a
record would turn "nobody knows" into an install claim. Two reports about one
client produce none either, since choosing between them would be a guess.
Derivation is pure and sorted, so one scan always yields one device record.

### Where "already there" comes from

Presence is measured, never assumed, and it is measured differently for the two
kinds of thing a plan can hold:

- **Copied content** (skills and the like) — the destination folder is read and
  its digest compared with the approved version, by `measure`.
- **A client's own packages** — the client's own report from the last check,
  `TargetObservation.pluginMetadata`, matched by the route's external plugin ID
  and the scope the client recorded. Claude Code writes `User`, `Project` or
  `Local`; Codex records no scope of its own and the scan writes `This Mac`,
  which is the account. A package installed for one project does not satisfy an
  account-wide assignment. Until this existed every package a client already
  held was planned as an install, forever: the folder check found nothing under
  a skill root and called that absent.

A client that was never checked has said nothing, and "not observed" stays
distinct from "observed absent".

### Which executable the executor runs

`ClientExecutableLocator` looks in the recorded install locations only, tests
that what a candidate leads to is a runnable file, and returns the candidate by
the tool's own name (`~/.local/bin/claude`, say) rather than the file behind it,
which Claude Code's installer names by version and the ChatGPT app keeps inside
its bundle. Plans carry that located path, so an app launched outside a login
shell still reaches the tool. `OperationCommandPolicy` accepts a bare name from
its allowlist or exactly the path the locator returns for that client, and
nothing else; the process runner follows the link again at launch.

A plan step no command can be built for — the client's tool was not found, no
command is recorded for that client, or its records do not line up — stays on
the review sheet marked as not running, and the Install button counts only the
steps that will.

## Staging and applying

`WorkspaceDeploymentOperations.stage` writes the approved trees into a staging
root that must be inside this app's own managed library — the executor refuses
to copy content from anywhere else, which is what stops a deployment installing
whatever happens to be lying around. Each staged folder carries its own
fingerprint, and the executor recomputes it before committing, so a staged
folder edited between review and apply fails instead of installing.

`operations(for:)` produces one reviewable operation per client and scope, so a
person approves what happens to each place rather than one undifferentiated
batch. Native package installs and managed connections are deliberately not
staged as folder copies; they have their own command bridges with their own
evidence requirements.

A project deployment needs its folder on this Mac; without one it is refused
rather than routed somewhere plausible.

## Reviewed applies

A review (the setup stage's panel, and the shared review sheet) installs
exactly the plan it showed:

- `WorkspaceDeploymentSession.applyReviewed(_ plan:, basedOn revision:,
  onStep:) -> ReviewedApplyOutcome` returns `.applied(DeploymentOutcome)`,
  `.stale` when the store's head moved since the plan was read (the caller
  passes the revision it read the plan at), or `.notRun(reason)`. It does not
  plan again: its caller re-checks the apps whose own tool ran
  (`device.refresh(only:)`, merged by surface), then prepares, then audits.
- One serial work queue is shared by `prepare`, `apply(only:)`,
  `applyDirect`, `applyReviewed` and linking, so a review never runs beside
  another write to the same plan.
- Operations are built in the app order: copied content, then plugins, then
  connections, each step mapped to its install key so the review can draw it
  running and done.
- `OperationExecutor.execute(_:onStep:)` reports each step as it starts and
  ends (`OperationStepEvent.started(UUID)`, `.finished(OperationStepResult)`),
  awaited in order. A step that has begun always finishes; a stopped plan
  stops between steps, and its receipts are written.
- Held-back steps (`heldBack(in:)`) are drawn in place as left alone and never
  counted: not in a review's title, not in `pendingItems` or `pendingCount`.
  A step whose command cannot be built reads "Will not run · <reason>". A
  destination already as approved (`.alreadyPresent`) is never a review
  reason.

### Replacing a registration (D30)

A managed connection an app already registers under its name is matched by
command (`WorkspaceDeploymentObservation.connectionMatches`): `nil` for an
address binding, `false` for a stdio binding the app starts some other way.
A mismatch is configured again as a replacement only when Agent Tooling can
prove it made that registration: a succeeded "Set up <name>" step in a
`.configureMCP` receipt for that app (`provenConnections(in:)`). The
replacement is modelled in the command plan (`preArguments`, with the old
command in `replacedCommand`) and runs as its own plan, "Replace <name> in
<App>": "Remove the old <name>", which stops the plan if it fails, then "Set up
<name>". Kiro CLI's add takes `--force` instead. A registration Agent Tooling
cannot prove it made is left alone and gets no command at all.

### Taking Agent Tooling's own connection out (D10)

Agent Tooling's own connection comes out of an app the person unticks on Let
your apps ask (a revisit or a rerun), and nowhere else is it planned. The
planner emits `.removeManagedConnection` for it at an app's user-scope
destination on this Mac only when all three hold:

- no contribution of the connection that reaches this Mac asks for it there,
  read from the contributions themselves, so an app whose request cannot be
  resolved right now (no version) still asks;
- the app registers it for the person and starts it with this Mac's binding
  (`connectionMatches == true`), so one pointed somewhere else since stays;
- `provenConnections` shows Agent Tooling set it up in that app.

The session observes the own connection in every checked app that lists it,
asked for or not (`reportedManagedConnections`), and reads the receipts before
planning whenever such a removal is possible. The step runs the app's own
`mcp remove` at user scope (Kiro CLI too, by `--name`), in an operation of its
own after the app's adds: "Remove 1 connection from <App>", step "Remove
<name>". `provenConnections(in:)` reads receipts oldest first, and a later
succeeded "Remove <name>" ends the proof an earlier "Set up <name>" gave, so a
registration somebody makes under the name afterwards is theirs. A scoped plan
leaves removals out unless asked (`plan(for:includingRemovalsOf:)`); Let your
apps ask's review names the connection there, and the shared review sheet
lists every removal. The risk classifier counts it as a removal, and the
review says Apply rather than Install.

## The Install surface

An **Install** destination shows what would change in this Mac's apps, what
would not and why, and what happened after applying. Preparing reads: it
captures this Mac's real destinations, measures what is already at each one,
and asks the service for a plan. Nothing is assumed — a destination reported as
already correct was actually read and compared.

A read-only workspace can look but cannot apply. After applying, the surface
re-reads, so what it shows next reflects what actually happened rather than what
was asked for.

## Removal

Withdrawing an assignment offers to remove the copy **this app installed**, and
only that. Three separate things must all hold: the app's own ledger or receipts
prove it put the folder there, the folder was measured just now, and its content
still matches what was approved. Missing any one of them leaves the folder
exactly where it is.

`removeManagedDirectory` is the executor's only removal primitive. It refuses a
destination without proven ownership, refuses one whose content no longer matches
what was approved — so a folder someone edited is reported, never deleted — and
clears the ledger record afterwards so a later check does not report a removed
folder as still installed.

Because a withdrawn item has no assignment left to point at its destination,
preparing also captures the places this Mac could hold something and measures
those, not only the places currently asked for.

## Not yet implemented

No packaged pilot or native consumption test has run. Installing a file is not
the same as an agent finding and using it; that check remains a separate gate.
No step removes any managed connection but Agent Tooling's own from an app.
