# Workspace contracts v1

Status: proposed F1 contract, September 8, 2026. This document defines types and invariants for D1, AP1, and their dependent work. It does not describe delivered behavior, authorize migration, or replace the current `WorkspaceSnapshot`, resolver, store, operation plans, or native adapters.

## Contract boundary

The workspace has three distinct facts:

1. **Portable intent** identifies artifacts, content authority, approved source revisions, assignments, and presets.
2. **Device state** records paths, installed client versions, observations, credentials by local reference, deployment baselines, pending plans, and receipts.
3. **Package content** is a complete filesystem tree held by its declared content authority. Metadata may refer to that tree by digest; SQLite is not a second editable copy of its files.

The first implementation adds new Codable domain types and encoders beside existing models. Existing reads, writes, onboarding, profiles, collections, and installation behavior remain unchanged until a separately reviewed migration and resolver cutover.

## Identity and aliases

Every logical artifact receives an immutable UUID when it first becomes managed or explicitly tracked. Names, paths, source URLs, and native identifiers are aliases and may change without changing identity.

```swift
struct ArtifactID: RawRepresentable, Codable, Hashable, Sendable {
    let rawValue: UUID
}

enum ArtifactKind: String, Codable, Sendable {
    case package, skill, mcpServer, nativePlugin, preset, logicalProject
}

struct ExternalAlias: Codable, Hashable, Sendable {
    var namespace: String       // e.g. "claude.plugin", "codex.plugin", "legacy.skill"
    var value: String
}

struct ArtifactIdentity: Codable, Hashable, Sendable {
    var id: ArtifactID
    var kind: ArtifactKind
    var displayName: String
    var aliases: [ExternalAlias]
    var parentPackageID: ArtifactID?
    var derivedFrom: ArtifactID?
}
```

Invariants:

- `(namespace, value)` identifies at most one live artifact within a workspace. Alias collisions produce a review conflict; they never merge records automatically.
- A rename changes `displayName` and may add an alias; it never changes `id`.
- A native-owned plugin child has exactly one `parentPackageID` and cannot be assigned, installed, forked, or removed independently. A skill inside a portable personal/upstream package may be assigned separately when the target supports skill delivery; its package membership and content authority remain intact. An explicit fork always creates a new identity with `derivedFrom`.
- Equal names or equal bytes are insufficient identity evidence.
- Tombstones retain the ID and aliases needed to prevent accidental recreation or stale-reference reuse.

## Content authority and source locks

```swift
enum ContentAuthority: Codable, Hashable, Sendable {
    case centralPersonal
    case centralUpstream(subscriptionID: WorkspaceObjectID)
    case nativeOwned
    case attachedAuthoring(sourceRootID: WorkspaceObjectID)
    case trackedOnly
}

struct NativePackageRoute: Codable, Hashable, Sendable {
    var client: ClientKind
    var externalPluginID: String
}

enum SourceRevisionKind: String, Codable, Sendable {
    case gitCommitSHA1, gitCommitSHA256, semanticVersion, opaquePublisherRevision
}

struct SourceRevision: Codable, Hashable, Sendable {
    var kind: SourceRevisionKind
    var value: String
}

enum ContentDigestAlgorithm: String, Codable, Sendable { case sha256TreeV1 }

struct ContentDigest: Codable, Hashable, Sendable {
    var algorithm: ContentDigestAlgorithm
    var value: String
}

enum DocumentDigestAlgorithm: String, Codable, Sendable { case sha256CanonicalJSONV1 }

struct DocumentDigest: Codable, Hashable, Sendable {
    var algorithm: DocumentDigestAlgorithm
    var value: String
}

struct UpstreamLock: Codable, Hashable, Sendable {
    var publisherID: String
    var sourceRootID: WorkspaceObjectID
    var requestedRef: String
    var approvedRevision: SourceRevision
    var approvedContent: ContentDigest
    var packageRelativePath: String
}

struct ArtifactRecord: Codable, Hashable, Sendable {
    var identity: ArtifactIdentity
    var authority: ContentAuthority
    var declaredName: String?          // optional for metadata-only records
    var packageRelativePath: String?   // native MCP declarations may omit it in schema 4
    var contentDigest: ContentDigest?
    var nativeRoutes: [NativePackageRoute] // native-owned roots only
}
```

