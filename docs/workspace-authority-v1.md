# Workspace authority v1

Status: implemented locally on September 9, 2026. This contract selects which
local workspace database the current app opens. It does not deploy skills,
plugins, or MCP servers, and it does not prove a production cutover.

## Durable selection

`WorkspaceAuthorityStore` keeps one canonical file beside the retained legacy
database:

```text
<legacy-root>/workspace-authority-v1.json
```

The file contains a versioned, append-only array of
`WorkspaceAuthoritySelection` records. Each record identifies its predecessor,
choice (`versioned` or `legacy`), versioned container/workspace/device/migration
attempt, retained legacy checkpoint SHA-256, versioned revision, and canonical
millisecond timestamp. The first selection must choose the versioned workspace.
The only subsequent transition in v1 is rollback to legacy; reactivation needs
an explicit future reconciliation contract.

The store rewrites the complete history through a private staged file, fsyncs
the file, atomically renames it over the canonical registry, and fsyncs the
directory. The registry and lock are regular, owner-only, single-link files in
an owner-owned `0700` root. Descriptor-relative operations reject symlinks and
detect replacement of the files they open. Reads reject corrupt, noncanonical, oversized, unsafe, or
future-version data instead of interpreting it as a missing selection. A
missing root, or an owned non-group-writable legacy root with neither registry
nor lock, means legacy remains selected and is not modified by the probe.

Authority operations use a sibling flock file. Locks are nonblocking; contention
returns `busy` for an explicit retry instead of waiting on the UI indefinitely.
The history is bounded to 1,024 records and 4 MiB, although the v1 transition
rules currently permit only activation followed by rollback.

## Review, freshness, and commit

`WorkspaceAuthorityService.prepareActivation` accepts only an initialized
migration attempt. It verifies the durable checkpoint and central content
objects, recaptures every reviewed source tree, recaptures the legacy database,
checks the target identities and paths, and requires the versioned head to
remain the migration's initial revision. The returned selection is a review
value; preparation does not change authority.

`apply` checks an exact prior receipt first. A new activation then repeats the
migration and target checks before entering the commit boundary. The boundary
holds locks in this order:

1. exclusive authority-registry flock;
2. versioned revision-store `BEGIN IMMEDIATE` at the reviewed head and attempt;
3. legacy SQLite `BEGIN IMMEDIATE`, followed by a final checkpoint capture.

The final legacy checkpoint must equal the reviewed digest before the registry
is published. No rows in either database change during authority selection.
Source trees are checked immediately before this boundary; the final locked
check covers the legacy database. Cancellation or a failed validation leaves
the prior registry intact. A crash after the atomic rename can be recovered by
replaying the same selection ID.

Commit uses compare-and-swap against `previousID`. Reusing an ID with identical
fields returns its historical receipt without rewriting the file, even if a
later rollback exists. Reusing an ID with different fields fails. A competing
selection with a stale predecessor also fails.

## Rollback

Rollback selects the retained legacy database; it does not restore the migration
checkpoint and does not erase either store. Preparation captures the current
legacy database and current versioned head. Apply rechecks both under the same
lock order and appends a legacy selection that points to the activation target.
The rollback record may therefore carry a newer legacy checkpoint digest and a
newer versioned revision than the activation record. This preserves edits made
on either side after activation.

## Startup and legacy write guards

At startup, an explicit migration-review pilot or `WorkspacePreviewLaunch`
request takes precedence. If neither is present, `WorkspaceAuthorityLaunch`
reads the durable registry. A versioned selection opens exactly its recorded
revision store with the guarded `openSelected` factory; it verifies the initialized migration, checkpoint binding,
legacy database path, workspace/device identity, selected revision, and current
snapshot. A missing registry or latest legacy selection proceeds to the legacy
app. Corrupt, unsupported, unsafe, or mismatched authority state produces the
startup failure screen. It never silently falls back to the legacy store.

