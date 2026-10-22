# Multi-Mac sync — contract v1

Status: implemented; two-Mac acceptance pilot pending (see "Pilot" at the end, run by hand
on two real Macs).

## Shape

Peers, not a hub. Every Mac has a complete workspace of its own: the shared
document, its own device state, its own content store, its own receipts. Macs
converge through a shared Git repository that is a mailbox, not an authority:
each Mac reads what is there, merges in its own engine, and publishes on top of
exactly what it read. Nothing is ever force-pushed; a Mac that finds the remote
moved merges again. No Mac depends on another being awake.

Each Mac scans itself, plans against its own disk, approves and applies its own
plans. What travels is *intent* (what should be where) and *content* (the bytes
of skills this library authored). What never travels is this Mac's observations,
destinations, project folders, receipts, keys, or credentials.

## Repository layout

```
<branch>/
  workspace.json                 the portable document (one file, one merge unit)
  content/<algorithm>/<digest>/  one immutable tree per content digest
      <the package files, verbatim>
  status/<deviceID>.json         one Mac's published summary (read-only to others)
```

**`workspace.json`** is merged by `WorkspaceMergeEngine` per record (artifacts,
assignments, projects, presets, devices, account choices…). Its revision history
is kept in every Mac's store; Git's history is a second copy, not the one the
engine reads.

**`content/`** is content-addressed and immutable. A tree is written once under
its digest and never modified; two Macs writing the same digest write identical
bytes, so there is no conflict class here. The document references content by
digest, exactly as a single Mac's content store already does. A Mac that reads a
document naming a digest it does not hold copies the tree into its own content
store on the same pass; only then is the item plannable there. Trees are
verified against their digest on import; a tree that does not match is refused
and reported, never trusted.

Only content the library *authored or adopted* (`centralPersonal`) is published.
Followed skills (`centralUpstream`) are re-fetched from their repository on
each Mac; native plugins are installed by their app; tracked-only items have no
content. Publishing happens with the document, in the same commit.

**Content report.** Each pass records a `ContentReport` of what it moved
besides the document: `imported` (trees this Mac copied in from the remote),
`published` (trees this Mac added to the remote, listed only after the remote
accepted the push), `unpublished` (trees this Mac owes the remote but a side
publish failed on this pass; the documents are in step and the next pass
retries), and `missing` (trees the document names that neither side could
supply).

