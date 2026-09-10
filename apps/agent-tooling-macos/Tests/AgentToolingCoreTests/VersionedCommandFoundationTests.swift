import Foundation
import Testing

@testable import AgentToolingCore

/// The shared model the four versioned commands are built on: the identity a
/// native package is recognized by, the allocation a catalog source cannot
/// exist without, and how two Macs combine both.
///
/// The first suite is the one that matters most. Everything here is additive,
/// so a workspace that has never used any of these commands must read, validate,
/// merge and project exactly as it did before — and that has to be measured
/// against fixed bytes rather than asserted.
struct VersionedCommandFoundationTests {
    // MARK: - Nothing changes for a workspace that uses none of this

    @Test func theFixedSchemaTwoWireAndDigestAreUntouched() throws {
        // The same bytes and digest the schema-two compatibility fixture pins.
        // This packet adds no field to any wire format, so they cannot move.
        let workspaceID = WorkspaceObjectID(rawValue: Self.fixed(0x10))
        let revisionID = WorkspaceObjectID(rawValue: Self.fixed(0x11))
        let writerID = WorkspaceObjectID(rawValue: Self.fixed(0x12))
        let document = try WorkspaceDocumentCoding.seal(
            PortableWorkspaceDocument(
                schemaVersion: 2, minimumReaderVersion: 2, minimumWriterVersion: 2,
                workspaceID: workspaceID,
                revision: .init(
                    id: revisionID, writerID: writerID,
                    createdAt: Date(timeIntervalSince1970: 1_767_323_045.678)),
                configurationState: .init()))

        #expect(
            document.revision.documentDigest.value
                == "6212c3683c14a47e998298e74696c35d79dd09e82e59d8b56bb7eaa6adca943a")
        let encoded = try WorkspaceDocumentCoding.encode(document)
        #expect(!String(decoding: encoded, as: UTF8.self).contains("catalogSourceTombstone"))
        #expect(try WorkspaceDocumentCoding.decode(encoded) == document)
    }

    @Test func aWorkspaceWithNoneOfThisDataStillValidatesMergesAndProjects() throws {
        // A scan-built workspace: a client's own package, a skill inside it, and
        // a server this Mac merely observed. None of the four commands has been
        // used, and nothing about it may change.
        let document = try Self.scanned()
        let device = DeviceWorkspaceState(workspaceID: document.workspaceID)
        try document.validateStructure()
        try device.validateStructure(against: document)

        let merged = WorkspaceMergeEngine.merge(
            base: document, local: document, remote: document, writerID: WorkspaceObjectID())
        #expect(merged.conflicts.isEmpty)
        let result = try #require(merged.document)
        #expect(result.artifacts == document.artifacts)
        #expect(result.configurationState == document.configurationState)

        let model = try WorkspaceLibraryReadModel(snapshot: .init(document: document, device: device))
        #expect(model.rows.allSatisfy { $0.connection == nil })
        #expect(model.rows.flatMap(\.includedChildren).allSatisfy { $0.connection == nil })
        let inventory = VersionedInventoryProjection.inventory(model)
        #expect(inventory.mcpServers.allSatisfy { $0.endpoint.isEmpty && $0.authentication.isEmpty })
        #expect(inventory.mcpServers.allSatisfy { $0.transport == .stdio && $0.secretNames.isEmpty })
    }

    @Test func aMergeOfTwoWorkspacesWithNoCatalogsIsByteIdenticalToBefore() throws {
        // The catalog merge must be invisible when there is nothing to merge.
        // Every workspace in the field is in exactly this state today.
        let base = try Self.scanned()
        var local = base
        local.artifacts[0].identity.displayName = "Renamed here"
        var remote = base
        remote.artifacts[1].identity.displayName = "Renamed there"

        let merged = WorkspaceMergeEngine.merge(
            base: base, local: try WorkspaceDocumentCoding.seal(local),
            remote: try WorkspaceDocumentCoding.seal(remote), writerID: WorkspaceObjectID())
        let result = try #require(merged.document)
        #expect(merged.conflicts.isEmpty)
        #expect(result.artifacts[0].identity.displayName == "Renamed here")
        #expect(result.artifacts[1].identity.displayName == "Renamed there")
        #expect(result.configurationState == WorkspaceConfigurationState())
    }

    // MARK: - One package, one record

    @Test func twoRecordsOfOneAppPackageAreRefusedByTheDocument() throws {
        var document = try Self.scanned()
        document.artifacts.append(
            .init(
                identity: .init(kind: .nativePlugin, displayName: "The same pack again"),
                authority: .nativeOwned, declaredName: "pack",
                nativeRoutes: [.init(client: .claude, externalPluginID: "pack")]))

        #expect(throws: WorkspaceDomainValidationError.duplicate("native package route Claude Code:pack")) {
            try document.validateStructure()
        }
    }

    @Test func oneArtifactMayStillCarryOneRoutePerClient() throws {
        var document = try Self.scanned()
        document.artifacts[0].nativeRoutes.append(.init(client: .codex, externalPluginID: "pack"))
        // A merged package keeps one identity with a route for each client;
        // that is the case the uniqueness rule must not break.
        try document.validateStructure()
    }

    @Test func bothMacsAddingTheSamePackageIsNamedRatherThanCalledInvalid() throws {
        let base = try Self.scanned()
        var local = base
        local.artifacts.append(
            .init(
                identity: .init(kind: .nativePlugin, displayName: "Docs"),
                authority: .nativeOwned, declaredName: "docs",
                nativeRoutes: [.init(client: .claude, externalPluginID: "docs")]))
        var remote = base
        remote.artifacts.append(
            .init(
                identity: .init(kind: .nativePlugin, displayName: "Docs"),
                authority: .nativeOwned, declaredName: "docs",
                nativeRoutes: [.init(client: .claude, externalPluginID: "docs")]))

        let merged = WorkspaceMergeEngine.merge(
            base: base, local: try WorkspaceDocumentCoding.seal(local),
            remote: try WorkspaceDocumentCoding.seal(remote), writerID: WorkspaceObjectID())
        #expect(merged.document == nil)
        #expect(merged.conflicts.map(\.kind) == [.nativeRouteCollision])
        // The generic "this did not pass its own checks" is exactly what a
        // person cannot act on, so it must not be what they are shown.
        #expect(!merged.conflicts.contains { $0.kind == .invalidResult })
    }

    // MARK: - Recognizing a listed package

    @Test func aRouteOrAClientAliasIsExactIdentity() throws {
        var document = try Self.scanned()
        document.artifacts.append(
            .init(
                identity: .init(
                    kind: .nativePlugin, displayName: "Aliased",
                    aliases: [NativePackageAdoption.pluginAlias(client: .codex, externalPluginID: "aliased")]),
                authority: .trackedOnly, declaredName: "something-else"))

        #expect(
            NativePackageAdoption.recognize(client: .claude, externalPluginID: "pack", in: document)
                == .exact(
                    .init(
                        artifactID: document.artifacts[0].identity.id,
                        displayName: "Pack", reason: .nativeRoute)))
        guard
            case .exact(let aliased) = NativePackageAdoption.recognize(
                client: .codex, externalPluginID: "aliased", in: document)
        else {
            Issue.record("An alias for this client is identity.")
            return
        }
        #expect(aliased.reason == .alias)
    }

    @Test func theSameIdentifierInAnotherAppIsReportedAsTheAmbiguityItIs() throws {
        let document = try Self.scanned()
        // "pack" is routed for Claude Code only. Codex listing a package with
        // the same identifier may be the same package or a different one, and
        // nothing here can tell — so it is neither claimed nor duplicated.
        guard
            case .sameDeclaredName(let match) = NativePackageAdoption.recognize(
                client: .codex, externalPluginID: "pack", in: document)
        else {
            Issue.record("An equal identifier without a route for this client is ambiguous.")
            return
        }
        #expect(match.displayName == "Pack")
        #expect(match.reason == .declaredName)
    }

    @Test func aNamesakeIsNeverMistakenForThePackageYouHave() throws {
        var document = try Self.scanned()
        document.artifacts[0].identity.displayName = "Docs"
        // Equal display names are not identity evidence, and this is the case
        // the rule exists for: two publishers, one product name.
        #expect(
            NativePackageAdoption.recognize(client: .claude, externalPluginID: "docs", in: document)
                == .none)
    }

    @Test func aRemovedPackageIsNotSilentlyRecreatedByACatalogListing() throws {
        var document = try Self.scanned()
        document.tombstones.append(
            .init(
                artifactID: ArtifactID(),
                aliases: [NativePackageAdoption.pluginAlias(client: .claude, externalPluginID: "gone")],
                deletedInRevisionID: document.revision.id))
        try document.validateStructure()

        #expect(
            NativePackageAdoption.recognize(client: .claude, externalPluginID: "gone", in: document)
                == .removed)
        #expect(
            NativePackageAdoption.recognize(client: .codex, externalPluginID: "gone", in: document)
                == .none)
    }

    // MARK: - What a recorded connection reports

    @Test func aReviewedAddressIsReportedExactlyAsItWasRecorded() throws {
        let inventory = try Self.projected(
            definition: .init(artifactID: Self.connectionID, connection: .remoteHTTPS(url: "https://example.com/mcp")))

        // A reviewed remote endpoint is portable state by design, so reporting
        // it is reporting what the workspace holds, not inventing an address.
        let server = try #require(inventory.mcpServers.first)
        #expect(server.endpoint == "https://example.com/mcp")
        #expect(server.transport == .http)
        #expect(server.definitionOrigin == .managed)
        // No binding, so nothing claims a credential or a workspace folder.
        #expect(server.authentication.isEmpty)
        #expect(server.secretNames.isEmpty)
        #expect(server.projectRoot == nil)
    }

    @Test func thisMacsOwnCommandIsReportedForADeviceResolvedConnection() throws {
        let inventory = try Self.projected(
            definition: .init(artifactID: Self.connectionID, connection: .deviceBound(transport: .stdio)),
            binding: .init(
                artifactID: Self.connectionID,
                destination: .stdio(executable: "npx", arguments: ["-y", "server beta"]),
                credentialRequirementNames: ["BETA_TOKEN"],
                authenticationRequirement: .apiKey))

        let server = try #require(inventory.mcpServers.first)
        // The command round-trips through the same reader a live test uses, so
        // an argument with a space stays one argument.
        #expect(server.endpoint == "npx -y 'server beta'")
        #expect(
            try MCPDefinitionValidator.validate(server.endpoint, transport: .stdio).command
                == ["npx", "-y", "server beta"])
        // Names only. A credential value cannot reach either record.
        #expect(server.secretNames == ["BETA_TOKEN"])
        #expect(server.authentication == "API key")
    }

    @Test func aDeviceResolvedConnectionWithNoLocalSetupReportsNoAddress() throws {
        let inventory = try Self.projected(
            definition: .init(artifactID: Self.connectionID, connection: .deviceBound(transport: .stdio)))

        // Another Mac recorded this connection; this one has never been set up
        // for it. Saying so is the answer, and Install explains the rest.
        let server = try #require(inventory.mcpServers.first)
        #expect(server.endpoint.isEmpty)
        #expect(server.definitionOrigin == .managed)
    }

    // MARK: - Catalog sources

    @Test func aCatalogSourceIsInvalidWithoutItsAllocation() throws {
        let sourceID = WorkspaceObjectID()
        var document = try Self.scanned()
        var state = WorkspaceConfigurationState()
        state.catalogSources = [
            .init(
                id: sourceID, name: "Team catalog", kind: .gitRepository,
                remoteLocation: "https://example.com/catalog")
        ]
        document.configurationState = state

        #expect(throws: WorkspaceDomainValidationError.self) { try document.validateStructure() }

        state.identityMap = [WorkspaceCatalogSourceIdentity.entry(for: sourceID)]
        document.configurationState = state
        try document.validateStructure()
        #expect(WorkspaceCatalogSourceIdentity.entry(for: sourceID, in: state)?.objectID == sourceID)
    }

    @Test func twoMacsEachAddingACatalogKeepBoth() throws {
        let base = try Self.scanned()
        let mine = WorkspaceObjectID()
        let theirs = WorkspaceObjectID()
        let local = try Self.adding(Self.catalog(mine, "Mine"), to: base)
        let remote = try Self.adding(Self.catalog(theirs, "Theirs"), to: base)

        let merged = WorkspaceMergeEngine.merge(
            base: base, local: local, remote: remote, writerID: WorkspaceObjectID())
        let result = try #require(merged.document)
        #expect(merged.conflicts.isEmpty)
        #expect(Set(result.configurationState?.catalogSources.map(\.id) ?? []) == [mine, theirs])
        // A record without its allocation fails validation, so the two moved
        // together or the merge would not have produced a document at all.
        #expect(result.configurationState?.identityMap.count == 2)
    }

    @Test func aCatalogOneMacRemovedIsNotBroughtBackByTheOtherAddingOne() throws {
        let shared = WorkspaceObjectID()
        let base = try Self.adding(Self.catalog(shared, "Shared"), to: try Self.scanned())
        let local = try Self.removing(shared, from: base)
        let remote = try Self.adding(Self.catalog(WorkspaceObjectID(), "New"), to: base)

        let merged = WorkspaceMergeEngine.merge(
            base: base, local: local, remote: remote, writerID: WorkspaceObjectID())
        let result = try #require(merged.document)
        #expect(merged.conflicts.isEmpty)
        #expect(result.configurationState?.catalogSources.map(\.name) == ["New"])
        #expect(result.configurationState?.identityMap.count == 1)
    }

    @Test func removingACatalogOneMacRenamedIsThePersonsDecision() throws {
        let shared = WorkspaceObjectID()
        let base = try Self.adding(Self.catalog(shared, "Shared"), to: try Self.scanned())
        let local = try Self.removing(shared, from: base)
        var renamed = base
        renamed.configurationState?.catalogSources[0].name = "Renamed"
        let remote = try WorkspaceDocumentCoding.seal(renamed)

        let merged = WorkspaceMergeEngine.merge(
            base: base, local: local, remote: remote, writerID: WorkspaceObjectID())
        #expect(merged.conflicts.map(\.kind) == [.catalogSource])
        // The record survives under the side that still has it, so nothing is
        // lost while the person decides.
        #expect(merged.document?.configurationState?.catalogSources.map(\.name) == ["Renamed"])
    }

    @Test func aDecidedCatalogRemovalIsAppliedByTheResolver() throws {
        let shared = WorkspaceObjectID()
        let base = try Self.adding(Self.catalog(shared, "Shared"), to: try Self.scanned())
        let local = try Self.removing(shared, from: base)
        var renamed = base
        renamed.configurationState?.catalogSources[0].name = "Renamed"
        let remote = try WorkspaceDocumentCoding.seal(renamed)
        let merged = WorkspaceMergeEngine.merge(
            base: base, local: local, remote: remote, writerID: WorkspaceObjectID())

        let resolved = WorkspaceConflictResolver.resolve(
            base: base, local: local, remote: remote, conflicts: merged.conflicts,
            resolutions: [.init(kind: .catalogSource, objectID: shared, choice: .keepLocal)],
            writerID: WorkspaceObjectID())
        #expect(resolved.isResolved)
        #expect(resolved.document?.configurationState?.catalogSources.isEmpty == true)
        #expect(resolved.document?.configurationState?.identityMap.isEmpty == true)
    }

    @Test func keepingTheChangedCatalogOverTheRemovalRetainsItsAllocation() throws {
        let shared = WorkspaceObjectID()
        let base = try Self.adding(Self.catalog(shared, "Shared"), to: try Self.scanned())
        let local = try Self.removing(shared, from: base)
        var renamed = base
        renamed.configurationState?.catalogSources[0].name = "Renamed"
        let remote = try WorkspaceDocumentCoding.seal(renamed)
        let merged = WorkspaceMergeEngine.merge(
            base: base, local: local, remote: remote, writerID: WorkspaceObjectID())

        let resolved = WorkspaceConflictResolver.resolve(
            base: base, local: local, remote: remote, conflicts: merged.conflicts,
            resolutions: [.init(kind: .catalogSource, objectID: shared, choice: .takeRemote)],
            writerID: WorkspaceObjectID())
        #expect(resolved.isResolved)
        #expect(resolved.document?.configurationState?.catalogSources.map(\.name) == ["Renamed"])
        #expect(resolved.document?.configurationState?.identityMap.count == 1)
    }

    @Test func bothMacsPointingOneCatalogSomewhereElseIsAConflict() throws {
        let shared = WorkspaceObjectID()
        let base = try Self.adding(Self.catalog(shared, "Shared"), to: try Self.scanned())
        var mine = base
        mine.configurationState?.catalogSources[0].remoteLocation = "https://example.com/mine"
        var theirs = base
        theirs.configurationState?.catalogSources[0].remoteLocation = "https://example.com/theirs"

        let merged = WorkspaceMergeEngine.merge(
            base: base, local: try WorkspaceDocumentCoding.seal(mine),
            remote: try WorkspaceDocumentCoding.seal(theirs), writerID: WorkspaceObjectID())
        #expect(merged.conflicts.map(\.kind) == [.catalogSource])
        #expect(
            merged.document?.configurationState?.catalogSources.first?.remoteLocation
                == "https://example.com/mine")
    }

    @Test func everythingElseInTheConfigurationSupplementKeepsItsOldBehaviour() throws {
        // Only the catalog list is combined. Collections and configurations are
        // taken from the local side exactly as they were before this packet,
        // because nothing writes them and an unexercised merge is an unchecked
        // one.
        let configurationID = WorkspaceObjectID()
        let key = LegacyReferenceKey(domain: .configuration, identifier: "setup")
        var local = try Self.scanned()
        local.configurationState = .init(
            configurations: [.init(id: configurationID, name: "Mine", targetBindings: [])],
            identityMap: [.init(legacy: key, objectID: configurationID)])
        var remote = try Self.scanned()
        remote.configurationState = .init()

        let merged = WorkspaceMergeEngine.merge(
            base: try Self.scanned(), local: try WorkspaceDocumentCoding.seal(local),
            remote: try WorkspaceDocumentCoding.seal(remote), writerID: WorkspaceObjectID())
        #expect(merged.document?.configurationState?.configurations.map(\.name) == ["Mine"])
    }

    // MARK: - Fixtures

    /// A fixed identity built from its last byte, so a fixture never has to
    /// force-unwrap a string it wrote itself.
    private static func fixed(_ byte: UInt8) -> UUID {
        UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, byte))
    }

    private static func scanned() throws -> PortableWorkspaceDocument {
        let packageID = ArtifactID(Self.fixed(0xa1))
        return try WorkspaceDocumentCoding.seal(
            .init(
                workspaceID: WorkspaceObjectID(Self.fixed(0xff)),
                revision: .init(
                    id: WorkspaceObjectID(Self.fixed(0xfe)),
                    writerID: WorkspaceObjectID(Self.fixed(0xfd)),
                    createdAt: Date(timeIntervalSince1970: 1_767_323_045.678)),
                artifacts: [
                    .init(
                        identity: .init(id: packageID, kind: .nativePlugin, displayName: "Pack"),
                        authority: .nativeOwned, declaredName: "pack",
                        nativeRoutes: [.init(client: .claude, externalPluginID: "pack")]),
                    .init(
                        identity: .init(
                            id: ArtifactID(Self.fixed(0xa2)),
                            kind: .skill, displayName: "Bundled", parentPackageID: packageID),
                        authority: .nativeOwned, declaredName: "bundled", packageRelativePath: "skills/bundled"),
                    .init(
                        identity: .init(
                            id: ArtifactID(Self.fixed(0xa3)),
                            kind: .mcpServer, displayName: "Observed", parentPackageID: packageID),
                        authority: .nativeOwned, declaredName: "observed"),
                ]))
    }

    private static let connectionID = ArtifactID(fixed(0xb2))

    /// One standalone managed connection, projected the way every read-only
    /// surface sees it.
    private static func projected(
        definition: PortableMCPDefinitionRecord, binding: DeviceMCPDefinitionBinding? = nil
    ) throws -> VersionedInventoryProjection.Inventory {
        let document = try WorkspaceDocumentCoding.seal(
            .init(
                workspaceID: WorkspaceObjectID(fixed(0xff)),
                revision: .init(writerID: WorkspaceObjectID(fixed(0xfd))),
                artifacts: [
                    .init(
                        identity: .init(id: connectionID, kind: .mcpServer, displayName: "Beta"),
                        authority: .centralPersonal)
                ],
                mcpDefinitions: [definition]))
        let device = DeviceWorkspaceState(
            workspaceID: document.workspaceID, mcpBindings: binding.map { [$0] } ?? [])
        return VersionedInventoryProjection.inventory(
            try WorkspaceLibraryReadModel(snapshot: .init(document: document, device: device)))
    }

    private static func catalog(_ id: WorkspaceObjectID, _ name: String) -> WorkspaceCatalogSourceRecord {
        .init(id: id, name: name, kind: .gitRepository, remoteLocation: "https://example.com/\(name.lowercased())")
    }

    private static func adding(
        _ source: WorkspaceCatalogSourceRecord, to document: PortableWorkspaceDocument
    ) throws -> PortableWorkspaceDocument {
        var updated = document
        var state = updated.configurationState ?? .init()
        state.catalogSources.append(source)
        state.identityMap.append(WorkspaceCatalogSourceIdentity.entry(for: source.id))
        updated.configurationState = state
        return try WorkspaceDocumentCoding.seal(updated)
    }

    private static func removing(
        _ id: WorkspaceObjectID, from document: PortableWorkspaceDocument
    ) throws -> PortableWorkspaceDocument {
        var updated = document
        var state = updated.configurationState ?? .init()
        state.catalogSources.removeAll { $0.id == id }
        state.identityMap.removeAll { $0.legacy.domain == .catalogSource && $0.objectID == id }
        updated.configurationState = state
        return try WorkspaceDocumentCoding.seal(updated)
    }
}
