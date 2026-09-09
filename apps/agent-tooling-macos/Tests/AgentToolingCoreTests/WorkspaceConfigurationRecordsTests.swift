import Foundation
import Testing

@testable import AgentToolingCore

struct WorkspaceConfigurationRecordsTests {
    @Test func nilEmptyAndThreeStateBindingsRoundTripDistinctly() throws {
        let skill = artifactReference(.skill, "sample", uuid: "00000000-0000-0000-0000-000000001001")
        let parent = objectReference(.configuration, "parent", uuid: "00000000-0000-0000-0000-000000001002")
        let child = objectReference(.configuration, "child", uuid: "00000000-0000-0000-0000-000000001003")
        let explicit = objectReference(.configuration, "explicit", uuid: "00000000-0000-0000-0000-000000001004")
        let records = [
            WorkspaceConfigurationRecord(id: objectID(parent), name: "Parent", targetBindings: nil),
            WorkspaceConfigurationRecord(
                id: objectID(child), name: "Child", inheritedFrom: parent, targetBindings: []),
            WorkspaceConfigurationRecord(
                id: objectID(explicit), name: "Explicit", targetBindings: [
                    .init(item: skill, client: .claude, enabled: true),
                    .init(item: skill, client: .codex, enabled: false),
                    .init(item: skill, client: .gemini, enabled: nil),
                ]),
        ]
        let state = WorkspaceConfigurationState(
            configurations: records,
            identityMap: allocations([skill, parent, child, explicit]),
            defaultConfigurationID: objectID(child))
        let restored = try JSONDecoder().decode(
            WorkspaceConfigurationState.self, from: JSONEncoder().encode(state))

        try restored.validate(artifacts: [artifactRecord(skill, kind: .skill)], logicalProjects: [])
        #expect(restored.configurations[0].targetBindings == nil)
        #expect(restored.configurations[1].targetBindings == [])
        #expect(restored.configurations[2].targetBindings?.map(\.enabled) == [true, false, nil])
    }

