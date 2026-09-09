import Foundation
import Testing

@testable import AgentToolingCore

struct WorkspaceConfigurationResolutionTests {
    @Test func resolvesAncestorIntentAndCollectionItemsWithoutVisibilityFiltering() throws {
        let fixture = try Fixture()
        let result = try WorkspaceConfigurationResolver.resolve(
            document: fixture.document, configurationID: fixture.childID)

        #expect(result.selectedConfigurationID == fixture.childID)
        #expect(result.selectedOrigin == .personal)
        #expect(result.contributingConfigurationIDs == [fixture.rootID, fixture.childID])
        #expect(result.requiredSkills.map(\.legacy.identifier) == ["child-skill", "missing-shelf-skill", "root-skill"])
        #expect(result.enabledPlugins.map(\.legacy.identifier) == ["shelf-plugin"])
        #expect(result.requiredMCPs.map(\.legacy.identifier) == ["root-mcp"])
        #expect(result.includedCollections.map(\.legacy.identifier) == ["shelf"])
        #expect(result.checkDefinitions.map(\.id) == ["root", "same", "child"])
        #expect(result.targetBindings?.map(\.enabled) == [true])
        #expect(result.requiredSkills.first { $0.legacy.identifier == "missing-shelf-skill" }?.resolution == .unresolved)
    }

    @Test func nearestBindingListPreservesNilEmptyAndOptionalEnabled() throws {
        var fixture = try Fixture()
        fixture.state.configurations[1].targetBindings = []
        let empty = try fixture.resolve()
        #expect(empty.targetBindings == [])

        fixture.state.configurations[1].targetBindings = [
            .init(item: fixture.childSkill, client: .claude, enabled: nil),
            .init(item: fixture.rootSkill, client: .codex, enabled: false),
        ]
        let explicit = try fixture.resolve()
        #expect(explicit.targetBindings?.map(\.enabled) == [nil, false])

        fixture.state.configurations[1].targetBindings = nil
        fixture.state.configurations[0].targetBindings = nil
        #expect(try fixture.resolve().targetBindings == nil)
    }

