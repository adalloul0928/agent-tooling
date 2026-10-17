# Workspace merge engine v1

Superseded by docs/multi-mac-sync-v1.md for sync; kept for the merge rules.

Status: the pure three-way merge is implemented and fixture-tested. The
transport, revision-store merge commit, scheduler, enrollment and conflict inbox
now exist (see multi-mac-sync-v1.md); the two-Mac acceptance pilot is pending.

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
| Both Macs made one item follow a repository, each through its own subscription | `subscriptionOwnerCollision` conflict; the subscription the merged authority cannot name is set aside, and each side's repository is kept |
| One Mac made an item follow a repository while the other changed its content | `subscriptionContentMismatch` conflict; the lock's approved digest is put back, so the result never claims a publisher published a personal edit |
| An item that no longer follows anything still has a subscription | The subscription is dropped, like a contribution for an item nobody kept |
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

## Still open

Common-ancestor discovery, revision-store merge commits, `GitWorkspaceTransport`,
enrollment, the scheduler and the conflict inbox UI are all implemented and
covered by multi-mac-sync-v1.md. What remains open is the sync outbox and
recovery journal, and the two-Mac acceptance pilot.
