import AgentToolingTestSupport
import Foundation
import Testing

@testable import AgentToolingCore

/// Agent Tooling's own connection is bound to each Mac, not carried by the
/// library: its row says so, and the library's sizes leave it out. A server
/// of the person's own under another name, or the same name reached at a
/// shared address, is an ordinary entry.
@Suite("Library read model · own connection")
struct WorkspaceLibraryReadModelOwnConnectionTests {
    @Test func theOwnConnectionIsFlaggedAndLeftOutOfTheCounts() throws {
        let workspaceID = WorkspaceObjectID()
        let own = ArtifactID()
        let shared = ArtifactID()
        let plugin = ArtifactID()
        var document = PortableWorkspaceDocument(
            workspaceID: workspaceID, revision: .init(writerID: WorkspaceObjectID()),
            artifacts: [
                .init(
                    identity: .init(id: ArtifactID(), kind: .skill, displayName: "Release Notes"), authority: .trackedOnly,
                    declaredName: "release-notes"),
                .init(
                    identity: .init(id: own, kind: .mcpServer, displayName: "Agent Tooling"), authority: .centralPersonal,
                    declaredName: "agent-tooling"),
                .init(
                    identity: .init(id: shared, kind: .mcpServer, displayName: "Linear"), authority: .centralPersonal,
                    declaredName: "linear"),
                .init(
                    identity: .init(id: plugin, kind: .nativePlugin, displayName: "Sentry"), authority: .trackedOnly,
                    declaredName: "sentry@claude-plugins-official"),
                .init(
                    identity: .init(id: ArtifactID(), kind: .mcpServer, displayName: "sentry", parentPackageID: plugin),
                    authority: .trackedOnly,
                    declaredName: "sentry"),
            ])
        document.mcpDefinitions = [
            .init(artifactID: own, connection: .deviceBound(transport: .stdio)),
            .init(artifactID: shared, connection: .remoteHTTPS(url: "https://mcp.linear.app/sse")),
        ]
        document = try WorkspaceDocumentCoding.seal(document)

        let model = try WorkspaceLibraryReadModel(
            snapshot: .init(document: document, device: DeviceWorkspaceState(workspaceID: workspaceID)))

        #expect(model.rows.count == 4)
        #expect(model.rows.filter(\.isOwnConnection).map(\.artifactID) == [own])
        #expect(model.entryCount == 3)
        #expect(model.nestedToolCount == 1)
        #expect(model.toolCount == 4)
    }

    @Test func aConnectionUnderItsNameAtASharedAddressIsNoOwnConnection() throws {
        let workspaceID = WorkspaceObjectID()
        let remote = ArtifactID()
        var document = PortableWorkspaceDocument(
            workspaceID: workspaceID, revision: .init(writerID: WorkspaceObjectID()),
            artifacts: [
                .init(
                    identity: .init(id: remote, kind: .mcpServer, displayName: "agent-tooling"), authority: .centralPersonal,
                    declaredName: "agent-tooling")
            ])
        document.mcpDefinitions = [.init(artifactID: remote, connection: .remoteHTTPS(url: "https://example.com/mcp"))]
        document = try WorkspaceDocumentCoding.seal(document)

        let model = try WorkspaceLibraryReadModel(
            snapshot: .init(document: document, device: DeviceWorkspaceState(workspaceID: workspaceID)))

        #expect(!model.rows.contains { $0.isOwnConnection })
        #expect(model.toolCount == 1)
    }
}
