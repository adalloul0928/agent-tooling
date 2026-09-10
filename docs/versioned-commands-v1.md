# Versioned workspace commands v1

Status: contract proposed 2026-09-09; all four commands implemented 2026-09-10
(`NativePackageAdoptionCommand`, `ManagedMCPServerIntakeCommand`,
`WorkspaceCatalogSourceCommand`, `LinkSkillUpstreamCommand`, each with its
`WorkspaceApplicationService+…` extension and tests) and wired into Discover,
Connections and Skills. Section 5's second tier remains unbuilt. Nothing here
installs a tool, writes a client file, contacts a catalog, or reports a native
result: every command below changes workspace metadata and returns a metadata
receipt.

PR #66 restored the app's interface on the versioned store, and every restored
screen was honest about the same thing: the versioned model has no command for
several things a person naturally does, so those screens show a disabled control
and one clause saying why. This document designs those commands, in the order
they cost a person the most.

Two rules hold in every section, and neither is re-argued below:

- **Requested assignment is never installation.** Adding something to the
  library, and asking for it somewhere, are two different acts; installing is a
  third, and only the Install surface performs it.
- **No action the authority forbids.** A command that would take ownership the
  person did not ask for is refused rather than negotiated.

## What the schema needs: nothing

Every record these four commands write already exists.

| Command needs | Record | Where it was added |
| --- | --- | --- |
| A catalog package as a library item | `ArtifactRecord` with `nativeOwned` authority and a `NativePackageRoute` | schema 1 |
| An MCP server definition | `PortableMCPDefinitionRecord` + `DeviceMCPDefinitionBinding` | [schema 3](workspace-mcp-definitions-v3.md) |
| A catalog source | `WorkspaceCatalogSourceRecord` + `WorkspaceMigrationIdentityEntry` + `CatalogSourceDeviceState` | schema 2 |
| A skill's upstream link | `PortableSourceDescriptor` + `UpstreamSubscription` + `UpstreamLock` | schema 1 |

**The document schema version does not change, and neither does the device
schema version.** Not as a compatibility concession — there is nothing to
version. This packet adds no field to any wire format, so every existing store
and every document synced from another Mac encodes to exactly the bytes it
encoded to before and keeps its digest. `VersionedCommandFoundationTests`
re-pins the fixed schema-2 bytes and digest to prove it.

If a later packet does need a field, the rule the canonical codec imposes is
narrow and worth stating once, because getting it wrong stops every existing
document opening. `WorkspaceDocumentCoding.decode` re-encodes what it decoded
and requires byte-for-byte equality with the input, and every root record uses
synthesized `Codable`. So a new **non-optional** property — even an array with a
default — makes every older document fail to decode: synthesized decoding throws
on the missing key, and if it did not, re-encoding would emit `"newField":[]`
and the byte comparison would fail. A new **optional** property is omitted when
`nil` by synthesized encoding and decodes as `nil` when absent, which is exactly
the `decodeIfPresent` shape `WorkspacePreferences` uses by hand. Any new field
must therefore be `Optional`, must be `nil` for every document written before
the command that fills it, must be normalized back to `nil` when empty in
`canonicalized()` so `nil` and `[]` cannot both occur, and must be mirrored into
`DigestDocument`.

## 1. Turn a catalog package into a library artifact

### Purpose

Discover lists real catalogs — 424 packages on the author's Mac — and every
install button is disabled. This command is the missing step between "this
catalog publishes a package" and "this package is an item in my library that I
can assign and then install".

### The gap

`Sources/AgentToolingApp/MarketplaceView.swift:613` disables the per-route
install button with a comment reading "Unreachable: the button never enables",
and `WorkspaceMarketplaceSession.swift:58` states the reason once for the whole
screen: "Adding catalog packages to the library is not available in this build."

Everything on the deployment side of that button exists and is public:
`NativeCatalogPackageIdentity.recognize` (`NativeCatalogPackageIdentity.swift:14`)
→ `NativePackageRoute` → `NativePluginInstallRegister.reviewedInstall`
(`NativePluginInstallRegister.swift:60`) →
`WorkspaceApplicationService.deploymentPlan(nativeInstallRoutes:)`
(`WorkspaceApplicationService.swift:146`) → `.installNativePackage(route:)`
(`WorkspaceDeploymentPlanner.swift:35`) →
`WorkspaceNativePluginCommandPlanning.plan`. What is missing is the one write
that puts an `ArtifactRecord` carrying that route into the document.

### Reads and writes

Reads `document.artifacts` and `document.tombstones`. Writes exactly one record:

```swift
ArtifactRecord(
    identity: ArtifactIdentity(
        id: command.artifactID,
        kind: .nativePlugin,
        displayName: command.displayName,
        aliases: [NativePackageAdoption.pluginAlias(client:externalPluginID:)]),
    authority: .nativeOwned,
    declaredName: command.externalPluginID,
    packageRelativePath: nil,
    contentDigest: nil,
    nativeRoutes: [NativePackageRoute(client:externalPluginID:)])
```

No assignment. No content digest. No device state. **No identity-map entry**:
`WorkspaceConfigurationState.validate` requires an allocation for a
configuration, policy, collection or catalog source, and for none of them is an
artifact one — `LegacyReferenceDomain.isArtifact` entries are validated only
when they already exist. The follow-up note in the restoration plan is wrong on
this point.

