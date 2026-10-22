# Legacy database checkpoints

The checkpoint API captures and retains a complete logical SQLite database
before typed migration interpretation. It does not initialize the legacy
`WorkspaceStore`, change its schema, normalize its compatibility blob, or
initialize the new revision store.

## Capture and interpretation

`WorkspaceLegacyCheckpoint.capture(databaseURL:)` runs on a cancellable worker.
It opens an existing regular database read-only, starts a read transaction and
pins it with a schema read. SQLite's backup API copies that snapshot into a
private in-memory database. Committed data visible through the WAL is included;
a concurrent writer's later commit cannot change the snapshot being copied.
Busy/locked capture fails with a retryable error instead of waiting indefinitely.

The backup is checked, serialized and assigned a SHA-256 digest. These immutable
bytes retain unknown tables, state keys, columns and JSON payload fields, as
well as normalized rows, operation plans and the legacy compatibility shadow.
This preserves database content, not the original physical main/WAL/SHM file
layout. SQLite may use its normal local WAL/SHM coordination files while reading;
the capture performs no application-data writes or source checkpoint commands.

The image remains unchanged. SQLite cannot deserialize a WAL-mode header, so
when necessary the reader changes only bytes 18 and 19 in its private query
buffer to rollback mode, as documented by SQLite. Archive bytes and their hash
remain exact. The copied image already includes the committed WAL pages.

`workspaceSnapshot()` reads exclusively from those captured bytes. It accepts
legacy schema migration versions 1–4. Normalized metadata takes precedence;
malformed normalized metadata, missing required tables, or mismatched entity
row IDs block interpretation and never fall back to a stale shadow. Only absent
normalized metadata admits the blob-only fallback, without writing it back.
Unknown future schemas can be archived but cannot be interpreted by this reader.
The typed view cannot retain unknown fields, so it never replaces the raw image.

Capture and reads enforce a 128 MiB image bound, bounded typed row counts,
SQLite progress deadlines and cancellation. They reject symlinked, nonregular
or multiply linked database/sidecar files and detect ordinary source pathname
replacement. They do not claim filesystem snapshot isolation for separately
captured skill trees or protection against arbitrary same-user hostile VFS races.

## Durable archive

`WorkspaceLegacyCheckpointStore` uses a dedicated, existing private local
folder with a version marker. It publishes exact checkpoint bytes under their
SHA-256 identity using staged, flushed files and a no-clobber rename. An existing
object is verified; corrupt bytes are reported instead of overwritten. Reading
verifies the regular private file, exact digest and SQLite integrity before
returning a checkpoint. This archive is device-local recovery material, not a
portable sync payload. It can contain private historical rows and unknown data.

`checkpoint.preview(context:decisions:)` derives the migration candidate from
the captured typed snapshot and returns the originating checkpoint digest.
Native/source evidence and complete skill trees remain separate reviewed inputs;
this digest does not establish their freshness or the live store's current state.

## Remaining cutover work

A durable archive and a checkpoint-bound candidate are necessary recovery inputs.
They are not a completed migration. The commit path still needs old/new physical
destination parity, final freshness checks, a durable migration receipt/journal,
crash recovery and an app cutover. Rollback must retain legacy edits made after
capture and newer-format edits instead of restoring over either side.

Current acceptance is temporary-database testing. No live library migration,
native-client write, packaged migration pilot or two-Mac verification is implied.
