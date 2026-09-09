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

Nothing calls the native-plugin or managed-MCP command bridges from this path
yet, and no packaged pilot or native consumption test has run. Installing a file
is not the same as an agent finding and using it; that check remains a separate
gate.
