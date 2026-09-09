# Workspace merge engine v1

Status: the pure three-way merge is implemented and fixture-tested. No transport,
revision-store merge commit, conflict inbox or two-Mac pilot exists yet, so this
does not establish working multi-Mac synchronization.

## Contract

`WorkspaceMergeEngine.merge(base:local:remote:writerID:)` combines two portable
revisions against their common ancestor. It is pure: no clock, no filesystem, no
device observation, and no network. Deletion is decided by tombstones and
ancestry, never by absence and never by which Mac wrote last.

| Concurrent change | Result |
| --- | --- |
| Different items changed | Combined |
| Rename on one Mac, content edit on the other | Combined, field by field |
| Aliases, native routes, source paths, repository hints, preset membership | Combined as sets, with each side's removals honored |
| Same scalar field changed to different values | Conflict; the local value is kept so nothing is lost |
| Different content digests from a shared ancestor | `artifactContent` conflict |
| Delete on one Mac, edit on the other | `deleteVersusEdit` conflict; the item stays and the pending removal is **not** recorded as a tombstone |
| Delete agreed by both | Item and its contributions removed; tombstone retained |
| Ownership, source locator, ref or role changed on both | `ownership` / `sourcePolicy` conflict |
| Approved upstream revision or content changed on both | `subscriptionLock` conflict |
| Different desired enable/disable, or presence versus removal | `assignmentEnablement` conflict |
| Two items colliding case- or Unicode-equivalently at one destination | `destinationCollision` conflict |
| Project renamed on both | `projectField` conflict |
| No common ancestor | Both histories combined; nothing is inferred as deleted |
| A newer document format on either side | Refused whole, with `unsupportedVersion` |

`nil`, `true` and `false` desired-enablement remain three distinct requests; a
`nil` is never read as agreement with an explicit choice. Preset membership uses
a three-way set merge, so one Mac adding a member cannot resurrect what the other
removed.

The result is canonicalized and validated against the workspace contract. A
result that fails validation is withheld entirely rather than partially applied.
Merging the same pair in either direction produces the same artifacts,
contributions and parent revisions. Two identical revisions produce one parent,
not a duplicated one.

Contributions for items no side kept are dropped, since they have nothing to
deliver. A result that still carries conflicts must not be applied; the caller
resolves them and merges again.

## Not yet implemented

Common-ancestor discovery from stored history, merge commits in the revision
store, the outbox and recovery journal for sync, `GitWorkspaceTransport`,
enrollment, the background scheduler, the conflict inbox UI and an actual
two-Mac convergence pilot all remain open (Y2–Y4).
