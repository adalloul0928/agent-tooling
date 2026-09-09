# Workspace migration design

Status: configuration and inventory previews, schema 3 managed MCP representation,
schema 4 device retention and combined migration assembly implemented locally,
September 8, 2026. Full D2 migration and live cutover remain
pending. The existing `WorkspaceSnapshot` is still authoritative for the app.
The new revision store is isolated at
`workspaces-v1/<workspace-id>/revisions.sqlite`.

## Accepted representation

`WorkspaceConfigurationRecords.swift` defines the portable supplement;
`WorkspaceConfigurationDeviceState.swift` defines its device counterpart.
`PortableWorkspaceDocument` uses schema 3 and `DeviceWorkspaceState` uses schema 4
for new records, retaining the older canonical wire formats. Older documents
cannot silently acquire or discard newer fields. The [MCP contract](workspace-mcp-definitions-v3.md)
defines the additive declaration and device-binding representation.

| Legacy concept | Portable record | Device record |
| --- | --- | --- |
| Personal configuration | `WorkspaceConfigurationRecord` with raw requirements, inheritance, scope, check definitions and optional target bindings | Project-root binding and check observations |
| Policy configuration | Same record with explicit policy ownership and a policy-qualified legacy key | Policy source path and import time |
| Collection | `WorkspaceCollectionRecord`, retaining independent membership | None |
| Tags | `WorkspaceTagAssignment` | None |
| Catalog/marketplace/source directory | `WorkspaceCatalogSourceRecord` with its original source kind and credential-free remote locator | Local location, refresh time, revision and trust observation, including for remote catalogs |
| Current active configuration | Shared default remains unset during migration | Existing personal active configuration becomes a device override |
| Plugin skill/profile and skill bundle references | `WorkspaceLegacyRelationshipRecord` | No native installations changed |
| Preferences, backup/encrypted-folder settings, account/connector status, receipts and cached catalog rows | None | `DeviceApplicationState` |
| Existing inventory descriptions, client health, revision/check history and authoring metadata | Authority remains in artifact/source records | `DeviceInventoryState` captured rows linked to live migrated IDs; no desired-state authority |
| Enrolled logical projects | `LogicalProjectRecord` and its artifact identity | `DeviceProjectRootBinding` |

Profiles are not presets. Catalog sources are not authoring roots or source
subscriptions. A skill's legacy bundle label is weak provenance, not evidence
that grants native ownership or creates a parent package. Top-level policy
requirements remain policy rules; they are not inserted into personal profile
requirements during conversion.

A `LegacyReferenceKey` identifies kind, original string identifier and optional
policy owner. `WorkspaceMigrationIdentityEntry` reserves one object UUID for
that key. Artifact IDs wrap the same UUID. `WorkspaceReference` separately
states whether the target is a live artifact, another live object, or unresolved.
An absent skill can keep its allocation and desired reference without falsely
claiming that its content exists.

The allocator preserves prior mappings and deterministically allocates unseen
keys using a workspace-namespaced SHA-256 UUIDv8 scheme. Hash fields are
length-delimited and Unicode-normalized consistently with Swift key equality.
Catalog UUIDs remain unchanged when available. Same-name skill, plugin and MCP
records remain distinct. Conflicting supplied identities produce a blocked
preview; they do not replace the earlier reservation.

## Resolution compatibility

The migration stores each configuration's raw lists. It does not save the
flattened output of `AppModel.effectiveProfile(for:)`.

- Requirements and collection membership union along inheritance.
- Checks retain their order. Duplicate check definitions remain visible in a
  blocked preview rather than being silently deduplicated.
- The nearest non-nil target-binding list replaces the entire inherited list.
- Nil inherits, empty explicitly selects no targets, and binding enablement
  remains true/false/unknown. Only true currently delivers a selected item.
- A native child requirement remains a reference; later assignment planning
  must retain native package ownership and avoid standalone child copying.
- Actual delivery destinations follow item scope, not merely configuration scope.

`LegacyConfigurationResolver` is an independent, pure compatibility oracle.
Its personal-profile result is compared directly with a fixture `AppModel`,
including visibility filtering and bindings. Qualified policy-template
resolution is a comparison aid; the existing app does not activate those
policy templates through its personal-profile resolver. The converter therefore
cannot silently activate a policy template when a personal active ID is missing.