Authority invariants:

- `centralPersonal` file content has one editable package under the central library. Deployments are derived copies or links. Schema 3 also represents standalone managed MCP declarations as typed metadata without a fabricated content tree; see [the MCP definition contract](workspace-mcp-definitions-v3.md).
- `centralUpstream` stores complete reviewed content for the approved lock. The publisher owns future releases; the approved central tree supplies local deployments. Editing requires an explicit personal fork with a new ID.
- `nativeOwned` stores provenance and desired presence only. One root artifact may have one typed `NativePackageRoute` per client, allowing a merged plugin to retain different Claude and Codex IDs without duplicating its identity or children. An empty route list represents known native ownership whose update routing remains unresolved. Children inherit `nativeOwned` and carry no routes. The native clients own the complete plugin, its adapters, children, enablement, and update route. Agent Tooling never extracts a child into a standalone managed skill implicitly.
- `attachedAuthoring` points to the one editable external source root. Central snapshots, staging, backups, and deployments are derived data and must not become competing editable masters.
- `trackedOnly` carries observation/identity decisions without claiming content control or an update route.
- `requestedRef`, immutable `approvedRevision`, and `approvedContent` remain separate. A branch tip is never substituted for an unavailable approved revision.
- Digest algorithms are named and versioned. A Git object ID and a file-tree digest are never compared as if they were the same algorithm.
- The exact `sha256TreeV1` preimage, complete-folder preservation bounds and additive immutable object-store behavior are defined in [the package content contract](package-tree-content-store-v1.md). Existing legacy/provider fingerprints require a fresh capture before they can use this algorithm identity.
- Native routes occur only on native-owned roots, have a nonempty bounded external ID, and contain at most one entry per client. Missing or ambiguous routing produces unsupported/unknown resolution; no client route is inferred from another client's alias.

## Source roots and destinations

A source root answers “where are authored or published bytes obtained?” A linked destination answers “where should reviewed bytes be made available on this device?” One path may be registered in only the role the user selected; matching paths do not collapse the roles.

```swift
enum SourceRootRole: String, Codable, Sendable {
    case publisherRepository, attachedAuthoring
}

struct PortableSourceDescriptor: Codable, Hashable, Sendable {
    var id: WorkspaceObjectID
    var role: SourceRootRole
    var repositoryURL: String?      // credential-free HTTPS identity when published
    var requestedRef: String?
    var packageRelativePaths: [String]
}

struct UpstreamSubscription: Codable, Hashable, Sendable {
    var id: WorkspaceObjectID
    var artifactID: ArtifactID
    var sourceID: WorkspaceObjectID
    var lock: UpstreamLock
}

struct LogicalProjectRecord: Codable, Hashable, Sendable {
    var id: ArtifactID
    var name: String
    var repositoryHints: [String]   // credential-free identities, never checkout paths
}

struct PortableDestination: Codable, Hashable, Sendable {
    var surface: TargetSurface
    var scope: ToolingScope
    var logicalProjectID: ArtifactID?
    var deviceIDs: [WorkspaceObjectID]? // nil all enrolled; empty no device
}
```

The device `SourceRootBinding` maps a portable source descriptor to a local checkout. It contains checkout paths, worktree identity, credential-reference IDs, last fetch result, dirty/index state, and resolved filesystem evidence.

`LinkedDestinationBinding` is device state: stable destination ID, target surface, scope, optional logical project ID, resolved local path, write policy, baseline digest, and last receipt. It cannot grant content authority. Apply-once writes do not subscribe the destination to later preset changes.

All package-relative paths are normalized, relative, traversal-free, and resolved within the source/package root before reading. Device paths and credential references never enter the portable document.

## Portable and device documents