### Authority

`nativeOwned`, and this is the decision that matters. The contract says
`nativeOwned` "stores provenance and desired presence only" and that "the native
clients own the complete plugin, its adapters, children, enablement, and update
route". That is precisely what adopting a catalog listing records: the client
will own these bytes, this app will not, and no content is claimed.

The two alternatives are worse and were rejected explicitly:

- `trackedOnly` records something without claiming an update route, but a
  tracked row is not assignable (`WorkspaceLibraryReadModel.swift:82`), so
  Install could never reach it. That is the disabled button in another costume.
- `centralPersonal` would claim this workspace holds the package's bytes. It
  does not, and `deploymentPlan` would then look for content that is not there.

Recording a route is not a presence claim. Four independent things still have to
hold before anything installs: a saved assignment, a resolved target for this
Mac, matching capability evidence, and the route appearing in
`nativeInstallRoutes` — which `WorkspaceDeploymentSession.reviewedNativeRoutes`
derives from `NativePluginInstallRegister`, not from the artifact.

### Identity, and being adopted twice

`NativePackageAdoption.recognize(client:externalPluginID:in:)` — landed — answers
one question with four answers, and both Discover and the command ask it:

| Answer | Evidence | What the command does |
| --- | --- | --- |
| `.exact(match)` | A root artifact carries this client's `NativePackageRoute`, or this client's `<client>.plugin` alias | Refuses `alreadyInLibrary(match)` |
| `.removed` | A tombstone carries this client's plugin alias | Refuses `previouslyRemoved` |
| `.sameDeclaredName(match)` | A root `nativePlugin` declared this identifier but carries no route for this client | Refuses `ambiguousExistingRecord(match)` |
| `.none` | — | Writes the record |

The first two are identity; the third deliberately is not. An external plugin ID
is a name inside one client's namespace, and the contract is explicit that
"equal names or equal bytes are insufficient identity evidence". A package
called `docs` in the Claude catalog and one called `docs` in the Codex catalog
may be the same product seen twice or two unrelated packages, and this build
cannot tell — so it refuses and names the row rather than silently merging two
publishers into one library item or silently creating a second record of one
package. A display name is never consulted at any point.

`.sameDeclaredName` is also how a first-run scan's `trackedOnly` package appears:
`WorkspaceFirstRun.prepare` records a package as `trackedOnly` with
`declaredName: plugin.id` and no routes whenever it saw no client route or could
not locate the package's member files (`WorkspaceFirstRun.swift:67-70`).
Promoting that record to `nativeOwned` is **not** in scope here — the contract
says "ownership changes, explicit forks and source rebinding require their own
commands", and it would fail validation anyway, because a tracked package's
pathless skill children are only legal under `trackedOnly` at schema 5
(`PortableWorkspaceDocument.swift:306`). Recognizing a tracked package as its
client's is named as later work below.

### Command and service

```swift
public struct NativePackageAdoptionCommand: Codable, Sendable, Equatable {
    public let expectedRevisionID: WorkspaceObjectID
    public let idempotencyKey: WorkspaceObjectID
    public let artifactID: ArtifactID
    public let client: ClientKind
    public let externalPluginID: String
    public let displayName: String

    /// Fails when the listing does not carry the exact catalog identity its
    /// parser preserved, or when no install command has been recorded for the
    /// client. Building the command is where a listing is refused; applying it
    /// is where the library is.
    public init(
        expectedRevisionID: WorkspaceObjectID,
        idempotencyKey: WorkspaceObjectID = WorkspaceObjectID(),
        artifactID: ArtifactID = ArtifactID(),
        package: MarketplacePackage,
        client: ClientKind) throws
}

extension WorkspaceApplicationService {
    public func adoptNativePackage(
        _ command: NativePackageAdoptionCommand) throws -> WorkspaceCommandReceipt
}
```

The initializer takes the `MarketplacePackage` rather than a client/ID pair so
that a caller cannot assemble an identity the catalog parser never produced;
`NativeCatalogPackageIdentity.recognize` is the only way in.

### Preconditions and refusals

| Refusal | Reason text the screen shows |
| --- | --- |
| `unrecognizedListing` | "This listing does not carry the package identity its catalog records, so it cannot be added by name." |
| `noRecordedInstallCommand(client)` | "Nothing has recorded how \(client) installs a package, so this would be a library item Install could never act on." |
| `alreadyInLibrary(match)` | "\(match.displayName) is already in your library. Open it to choose where it goes." |
| `ambiguousExistingRecord(match)` | "Your library already has a package called \(externalPluginID) — \(match.displayName) — recorded from another app. Open it rather than adding a second record of the same name." |
| `previouslyRemoved` | "You removed this package from your library before. Add it back from the library rather than from a catalog listing." |
| `identityCollision` | "That identity is already used in this workspace." |

`noRecordedInstallCommand` is what Gemini gets:
`NativePluginInstallRegister.command` returns `nil` for it on purpose, because
nothing has read Gemini's install command and writing a plausible one is the
invention the register exists to avoid.

### Receipt

`WorkspaceCommandReceipt` with `affectedArtifactIDs == [artifactID]`. It records
that the library changed. It says nothing about installation, and the screen
must not present it as one — after it lands, the row's next step is assignment.