## Preview boundary

`WorkspaceConfigurationMigration.preview` accepts a snapshot, workspace ID,
explicit artifact bindings, optional configuration-to-logical-project bindings,
and prior identity reservations. It returns portable/device configuration
records, reference coverage with source owners and positions, and blockers.

The preview performs no filesystem reads, writes, fetches, native commands, or
revision-store initialization. Artifact bindings establish reference identity
only. Temporary typed shapes are used to validate references; they do not become
new content-authority records. The caller must validate the eventual complete
portable document against its actual inventory and projects.

Missing parents/collections/catalogs, duplicate identities, conflicting policy
rules, invalid paths/locators, ambiguous active selection and structural failures
block configuration migration. Missing artifact references can remain unresolved;
present artifacts require explicit mappings. Credential-bearing catalog URLs
are excluded and diagnosed without echoing their values. Local observations do
not enter the portable digest.

`canMigrateConfigurations` covers this conversion packet only. It does not mean
that the entire workspace is ready to migrate or that any changes were applied.

## Inventory preview

`WorkspaceInventoryMigration.preview` now converts all captured skill, plugin
and MCP identities through the same stable allocator. It accepts explicit
verified artifact resolutions plus typed source/subscription records. It
performs no I/O and cannot prove that content exists on disk; the importer must
verify complete-tree bytes before supplying a central-content resolution.

Unknown unowned standalone items can remain tracked. Existing owned skills,
repository bindings, managed MCP definitions, plugins and package membership
require a resolution. A missing decision blocks the preview instead of silently
weakening their existing management. A source lock requires its own typed
approved revision and complete-tree digest; legacy deployment fingerprints do
not become that digest. Existing repository/ref/subdirectory intent cannot be
replaced during migration.

Observed native ownership requires exact routes from the captured client
inventory. Child records retain one parent and package-relative paths, and do
not acquire independent routes. Legacy plugin membership alone does not prove
native ownership, but it still blocks extracting a listed child as a standalone
item. Display labels, client health and imported repository paths do not confer
ownership. The final artifact/source/subscription graph is checked using the
real portable validator, and the configuration preview can use those exact IDs.

Each inventory record has coverage for identity, authority, parentage, source
updates, device observations and remaining metadata. The preview retains the
entire typed legacy snapshot in a deliberately non-Codable local wrapper. This
preserves preferences, account/connector observations, receipts, backup/sync
settings, original descriptions and repository observations during review. It
is not a durable archive or an application cutover. The [checkpoint implementation](workspace-legacy-checkpoints-v1.md) preserves
original payload bytes and unknown fields in a complete logical SQLite backup.
It does not copy the physical main/WAL/SHM layout. Managed MCP
definitions require explicit matching schema 3 definitions, device setup and
current-device client contributions; typed retention alone remains insufficient.
Nonnative installed marketplace rows require explicit links to resolved
inventory. Native catalog records can match exact observed, resolved plugin
roots automatically; unmatched native cache rows and uninstalled catalog-only
listings remain local metadata without becoming artifacts. Their coverage is
reported separately.

## Remaining D2 acceptance

1. Connect the [combined candidate](workspace-migration-assembly-v1.md) to
   actual source/native evidence capture and application read models. Complete
   trees, typed definitions, configuration/project joins, application settings
   and captured inventory metadata now have persisted representations. This
   does not establish live application behavior or raw checkpoint fidelity.
2. Compare actual old/new assignment plans and destinations, including fallback
   behavior, native children, project scope and disabled/unknown targets.
3. Use the implemented checkpoint-bound candidate and immutable archive in a
   durable migration receipt. Check that the live store and separately captured
   source/native evidence still match the reviewed inputs before cutover. A
   database checkpoint does not establish source-tree or destination freshness.
4. Make initialization/retry/crash recovery atomic. Retain the original store
   and client files; rollback must preserve both legacy edits made after the
   checkpoint and newer-format edits instead of overwriting either side.
5. Wire the preview/review/service into the app and verify a packaged pilot.

Local tests cover the schema supplement, canonical v1/v2 compatibility,
identity allocation, configuration conversion, missing references, inheritance
semantics and device separation. They do not establish full workspace migration,
source materialization, native consumption or multi-Mac correctness.

