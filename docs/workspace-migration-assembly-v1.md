# Workspace migration assembly v1

Status: an in-memory, validated candidate is implemented locally. Test evidence
is recorded in [the progress ledger](implementation-progress-2026-09.md).
This is not a migration-ready declaration and does not write
a store, fetch a source, or change a live workspace.

## Candidate boundary

`WorkspaceMigrationAssembly.preview` accepts one `WorkspaceSnapshot`, a stable
`WorkspaceMigrationContext`, and explicitly reviewed decisions. It passes that
same snapshot and preserved identity context to the inventory and configuration
converters. It refuses to combine independently produced packets, so a
configuration preview cannot be joined to inventory from another snapshot.

The context contains the workspace ID, device ID, and root revision. Callers
retain the returned identity entries, marketplace bindings, and MCP project
mappings across review retries. Those inputs preserve previously allocated
object IDs; timestamps and later retries do not create replacements. Conflicts
in supplied or retained identities leave the candidate blocked.

`WorkspaceLegacyCheckpoint.preview` now derives that snapshot from a pinned
SQLite backup and returns the checkpoint digest alongside the assembly. The
[checkpoint archive](workspace-legacy-checkpoints-v1.md) retains raw data that
typed decoding cannot preserve. This binds database provenance, not separately
captured source-tree freshness or native destination parity.

The result is a sealed schema 4 `PortableWorkspaceDocument`, a canonical schema
4 `DeviceWorkspaceState`, verified in-memory content trees, and the original
snapshot for review. It is not an initialized revision store, a checkpoint, or
a migration receipt.

## Graph assembly

Inventory produces the artifact graph, authoring/publisher sources, subscriptions,
managed MCP definitions, observations, and its stable identity reservations.
Configuration conversion supplies catalog records and consumes the inventory's exact artifact IDs. The
assembly verifies that every reservation survived unchanged before sealing the
combined document.

Logical projects are joined only through explicit MCP-project and
configuration-project decisions. A project root must be absolute, can identify
only one logical project, and must agree with every configuration device
binding that names that project. The assembly adds a logical-project artifact
only when an explicit project mapping requires it; it does not infer a project
or a root from a destination.

Attached authoring sources require exactly one local source-root binding.
Catalog source IDs retain their live legacy identities for device-local
marketplace context, while portable catalog records retain their remapped
object identities and credential-free descriptors. Source locations, refresh
facts, revisions, trust observations, and credential-reference names remain device-local.
Credential values are not copied into either record.

## Content and ownership

Central personal and central upstream artifacts require a supplied complete
`CapturedPackageTree`. The tree digest must equal the artifact content digest.
For a package child, assembly derives the child's tree from its verified parent
tree at the declared relative path and verifies that digest as well. A caller
cannot supply separate child bytes.

The exception is a typed standalone managed MCP definition: it has no package
tree. A centrally owned MCP component is still a child and still requires its
parent's verified content. Native MCP declarations remain named children of the
native plugin without a manufactured file path, copied bytes or standalone
definition. Native-owned, attached-authoring, and tracked-only
artifacts must not receive copied central content. Native routes and source
authority require explicit resolutions backed by the captured source/native evidence;
labels and installation flags alone do not establish ownership.

## Portable and device separation

Portable schema 4 carries shared artifact, source, subscription, configuration,
logical-project, assignment, and typed MCP-definition records, and permits named
native MCP children without individual file paths. Schemas 1–3 retain the
mandatory child-path rule and their existing canonical representation. Device schema 4
carries local source paths, observations, configuration bindings, MCP command
or endpoint bindings, project roots, and the application-state record.

The device inventory record also retains complete captured skill, plugin and
MCP metadata, including descriptions, client-state arrays, authoring fields and
repository check/deployment observations. Each captured row is tied to its
live artifact and legacy identity mapping. These are historical display facts:
captured `owned`, `installed`, endpoint and repository values cannot supply new
authority, desired assignments, update routes or executable operations. There
is deliberately no adapter that writes these rows back as desired state.

The application-state record projects local preferences, backup and encrypted
sync configuration, imported repository path, activities, operation receipts,
account surfaces, connectors, marketplace packages, and catalog-source context.
It is typed active local state, not a raw database checkpoint. Meaningful
receipt and history order is retained. Set-backed device fields are encoded in
canonical sorted order, and nested timestamps are reduced to the document's
millisecond precision before canonical encoding. Marketplace package component
and supported-client sets use a device wire wrapper so their legacy object
shape remains intact while their array encoding is deterministic.

Validation seals the portable document, validates the device graph against it,
and immediately encodes and decodes the device bytes. Invalid IDs, malformed
paths, unresolved source context, project-root disagreement, content digest
mismatch, or schema incompatibility block assembly.

## Gates still open

The following work is outside this candidate and remains required before any
cutover:

1. Connect the stored metadata to application read models while using the
   portable document for current ownership, identity and desired state. A
   faithful captured inventory does not prove correct runtime behavior.
2. Connect the implemented raw checkpoint archive to the durable migration
   receipt and recovery path; recheck the live store before cutover. SQLite
   backup preserves logical database content, including unknown payload fields,
   rather than the original physical main/WAL/SHM layout.
3. Prove old and new assignment behavior and native destination parity,
   including scope, disabled or unknown targets, package children, and project
   routing.
4. Switch the app store and UI only after review, recovery, and retry behavior
   are implemented and validated.
5. Run a packaged pilot and two-Mac verification. Current local tests do not
   establish either result.

Assembly performs no source fetch, no live write, and no native-client
installation. It is a bounded composition and validation stage for a later
reviewed migration flow.