```swift
struct PortableWorkspaceDocument: Codable, Sendable {
    var schemaVersion: UInt
    var minimumReaderVersion: UInt
    var minimumWriterVersion: UInt
    var workspaceID: WorkspaceObjectID
    var revision: WorkspaceRevision
    var artifacts: [ArtifactRecord]
    var sources: [PortableSourceDescriptor]
    var subscriptions: [UpstreamSubscription]
    var logicalProjects: [LogicalProjectRecord]
    var assignments: [AssignmentContribution]
    var presets: [PresetRecord]
    var tombstones: [ArtifactTombstone]
}

struct DeviceWorkspaceState: Codable, Sendable {
    var schemaVersion: UInt
    var workspaceID: WorkspaceObjectID
    var deviceID: WorkspaceObjectID
    var sourceLocations: [SourceRootBinding]
    var destinations: [LinkedDestinationBinding]
    var observations: [TargetObservation]
    var capabilityEvidence: [TargetCapabilityEvidence]
    var deploymentBaselines: [DeploymentBaseline]
    var pendingPlanIDs: [WorkspaceObjectID]
    var receiptIDs: [WorkspaceObjectID]
}
```

The remaining root records have deliberately small v1 shapes:

```swift
struct WorkspaceRevision: Codable, Hashable, Sendable {
    var id: WorkspaceObjectID
    var parentIDs: [WorkspaceObjectID]
    var documentDigest: DocumentDigest
    var writerID: WorkspaceObjectID
    var createdAt: Date
}

struct PresetRecord: Codable, Hashable, Sendable {
    var id: ArtifactID
    var name: String
    var revision: UInt64
    var memberArtifactIDs: [ArtifactID]
}

struct ArtifactTombstone: Codable, Hashable, Sendable {
    var artifactID: ArtifactID
    var aliases: [ExternalAlias]
    var deletedInRevisionID: WorkspaceObjectID
}

struct SourceRootBinding: Codable, Hashable, Sendable {
    var sourceRootID: WorkspaceObjectID
    var checkoutPath: String
    var worktreeIdentity: String?
    var credentialReferenceID: String?
    var observedRevision: SourceRevision?
    var hasUnpublishedChanges: Bool?
}


enum DestinationWritePolicy: String, Codable, Sendable {
    case reviewedReplacement, noClobberApplyOnce
}

struct LinkedDestinationBinding: Codable, Hashable, Sendable {
    var id: WorkspaceObjectID
    var selector: PortableDestination
    var resolvedPath: String
    var writePolicy: DestinationWritePolicy
}

struct DeploymentBaseline: Codable, Hashable, Sendable {
    var artifactID: ArtifactID
    var destinationID: WorkspaceObjectID
    var deployedContent: ContentDigest
    var lastReceiptID: WorkspaceObjectID?
}

struct TargetCapabilityEvidence: Codable, Hashable, Sendable {
    var surface: TargetSurface
    var installedClientVersion: String?
    var adapterContractVersion: UInt
    var component: ComponentKind
    var transport: String?
    var scopes: [ToolingScope]
    var support: CapabilitySupport
    var observedAt: Date
}

enum CapabilitySupport: Codable, Hashable, Sendable {
    case supported
    case unsupported(reason: String)
    case unknown(reason: String)
}
```

`DestinationWritePolicy` initially distinguishes reviewed replacement from no-clobber Apply once. `CapabilitySupport` is `supported`, `unsupported(reason:)`, or `unknown(reason:)`. Associated-value enums encode as `{ "kind": "...", "payload": { ... } }`; they do not use synthesized enum encoding.

Portable state may contain credential-free HTTPS repository identities, publisher IDs, approved revisions/digests, logical projects, and desired assignments. It must exclude absolute paths, environment values, credential names or values, client scan timestamps, command availability, runtime health, caches, pending operations, and receipts. Unsupported document versions are rejected for writing; readers may preserve opaque future fields only through an explicit versioned envelope.

Every `centralUpstream(subscriptionID:)` points to one `UpstreamSubscription` owned by a root package or standalone root skill with no parent. A child inherits that same authority/subscription; it does not create another subscription. The owning root's materialized `contentDigest`, when present, equals the lock's `approvedContent`; a child digest describes only its subtree. The lock's `packageRelativePath` must appear in its source's `packageRelativePaths`. The subscription's `artifactID`, `sourceID`, and lock must otherwise agree with the artifact and source records. A publisher source requires `repositoryURL` and `requestedRef`. An unpublished attached-authoring source may omit both and rely on a per-device `SourceRootBinding`; it remains unavailable on a device with no binding. Every logical project referenced by an assignment appears in `logicalProjects`.

