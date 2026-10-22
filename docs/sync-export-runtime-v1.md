# Git transport, package export and ToolHive actions v1

Superseded by docs/multi-mac-sync-v1.md for sync; kept for the export section
and as the record of the ToolHive actions, which the app no longer has.

Status: the Git transport, revision-store sync lifecycle and package export are
implemented and fixture-tested, and the Git transport is exercised against real
local repositories. The ToolHive lifecycle actions and their tests were removed
from the app. ToolHive stays read-only inspection, described in
toolhive-runtime-inspection-v1.md. The two-Mac acceptance pilot remains open.

## Git workspace transport

`GitWorkspaceTransport` carries one file — the portable document — inside a
repository the person connected for this purpose. It never synchronizes the
live database, never commits unrelated working-tree changes, and never
force-pushes.

Enrollment accepts only an explicit `https`, `ssh`, `file` or absolute-path
remote with no credentials in the URL, and a branch name Git itself would
accept. A repository with no commits reports no head and no document, which is
different from an empty workspace.

Publishing requires the caller's expected remote head. If the remote advanced,
`remoteAdvanced` reports the actual head and nothing is written; the caller
fetches, merges through `WorkspaceMergeEngine` and publishes the merged
revision. A rejected push is reported the same way rather than retried with
force. Anything in the checkout other than the workspace document stops the
publish: committing someone's unrelated edits is not this transport's business.

Repository access is not end-to-end encryption. Anything published is readable
by anyone with access to that repository.

Tested against real local bare repositories: an empty repository, publish and
read from a second checkout, a rejected push that leaves the other side's
revision untouched, and the full loop where a rejected push is resolved by
merging and publishing the result so both checkouts converge on a two-parent
revision. Two checkouts are not two Macs; the two-Mac pilot remains required.

## Package export

`WorkspacePackageExporter` writes a complete package folder and reports what
each target can do with it. Every byte is carried verbatim: files, resources,
scripts with their executable bit, empty directories, internal links and unknown
vendor files. Nothing is translated between vendors, and no note repairs
anything — an unsupported component or transport is named and the export is left
intact. Re-capturing an exported folder reproduces the same content digest.

An existing non-empty destination is refused rather than merged into. Content
that leaves the package needs no report: `CapturedPackageTree` refuses an
escaping or absolute link, so an export always resolves within itself.

Executable content is named for the reader without being called an
incompatibility. A natively owned package says its own app installs and updates
it, so an export is not an install route.

## ToolHive lifecycle actions

Not in the app. `ToolHiveLifecycleService` offered start, stop and restart, but
nothing in the app called it, and it would have started and stopped workloads
outside `OperationEngine`. It was removed along with its scripted-`thv`
tests and the one live case that drove it. The app offers no start, stop or restart, so a workload is started and
stopped with ToolHive's own tools.

The removed service bound each action to one exact workload and to the state
observed when the action was prepared, and confirmed it by re-reading that
workload afterwards. A clean exit without the expected state was reported as
`ambiguous` and never retried, and a workload that changed between review and
apply was reported as `stalePlan` with no command run.

Replacement, upgrade and deletion were never offered. The inspected workload API
exposes no conditional-mutation contract, so this app cannot promise its view is
current when it writes; those actions stay in ToolHive's own tools until such a
contract exists.

Read-only inspection stays, as toolhive-runtime-inspection-v1.md describes.
`status` now distinguishes an absent `thv` from a failing command, matching
`version`, so a caller can offer installation instead of an error.

## Sync lifecycle

`WorkspaceRevisionStore` now records revisions received from another device
without ever making them the head, resolves the newest common ancestor from its
own stored history, commits a merged two-parent revision against an expected
local head, and fast-forwards onto a recorded descendant. A fast-forward keeps
the shared revision's own identity, so two devices that agree settle on one head
instead of each minting a new one and chasing the other. Ancestry walks are
bounded so a long or damaged history cannot stall a read.

`WorkspaceSyncCoordinator` runs one pass: read the remote, record it, find the
ancestor, merge, commit locally, then publish. Local intent is never replaced by
a remote revision, and nothing is published until the merged revision is durably
committed here. A merge that still carries conflicts stops the pass with nothing
committed and nothing pushed. A remote that moved during the pass leaves the
merged revision committed locally to publish next time; nothing is forced.
Repeating a pass with the same key returns its original result.

Arriving shared intent is not evidence that any native client file changed.
Deployment remains a separate reviewed step.

Tested with two isolated stores and two checkouts of one real local repository:
publish, adopt whole, independent edits on both sides converging on one head,
and a conflicting rename that commits and publishes nothing. Two stores are not
two Macs; the two-Mac pilot remains a required gate.

## Still open

The scheduler, enrollment flow, devices UI, conflict inbox and package export
session are implemented (see multi-mac-sync-v1.md and
`WorkspacePackageExportSession`), and the encrypted-folder transport exists
(`EncryptedFolderWorkspaceTransport`, encrypted-folder-sync-v1.md). What remains
open is the sync outbox and recovery journal and the two-Mac acceptance pilot.
With the ToolHive actions removed, nothing here needs qualifying against a live
ToolHive; live qualification of the read-only inspection is tracked in
toolhive-runtime-inspection-v1.md.