**`status/<deviceID>.json`** is written only by the Mac it names, after each
scan or apply. It is a small summary — device name, last scan, what is installed
per app, what is pending, and per account the sign-in method, plan, an account
fingerprint and item counts — for other Macs to *show*. The fingerprint is a
salted digest compared only for equality; no address, account name or item list
is published (see [account surfaces](account-surfaces-v1.md#other-macs)). It is
never read back into the writer's own state and never merged; the newest commit
wins trivially because only one writer exists per file. A missing or stale file
is shown as "last seen …", never as an error.

Anything else in the checkout stops a publish, as today.

Every Git call, including the `git archive` that extracts a content tree, runs
through one hardened invocation: `core.hooksPath=/dev/null`,
`core.fsmonitor=false`, `core.quotePath=false`, `--no-optional-locks` and
`--no-pager`. Working-tree status is read as porcelain v1 `-z` records (a rename
or copy carries its source as a second NUL-terminated field), and the status
listing at a head is filtered to `status/*.json` and then bounded to 256 files.

## Device identity

A device ID is random, minted when the store is created, and never derived from
the hostname: a renamed Mac is the same Mac. The shared document carries a
**device registry**:

```
devices: [{ id, name, receivesSharedAssignments, registeredAt, lastSeenAt }]
```

- `name` defaults to the Mac's computer name and is editable from any Mac.
- `receivesSharedAssignments` (default `true`) is the one bit that makes a
  deliberately limited Mac possible; see "Scope".
- `lastSeenAt` is stamped by that Mac on each pass. It is informational.

A device is **registered** when it joins (below) or when a pre-registry store
first syncs. A device is **retired** by a person from any Mac: the record is
marked `retiredAt`, kept for history, and its name may not be reused silently.
Assignments that name a retired device keep naming it; the planner ignores
them, and the Library labels them. Retiring never deletes files anywhere.

## Joining

Joining is the first-run path for a second Mac. The person points the fresh Mac
at the repository; the app reads the document there, initialises its own store
with that **workspace ID** and a **fresh device ID**, scans this Mac for its
device state, registers the device in the document, and publishes. Before the
join commits nothing is written on this Mac but the dedicated checkout.

The joined store's history starts at the remote head: the first revision this
Mac holds is the one it adopted, so ancestry queries stop there. That is
sufficient because merges need only the newest common ancestor, and both Macs
hold every revision from the join onward.

A Mac that already has a workspace cannot join another; it would have two
sources of truth. The app says so and offers nothing destructive.

### Before joining: the preflight

`GitRemotePreflight.run(remote:branch:deviceName:expectingWorkspace:thisDevice:
runner:scratch:progress:)` is what the setup stage's Join (J01) and Your other
Macs (S17) run as an address is typed. Address and branch problems return
before anything runs. Then, in a scratch folder removed on return: `xcode-select
-p` before Git ever runs, `git --version` (check 1, *Git is installed*), `git
ls-remote` for the branch (check 2, *the host answered*: it separates an empty
repository from one that cannot be reached), a shallow fetch of its head
(check 3, *holds a library*), and the library's record read before anything is
decoded (check 4, *this build can read it*). The result names the library's
tool count (Agent Tooling's own connection left out), the other Macs, the
numbered name this Mac would get ("Juniper 2") and their statuses. Failures
are a typed `GitRemoteProblem` worded for the person, each ending "Nothing was
changed." except the two that help with the field, `invalidAddress` and
`invalidBranch`. A typo, a failed sign-in, no network and a timeout are never
read as an empty repository; `noSuchBranch` is a branch the repository lacks,
and `emptyRemote` a repository with no branch at all.

### The join's phases

`WorkspaceJoin.join(...)` reports its steps as J01 lists them (`Step`):
reaching the repository (a fresh `<support>/sync-checkout`, cloned and
fetched; a stale one is set aside, to the Trash by default), reading the
library, checking this Mac's apps (the `observe` closure: each chosen app's
first read, and the sign-in reads beside it), registering and sharing.

It runs in two phases. Until this Mac's store is created a Stop ends it,
keeping nothing but the checkout. From the store on it finishes or fails as a
whole, in this order: the store (this Mac's choices as its device
preferences: the chosen apps, every assistant run off, projects not found
from Claude Code's history), the sync enrollment beside it,
`afterStoreCreated` (the setup stage writes its record there, so a launch that
finds no library can finish the join), this Mac's registration under the name
shown (numbered when another Mac has it), the first sync, and the locator
record last. A failure in that phase is `WorkspaceJoinError.lateFailure`.
`WorkspaceJoin.finish(containerRoot:workspaceID:homeURL:...)` completes what
it left, reading the repository from the enrollment; joining the same library
again does too, keeping the registered name. The result carries the
`registeredName` and the other Macs' published statuses.

### Connecting the first Mac

The setup stage's Your other Macs connects through
`WorkspaceSyncSession.connectAndShare`: the preflight, the enrollment in
`<support>/sync-checkout`, this Mac registered under the typed name before
anything is published, then the first publish. If the publish fails, the
enrollment it wrote is removed; the registration stays.

## Scope: which Macs an assignment is for

`PortableDestination` carries `deviceIDs` and `excludedDeviceIDs`:

| `deviceIDs` | `excludedDeviceIDs` | Meaning |
|---|---|---|
| `nil` | empty | every Mac that takes shared assignments |
| `nil` | [x, y] | every such Mac except x and y |
| [a, b] | — | exactly a and b, whether or not they take shared assignments |
| `[]` | — | no Mac (kept for history; never planned) |

The resolver's rule for "does this apply here" is:

```
if let ids = deviceIDs  { return ids.contains(me) }
if excludedDeviceIDs.contains(me) { return false }
return registry[me].receivesSharedAssignments
```

A Mac with `receivesSharedAssignments == false` is **opt-in**: it gets only
what names it. A Mac with it on and an `excludedDeviceIDs` entry is **opt-out**
for that one item. Both directions are first-class; neither requires editing
other assignments when a Mac joins or leaves.

The install picker's default for user-scope installs is **Every Mac** (`nil`).
"This Mac only", "Choose Macs", and "One project" are the other choices.

## Incoming changes

A sync pass that brings the document forward may leave assignments this Mac has
not satisfied. That is the same situation as a found update, and it is handled
by the same rule: `UpdatePolicy` per kind — install automatically, or ask. After
each pass the app plans only what is new and unsatisfied here; kinds set to
automatic are installed through the ordinary direct path (same classifier, same
executor, same receipts); the rest wait on Home under "From your other Macs".
A deliberately limited Mac is never nagged about items that do not apply to it,
and nothing this Mac's own setup placed is ever listed as from another Mac
(`WorkspaceSetupProgressSession.ownPlacements`).

Arriving intent is never evidence that a file changed. Everything still goes
through this Mac's own plan.

## Secrets

The document carries the *names* of credentials a server needs, never values.
MCP definitions already refuse credential-shaped content; the Git transport
already refuses credentials in a remote URL; `status/` files carry no paths
outside `~` abbreviation, no tokens, and no account address. Each Mac supplies
its own values through its own client. This line does not move.

## Scheduling

The pure `WorkspaceSyncScheduler` decides when a pass may run; the shell asks it
on open and after each local write, and a status line says "Synced 2m ago ·
MacBook Pro last seen 3h ago". Passes never overlap, failures back off, and an
unresolved conflict stops automatic passes until a person decides.

## Not covered by v1

Live control of another Mac (running a scan or an install *there* from here).
Any Mac can set intent for another by name; the named Mac carries it out on its
next pass. Executing remotely would reintroduce the hub's dependency through the
back door and is deliberately absent.

## Pilot

Two real Macs, in this order; each step has a visible check:

1. **Join.** Mac A connected to a private repository; Mac B fresh: choose "Join
   an existing workspace", paste the remote. B shows A's library and both Macs
   appear under Settings › Sync › Macs with their names.
2. **Author on A, see on B.** Create a skill on A (any method), install it on A
   as *Every Mac*. On B, sync (or wait for the open-time pass): the skill
   appears with its content and Home shows "From your other Macs: 1".
3. **Install by policy on B.** With Skills set to *Ask me first*, press Install
   on the Home card; with *Install automatically*, the pass installs it and Home
   says so. Verify `~/.claude/skills/<name>` exists on B.
4. **Limited Mac.** On B, turn off *Take shared assignments on this Mac*.
   Install something on A as Every Mac; confirm B does not plan it and shows no
   warning. Assign something to B by name from A; confirm B installs it.
5. **Offline edits.** Disconnect B from the network. Rename a project on A and
   assign a different skill on B. Reconnect; sync both. Both converge with no
   conflict. Then rename the *same* project differently on both while apart;
   confirm the conflict appears once, is decided on one Mac, and the other
   adopts the decision.
6. **Retire.** Retire B from A. B's row shows retired on both; B's assignments
   are labelled; nothing on B's disk changed.

Things to watch: the first pass after join takes longer (content copy); a Mac
whose name you changed in System Settings keeps its registry name until you
rename it in the app; Git credential prompts belong to Git, not the app.