    @Test func rejectsManagedPolicyTemplateAsPersonalSelection() throws {
        let policyID = Self.object("00000000-0000-0000-0000-000000000090")
        let configurationID = Self.object("00000000-0000-0000-0000-000000000091")
        let policyLegacy = LegacyReferenceKey(domain: .policy, identifier: "company")
        let configurationLegacy = LegacyReferenceKey(
            domain: .configuration, identifier: "template", ownerPolicyID: "company")
        let configurationReference = WorkspaceReference(
            legacy: configurationLegacy, resolution: .object(configurationID))
        let state = WorkspaceConfigurationState(
            configurations: [.init(
                id: configurationID, name: "Template", origin: .managedPolicy(policyID: policyID))],
            managedPolicies: [.init(
                id: policyID, name: "Company", configurations: [configurationReference])],
            identityMap: [
                .init(legacy: policyLegacy, objectID: policyID),
                .init(legacy: configurationLegacy, objectID: configurationID),
            ])
        let document = try Self.makeDocument(state: state)

        #expect(throws: WorkspaceConfigurationResolutionError.managedPolicyTemplate(configurationID)) {
            _ = try WorkspaceConfigurationResolver.resolve(
                document: document, configurationID: configurationID)
        }
    }

    @Test func rejectsPersonalInheritanceFromManagedTemplate() throws {
        let policyID = Self.object("00000000-0000-0000-0000-000000000092")
        let managedID = Self.object("00000000-0000-0000-0000-000000000093")
        let personalID = Self.object("00000000-0000-0000-0000-000000000094")
        let policyKey = LegacyReferenceKey(domain: .policy, identifier: "company")
        let managedKey = LegacyReferenceKey(
            domain: .configuration, identifier: "base", ownerPolicyID: "company")
        let personalKey = LegacyReferenceKey(domain: .configuration, identifier: "personal")
        let managedReference = WorkspaceReference(legacy: managedKey, resolution: .object(managedID))
        let state = WorkspaceConfigurationState(
            configurations: [
                .init(id: managedID, name: "Base", origin: .managedPolicy(policyID: policyID)),
                .init(id: personalID, name: "Personal", inheritedFrom: managedReference),
            ],
            managedPolicies: [.init(
                id: policyID, name: "Company", configurations: [managedReference])],
            identityMap: [
                .init(legacy: policyKey, objectID: policyID),
                .init(legacy: managedKey, objectID: managedID),
                .init(legacy: personalKey, objectID: personalID),
            ])
        let document = try Self.makeDocument(state: state)

        #expect(throws: WorkspaceConfigurationResolutionError.invalidInheritanceOrigin(
            child: personalID, parent: managedID
        )) {
            _ = try WorkspaceConfigurationResolver.resolve(
                document: document, configurationID: personalID)
        }
    }

    @Test func validatesTheWholeDocumentAndReportsMissingSelection() throws {
        let fixture = try Fixture()
        #expect(throws: WorkspaceConfigurationResolutionError.missingConfiguration(
            Self.object("00000000-0000-0000-0000-000000000099")
        )) {
            _ = try WorkspaceConfigurationResolver.resolve(
                document: fixture.document,
                configurationID: Self.object("00000000-0000-0000-0000-000000000099"))
        }

        var invalid = try fixture.document
        invalid.configurationState?.configurations[1].inheritedFrom = .init(
            legacy: .init(domain: .configuration, identifier: "missing"),
            resolution: .object(Self.object("00000000-0000-0000-0000-000000000098")))
        #expect(throws: WorkspaceDomainValidationError.self) {
            _ = try WorkspaceConfigurationResolver.resolve(
                document: invalid, configurationID: fixture.childID)
        }
    }

    @Test func matchesSupportedLegacyResolutionWithoutApplyingLegacyVisibility() throws {
        let root = ToolingProfile(
            id: "root", name: "Root", summary: "", checks: [Self.legacyCheck("root")],
            enabledPlugins: ["plugin"], requiredMCPs: ["mcp"], requiredSkills: ["skill"],
            includedCollections: ["shelf"], targetBindings: nil)
        let child = ToolingProfile(
            id: "child", name: "Child", summary: "", inheritedFrom: "root",
            checks: [Self.legacyCheck("child")], enabledPlugins: [], requiredMCPs: [],
            requiredSkills: ["child-skill"], includedCollections: [], targetBindings: [])
        let snapshot = WorkspaceSnapshot(
            profiles: [root, child], activeProfileID: "child",
            collections: [.init(
                id: "shelf", name: "Shelf",
                items: [.init(kind: .skill, identifier: "shelf-skill")],
                createdAt: Date(timeIntervalSince1970: 0))])
        let legacy = try LegacyConfigurationResolver.resolve(snapshot, configurationID: "child")
        let preview = try WorkspaceConfigurationMigration.preview(
            snapshot: snapshot, workspaceID: Self.object("00000000-0000-0000-0000-000000000080"),
            artifactBindings: [:])
        let childID = try #require(preview.state.identityMap.first {
            $0.legacy == LegacyReferenceKey(domain: .configuration, identifier: "child")
        }?.objectID)
        let document = try Self.makeDocument(state: preview.state)
        let portable = try WorkspaceConfigurationResolver.resolve(
            document: document, configurationID: childID)

        let contributingLegacyIDs = portable.contributingConfigurationIDs.compactMap { id in
            preview.state.identityMap.first { $0.objectID == id }?.legacy.identifier
        }
        let portableSkills = portable.requiredSkills.map { $0.legacy.identifier }
        let portablePlugins = portable.enabledPlugins.map { $0.legacy.identifier }
        let portableMCPs = portable.requiredMCPs.map { $0.legacy.identifier }
        let portableCollections = portable.includedCollections.map { $0.legacy.identifier }
        let portableChecks = portable.checkDefinitions.map(\.id)
        let legacyChecks = legacy.checks.map(\.id)
        #expect(contributingLegacyIDs == legacy.contributingConfigurationIDs)
        #expect(portableSkills == legacy.requiredSkills)
        #expect(portablePlugins == legacy.enabledPlugins)
        #expect(portableMCPs == legacy.requiredMCPs)
        #expect(portableCollections == legacy.includedCollections)
        #expect(portableChecks == legacyChecks)
        #expect(portable.targetBindings == [])
    }

    private struct Fixture {
        let rootID = WorkspaceConfigurationResolutionTests.object("00000000-0000-0000-0000-000000000001")
        let childID = WorkspaceConfigurationResolutionTests.object("00000000-0000-0000-0000-000000000002")
        let collectionID = WorkspaceConfigurationResolutionTests.object("00000000-0000-0000-0000-000000000003")
        let rootSkill = WorkspaceConfigurationResolutionTests.artifactReference(
            .skill, "root-skill", "00000000-0000-0000-0000-000000000011")
        let childSkill = WorkspaceConfigurationResolutionTests.artifactReference(
            .skill, "child-skill", "00000000-0000-0000-0000-000000000012")
        var state: WorkspaceConfigurationState
        let artifacts: [ArtifactRecord]

        init() throws {
            let rootConfiguration = WorkspaceConfigurationResolutionTests.objectReference(
                .configuration, "root", rootID)
            let childConfiguration = WorkspaceConfigurationResolutionTests.objectReference(
                .configuration, "child", childID)
            let shelf = WorkspaceConfigurationResolutionTests.objectReference(.collection, "shelf", collectionID)
            let rootMCP = WorkspaceConfigurationResolutionTests.artifactReference(
                .mcpServer, "root-mcp", "00000000-0000-0000-0000-000000000013")
            let shelfPlugin = WorkspaceConfigurationResolutionTests.artifactReference(
                .plugin, "shelf-plugin", "00000000-0000-0000-0000-000000000014")
            let missingShelfSkill = WorkspaceConfigurationResolutionTests.unresolved(.skill, "missing-shelf-skill")
            let missingID = WorkspaceConfigurationResolutionTests.object("00000000-0000-0000-0000-000000000015")
            artifacts = [
                WorkspaceConfigurationResolutionTests.artifact(rootSkill, .skill),
                WorkspaceConfigurationResolutionTests.artifact(childSkill, .skill),
                WorkspaceConfigurationResolutionTests.artifact(rootMCP, .mcpServer),
                WorkspaceConfigurationResolutionTests.artifact(shelfPlugin, .nativePlugin),
            ]
            state = WorkspaceConfigurationState(
                configurations: [
                    .init(
                        id: rootID, name: "Root", requiredMCPs: [rootMCP],
                        requiredSkills: [rootSkill], includedCollections: [shelf],
                        checkDefinitions: [.init(id: "root", name: "Root"), .init(id: "same", name: "Same")],
                        targetBindings: [.init(item: rootSkill, client: .codex, enabled: true)]),
                    .init(
                        id: childID, name: "Child", inheritedFrom: rootConfiguration,
                        requiredSkills: [childSkill, rootSkill],
                        checkDefinitions: [.init(id: "same", name: "Same child"), .init(id: "child", name: "Child")]),
                ],
                collections: [.init(
                    id: collectionID, name: "Shelf", items: [shelfPlugin, missingShelfSkill],
                    createdAt: Date(timeIntervalSince1970: 0))],
                identityMap: [
                    WorkspaceConfigurationResolutionTests.allocation(rootConfiguration),
                    WorkspaceConfigurationResolutionTests.allocation(childConfiguration),
                    WorkspaceConfigurationResolutionTests.allocation(shelf),
                    WorkspaceConfigurationResolutionTests.allocation(rootSkill),
                    WorkspaceConfigurationResolutionTests.allocation(childSkill),
                    WorkspaceConfigurationResolutionTests.allocation(rootMCP),
                    WorkspaceConfigurationResolutionTests.allocation(shelfPlugin),
                    .init(legacy: missingShelfSkill.legacy, objectID: missingID),
                ])
        }

        var document: PortableWorkspaceDocument {
            get throws {
                try WorkspaceConfigurationResolutionTests.makeDocument(state: state, artifacts: artifacts)
            }
        }

        func resolve() throws -> WorkspaceConfigurationResolution {
            try WorkspaceConfigurationResolver.resolve(document: document, configurationID: childID)
        }
    }

    private static func makeDocument(
        state: WorkspaceConfigurationState,
        artifacts: [ArtifactRecord] = []
    ) throws -> PortableWorkspaceDocument {
        try WorkspaceDocumentCoding.seal(.init(
            revision: .init(writerID: object("00000000-0000-0000-0000-000000000070")),
            artifacts: artifacts, configurationState: state))
    }

    private static func object(_ value: String) -> WorkspaceObjectID {
        WorkspaceObjectID(UUID(uuidString: value)!)
    }

    private static func artifactReference(
        _ domain: LegacyReferenceDomain, _ identifier: String, _ value: String
    ) -> WorkspaceReference {
        .init(
            legacy: .init(domain: domain, identifier: identifier),
            resolution: .artifact(ArtifactID(UUID(uuidString: value)!)))
    }

    private static func objectReference(
        _ domain: LegacyReferenceDomain, _ identifier: String, _ id: WorkspaceObjectID
    ) -> WorkspaceReference {
        .init(legacy: .init(domain: domain, identifier: identifier), resolution: .object(id))
    }

    private static func unresolved(
        _ domain: LegacyReferenceDomain, _ identifier: String
    ) -> WorkspaceReference {
        .init(legacy: .init(domain: domain, identifier: identifier), resolution: .unresolved)
    }

    private static func allocation(_ reference: WorkspaceReference) -> WorkspaceMigrationIdentityEntry {
        switch reference.resolution {
        case .artifact(let id): .init(legacy: reference.legacy, objectID: WorkspaceObjectID(id.rawValue))
        case .object(let id): .init(legacy: reference.legacy, objectID: id)
        case .unresolved: fatalError("Unresolved references need an explicit reserved identity")
        }
    }

    private static func artifact(_ reference: WorkspaceReference, _ kind: ArtifactKind) -> ArtifactRecord {
        guard case .artifact(let id) = reference.resolution else { fatalError("Expected artifact") }
        return .init(
            identity: .init(id: id, kind: kind, displayName: reference.legacy.identifier),
            authority: .trackedOnly)
    }

    private static func legacyCheck(_ id: String) -> ProfileCheck {
        .init(id: id, name: id, detail: "", state: .healthy)
    }
}
