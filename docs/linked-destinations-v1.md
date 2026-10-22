# Linked external destinations — contract v1 (S4b)

Status: implemented and fixture-tested, including a real install into a folder
outside the client's own directory. No packaged pilot.

## What it is

A destination the workspace already describes — "Codex, user scope" — written to
a folder the person named instead of that client's own folder. The portable side
does not change and is identical on every Mac; only this device knows where it
resolves. That is why the binding is device state and never portable bytes.

## The two rules that make it safe

**One path, one role.** A folder registered as a destination cannot also be a
source root, in either direction of containment. A source root is where authored
bytes come *from*; a destination is where reviewed bytes *go*. One folder being
both is how a deployment quietly becomes an edit to someone's repository.

**Apply-once never clobbers.** `noClobberApplyOnce` writes only where nothing is
already present under that tool's name. Anything already there is left exactly as
it is and the install stops and says so. This app did not put it there and has no
basis for deciding it is disposable.

The one exception is proof: when the managed install ledger shows this app put
that exact folder there, it may update it. Without that, a folder existing is
precisely what the no-clobber rule looks for, and updating a linked destination
would be impossible. The ledger is what tells the two cases apart.

## What the executor does and does not allow

`OperationExecutor` refuses to write outside its managed library or a supported
client skill folder. Linked destinations do not remove that rule; they add named
folders to it. `linkedDestinationRoots` is an explicit list a caller passes in,
and inside each one every other check still applies:

- the folder must exist and must not be a symlink
- the item's own folder name is checked exactly as it is everywhere else, so a
  name that climbs out is refused rather than resolved
- the copy is still bound to the fingerprint that was reviewed
- each registered folder is its own anchor, so nothing lands outside it

Registering one folder does not open the folder beside it. Both are covered by
tests.

## Removal

Removal is receipt-backed and unchanged: `removeManagedDirectory` requires
proven ownership and a content match against what was approved. A folder someone
edited is reported, never deleted. Unregistering a binding touches nothing at
that path — it says where future installs go, not what happens to what is there.

## Not covered

No packaged pilot. Nothing has been tested against a network volume that goes
away mid-write, or against a folder a file-sync service is also touching. The
`reviewedReplacement` policy exists in the model and is reachable through the
API, but no surface offers it: everything the app registers today is apply-once.