## Assignments and target capability

An assignment is the union of independent contributions, not one mutable enabled flag.

```swift
enum AssignmentReason: Codable, Hashable, Sendable {
    case manual
    case preset(presetID: ArtifactID)
    case onboarding(configurationID: WorkspaceObjectID)
    case projectDeclaration(projectID: ArtifactID)
}

struct AssignmentContribution: Codable, Hashable, Sendable {
    var id: WorkspaceObjectID
    var artifactID: ArtifactID
    var destination: PortableDestination
    var reason: AssignmentReason
    var desiredPresence: Bool
    var desiredEnabled: Bool?
}
```

- V1 persists only contributions with `desiredPresence == true`; removing intent deletes that contribution. Effective presence is required while any contribution remains, so removing one cannot remove another reason.
- `desiredEnabled == nil` preserves current/unknown native enablement. It does not mean enabled. Concurrent explicit `true` and `false` contributions produce an assignment conflict; neither value wins by ordering.
- `PortableDestination.deviceIDs == nil` addresses all enrolled devices and an empty array intentionally addresses none. Device intent is never inferred from the Mac currently evaluating the document.
- Whole-plugin assignment resolves through the parent. Children may explain inherited availability but generate no independent install step.
- Portable assignment records reject native-owned plugin children; callers assign the parent package explicitly. Portable personal/upstream skill children remain assignable when supported.
- D2 preserves a merged native plugin as one root ID and one child identity graph while attaching each observed client ID as a typed route. A1 expands a root assignment into at most one action for each supported destination client and selects that client's route; it never duplicates child identities or invents a missing route.
- `project` and `localProject` destinations require a logical project ID. User, workspace, managed, account, and session destinations must omit it, so no project context is inferred from the evaluating Mac.
- A physical destination receives at most one planned mutation per command, even when several logical surfaces consume it.
- `TargetCapabilityEvidence` is device state keyed by target surface, installed client version, adapter contract version, component kind, transport, scope, and evidence time. Resolution returns supported, unsupported with reason, or unknown. Unknown never becomes an actionable install claim.
- Legacy profiles, collections, and target bindings retain their current nil/empty/inheritance semantics until D2 supplies an explicit conversion preview.

### Implemented assignment intent resolver

`WorkspaceAssignmentResolver` is the pure A1 device read model. It consumes
explicit artifact contributions and adapter-captured `ResolvedAssignmentTarget`
records. A resolved target maps a logical surface/scope/project selector to a
physical destination ID and an installed client/adapter version. It does not
derive paths from a portable selector. The adapter must capture that identity;
the resolver cannot verify a filesystem path itself.

Requirements group by artifact ID and physical destination ID, retaining the
original contribution IDs, reasons, selectors and optional enabled directives.
Multiple logical surfaces using the same destination do not become duplicate
requirements. Removing one preset contribution leaves manual/other reasons
intact. Preset membership is never re-expanded here: Apply-once contributions
are explicit snapshots of intent, not subscriptions to the current preset.

The resolver requires matching surface, client version, adapter contract,
component, transport and scope capability evidence. Missing, unknown,
unsupported or contradictory evidence stays blocked. Native roots use the
selected client's exact route; native children are rejected. Tracked-only
records remain unresolved ownership. Content requirements compare a captured
typed digest with the artifact's declared digest, and MCP requirements also
need explicit transport definition evidence. These checks do not read or stage
files and do not establish executable readiness.

Conflicting enabled values and incompatible native strategies at one physical
destination block that requirement. An unresolved contribution must not be
dropped to make the remaining shared-destination intent appear satisfiable.
Independent destinations can still be explained separately. Full portable
source/project/reference validation remains the document/service boundary.

This module returns requirements and issues, not filesystem patches or native
commands. S3/Y2 still need fresh complete-content capture, destination entry
collision/composition, baselines, a reviewed journal, writes and receipts.
Several artifact requirements targeting one shared config file must eventually
compose into one reviewed file mutation. Removal requires contribution deletion
and a receipt-backed plan; `desiredPresence == false` is rejected. The A1 UI,
service command and old/new destination-plan parity remain separate acceptance
work.