### Merge and sync

Two Macs adopting **different** packages combine, since they are different
artifact IDs. Two Macs adopting the **same** package produce two artifacts
carrying one route, which the landed document-wide route-uniqueness rule
(`PortableWorkspaceDocument.validateNativeRouteUniqueness`) refuses — the same
"at most one live artifact" guarantee aliases already have. Without a named
conflict the whole merge would come back as `invalidResult`, which a person
cannot act on, so the merge engine now reports `nativeRouteCollision`: "Both Macs
added the same app package to the library separately." It is not a pick-a-side
conflict — the fix is to remove one of the two rows — so
`WorkspaceConflictResolver` lists it among the kinds it declines to resolve.
Adoption on one Mac and nothing on the other fast-forwards.

### Call site

`MarketplaceView.installRoutes(for:)` (the `.disabled(true)` at line 613) and a
new `WorkspaceMarketplaceSession.adopt(_:client:)`. After the receipt the session
refreshes the library session, `reload()` repopulates `installedRoutes`, and
`libraryMatch(for:)` — which already exists — flips the button to the existing
row. `MarketplaceView.swift:47` (Add source) belongs to command 3, not this one.

### Tests

Adopting writes exactly one `nativeOwned` root with one route, one alias, no
digest and no assignment; the same command replayed returns its original
receipt; a second adoption of the same package is refused by name; a listing
whose route is already in the library is refused; a first-run `trackedOnly`
package of the same identifier is refused as ambiguous rather than duplicated; a
tombstoned package is refused; a Gemini listing is refused; a stale expected
revision is refused; and the adopted row appears in `deploymentPlan` only once
an assignment and a reviewed route exist.

## 2. Record an MCP server definition as a library item

### Purpose

Give a person a way to write down how a connection is reached, so the test
console can test it, the paste sheet can save it, and an agent's request to add
a server has a row to land on.

### The gap

`VersionedInventoryProjection.server` emitted `endpoint: ""` for every projected
server (`VersionedInventoryProjection.swift:82` and `:91` at `f121ab8`). Three
things followed:

- `MCPTestConnectionPolicy.resolve(server:)` calls
  `MCPDefinitionValidator.validate("")`, which throws `destinationTooLong`, so
  the restored console refuses every projected server with a message about a
  malformed endpoint rather than the truth.
- `PasteImportSheet.isPrimaryDisabled` returns `true` for every parsed server
  with the comment "No versioned command admits a server definition, so this
  never enables" (`PasteImportSheet.swift:133`), and
  `noServerIntakeExplanation` (line 149) says so on the button.
- `WorkspaceRequestSession.intent(for:)` can accept an agent's `.addMCPServer`
  only when a matching row already exists (`WorkspaceRequestSession.swift:243`),
  which is correct and stays correct — accepting a request must never create a
  library item — but nothing else could create one either.

**The record was never missing.** `PortableMCPDefinitionRecord` and
`DeviceMCPDefinitionBinding` have existed since schema 3
(`WorkspaceMCPDefinitions.swift:35` and `:86`), the resolver already produces a
`managedMCP` strategy from them (`WorkspaceAssignmentResolver.swift:349`), the
planner already turns that into `configureManagedConnection`
(`WorkspaceDeploymentPlanner.swift:244`), and
`WorkspaceManagedMCPCommandPlanning` already bridges it to a reviewed operation.
What is missing is the intake command, and the projection — which is landed.

### Reads and writes

Reads `document.artifacts`, `document.mcpDefinitions`, `device.mcpBindings`.
Writes, in one transaction:

- `ArtifactRecord(kind: .mcpServer, authority: .centralPersonal, declaredName:
  name, contentDigest: nil, parentPackageID: nil)`;
- `PortableMCPDefinitionRecord(artifactID:connection:)` appended to
  `document.mcpDefinitions`;
- `DeviceMCPDefinitionBinding(...)` appended to `device.mcpBindings`, through
  `commitMetadata`'s `deviceMutation`, exactly as `attachAuthoringRoot` does.

All three must land together: `WorkspaceMCPDefinitionValidation.validatePortable`
requires that *every* standalone `centralPersonal` `mcpServer` artifact has a
definition (`WorkspaceMCPDefinitions.swift:168-172`), so an artifact written without
one fails validation inside the same transaction, and the whole command rolls
back.

### Portable or device, and secrets

The split is the contract's, not the caller's, and the command computes it so two
Macs cannot disagree:

- an `https` URL whose host is a multi-label DNS name that does not end in
  `.local` or `.localhost` becomes `.remoteHTTPS(url:)` in the **portable**
  document;
- everything else — `http`, IP literals, single-label and local names, and every
  stdio command — becomes `.deviceBound(transport:)` portably, with the actual
  address or argument vector in this Mac's **device** binding.

`WorkspaceMCPDefinitionValidation.validateURL(_:portable:)` already decides this
and already rejects the rest.