## Managed MCP definitions and marketplace links

A review after the content-store batch identified two distinct gaps. The
additive implementation now addresses them within the pure inventory preview.

Managed MCP declarations have active `transport` and `endpoint` values in the
legacy model, plus client/scope/project intent. D1 artifact metadata and the
transport-only assignment evidence cannot preserve the actual definition.
Schema 3 adds a versioned definition record keyed by the existing MCP ArtifactID,
with separate device bindings for executable/argument vectors, local endpoints
and credential requirements. Only explicitly reviewed, validated remote DNS
locators belong in portable state. Commands do not become invented package
content and managed declarations cannot silently become tracked-only. Schema
1/2 reading and writing remain explicit and unchanged in meaning.

Definition conversion alone does not resolve client/scope intent. Project
roots need their logical-project/device-root mapping and per-client
contributions. Any missing mapping remains a distinct blocker. Native/plugin
children continue to inherit their package authority and must not become new
personal standalone definitions.

Settings intake now produces these resolutions for existing managed declarations
with sufficient checkpoint data. It preserves normalized HTTP addresses or parsed
stdio argument vectors in a device binding and emits deterministic current-device
manual assignments for the exact legacy clients and scope. Public HTTPS alone
does not authorize portable sharing. Authentication and credential names are
validated independently; project/local-project records require an explicitly
confirmed logical project. Settings now collects one project name per exact
saved root and rebuilds both MCP and policy-qualified configuration bindings
from each fresh checkpoint. A changed root invalidates the old choice; an edited
draft name cannot be staged without confirmation. Missing or invalid roots
remain blocked. The old desired-local summary marker
is accepted only through the existing `isManagedDefinition` compatibility rule.
Both profile and collection references retain the reserved live MCP identity.

Installed marketplace listings receive validated preview
links to already resolved root artifacts. Preserve a stable package-ID to
ArtifactID binding and validate aliases, root kind, parent graph and exact
native routes. Catalog labels, installed flags, executable install commands,
legacy revision strings and legacy fingerprints are insufficient evidence for
native or central-upstream authority. An uninstalled catalog-only listing may
remain local without creating an artifact. A marketplace-only installed item
needs an explicit, stable reviewed resolution rather than a guessed duplicate.
The caller retains returned marketplace bindings and MCP project mappings for
retries. Catalog ownership labels alone do not establish local installation;
registry providers also use them to describe future install routes. Managed catalog
ownership requires central-upstream authority, a subscription and approved
complete-tree digest; it does not prove personal authorship. An explicit existing
Git repository locator must match the new source. Untyped legacy revision/hash
strings cannot replace freshly verified revision/content evidence. Native ownership
requires exact observed native routes. Unmanaged listings migrate as tracking.
For native catalogs, parser-preserved `codex:<plugin ID>` and
`claude:<plugin ID>` keys establish client/package identity only when component,
client, ownership and any explicit catalog provenance agree. Those keys match
exact observed routes on resolved native plugin roots. Contradictory or
malformed reserved keys cannot fall through as managed or tracked packages.
Missing observed roots retain the valid native listing as device-local cache;
an explicit or preserved link that no longer matches instead blocks review.
Two different clients may have catalog aliases for one intact native root.
Competing roots or same-client aliases remain blocked. Matching creates no
assignments or copied content. Cached installed flags alone do not create
portable installation intent.

Other catalog rows cannot share a root implicitly. Marketplace-only
resolutions create one root; complete package children still require captured
inventory/evidence rather than invented catalog metadata.

Local acceptance fixtures cover:

1. Managed remote MCP preserving its reserved identity and active definition,
   with no invented complete-tree digest.
2. Managed stdio MCP preserving parsed quoted arguments and device credential
   requirements; invalid/inline-secret definitions remain blocked and redacted.
3. Managed project MCP preserving project and client intent; absent/ambiguous
   project roots cannot produce a ready migration.
4. Installed native listing linked to an observed native plugin using one root
   identity and its exact captured per-client routes.
5. Agent-managed upstream listing requiring matching source/subscription and
   approved complete-tree evidence; catalog metadata alone remains insufficient.
6. Explicit marketplace-only tracking with a stable identity, plus rejected
   duplicate links, kind mismatches and identity changes on retry.
