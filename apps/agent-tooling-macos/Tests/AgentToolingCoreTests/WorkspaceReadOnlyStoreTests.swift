import Foundation
import Testing

@testable import AgentToolingCore

struct WorkspaceReadOnlyStoreTests {
    @Test func readOnlyOpeningSeesLatestWriterHeadAndWALRevision() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let receipt = try await fixture.service.renameArtifact(.init(expectedRevisionID: fixture.document.revision.id,
            artifactID: fixture.artifactID, displayName: "Latest writer edit"))

        let readOnly = try WorkspaceRevisionStore(containerRoot: fixture.root,
            workspaceID: fixture.document.workspaceID, deviceID: fixture.device.deviceID, access: .existingReadOnly)
        let snapshot = try #require(try readOnly.snapshot())
        #expect(snapshot.document.revision.id == receipt.committedRevisionID)
        #expect(snapshot.document.artifacts.first?.identity.displayName == "Latest writer edit")
    }

    @Test func readOnlyRenameAndInitializeAreDeniedAndHeadIsPreserved() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let readOnlyStore = try WorkspaceRevisionStore(containerRoot: fixture.root,
            workspaceID: fixture.document.workspaceID, deviceID: fixture.device.deviceID, access: .existingReadOnly)
        let service = WorkspaceApplicationService(store: readOnlyStore, writerID: fixture.writerID)
        let before = try #require(try readOnlyStore.snapshot())

        await #expect(throws: WorkspaceRevisionStoreError.readOnly) {
            try await service.renameArtifact(.init(expectedRevisionID: before.document.revision.id,
                artifactID: fixture.artifactID, displayName: "Must not save"))
        }
        #expect(throws: WorkspaceRevisionStoreError.readOnly) {
            try readOnlyStore.initialize(document: fixture.document, device: fixture.device)
        }
        #expect(try readOnlyStore.snapshot()?.document == before.document)
    }

    @Test func readOnlyMissingContainerOrDatabaseIsNotCreated() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "readonly-missing-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let workspaceID = WorkspaceObjectID()
        let deviceID = WorkspaceObjectID()
        #expect(throws: WorkspaceRevisionStoreError.self) {
            _ = try WorkspaceRevisionStore(containerRoot: root, workspaceID: workspaceID, deviceID: deviceID,
                access: .existingReadOnly)
        }
        #expect(FileManager.default.fileExists(atPath: root.path) == false)

        let existingRoot = FileManager.default.temporaryDirectory.appending(path: "readonly-no-database-\(UUID())")
        defer { try? FileManager.default.removeItem(at: existingRoot) }
        try FileManager.default.createDirectory(at: existingRoot.appending(path: "workspaces-v1").appending(path: workspaceID.rawValue.uuidString.lowercased()),
            withIntermediateDirectories: true)
        #expect(throws: WorkspaceRevisionStoreError.self) {
            _ = try WorkspaceRevisionStore(containerRoot: existingRoot, workspaceID: workspaceID, deviceID: deviceID,
                access: .existingReadOnly)
        }
        let database = existingRoot.appending(path: "workspaces-v1").appending(path: workspaceID.rawValue.uuidString.lowercased()).appending(path: "revisions.sqlite")
        #expect(FileManager.default.fileExists(atPath: database.path) == false)
    }

    @Test func readOnlyVersionUpgradeIsRefusedBeforeAnyMutation() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let before = try #require(try fixture.store.snapshot())
        #expect(throws: WorkspaceRevisionStoreError.readOnly) {
            _ = try WorkspaceRevisionStore(containerRoot: fixture.root, workspaceID: fixture.document.workspaceID,
                deviceID: fixture.device.deviceID, formatUpgrade: .version1To2, access: .existingReadOnly)
        }
        #expect(try fixture.store.snapshot()?.document == before.document)
    }

    private struct Fixture {
        let root: URL
        let artifactID = ArtifactID()
        let writerID = WorkspaceObjectID()
        let document: PortableWorkspaceDocument
        let device: DeviceWorkspaceState
        let store: WorkspaceRevisionStore
        let service: WorkspaceApplicationService

        init() throws {
            root = FileManager.default.temporaryDirectory.appending(path: "readonly-store-\(UUID())")
            document = try WorkspaceDocumentCoding.seal(.init(revision: .init(writerID: writerID), artifacts: [
                .init(identity: .init(id: artifactID, kind: .skill, displayName: "Original"), authority: .centralPersonal)
            ]))
            device = DeviceWorkspaceState(workspaceID: document.workspaceID)
            store = try WorkspaceRevisionStore(containerRoot: root, workspaceID: document.workspaceID, deviceID: device.deviceID)
            try store.initialize(document: document, device: device)
            service = WorkspaceApplicationService(store: store, writerID: writerID)
        }

        func remove() { try? FileManager.default.removeItem(at: root) }
    }
}
