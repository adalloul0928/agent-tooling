# Versioned library browser and assignment session

Status: A2 application components and read-only pilot route implemented; local
integration checks are recorded in the progress ledger. The app uses its legacy
store unless an explicit authority selection exists. Selected versioned launches
currently remain read-only; these components do not constitute a writable
production cutover or native deployment.

## Read model

`WorkspaceLibraryReadModel` validates one consistent portable/device snapshot,
then indexes roots, children, sources, observed descriptions, presets, projects
and assignment reasons. Native packages appear once; their included tools stay
in details and are never independent choices. The index is built on the shared
service actor, outside SwiftUI rendering. Parent and search indexes avoid a
whole-inventory scan for every row. Desired assignments remain distinct from
installed, enabled, authenticated or usable state.

`WorkspaceLibraryView` uses the same browser for a library or an explicit project
context. It has a flat, lazy list, concise ownership, separate repository labels,
on-demand details and one assignment sheet. Presets use that same sheet. The
sheet starts with no app selected, supports current-Mac user/project choices,
keeps selected items and reviewed targets visible, and bounds expanded item
lists. A metadata receipt says that assignments were saved; it is not an
installation receipt.

## Session boundary

`WorkspaceLibrarySession` receives a service and explicit workspace/device IDs.
It does not discover, initialize, migrate or select an authority. Every read is
checked against those IDs. Read-only is the default; its save action is disabled
and the session itself rejects writes. Writable sessions are currently used only
by disposable test fixtures. This UI access mode is not an agent approval token.

The shared `WorkspaceApplicationService` provides state, preview and atomic
assignment commands. Reviewing re-reads the current snapshot; saving uses the
reviewed command's expected revision and idempotency key. Stale saves cannot
overwrite another writer. A successful commit followed by a failed refresh
retains its receipt and reports the read failure instead of inviting a duplicate
write. Independent manual/preset reasons remain in the core command model.

MCP continues to queue requests. This session does not grant the MCP operator
direct access to the writer or native executor.

## Read-only packaged pilot

`WorkspaceRevisionStore` supports an `existingReadOnly` open mode. It requires
existing directories/database, opens SQLite read-only with query-only enabled,
rejects schema upgrades and write transactions, and leaves workspace/head data
untouched. It reads current WAL-backed revisions through SQLite; it does not
freeze an immutable copy that could omit recent commits. SQLite may maintain
its own read-coordination sidecars, so this is not a promise of zero filesystem
activity. No native or source files are opened by the browser.

An explicit development launch can show that store:

```text
AgentTooling --agent-tooling-versioned-preview-root /absolute/container \
  --agent-tooling-workspace-id <workspace-uuid> \
  --agent-tooling-device-id <device-uuid>
```

All three arguments are required together. A malformed request fails startup;
it never falls back to opening the person's live library. This route constructs
no legacy `AppModel`, performs no bootstrap/discovery, and exposes a read-only
session. It does not persist authority selection. Normal launches consult the
[durable authority registry](workspace-authority-v1.md); a selected versioned
workspace currently also opens in read-only mode.
Use disposable fixture stores for this pilot, not an automatic live migration.

## Remaining integration

Before a writable production cutover, expose the implemented durable authority
selection through a reviewed UI and route or disable every legacy writer,
including external native/source tasks. Selected metadata sessions must use
`WorkspaceRevisionStore.openSelected`; ordinary unbound migration/recovery
stores do not provide that write guard.
An initialized migration journal proves bootstrap only. Rollback must select the
current legacy store while preserving both stores' later edits and native files;
it must never restore a checkpoint over newer work. Native reviewed deployment,
per-target results/retry, source intake/update UI and the complete project entry
point remain separate acceptance work.