Secrets never enter either record, and three independent things enforce it.
`PastedDefinitionParser` drops every environment and header **value** on the way
in and keeps only names. It carries those names as data, on
`PastedMCPServerDraft.secretNames` — sorted, without repeats, values never
included — and *also* says so in a note the sheet shows. The note is for the
person; the list is what a caller reads. Neither the sheet nor the intake
command parses that sentence back apart to find the names.
`MCPDefinitionValidator.containsInlineSecret` refuses credential flags,
`authorization: bearer`, secret-shaped `KEY=value` arguments and URLs with a
user, password or query. `DeviceMCPDefinitionBinding.validate` refuses any
credential requirement *name* that itself looks like a value, and bounds the
name grammar to letters, digits, underscore, dot and hyphen. The command records
the union of environment and header names from the draft as
`credentialRequirementNames`, deduplicated and sorted, and maps
`MCPDraft.authentication` to `MCPAuthenticationRequirement`
(`OAuth`→`.oauth`, `API key`→`.apiKey`, `Doppler`→`.doppler`, `None`→`.none`,
and `.environment` when the paste dropped environment names and the person chose
nothing else). A name that fails the grammar is refused with the name quoted,
never silently dropped — "Other legacy names require review", per the schema-3
contract.

### Command and service

```swift
public struct ManagedMCPServerIntakeCommand: Sendable {
    public let expectedRevisionID: WorkspaceObjectID
    public let idempotencyKey: WorkspaceObjectID
    public let artifactID: ArtifactID
    public let displayName: String
    public let declaredName: String
    public let connection: PortableMCPConnection
    public let destination: DeviceMCPDestination?
    public let credentialRequirementNames: [String]
    public let authenticationRequirement: MCPAuthenticationRequirement
    public let workspaceRootPath: String?

    /// Validates and splits the draft. A draft that cannot be recorded is
    /// refused here, with the validator's own words.
    public init(
        expectedRevisionID: WorkspaceObjectID,
        idempotencyKey: WorkspaceObjectID = WorkspaceObjectID(),
        artifactID: ArtifactID = ArtifactID(),
        draft: MCPDraft,
        credentialRequirementNames: [String] = []) throws
}

extension WorkspaceApplicationService {
    public func intakeManagedMCPServer(
        _ command: ManagedMCPServerIntakeCommand) throws -> WorkspaceCommandReceipt
}
```

### Preconditions and refusals

| Refusal | Reason text the screen shows |
| --- | --- |
| the validator's own error | `MCPDefinitionValidationError`'s message, verbatim — it already explains credentials, control characters and unmatched quotes better than a restatement would |
| `alreadyManaged(name)` | "A connection called \(name) is already in your library. Open it to change how it is reached." |
| `invalidCredentialName(name)` | "\(name) is not a name this workspace will record. Rename it in the app that needs it, or set it up through that app's own credential flow." |
| `identityCollision` | "That identity is already used in this workspace." |
| `previouslyRemoved` | "You removed a connection with this identity before. Add it back from the library rather than from a paste." |

A workspace-scoped connection with no project folder is **not** refused: the
binding's `workspaceRootPath` is optional, and the resolver reports the missing
setup at Install time (`WorkspaceAssignmentResolver.swift:324`) where it can be
fixed. Refusing at intake would lose the definition over a fact that belongs to
one device.

### Receipt

`WorkspaceCommandReceipt` with `affectedArtifactIDs == [artifactID]`. It records
that a declaration exists. It asserts nothing about the server running, being
reachable, or being authenticated — the AP5 contract's line, unchanged.

### Merge and sync