`WorkspaceStore` checks the registry before creating directories, changing
permissions, opening its database, or running schema repair. When versioned is
selected, construction fails with `versionedSelected`. Every cooperating legacy
mutation also takes a shared authority lock and rechecks the current choice;
the authority publisher's exclusive lock therefore excludes those writers.
The final legacy `BEGIN IMMEDIATE` additionally excludes older SQLite writers
during activation. Older binaries do not understand the cooperative registry
lock and can still edit the retained legacy database at other times, so rollback
captures its current state rather than assuming it stayed frozen.

## Selected versioned writers

`WorkspaceRevisionStore.openSelected` is the explicit factory for trusted
writable app sessions. It requires the exact current activation record, opens
only an existing database without schema creation or upgrade, and verifies the
initialized migration and legacy/workspace/device bindings. Every write takes
a shared registry lease before the store queue and SQLite transaction and keeps
it through commit. Rollback's exclusive lease cannot publish between that check
and the write. A session opened before rollback rejects subsequent writes,
including mutating command replay, while historical reads remain available.

The ordinary unbound store constructor remains for migration, recovery and
isolated fixtures. It is not the factory for active production metadata writers.
This guard covers metadata transactions; complete-content staging and external
native/source operations retain their separate lifecycle boundaries.

## Current application boundary

The selected versioned workspace opens only `WorkspaceLibrarySession` and
`WorkspaceLibraryView`, with metadata writes guarded by the exact current
authority selection. Users can browse the library and review and save assignment
changes. An explicitly requested development preview still opens read-only. The UI
reports assignment intent separately from installation and does not instantiate
the legacy `AppModel` for a valid versioned selection.

Migration review is available through an explicit pilot launch, described below.
Production candidate creation/onboarding, in-session legacy-to-versioned cutover,
native plugin and MCP execution, source update writers, and complete gating of
external native/source writers remain future work. A writable metadata surface
does not establish a native deployment result or complete the live migration gate.

## Explicit migration review pilot

`--agent-tooling-migration-review <descriptor-file> --agent-tooling-home <home-folder>`
opens one already-prepared migration. Both paths must be explicit; malformed or
mixed workspace/preview flags fail without falling back to the live app. The
descriptor is a bounded canonical `WorkspaceMigrationReviewLocation` encoding.
It names the legacy root, existing revision/content/checkpoint roots and exact
workspace/device/attempt IDs. Decoding performs no discovery or initialization.

`WorkspaceMigrationReviewService.state` reads the durable journal and current
head/selection. It builds the ownership summary and indexed included-item list
off the main actor. Viewing the review does not initialize the new workspace or
select it. Personal/upstream content stays distinct from intact native plugins;
their bundled children remain visible through their owner. Assignment destinations
are shown as saved intent, not as a claim of new installation.

The UI offers explicit initialization of the exact reviewed record, followed by
a separate workspace-choice confirmation. It preserves initialization/selection
receipts even when the next read fails. Cancel closes the confirmation without
applying it; refresh invalidates the pending choice. Already-initialized records
support exact retry. A changed versioned head cannot activate from the original
review. The active migration can open its writable metadata library or prepare
a separate confirmed return to the retained legacy library. Returning preserves
both histories, including assignments saved after migration.

The pilot constructs no legacy `AppModel` before selection, so it cannot carry
an in-flight legacy operation into activation. Only after a saved rollback can it
reopen the retained legacy shell with the explicitly supplied home folder. This
is distinct from the [Settings migration intake](workspace-migration-intake-v1.md),
which gates an already-running legacy shell before inspection and keeps it gated
through selection. The normal selected startup never creates that shell.

Content and checkpoint stores support `initializeIfEmpty: false`; migration
review actions use this mode and an existing writable revision store. Missing,
empty or partial stores are rejected rather than recreated as part of review.
The opt-in `WorkspaceMigrationPilotFixtureTests` exporter creates a disposable
prepared personal-skill/native-plugin fixture for packaged interaction checks.
Its home folder is empty and independent of the user's real client directories.
