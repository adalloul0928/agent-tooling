# Migration preparation and bootstrap journal

Status: implemented and locally tested, September 9, 2026. This packet
connects the checkpoint, assembled workspace, standalone assignments and complete
content store. It does not activate the new store in the packaged app.

## Review inputs

`WorkspaceMigrationPreparation.build` consumes one checkpoint, a retained
workspace/device/revision context and the explicit migration decisions. It runs
checkpoint-backed assembly, standalone assignment preview and native-plugin
placement preview, merges the proposed contributions, then seals the initial
document. A blocker in any preview prevents preparation.

Each immutable device-local manifest binds:

- A retained attempt ID, workspace ID, device ID and initial revision ID.
- The legacy database location and exact checkpoint SHA-256.
- SHA-256 of the exact canonical portable and device document bytes.
- Every central artifact's complete-tree digest, including derived package children.
- Explicit source folder locations for central owning roots only.
- Standalone skill installation folder names, separately from display names.

The input digest covers the canonical manifest, which in turn covers both
documents. Source paths and checkpoint bytes are local evidence; they are not
added to the portable document. Native plugin parent/child graphs and exact
native ownership routes remain intact. They do not acquire central content.

Native-plugin placement requires an explicit reviewed scope, with a real
logical-project/device-root mapping for project scopes. An existing configuration
scope is not assumed to be the plugin's installation scope. Explicit plugin
bindings preserve enabled, disabled and unknown values, including all-disabled
plugins deliberately omitted from the configuration's enabled-plugin list. Nil
or empty target bindings do not expand observations into assignments. Scope
choices require separate native-route support before execution.
Bindings for a disabled device client remain in portable configuration but do
not create assignments on this device. An explicit placement for that disabled
client is reported as unused, requiring the caller to reconcile the choice.

## Staging and initialization

`WorkspaceMigrationService` is a trusted local actor. MCP does not receive this
operator interface. The caller provides dedicated checkpoint and content stores
and the explicitly enrolled revision store.

| State | Meaning | Recovery |
| --- | --- | --- |
| No journal entry | Staging has not committed review inputs | Retry the same preparation; immutable unreferenced objects can remain after interruption |
| Prepared | Checkpoint, complete trees and canonical review inputs were durably published | Discover attempts through `journal()` and initialize by attempt ID plus expected input digest |
| Initialized | Initial revision, device state, head and completion marker committed atomically | Return the historical receipt; never initialize again or reset the current head |

Staging checks the current source trees and legacy database against the review,
publishes the checkpoint and complete immutable trees, checks freshness again,
then writes the prepared record. Different inputs under the same attempt ID are
a conflict. A new review uses a new attempt ID. Different attempts may remain
prepared; only one can initialize a workspace. All records are retained.
Replaying an existing prepared entry validates durable dependencies; initialization
performs the live freshness check again.

Initialization reopens the durable checkpoint/content and checks current source
and database evidence before entering the revision-store transaction. The
transaction requires the named preparation and an empty, valid store. It writes
the initial revision, device state, head and initialized marker together. Any
failure rolls back all four. Ordinary unreviewed bootstrap refuses to bypass a
pending migration journal.

Completed retries validate the stored initial revision and current workspace,
but do not compare the initial document to today's head. Later valid edits in
the new store and later edits in the legacy store are preserved. A completed
receipt is historical evidence, not a claim that current files still equal the
old checkpoint or that native tools were installed.

## Store format

The existing isolated `workspaces-v1/<workspace-id>/revisions.sqlite` layout now
uses SQLite store format 2. Portable/device document versions are unchanged.
Migration inputs have immutable-row triggers; completion can only move forward;
the unique completion index prevents two initialized migrations.

Opening a format-1 store does not silently upgrade it. An explicit
`formatUpgrade: .version1To2` performs the additive journal-table upgrade in one
transaction after checking identity and existing workspace state. Unknown,
future, or mismatched stores remain unchanged. Older format-1 writers reject
format 2 through their existing per-transaction format check.

## Remaining activation gates

Source and database freshness checks are bounded observations. They are not a
transaction spanning the old SQLite writer and independently mutable folders.
This packet performs no app-store selection, legacy replacement, source write,
native deployment or rollback over either store. The subsequent
[authority packet](workspace-authority-v1.md) implements coordinated final
database freshness, read-only startup routing and selection of the current
retained store for rollback. Production review controls, writable app integration
and native/source operation routing remain required. An old checkpoint is never
restored over later edits by that selection operation.

The native/MCP parity audit identified these concrete integration requirements:

1. Explicit native-plugin bindings now expand into contributions using reviewed
   placement choices. The app must capture and present those scope/project
   choices; observed inventory cannot fill that gap as desired intent.
2. Native ownership routes identify a package/client, not executable install
   arguments. Use the exact reviewed native marketplace route and keep package
   children indivisible. Unsupported updates remain manual.
3. Project/local-project MCP commands obtain their working directory from the
   logical-project/current-device root mapping. Workspace-scope MCP commands
   use their explicit workspace binding. Codex non-user scope remains manual.
4. MCP identifiers, scope, transport and tokenized arguments must pass the real
   `MCPClientCommand` contract. Installation, credentials, consent and runtime
   health remain separate observations.

`WorkspaceManagedMCPCommandPlanning` now bridges validated managed MCP
requirements into that existing command contract. It re-runs assignment resolution
over every contribution for the artifact and complete captured targets, admits
only the exact resulting requirement and one of its contributing selectors, and
requires matching capability/version evidence. An add/configure command cannot
express explicit enablement, so enabled/disabled requests remain unsupported by
this narrow bridge. Other-device assignments are retained and ignored locally.
The bridge describes a command; executable/source/destination freshness and the
existing trusted operation review remain required before execution.

Packaged activation, rollback selection, native consumption and two-Mac
validation remain milestone gates; a prepared or initialized journal entry does
not satisfy them.