## Revision and writer semantics

`WorkspaceRevision` contains a unique revision ID, zero or more parent revision IDs, document digest, opaque writer ID, and creation time. `writerID` identifies the revision author for merge/audit and is not a local path, credential, or permission. Time is audit metadata, not conflict ordering.

Every mutation command carries `expectedRevisionID`, an `idempotencyKey`, a canonical input digest, and an actor classification. The Swift `WorkspaceApplicationService` is the sole writer of new-format workspace state. UI and management CLI call it; MCP remains queue-only and cannot approve or apply its own request.

The service must:

1. Reject a stale expected revision before preparing filesystem writes.
2. Return the recorded result when the same idempotency key and input digest repeat; reject reuse with different input.
3. Stage complete content, validate it, and verify fresh destination baselines before apply.
4. Journal intended filesystem changes and the database projection before replacement.
5. Commit one new revision only after required writes succeed; record partial native outcomes as device receipts rather than portable success.
6. Recover or surface an explicit conflict after interruption. It must never pair new metadata with old content silently.

These rules are contracts for D3/Y2. D1 only defines and round-trips the types.

## Agent Plugins diagnostics

Agent Plugins is a package contract, not a marketplace feed or workspace database. V1 recognizes only locally bundled schema identifiers and never downloads a schema while loading.

```swift
enum PackageDiagnosticScope: String, Codable, Sendable {
    case package, manifestField, componentType, skill, mcpEntry, compatibility, runtime
}

enum DiagnosticSeverity: String, Codable, Sendable {
    case information, warning, error
}

struct PackageDiagnostic: Codable, Hashable, Sendable {
    var scope: PackageDiagnosticScope
    var severity: DiagnosticSeverity
    var code: String
    var relativePath: String?
    var componentID: String?
    var message: String
}
```

Failure invariants for AP1/AP2:

- Unsupported/missing manifest schema and fatal manifest violations reject the package before component discovery.
- Unknown top-level manifest fields are reported and ignored. A non-object `extensions` value is reported and ignored. Unimplemented extension namespaces remain opaque and are not interpreted.
- A wrong-kind or escaping fixed component location disables only that component type. One invalid skill skips that skill; one invalid MCP entry skips that entry. Siblings continue.
- `plugin.json` and `mcp.json` Agent Plugins versions must match. Schema validation limits and product ingestion limits produce distinct diagnostic codes.
- Compatibility diagnostics state what a specific installed adapter/version can consume. A portable manifest alone never implies support in every client.
- MCP parsing does not establish runtime conformance. Placeholder expansion, persistent `PLUGIN_DATA`, command/cwd containment, environment precedence, transport behavior, redirect/header-origin handling, and failure isolation require AP5 mapping fixtures before that route is supported.
- Native `.claude-plugin`, `.codex-plugin`, reverse-domain extension directories, scripts, resources, and unknown package files remain complete bytes through supported staging/export operations. Native adapter semantics are not translated speculatively.

## Initial encoding example

```json
{
  "schemaVersion": 1,
  "minimumReaderVersion": 1,
  "minimumWriterVersion": 1,
  "workspaceID": "89b7e86e-60f2-45cc-90fa-b56b5a318904",
  "revision": {
    "id": "cc46f206-c4d0-4d60-9599-d7fd84dd2680",
    "parentIDs": [],
    "documentDigest": { "algorithm": "sha256CanonicalJSONV1", "value": "<hex>" },
    "writerID": "fe83934a-e9c3-4b0e-a879-c79ebf31085c",
    "createdAt": "2026-09-08T12:00:00.000Z"
  },
  "artifacts": [],
  "sources": [],
  "subscriptions": [],
  "logicalProjects": [],
  "assignments": [],
  "presets": [],
  "tombstones": []
}
```

Encoding is deterministic: object keys are lexicographically sorted by Unicode scalar value; UUID strings are lowercase RFC 4122 text; dates are rounded once to the nearest millisecond and encoded as UTC RFC 3339 with exactly three fractional digits; optional `nil` fields are omitted; arrays without product ordering are sorted by their canonical scalar or stable ID; strings are UTF-8 without insignificant whitespace. Before hashing, omit `revision.documentDigest` entirely, encode the remaining document canonically, hash those bytes with SHA-256, then insert `{ "algorithm": "sha256CanonicalJSONV1", "value": <lowercase hex> }`. Complete package trees use `sha256TreeV1`; canonical JSON uses `sha256CanonicalJSONV1`. D1 fixtures must assert exact bytes, not only decoded equality.

