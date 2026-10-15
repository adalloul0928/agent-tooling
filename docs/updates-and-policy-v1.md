# Updates and update policy v1

Status: implemented.

## Purpose

This Mac looks for newer versions of what its library holds, compares each item
with its source, and installs a found update by a per-kind policy. The same
policy governs assignments that arrive from another Mac through sync. A check
never changes anything; installing an update takes the ordinary reviewed install
path.

## The model

`UpdatePolicy` (`DeviceApplicationState.swift`) holds one `UpdateCheckCadence`
and three `UpdateInstallPolicy` values, one per `ToolingItemKind`:

- `cadence`: `onOpen`, `daily`, or `manual`.
- `skills`, `plugins`, `mcpServers`: each `automatic` (install, leave a receipt,
  say so) or `ask` (show it and wait for a press). Every kind defaults to `ask`.

`policy(for:)` maps a `ToolingItemKind` to its `UpdateInstallPolicy`.
`UpdateCheckCadence.isDue(lastChecked:now:)` decides whether a check is due:
`onOpen` is always due, `daily` is due 24 hours after the last check, `manual`
is never due.

The policy lives in `DeviceWorkspacePreferences.updatePolicy` with
`lastUpdateCheck`, both device state on this Mac's own record, read through
`effectiveUpdatePolicy` (the chosen value, else `UpdatePolicy()`). It is not in
the portable document, so another Mac sharing the library decides for itself.

`UpdateAvailability` (`UpdateAvailability.swift`) is the verdict of one
comparison: `upToDate`, `updateAvailable`, `unknown`, `notChecked`,
`checkFailed`, or `sourceMissing`. `upToDate` is reached only when a source and
an installed revision were actually compared.

## Behaviour

`WorkspaceUpdateSession.checkIfDue` reads the device policy's cadence and runs a
check only when one is due. `check(installingAutomatically:)` compares each kind
with its source:

- Followed skills are compared with their repository. One bounded Git fetch per
  skill through `UpstreamFetcher`; the fetched content's `contentDigest` is
  compared with the library row's digest. A repository that cannot be reached is
  reported for that skill as `checkFailed`, and the rest proceed.
- Native plugins and packages are compared through `PluginUpdateEvaluation`
  against the catalog this Mac kept from Discover, matched by native route
  rather than by name.
- MCP servers are compared with the catalog entry of the same name when one
  exists; a changed listing cannot be applied here.

After a check, `recordUpdateCheck` stamps `lastUpdateCheck`. When
`installingAutomatically` is set, every available entry whose kind the policy
marks `automatic` and whose `cannotUpdate` is nil is then installed without a
press. A button's `check()` passes `installingAutomatically: false`, because a
press is itself the ask.

Installing a skill update runs the library update (`updateStandaloneSkill`) then
replaces the copies this app proved it installed, through
`WorkspaceDeploymentSession.replaceProvenCopies`. Copies this app cannot prove
it installed, or that were edited after install, are left alone; `notice`
reports that they wait on the Apps screen's Review changes. Installing a plugin
update runs the app's own `plugin update` command through the operation
executor's allowlist. An MCP server update is refused from here with a
`cannotUpdate` note pointing at the MCP Servers screen.

Multi-Mac arrivals reuse this policy. `WorkspaceIncomingSession.review` runs
after a sync pass and inspects plan items for assignments that did not originate
on this Mac (`arrivals`). For each, when the kind's policy is `automatic` it
installs through the ordinary one-step path (`deployment.risk` then
`applyDirect`); a plan the risk classifier marks `needsReview` is held in
`heldForReview` rather than applied. Items whose kind is `ask` stay in `waiting`
until `install` is pressed. Arriving intent is never treated as evidence that a
file changed; only first installs are arrivals, not updates or removals.

## Safety boundary

A check reads only: it fetches a repository's content, refreshes the retained
catalog, and compares digests. It never writes to a client during a check.
Skill-update installs run only through the reviewed deployment path, which
copies only from this app's managed staging and refuses a destination this app
cannot prove it owns. Plugin updates run only the app's own recorded update
command through `OperationCommandPolicy`, which accepts a bare allowlisted name
or the exact located executable path and nothing else. The policy and
`lastUpdateCheck` are device-local and never enter the portable document, so no
secret or local decision travels to another Mac.

## What the UI shows

Settings holds the Updates card (`SettingsGeneralView.swift`): a cadence picker,
a Check now button, and one install-policy picker per kind (Skills, Plugins, MCP
servers). Home surfaces available updates with Update buttons. Available plugin
updates also appear on Library. Incoming arrivals from other Macs surface on
Home.

## Tests

- `UpdatePolicyTests.swift` — cadence due-ness, per-kind policy mapping.
- `UpdateAvailabilityTests.swift` — the evaluator's verdicts.
- `WorkspaceUpdateSessionTests.swift` — check, automatic install, held-back
  copies, plugin-update refusals.
- `WorkspaceIncomingSessionTests.swift` — arrival detection, automatic vs ask,
  held-for-review.

## Not covered

No background check off a timer: a check runs on open or on a press. No MCP
server auto-update. No two-Mac acceptance pilot has run against the incoming
path. The automatic install still depends on the reviewed deployment path's own
pending native-consumption gate.