`mcpDefinitions` already merges, keyed by `artifactID`, reporting `artifactField`
when both Macs changed one definition ("Both Macs changed this connection's
shared definition"). Two Macs adding **different** servers combine.

Two Macs adding the **same** server produce two artifacts with different IDs and
the same `declaredName`, and this is deliberately *not* made a validation error.
Two rows is recoverable and visible; a document-wide name-uniqueness rule would
turn an ordinary concurrent action into a whole-merge refusal. The case that
actually breaks a client file — both being assigned to one destination — is
already caught as `destinationCollision`, which compares declared names at a
destination (`WorkspaceMergeEngine.reportDestinationCollisions`).

Device bindings never sync, by contract. The other Mac sees the connection, has
no binding, and is told so: the resolver raises `missingDeviceMCPBinding` and
Install says "This connection has no local setup on this Mac yet." A remote
HTTPS connection needs no binding at all and works on both Macs immediately.

### Call sites

`PasteImportSheet` — `primaryTitle` ("Add server"), `isPrimaryDisabled`,
`performPrimaryAction`, and the `noServerIntakeExplanation` clause, all of which
become live. `MCPServersView` gains an "Add connection…" entry through the same
sheet. `MCPTestConsoleView` needs **no change**: once the projection carries an
endpoint, `MCPTestConnectionPolicy.resolve` resolves it.
`WorkspaceRequestSession` also needs no change — its rule that a request can only
be accepted onto an existing row is correct and stays.

### Tests

A remote HTTPS draft lands as `remoteHTTPS` with no device destination; an
`http://localhost` draft and every stdio draft land as `deviceBound` plus a
binding; a stdio argument containing a space survives intake and round-trips
through `MCPDefinitionValidator.parseCommandLine`; a draft with a credential in
the URL, an inline `--api-key`, or an `Authorization: Bearer` header is refused
with the validator's message; environment and header names are recorded and
their values are absent from both the portable bytes and the device bytes; a
second server with the same declared name is refused; the artifact and the
definition commit together, and a forced failure leaves neither; the projected
server resolves in `MCPTestConnectionPolicy`; and a document written by this
command still validates on a Mac with no binding.

## 3. Add or remove a catalog source

### Purpose

Let a person add a catalog — a Git repository, a folder of packages, a registry —
and remove one they added.

### The gap

`WorkspaceCatalogSourceRecord` lives in
`document.configurationState.catalogSources` and nothing appends to it.
`MarketplaceView.swift:47` disables "Add source…" and line 107 states why once:
"Adding or removing a catalog source is not available in this build. The sources
shown are the ones this workspace already records."
`WorkspaceMarketplaceSession.sources` says the same in a comment: "Read-only:
adding one is not a command this build has" (line 35). The per-source Remove was
dropped in the port. `WorkspaceApplicationService` has no method that touches
`configurationState`.

### Reads and writes

Portable: appends or removes a `WorkspaceCatalogSourceRecord` in
`configurationState.catalogSources`, **and** its
`WorkspaceMigrationIdentityEntry` in `configurationState.identityMap`. The
allocation is not optional — `WorkspaceConfigurationState.validate:410-413` refuses a
source without one, and `validateAllocation:513` refuses an allocation whose
object is gone. The two move together or the document does not validate;
`WorkspaceCatalogSourceIdentity` — landed — is the one place that pairs them.

A source nobody migrated has no legacy identifier, so its allocation uses its own
lowercase UUID as the identifier: unique by construction, stable for the life of
the record, and not a claim that some earlier database held it. A migrated source
keeps whatever identifier it was allocated under, which is why removal looks the
entry up by object rather than recomputing one.

Device: `CatalogSourceDeviceState` in `device.configurationState.catalogSources`
holds `localLocation`, `lastRefreshedAt`, `lastRevision` and `trustSummary`. A
**local folder** catalog's path is device state and its portable record carries
`kind: .localFolder` with `remoteLocation: nil` — the record's own comment says
"Local paths belong in device state", and the contract forbids absolute paths in
portable bytes.

### Command and service

```swift
public struct WorkspaceCatalogSourceCommand: Sendable {
    public enum Change: Sendable {
        case add(WorkspaceCatalogSourceRecord, localLocation: String?)
        case remove(WorkspaceObjectID)
    }
    public let expectedRevisionID: WorkspaceObjectID
    public let idempotencyKey: WorkspaceObjectID
    public let change: Change
}

extension WorkspaceApplicationService {
    public func changeCatalogSource(
        _ command: WorkspaceCatalogSourceCommand) throws -> WorkspaceCommandReceipt
}
```

The receipt's `affectedArtifactIDs` is empty: a catalog source is a workspace
object, not an artifact, and the receipt must not name one that does not exist.

### Preconditions and refusals

| Refusal | Reason text the screen shows |
| --- | --- |
| `alreadyRecorded(name)` | "That catalog is already in your list, as \(name)." |
| `identityCollision` | "That identity is already used in this workspace." |
| `missingSource` | "That catalog is not one this workspace recorded, so there is nothing to remove." |
| `invalidLocation` | "Enter a catalog address without a user name, password, query or fragment." |
| `invalidLocalFolder` | "Choose a folder that exists on this Mac." |

`missingSource` is what the five built-in reference rows get. They are not
records — `MarketplaceCatalogs.builtInSourceID` derives a stable UUID per kind so
a selection survives a refresh — and the screen already says nobody added them
and nobody can remove them. Removing a *recorded* source of a kind simply reveals
its reference row again, which is the behaviour `reload()` already implements.

### Removal, and why there is no tombstone

This is the decision in this document most worth a second opinion.

Removal deletes the record, its identity-map entry and this device's
`CatalogSourceDeviceState` row in one transaction, and writes **no tombstone**.

`ArtifactTombstone` is typed to `ArtifactID` and its stated purpose is to
"prevent accidental recreation or stale-reference reuse" — the case where
something that scans the machine would silently resurrect an item a person
deleted. Nothing scans catalog sources into the document; they exist only because
somebody typed one in, and typing the same one again is both intended and
harmless. Deletion is therefore decided by the merge engine's **other** named
mechanism, ancestry, exactly as preset membership already is: "Preset membership
uses a three-way set merge, so one Mac adding a member cannot resurrect what the
other removed."

The alternative — a `catalogSourceTombstones` field — would also be the only new
wire field in this packet, and would force the schema-version question the rest
of this design avoids. A retained identity-map entry cannot stand in for one
either: `validateAllocation` refuses an allocation whose live object is gone.

### Merge

Before this packet the merge engine took `configurationState` wholesale from the
local side — `local.configurationState ?? remote.configurationState ?? .init()` —
so a catalog added on the other Mac was silently lost. That was harmless while
nothing could write one and is not harmless now. Landed
(`WorkspaceMergeEngineConfiguration.swift`):

| Concurrent change | Result |
| --- | --- |
| Each Mac adds a different catalog | Both kept, with both allocations |
| One removes a catalog, the other adds a different one | The removal is honoured and the addition kept |
| One removes a catalog, the other renames or re-points it | `catalogSource` conflict; the record survives under the side that still has it |
| Both rename, re-point, re-kind or re-flag one catalog | `catalogSource` conflict, local value kept |
| Everything else in `configurationState` | Unchanged: the local side is taken whole, because nothing writes those records and an unexercised merge is an unchecked one |

`catalogSource` **is** a pick-a-side conflict, so `WorkspaceConflictResolver`
resolves it, in both directions: choosing the removal drops the record and its
allocation; choosing the change keeps both.

### Call sites

`MarketplaceView`'s toolbar "Add source…" button (lines 40-47) and a per-source
Remove in `sourcePane`, plus `WorkspaceMarketplaceSession.add(_:)` /
`remove(_:)`. `reload()` already renders the portable and device halves together
and already replaces a reference row with a recorded source of the same kind.

### Tests

Adding writes the record and its allocation together and the document validates;
adding without the allocation fails validation (the reason the helper exists);
a local-folder catalog keeps its path out of the portable bytes; removing takes
the record, the allocation and the device row; removing an unrecorded ID is
refused; removing a built-in reference row is refused; replay returns the
original receipt; and the four merge rows above.

## 4. Link an existing skill to an upstream repository

### Purpose

Turn a skill this library holds as the person's own into one that follows a
published repository, so "Check for updates" and "Review update…" start working
for it.

### The gap

`SkillRepositorySection` handles four ownerships
(`SkillRepositorySection.swift:20-25`). `centralUpstream` gets the working
check-and-review pair. `centralPersonal` gets a paragraph — "You hold this
skill's source. Edit it here, then review where the change should be used" —
and no way to link one, because there is no command: `intakeStandaloneSkill`
creates a *new* artifact and `StandaloneSkillUpdateCommand` preserves authority
rather than changing it (`WorkspaceSkillCommands.swift:135-156`). The port did
not leave a disabled button here; it left the affordance out entirely, which is
worth noting because the restoration plan's follow-up list implies a disabled
control that does not exist.

### Reads and writes

Reads the artifact, `document.sources`, `document.subscriptions`. Writes:

- a `PortableSourceDescriptor(role: .publisherRepository, repositoryURL:,
  requestedRef:, packageRelativePaths:)`, **or** the existing source for the same
  repository and ref, gaining this skill's `packageRelativePath`;
- an `UpstreamSubscription` whose `UpstreamLock` carries the publisher, the
  fetched commit as `approvedRevision`, the skill's current digest as
  `approvedContent`, and the package path;
- the artifact's `authority`, from `.centralPersonal` to
  `.centralUpstream(subscriptionID:)`.

Content is **not** republished. Linking is a statement about where the next
version comes from, not a new version, and the artifact's `contentDigest` does
not move.

### The decision that matters: the bytes must already match

The command carries a `PreparedStandaloneSkill` from
`WorkspaceSkillPreparation.fetchUpstream(binding:cacheURL:)` and refuses unless
`prepared.review.contentDigest == artifact.contentDigest`.

This is forced, and it is also right. `validateStructure` already requires that a
materialized upstream artifact's digest equal its lock's `approvedContent`
(`PortableWorkspaceDocument.swift:169`), so a lock describing bytes the library
does not hold is not a representable document. Behind that rule is the reason:
`centralUpstream` means "the publisher owns future releases; the approved central
tree supplies local deployments". An approved lock that does not describe the
tree actually held would make every later update diff against a fiction, and
would deploy content nobody approved.

So a skill with local edits **cannot** be linked, and **nothing is done to those
edits**. The command never rewrites content and never discards anything; it
refuses, and the screen offers the two honest routes: review the repository's
version as an update (which goes through the existing
`StandaloneSkillUpdateCommand` and is a reviewed content change), or keep the
skill personal.

### Command and service

```swift
public struct LinkSkillUpstreamCommand: Sendable {
    public let expectedRevisionID: WorkspaceObjectID
    public let idempotencyKey: WorkspaceObjectID
    public let artifactID: ArtifactID
    public let expectedContentDigest: ContentDigest
    public let upstreamIDs: StandaloneSkillUpstreamIDs
    public let content: StandaloneSkillContentReview

    public init(
        expectedRevisionID: WorkspaceObjectID,
        idempotencyKey: WorkspaceObjectID = WorkspaceObjectID(),
        artifactID: ArtifactID,
        expectedContentDigest: ContentDigest,
        prepared: PreparedStandaloneSkill,
        upstreamIDs: StandaloneSkillUpstreamIDs = .init()) throws
}

extension WorkspaceApplicationService {
    public func linkSkillUpstream(
        _ command: LinkSkillUpstreamCommand,
        prepared: PreparedStandaloneSkill) async throws -> WorkspaceCommandReceipt
}
```

Taking the preparation at apply time mirrors `intakeStandaloneSkill`: the
service does not re-fetch between review and apply, so what was reviewed is what
lands.

### Preconditions and refusals

| Refusal | Reason text the screen shows |
| --- | --- |
| `contentDiffersFromUpstream` | "The version in your library is not the version this repository publishes. Review the repository's version as an update, or keep this skill as your own." |
| already `centralUpstream` | "This skill already follows a repository." |
| `attachedAuthoring` | "You author this folder yourself, so its own repository is where it is published from." |
| bundled (`parentPackageID != nil`) | "Bundled tools follow their package. Manage the whole package instead." |
| `nativeOwned` / `trackedOnly` | "This library does not hold this skill's content, so it cannot follow a repository for it." |
| `missingContent` | "This skill has no recorded content to compare with the repository." |
| `sourceIdentityConflict` | "This workspace already records a different entry for that repository and branch. Use the one it has." |
| `upstreamAlreadyManaged` | "Another skill in your library already follows that folder in that repository." |
| `reviewMismatch` | "The repository changed while this was being reviewed. Check it again." |

The bundled and non-personal refusals are `requireCentralStandaloneSkill`'s
existing rules, reused rather than restated: it already demands `kind == .skill`,
`parentPackageID == nil`, no native routes and a central authority.
Source-identity reuse follows `StandaloneSkillIntakeCommand` exactly — an
existing publisher source for the same repository and ref must be reused and
gains the new path; a second identity for one repository is refused.

### Receipt

`WorkspaceCommandReceipt` with `affectedArtifactIDs == [artifactID]`. It records
that the skill now follows a repository. It does not fetch anything later, and it
is not a claim that the repository is reachable now.

### Merge and sync

Linking on one Mac and nothing on the other fast-forwards, and the other Mac
needs no device state at all: a publisher source is fetched into a cache and has
no `SourceRootBinding` requirement, unlike an attached authoring root.

The two concurrent cases are not the ordinary field conflicts this section first
claimed. Each writes a *new* subscription with a *new* identity, so nothing
scalar collides — the records simply combine into a graph the workspace contract
does not admit. Each therefore has its own named conflict, reported before the
merged document is validated so a person is told which skill it happened to
rather than only that the whole merge failed its checks:

| Concurrent change | Result |
| --- | --- |
| Both Macs link the same skill | `ownership`, because the artifact's authority moved on both sides and the local value is kept, plus `subscriptionOwnerCollision` — "Both Macs made this skill follow a repository separately." The subscription the merged authority cannot name is set aside; the repository each side recorded stays. Not a pick-a-side conflict: this Mac cannot un-link what the other one asked for, so `WorkspaceConflictResolver` declines it and the person drops one side on the Mac that made it. |
| One Mac links while the other edits the content | `subscriptionContentMismatch` — "One Mac made this skill follow a repository while the other changed its files." Only one side moved each fact, so the ordinary rules take the new authority *and* the new bytes and leave the lock approving a version nobody holds. The approved digest is put back — the one value already in the inputs — and the conflict stands. It is resolvable both ways: keeping the followed version restores the locked digest, and keeping the personal edit moves the authority back to `centralPersonal`, which drops the subscription with it. |
| Both Macs link the same skill to *different* repositories | The two above, plus nothing else: the sources have different identities, so `sourcePolicy` and `subscriptionLock` do not fire. Both repositories are still recorded. |

A subscription whose artifact no longer follows anything is dropped rather than
carried, for the same reason a contribution for an item nobody kept is: it has
nothing left to approve. That is what lets the second row be resolved in the
direction that keeps the edit.

### Call site

`SkillRepositorySection.personal` gains "Follow a repository…", opening a sheet
that takes the repository, ref and subdirectory as a `SkillRepositoryBinding`,
fetches with `WorkspaceSkillPreparation.fetchUpstream`, shows the exact commit
and whether the bytes match, and applies. `SkillUpstreamBinding.resolve` already
reads the result back out of the document for the `centralUpstream` branch.

### Tests

Linking a personal skill whose bytes match creates the source, the subscription
and the lock and flips the authority; the content digest does not move; existing
assignments, aliases and display name survive; a second skill from the same
repository reuses the source and adds its path; a skill with local edits is
refused; an upstream, attached, bundled, native or tracked skill is refused; a
stale revision is refused; replay returns the original receipt; and after
linking, `SkillUpstreamBinding.resolve` produces the binding the section renders.

## 5. Later work, named rather than implied

Small, and specifiable in an afternoon each:

- **Create a preset and edit its membership.** `PresetRecord` exists and its
  membership already merges three-way; the command creates the `.preset`
  artifact and the record together and bumps `revision` on every membership
  change, which `WorkspacePresetApplicationReview` already re-checks inside the
  writer transaction. `PresetsView.swift:9` states the gap.
- **Add or forget a project.** A `.logicalProject` artifact plus a
  `LogicalProjectRecord` plus a `DeviceProjectRootBinding`. Forgetting needs an
  `ArtifactTombstone` and must refuse while any assignment names the project,
  since `validateStructure` requires the reference.
- **A reviewed removal for a native plugin that was never assigned.** The
  `AttachedAuthoringDetachCommand` shape — remove the artifact and its children,
  its contributions, its preset memberships, write a tombstone — refusing while
  any assignment or preset still names it, and never touching the client's own
  files. This is also what makes `previouslyRemoved` reachable in command 1.
- **Recognize a tracked package as its client's.** The `trackedOnly` →
  `nativeOwned` promotion command 1 refuses. It must handle the children whose
  missing `packageRelativePath` is only legal under `trackedOnly`, which is why
  it is its own packet.

Larger, or not ours:

- **Managed-policy import** needs a reviewed local file read alongside
  `WorkspaceManagedPolicyRecord` and `ManagedPolicyDeviceImport`. Its own packet.
- **Diagnostics export** touches no portable state at all; it is a device-side
  read and belongs with the settings work.
- **MCP sign-in** is out of scope, as it was for the restoration.

## Landed shared model

These are in the tree already, so four implementers do not each need to add
them, and none of them changes what an existing workspace does.

| File | What it does |
| --- | --- |
| `Sources/AgentToolingCore/WorkspaceApplicationService.swift` | `store`, `writerID` and `contentStore` are module-internal instead of `private`, so each command's method can live in its own extension file. `commitMetadata` and `preflightMetadata` were **already** internal and need no public facade |
| `Sources/AgentToolingCore/PortableWorkspaceDocument.swift` | `validateNativeRouteUniqueness`: at most one live artifact per `(client, externalPluginID)`, the guarantee aliases already had |
| `Sources/AgentToolingCore/NativePackageAdoption.swift` | The four-answer recognition Discover and command 1 share, plus the `<client>.plugin` alias namespace |
| `Sources/AgentToolingCore/WorkspaceCatalogSourceIdentity.swift` | The identity-map allocation a catalog source cannot exist without, for both add and remove |
| `Sources/AgentToolingCore/WorkspaceMergeEngineConfiguration.swift` | Three-way catalog-source merge with its allocations, and the named `nativeRouteCollision` |
| `Sources/AgentToolingCore/WorkspaceMergeEngine.swift` | Two conflict kinds; the helper extension is internal so the file above can use it; `configurationState` goes through the new merge |
| `Sources/AgentToolingCore/WorkspaceConflictResolution.swift` | Resolves `catalogSource` both ways; declines `nativeRouteCollision` by name |
| `Sources/AgentToolingCore/WorkspaceLibraryReadModel.swift` | `WorkspaceLibraryMCPConnection` on rows and included items, joined from the portable definition and this Mac's binding |
| `Sources/AgentToolingCore/VersionedInventoryProjection.swift` | A projected server reports its endpoint, transport, credential names and workspace root when a definition exists, and stays empty when none does |
| `Sources/AgentToolingApp/SyncSettingsView.swift` | Two titles for the two new conflict kinds — the only app-side change, forced by an exhaustive switch |

## Implementation plan

Four units, one command each. Every unit owns its files outright: no two units
edit the same file, so all four can run in parallel worktrees from the start.
The shared model each depends on is already in the tree (previous section).

### Unit 1 — Adopt a catalog package  *(highest impact; start first)*

- **Owns (new):** `Sources/AgentToolingCore/NativePackageAdoptionCommand.swift`;
  `Sources/AgentToolingCore/WorkspaceApplicationService+NativePackageAdoption.swift`;
  `Tests/AgentToolingCoreTests/NativePackageAdoptionCommandTests.swift`.
- **UI it wires:** `Sources/AgentToolingApp/MarketplaceView.swift` (the
  `.disabled(true)` install button at line 613 and its help text);
  `Sources/AgentToolingApp/WorkspaceMarketplaceSession.swift` (a new `adopt`,
  and `installUnavailable` at line 58 goes away);
  `Tests/AgentToolingAppTests/` — its own new file only.
- **Why first:** 424 listings, every button disabled. It is also the only unit
  whose whole downstream path already exists, so it turns on end to end.

### Unit 2 — Record an MCP server definition  *(second)*

- **Owns (new):** `Sources/AgentToolingCore/ManagedMCPServerIntakeCommand.swift`;
  `Sources/AgentToolingCore/WorkspaceApplicationService+ManagedMCPIntake.swift`;
  `Tests/AgentToolingCoreTests/ManagedMCPServerIntakeCommandTests.swift`.
- **UI it wires:** `Sources/AgentToolingApp/PasteImportSheet.swift`;
  `Sources/AgentToolingApp/MCPServersView.swift` (an "Add connection…" entry
  only). `MCPTestConsoleView.swift` and `WorkspaceRequestSession.swift` need no
  change.
- **Note:** the projection half is landed, so this unit is the command alone.

### Unit 3 — Add or remove a catalog source  *(third)*

- **Owns (new):** `Sources/AgentToolingCore/WorkspaceCatalogSourceCommand.swift`;
  `Sources/AgentToolingCore/WorkspaceApplicationService+CatalogSource.swift`;
  `Tests/AgentToolingCoreTests/WorkspaceCatalogSourceCommandTests.swift`.
- **UI it wires:** `Sources/AgentToolingApp/MarketplaceView.swift` — **the source
  pane and the toolbar's "Add source…" only**. Unit 1 owns the install button in
  the same file, so these two coordinate on one file or Unit 3 lands after Unit 1;
  everything else in Unit 3 is independent.

### Unit 4 — Link a skill to an upstream repository  *(fourth)*

- **Owns (new):** `Sources/AgentToolingCore/LinkSkillUpstreamCommand.swift`;
  `Sources/AgentToolingCore/WorkspaceApplicationService+LinkSkillUpstream.swift`;
  `Tests/AgentToolingCoreTests/LinkSkillUpstreamCommandTests.swift`.
- **UI it wires:** `Sources/AgentToolingApp/SkillRepositorySection.swift` and one
  new sheet file of its own.

### Parallelism

Units 1, 2 and 4 are fully independent and can run at once. Unit 3 shares one
file with Unit 1 (`MarketplaceView.swift`) and nothing else; run it in the same
wave and merge Unit 1 first, or run it in a second wave. Units 2 and 4 touch no
file any other unit touches.