    @Test func unresolvedArtifactReferencesKeepTheirReservedIdentity() throws {
        let missing = WorkspaceReference(
            legacy: .init(domain: .skill, identifier: "temporarily-missing"), resolution: .unresolved)
        let reserved = object("00000000-0000-0000-0000-000000001010")
        let collection = objectReference(
            .collection, "shelf", uuid: "00000000-0000-0000-0000-000000001011")
        let state = WorkspaceConfigurationState(
            collections: [WorkspaceCollectionRecord(id: objectID(collection), name: "Shelf", items: [missing])],
            tagAssignments: [.init(item: missing, tags: ["Review"])],
            identityMap: [
                .init(legacy: missing.legacy, objectID: reserved),
                allocation(collection),
            ])

        try state.validate(artifacts: [], logicalProjects: [])
        #expect(state.identityMap.first?.objectID == reserved)
        #expect(state.collections[0].items[0].resolution == .unresolved)

        var falselyResolved = state
        falselyResolved.collections[0].items[0].resolution = .artifact(ArtifactID(reserved.rawValue))
        #expect(throws: WorkspaceDomainValidationError.self) {
            try falselyResolved.validate(artifacts: [], logicalProjects: [])
        }
    }

    @Test func missingConfigurationAndCollectionObjectsAreRejected() throws {
        let missingParent = objectReference(
            .configuration, "missing-parent", uuid: "00000000-0000-0000-0000-000000001020")
        let child = objectReference(
            .configuration, "child", uuid: "00000000-0000-0000-0000-000000001021")
        var state = WorkspaceConfigurationState(
            configurations: [WorkspaceConfigurationRecord(
                id: objectID(child), name: "Child", inheritedFrom: missingParent)],
            identityMap: allocations([missingParent, child]))
        #expect(throws: WorkspaceDomainValidationError.self) {
            try state.validate(artifacts: [], logicalProjects: [])
        }

        let missingCollection = objectReference(
            .collection, "missing", uuid: "00000000-0000-0000-0000-000000001022")
        state.configurations[0].inheritedFrom = nil
        state.configurations[0].includedCollections = [missingCollection]
        state.identityMap = allocations([child, missingCollection])
        #expect(throws: WorkspaceDomainValidationError.self) {
            try state.validate(artifacts: [], logicalProjects: [])
        }
    }

    @Test func policyOwnedDuplicateProfileNameUsesOwnerNamespace() throws {
        let policy = objectReference(.policy, "company", uuid: "00000000-0000-0000-0000-000000001030")
        let personal = objectReference(
            .configuration, "review", uuid: "00000000-0000-0000-0000-000000001031")
        let managed = objectReference(
            .configuration, "review", ownerPolicyID: "company",
            uuid: "00000000-0000-0000-0000-000000001032")
        let state = WorkspaceConfigurationState(
            configurations: [
                .init(id: objectID(personal), name: "Review", origin: .personal),
                .init(id: objectID(managed), name: "Review", origin: .managedPolicy(policyID: objectID(policy))),
            ],
            managedPolicies: [.init(
                id: objectID(policy), name: "Company", configurations: [managed])],
            identityMap: allocations([policy, personal, managed]),
            defaultConfigurationID: objectID(personal))

        try state.validate(artifacts: [], logicalProjects: [])
        #expect(personal.legacy != managed.legacy)
        #expect(state.configurations.map(\.id).allSatisfy { $0 != objectID(policy) })

        var wrongNamespace = state
        let managedIndex = try #require(wrongNamespace.identityMap.firstIndex(where: {
            $0.objectID == objectID(managed)
        }))
        wrongNamespace.identityMap[managedIndex].legacy.ownerPolicyID = "another-policy"
        #expect(throws: WorkspaceDomainValidationError.self) {
            try wrongNamespace.validate(artifacts: [], logicalProjects: [])
        }

        var orphan = state
        orphan.managedPolicies[0].configurations = []
        #expect(throws: WorkspaceDomainValidationError.self) {
            try orphan.validate(artifacts: [], logicalProjects: [])
        }
    }

    @Test func artifactResolutionUsesReservedUUIDAndEnforcesKind() throws {
        let uuid = UUID(uuidString: "00000000-0000-0000-0000-000000001040")!
        let pluginReference = WorkspaceReference(
            legacy: .init(domain: .plugin, identifier: "bundle"),
            resolution: .artifact(ArtifactID(uuid)))
        let skillArtifact = ArtifactRecord(
            identity: ArtifactIdentity(id: ArtifactID(uuid), kind: .skill, displayName: "Wrong kind"),
            authority: .trackedOnly)
        let state = WorkspaceConfigurationState(identityMap: [
            .init(legacy: pluginReference.legacy, objectID: WorkspaceObjectID(uuid)),
        ])

        #expect(throws: WorkspaceDomainValidationError.self) {
            try state.validate(artifacts: [skillArtifact], logicalProjects: [])
        }
        #expect(ArtifactID(state.identityMap[0].objectID.rawValue) == ArtifactID(uuid))
    }

    @Test func cyclesAndDuplicateReservedIdentitiesAreRejected() throws {
        let first = objectReference(
            .configuration, "first", uuid: "00000000-0000-0000-0000-000000001050")
        let second = objectReference(
            .configuration, "second", uuid: "00000000-0000-0000-0000-000000001051")
        var state = WorkspaceConfigurationState(
            configurations: [
                .init(id: objectID(first), name: "First", inheritedFrom: second),
                .init(id: objectID(second), name: "Second", inheritedFrom: first),
            ], identityMap: allocations([first, second]))
        #expect(throws: WorkspaceDomainValidationError.self) {
            try state.validate(artifacts: [], logicalProjects: [])
        }

        state.configurations[0].inheritedFrom = nil
        state.configurations[1].inheritedFrom = nil
        state.identityMap[1].objectID = state.identityMap[0].objectID
        #expect(throws: WorkspaceDomainValidationError.self) {
            try state.validate(artifacts: [], logicalProjects: [])
        }
    }

    @Test func canonicalizationSortsSetLikeFieldsWithoutCollapsingIntent() throws {
        let skillA = artifactReference(.skill, "a", uuid: "00000000-0000-0000-0000-000000001060")
        let skillB = artifactReference(.skill, "b", uuid: "00000000-0000-0000-0000-000000001061")
        let configuration = objectReference(
            .configuration, "config", uuid: "00000000-0000-0000-0000-000000001062")
        let collection = objectReference(
            .collection, "shelf", uuid: "00000000-0000-0000-0000-000000001063")
        let state = WorkspaceConfigurationState(
            configurations: [.init(
                id: objectID(configuration), name: "Config", requiredSkills: [skillB, skillA],
                targetBindings: [])],
            collections: [.init(
                id: objectID(collection), name: "Shelf", items: [skillB, skillA],
                createdAt: Date(timeIntervalSince1970: 1_788_890_400.1236))],
            tagAssignments: [.init(item: skillA, tags: ["Zeta", "Alpha"])],
            identityMap: allocations([skillB, collection, configuration, skillA]))
        let canonical = state.canonicalized()

        try canonical.validate(
            artifacts: [artifactRecord(skillA, kind: .skill), artifactRecord(skillB, kind: .skill)],
            logicalProjects: [])
        #expect(canonical.configurations[0].requiredSkills.map(\.legacy.identifier) == ["a", "b"])
        #expect(canonical.configurations[0].targetBindings == [])
        #expect(abs(canonical.collections[0].createdAt.timeIntervalSince1970 - 1_788_890_400.124) < 0.0001)
        #expect(canonical.tagAssignments[0].tags == ["Alpha", "Zeta"])
        #expect(canonical.identityMap.map(\.legacy.identifier) == ["shelf", "config", "a", "b"])
    }

    @Test func catalogRecordDoesNotCreateSourceAuthorityAndRejectsCredentials() throws {
        let catalog = objectReference(
            .catalogSource, "directory", uuid: "00000000-0000-0000-0000-000000001070")
        var state = WorkspaceConfigurationState(
            catalogSources: [.init(
                id: objectID(catalog), name: "Directory", kind: .agentPlugins,
                remoteLocation: "https://example.com/plugins")],
            identityMap: allocations([catalog]))
        try state.validate(artifacts: [], logicalProjects: [])
        #expect(state.catalogSources[0].kind == .agentPlugins)

        state.catalogSources[0].remoteLocation = "https://user:secret@example.com/plugins"
        #expect(throws: WorkspaceDomainValidationError.self) {
            try state.validate(artifacts: [], logicalProjects: [])
        }
    }

    private func artifactReference(
        _ domain: LegacyReferenceDomain, _ identifier: String, uuid: String
    ) -> WorkspaceReference {
        WorkspaceReference(
            legacy: .init(domain: domain, identifier: identifier),
            resolution: .artifact(ArtifactID(UUID(uuidString: uuid)!)))
    }

    private func objectReference(
        _ domain: LegacyReferenceDomain, _ identifier: String,
        ownerPolicyID: String? = nil, uuid: String
    ) -> WorkspaceReference {
        WorkspaceReference(
            legacy: .init(domain: domain, identifier: identifier, ownerPolicyID: ownerPolicyID),
            resolution: .object(WorkspaceObjectID(UUID(uuidString: uuid)!)))
    }

    private func objectID(_ reference: WorkspaceReference) -> WorkspaceObjectID {
        guard case .object(let id) = reference.resolution else { fatalError("Expected object reference") }
        return id
    }

    private func allocation(_ reference: WorkspaceReference) -> WorkspaceMigrationIdentityEntry {
        let id: WorkspaceObjectID
        switch reference.resolution {
        case .artifact(let artifactID): id = WorkspaceObjectID(artifactID.rawValue)
        case .object(let objectID): id = objectID
        case .unresolved: fatalError("Pass an explicit reserved allocation for unresolved references")
        }
        return .init(legacy: reference.legacy, objectID: id)
    }

    private func artifactRecord(_ reference: WorkspaceReference, kind: ArtifactKind) -> ArtifactRecord {
        guard case .artifact(let id) = reference.resolution else { fatalError("Expected artifact reference") }
        return ArtifactRecord(
            identity: ArtifactIdentity(id: id, kind: kind, displayName: reference.legacy.identifier),
            authority: .trackedOnly)
    }

    private func allocations(_ references: [WorkspaceReference]) -> [WorkspaceMigrationIdentityEntry] {
        references.map(allocation)
    }

    private func object(_ value: String) -> WorkspaceObjectID {
        WorkspaceObjectID(UUID(uuidString: value)!)
    }
}
