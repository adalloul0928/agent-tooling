# Versioned workspace store and service

Status: D2/D3 foundation under integration, September 8, 2026. This additive implementation does not replace `WorkspaceStore`, migrate a live workspace, or authorize native operations.

## Store isolation

New-format metadata resides at `workspaces-v1/<workspace-id>/revisions.sqlite` under an explicitly chosen device-local container. The legacy `agent-tooling.sqlite` remains separate. The new service never saves a backward-compatible `workspace.snapshot` shadow. Old binaries therefore cannot write the new authority through their existing store implementation; editing the retained legacy store does not change the new workspace.

The SQLite application ID, schema version, workspace ID and device ID are checked on opening and on every transaction. A connection that predates a newer schema cannot continue writing it. Portable and device documents also enforce their own format/version and digest rules. Store layout/version changes must be introduced deliberately; opening an unknown database does not adopt or reset it.

`initialize(document:device:)` is explicit bootstrap for a newly created or reviewed migrated workspace. It accepts a sealed initial revision with no missing ancestors and commits portable state, device state and the head together. It refuses to replace an existing or damaged workspace. Enrollment that imports existing history will need a separate bounded history-import API.

## Metadata commands

`WorkspaceApplicationService` is a Swift actor whose initial operation changes a library display label. It preserves declared names, aliases, content authority, package membership, source locks, native routes and physical files. Logical project and preset records retain the same display label as their artifact record.

The actor is an integration boundary, not an authentication mechanism. It is not exposed through MCP. Existing MCP tools remain request-only. It now also supports [central standalone intake and content updates](central-skill-intake-v1.md), with immutable reviewed content and source metadata. Assignment and native actions still need reviewed planner/service integration.

Each command contains an expected revision and idempotency key. Core computes a domain-separated canonical input digest. A SQLite `BEGIN IMMEDIATE` transaction serializes mutation across independent connections/processes; per-process actor serialization is insufficient on its own.

Inside that transaction the store:

1. Returns a previously committed result for the same key and digest, after validating the result against stored history. Reusing a key for different input is rejected.
2. Checks the current head before running the pure metadata mutation.
3. Validates and seals a new revision parented to that head.
4. Inserts immutable revision history, advances the head and records the command result atomically.
5. Rolls the entire transaction back on any failure.

A retried older command returns its original result even after newer commands advance the head. It does not move the head backward. Command receipts describe metadata outcomes and never claim that a client installed or enabled a tool.

## Integration and recovery still required

- D2 now has explicit identity/reference mapping and a [validated in-memory candidate](workspace-migration-assembly-v1.md), including local metadata retention. A [consistent raw checkpoint and immutable archive](workspace-legacy-checkpoints-v1.md) are also implemented separately. Resolver/destination comparison, final freshness checks and a rollback receipt remain required. No launch-time conversion is implemented here.
- D3 must integrate rename and central skill intake/update with actual GUI/CLI entry points and the existing trusted operation executor. The service is not yet the packaged app's active writer.
- S3/Y2 must journal complete content staging and filesystem/database recovery. SQLite metadata atomicity alone does not make native filesystem changes atomic.
- Y1/Y2/Y3 must add history import, merge publication, outbox acknowledgment, retention and restore-as-a-new-revision semantics.
- Private directories and no-follow checks reject ordinary database/directory/sidecar symlinks. They are not proof against every same-user path-swap race; filesystem mutation/journal work needs descriptor-based destination validation.
- Local tests use temporary stores and independent SQLite connections. They do not substitute for an actual app/CLI process pilot, two-Mac convergence or native-client consumption tests.
