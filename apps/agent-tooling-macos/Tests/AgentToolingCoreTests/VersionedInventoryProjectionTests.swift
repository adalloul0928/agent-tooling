import Foundation
import Testing

@testable import AgentToolingCore

/// The versioned library, seen through the shape the read-only surfaces speak.
/// A requested destination is never reported as an installed one, whatever the
/// legacy field is called.
@Suite("Versioned inventory projection")
struct VersionedInventoryProjectionTests {
    @Test func eachKindOfItemBecomesItsOwnKindOfRecord() throws {
        let inventory = try Self.inventory(artifacts: [
            Self.artifact(Self.alpha, "Alpha", kind: .skill, authority: .centralPersonal),
            Self.artifact(Self.beta, "Beta", kind: .mcpServer, authority: .trackedOnly),
            Self.artifact(Self.gamma, "A package", kind: .nativePlugin, authority: .nativeOwned),
        ])

        #expect(inventory.skills.map(\.displayName) == ["Alpha"])
        #expect(inventory.mcpServers.map(\.name) == ["Beta"])
        #expect(inventory.plugins.map(\.name) == ["A package"])
        // Ownership travels: content the workspace holds is its own, and a
        // record of something a client owns is not.
        #expect(inventory.skills.first?.owned == true)
        #expect(inventory.mcpServers.first?.definitionOrigin == .observed)
    }

    @Test func aPackagesMembersAreSearchableRatherThanHiddenInsideIt() throws {
        var member = Self.artifact(Self.beta, "Bundled skill", kind: .skill, authority: .trackedOnly)
        member.identity.parentPackageID = Self.gamma
        member.declaredName = "bundled"
        let inventory = try Self.inventory(artifacts: [
            Self.artifact(Self.gamma, "A package", kind: .nativePlugin, authority: .trackedOnly),
            member,
        ])

        #expect(inventory.plugins.map(\.name) == ["A package"])
        #expect(inventory.skills.map(\.displayName) == ["Bundled skill"])
        // And the package still says what it contains.
        #expect(inventory.plugins.first?.skills == ["Bundled skill"])
        #expect(inventory.skills.first?.bundle == "A package")
    }

    @Test func aRequestedDestinationIsNeverReportedAsAnInstalledOne() throws {
        let inventory = try Self.inventory(
            artifacts: [Self.artifact(Self.alpha, "Alpha", kind: .skill, authority: .centralPersonal)],
            assignments: [
                .init(artifactID: Self.alpha, destination: .init(surface: .codexCLI, scope: .user),
                      reason: .manual),
            ])

        let skill = try #require(inventory.skills.first)
        let state = try #require(skill.clients.first)
        #expect(state.client == .codex)
        // The whole point: an ask is not a measurement.
        #expect(state.state == .pending)
        #expect(state.isInstalled == false)
        #expect(!state.reportsLocalPresence)
        #expect(state.detail.contains("Not checked against this Mac"))
    }

    @Test func aPackageIsNotClaimedToBeInstalledEither() throws {
        let inventory = try Self.inventory(
            artifacts: [Self.artifact(Self.gamma, "A package", kind: .nativePlugin, authority: .trackedOnly)],
            assignments: [
                .init(artifactID: Self.gamma, destination: .init(surface: .claudeCode, scope: .user),
                      reason: .manual),
            ])

        #expect(inventory.plugins.first?.installed == false)
        // No version is invented for content the workspace pins by digest.
        #expect(inventory.plugins.first?.revision == "")
    }

    @Test func oneClientAskedForTwiceIsStillOneClient() throws {
        let inventory = try Self.inventory(
            artifacts: [Self.artifact(Self.alpha, "Alpha", kind: .skill, authority: .centralPersonal)],
            assignments: [
                .init(artifactID: Self.alpha, destination: .init(surface: .codexCLI, scope: .user),
                      reason: .manual),
                .init(artifactID: Self.alpha,
                      destination: .init(surface: .codexCLI, scope: .project,
                                         logicalProjectID: Self.project),
                      reason: .manual),
            ],
            projects: [.init(id: Self.project, name: "Work")],
            projectArtifacts: true)

        let clients = try #require(inventory.skills.first?.clients)
        #expect(clients.count == 1)
        #expect(clients.first?.detail.contains("2 places") == true)
    }

    @Test func aConnectionsAddressIsNotInventedForTheAnswer() throws {
        let inventory = try Self.inventory(
            artifacts: [Self.artifact(Self.beta, "Beta", kind: .mcpServer, authority: .centralPersonal)],
            definitions: [.init(artifactID: Self.beta,
                                connection: .remoteHTTPS(url: "https://example.com/mcp"))])

        // The address lives in this Mac's own client files, not in the portable
        // workspace, so an empty string is the truthful answer.
        #expect(inventory.mcpServers.first?.endpoint.isEmpty == true)
        #expect(inventory.mcpServers.first?.authentication.isEmpty == true)
        #expect(inventory.mcpServers.first?.definitionOrigin == .managed)
    }

    @Test func presetsAndProjectsAreNotThingsAnAgentCanInstall() throws {
        let inventory = try Self.inventory(artifacts: [
            .init(identity: .init(id: Self.alpha, kind: .preset, displayName: "Starter"),
                  authority: .centralPersonal),
        ], presets: [.init(id: Self.alpha, name: "Starter", revision: 1, memberArtifactIDs: [])])
        _ = inventory

        #expect(inventory.skills.isEmpty)
        #expect(inventory.mcpServers.isEmpty)
        #expect(inventory.plugins.isEmpty)
    }

    private static let alpha = ArtifactID(UUID(uuidString: "00000000-0000-0000-0000-0000000000a1")!)
    private static let beta = ArtifactID(UUID(uuidString: "00000000-0000-0000-0000-0000000000b2")!)
    private static let gamma = ArtifactID(UUID(uuidString: "00000000-0000-0000-0000-0000000000c3")!)
    private static let project = ArtifactID(UUID(uuidString: "00000000-0000-0000-0000-0000000000d4")!)

    private static func artifact(
        _ id: ArtifactID, _ name: String, kind: ArtifactKind, authority: ContentAuthority
    ) -> ArtifactRecord {
        .init(identity: .init(id: id, kind: kind, displayName: name), authority: authority)
    }

    private static func inventory(
        artifacts: [ArtifactRecord],
        assignments: [AssignmentContribution] = [],
        presets: [PresetRecord] = [],
        projects: [LogicalProjectRecord] = [],
        projectArtifacts: Bool = false,
        definitions: [PortableMCPDefinitionRecord] = []
    ) throws -> VersionedInventoryProjection.Inventory {
        var artifacts = artifacts
        if projectArtifacts {
            artifacts += projects.map {
                .init(identity: .init(id: $0.id, kind: .logicalProject, displayName: $0.name),
                      authority: .centralPersonal)
            }
        }
        let document = try WorkspaceDocumentCoding.seal(.init(
            workspaceID: WorkspaceObjectID(UUID(uuidString: "00000000-0000-0000-0000-0000000000e5")!),
            revision: .init(writerID: WorkspaceObjectID()),
            artifacts: artifacts, logicalProjects: projects, assignments: assignments,
            presets: presets, mcpDefinitions: definitions))
        let device = DeviceWorkspaceState(workspaceID: document.workspaceID)
        let model = try WorkspaceLibraryReadModel(
            snapshot: .init(document: document, device: device))
        return VersionedInventoryProjection.inventory(model)
    }
}