The v1 decoder is deliberately strict. After typed decoding, structural validation, and digest verification, it canonicalizes and re-encodes the value and requires byte-for-byte equality with the input. Extra root or nested fields, alternate key or array order, insignificant whitespace, noncanonical dates or UUIDs, and unexpected enum payloads are rejected as noncanonical or unsupported content. Future opaque fields require an explicit versioned envelope; synthesized `Codable` must never silently discard them and then save a reduced document.

## First implementation boundary

D1 and AP1 may add these proposed types, validation errors, deterministic encoding, and fixture tests in new Core files. They must not migrate the SQLite store, rewrite `WorkspaceSnapshot`, alter live resolver output, move package files, edit native configuration, fetch sources, or claim Agent Plugins runtime conformance. Any contract change discovered during implementation returns to F1 review before dependent workers invent divergent types.

## Schema 2 configuration supplement

Schema 2 adds a required `configurationState` to the portable document and a
separate configuration supplement to device state. The canonical v1 reader and
writer remain available for existing v1 documents; they omit the new field and
retain their original digest. A v2 document requires reader/writer version 2.
Supplying v2 fields under a v1 version, dropping the v2 field, or supplying
unknown fields fails validation rather than discarding data.

Configurations retain inheritance, check definitions, raw requirements,
collection references, and nil/empty/three-state target choices. Collections,
tags, policies, and catalog sources keep their own records. They are not
converted into presets or authoring repositories. Each typed legacy key has a
single reserved object UUID in the identity map; resolution is a separate
reference state. Missing inventory can therefore retain its allocation while
its requirement remains unresolved.

A portable default configuration and a device active-configuration override
are separate. Migration preserves the old active selection as the local
override and leaves the shared default unset. Project paths, check observations,
local catalog paths, policy-import locations, and refresh times are device
records. None contributes to the portable revision digest.

The migration allocator uses domain-separated SHA-256 with length-delimited
UTF-8 fields and UUIDv8 version/variant bits. The workspace ID, entity kind,
legacy identifier, and optional policy owner all contribute. Previous mappings
are retained even when an entity disappears from a scan. Catalog UUIDs are
retained when unclaimed; collisions with a prior mapping receive the hashed
identity, while conflicting persisted mappings fail. This is identity
allocation only, not evidence of source or content ownership.

The configuration supplement and pure preview are additive. They do not
activate the new store or migrate client files. Full reference coverage,
assignment comparison, migration checkpoints and rollback remain separate D2
acceptance requirements.

## Schema 4 device inventory and application state

New device records use schema 4 alongside portable schema 3. They require
`applicationState`, `inventoryState` and `projectRoots`; empty records are
valid, omitted records are not. Device schemas 1–3 omit all three fields and
cannot write them under an older version.

Application state contains local preferences, backup/sync locations,
account/connector observations, cached catalog rows and history. Catalog rows
retain their legacy UUID source references, validated through the configuration
identity map to live catalog records. Project roots refer to actual logical
projects and must agree with any configuration root that is present.

Inventory metadata retains complete captured legacy skill/plugin/MCP rows,
linked to live artifact IDs. These are historical observations, not authority,
assignments, source subscriptions or operations. The shared artifact and source
records remain authoritative even when a captured `owned` or `installed` flag
describes an older state. Application read models must keep that distinction.

The schema 4 device wire preserves the existing Codable leaf shapes for legacy
records, including Foundation UUID casing in receipt/account/catalog IDs and
original string identifiers. New domain IDs still use lowercase UUID strings.
Known set fields are sorted explicitly, all dates use millisecond precision,
and ordered histories and client arrays retain their order. Canonical
decode/re-encode rejects unsupported fields and alternate encodings.

See [migration assembly](workspace-migration-assembly-v1.md) for the combined
candidate and the remaining checkpoint, resolver and application cutover gates.
