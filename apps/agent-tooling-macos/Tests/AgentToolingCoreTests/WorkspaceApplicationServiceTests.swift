import Foundation
import SQLite3
import Testing

@testable import AgentToolingCore

struct WorkspaceApplicationServiceTests {
    @Test func renameRetainsHistoryAndReplaysOriginalResultAfterReopen() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let original = fixture.document
        let command = fixture.rename("A clearer label")
        let result = try await fixture.service.renameArtifact(command)
        let after = try #require(try fixture.store.snapshot())
        #expect(after.document.artifacts[0].identity.id == fixture.artifactID)
        #expect(after.document.artifacts[0].identity.displayName == "A clearer label")
        #expect(after.document.artifacts[0].declaredName == "shared-instructions")
        #expect(after.document.artifacts[0].identity.aliases == original.artifacts[0].identity.aliases)
        #expect(after.document.revision.parentIDs == [original.revision.id])
        #expect(after.device == fixture.device)
        #expect(try fixture.store.revision(original.revision.id) == original)

        let reopened = try fixture.anotherStore()
        let service = WorkspaceApplicationService(store: reopened, writerID: fixture.writerID)
        let second = RenameArtifactCommand(expectedRevisionID: result.committedRevisionID,
            artifactID: fixture.artifactID, displayName: "A later edit")
        let later = try await service.renameArtifact(second)
        let replay = try await service.renameArtifact(command)
        #expect(replay == result)
        #expect(try reopened.snapshot()?.document.revision.id == later.committedRevisionID)
        #expect(try reopened.snapshot()?.document.artifacts[0].identity.displayName == "A later edit")
    }

    @Test func schemaThreeMCPDefinitionAndDeviceBindingSurviveRenameAndReopen() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "schema-three-mcp-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let writerID = WorkspaceObjectID()
        let artifactID = ArtifactID()
        let definition = PortableMCPDefinitionRecord(
            artifactID: artifactID, connection: .deviceBound(transport: .stdio))
        let document = try WorkspaceDocumentCoding.seal(PortableWorkspaceDocument(
            revision: .init(writerID: writerID),
            artifacts: [.init(
                identity: .init(id: artifactID, kind: .mcpServer, displayName: "Managed runner"),
                authority: .centralPersonal)],
            mcpDefinitions: [definition]))
        let binding = DeviceMCPDefinitionBinding(
            artifactID: artifactID,
            destination: .stdio(executable: "mcp-runner", arguments: ["--label", "two words"]),
            credentialRequirementNames: ["MCP_RUNNER_TOKEN"])
        let device = DeviceWorkspaceState(workspaceID: document.workspaceID, mcpBindings: [binding])
        try device.validateStructure(against: document)
        let portableBytes = try WorkspaceDocumentCoding.encode(document)
        #expect(!String(decoding: portableBytes, as: UTF8.self).contains("mcp-runner"))
        #expect(!String(decoding: portableBytes, as: UTF8.self).contains("two words"))

        let store = try WorkspaceRevisionStore(
            containerRoot: root, workspaceID: document.workspaceID, deviceID: device.deviceID)
        try store.initialize(document: document, device: device)
        let service = WorkspaceApplicationService(store: store, writerID: writerID)
        _ = try await service.renameArtifact(.init(
            expectedRevisionID: document.revision.id, artifactID: artifactID, displayName: "Renamed runner"))

        let reopened = try WorkspaceRevisionStore(
            containerRoot: root, workspaceID: document.workspaceID, deviceID: device.deviceID)
        let saved = try #require(try reopened.snapshot())
        #expect(saved.document.artifacts.first?.identity.id == artifactID)
        #expect(saved.document.artifacts.first?.identity.displayName == "Renamed runner")
        #expect(saved.document.mcpDefinitions == [definition])
        #expect(saved.device.mcpBindings == [binding])
    }

    @Test func concurrentConnectionsCannotLoseAnEditOrRunOneRequestTwice() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let other = WorkspaceApplicationService(store: try fixture.anotherStore(), writerID: WorkspaceObjectID())
        let command = fixture.rename("One request")
        async let first = fixture.service.renameArtifact(command)
        async let replay = other.renameArtifact(command)
        let (one, two) = try await (first, replay)
        #expect(one == two)

        let left = RenameArtifactCommand(expectedRevisionID: one.committedRevisionID,
            artifactID: fixture.artifactID, displayName: "Left")
        let right = RenameArtifactCommand(expectedRevisionID: one.committedRevisionID,
            artifactID: fixture.artifactID, displayName: "Right")
        async let leftResult = attempt(fixture.service, left)
        async let rightResult = attempt(other, right)
        let outcomes = await [leftResult, rightResult]
        #expect(outcomes.filter { if case .success = $0 { true } else { false } }.count == 1)
        #expect(outcomes.filter { if case .failure(.staleRevision) = $0 { true } else { false } }.count == 1)
        let final = try #require(try fixture.store.snapshot())
        #expect(final.document.revision.parentIDs == [one.committedRevisionID])
        #expect(["Left", "Right"].contains(final.document.artifacts[0].identity.displayName))
    }

    @Test func staleAndReusedKeysFailWithoutChangingTheHead() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let command = fixture.rename("First")
        let first = try await fixture.service.renameArtifact(command)
        let collision = RenameArtifactCommand(expectedRevisionID: fixture.document.revision.id,
            idempotencyKey: command.idempotencyKey, artifactID: fixture.artifactID, displayName: "Different payload")
        #expect(await attempt(fixture.service, collision) == .failure(.idempotencyKeyReused))
        #expect(await attempt(fixture.service, fixture.rename("Stale")) == .failure(.staleRevision(current: first.committedRevisionID)))
        #expect(try fixture.store.snapshot()?.document.revision.id == first.committedRevisionID)
    }

    @Test func failureAfterHeadUpdateRollsBackRevisionAndAllowsRetry() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.sql("""
            CREATE TRIGGER reject_receipt BEFORE INSERT ON command_receipts
            BEGIN SELECT RAISE(ABORT, 'Injected interruption before receipt'); END;
            """)
        let command = fixture.rename("Retry me")
        let failed = await attempt(fixture.service, command)
        #expect({ if case .failure(.sqlite) = failed { true } else { false } }())
        #expect(try fixture.store.snapshot()?.document == fixture.document)
        #expect(try fixture.scalar("SELECT COUNT(*) FROM revisions") == 1)
        #expect(try fixture.scalar("SELECT COUNT(*) FROM command_receipts") == 0)

        try fixture.sql("DROP TRIGGER reject_receipt")
        let result = try await fixture.service.renameArtifact(command)
        #expect(try fixture.store.snapshot()?.document.revision.id == result.committedRevisionID)
        #expect(try fixture.scalar("SELECT COUNT(*) FROM revisions") == 2)
    }

    @Test func newerFormatIsRejectedByOpenConnectionsAndOnReopen() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let futureVersion = WorkspaceRevisionStore.storeFormatVersion + 1
        try fixture.sql("PRAGMA user_version = \(futureVersion)")
        #expect(await attempt(fixture.service, fixture.rename("Must not save")) == .failure(.unsupportedStoreFormat))
        #expect(throws: WorkspaceRevisionStoreError.unsupportedStoreFormat) { _ = try fixture.anotherStore() }
        #expect(try fixture.scalar("PRAGMA user_version") == futureVersion)
        #expect(try fixture.scalar("SELECT COUNT(*) FROM revisions") == 1)
    }

    @Test func bootstrapRefusesOverwriteMismatchedDeviceAndMissingAncestry() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        #expect(throws: WorkspaceRevisionStoreError.alreadyInitialized) {
            try fixture.store.initialize(document: fixture.document, device: fixture.device)
        }
        #expect(throws: WorkspaceRevisionStoreError.wrongWorkspaceOrDevice) {
            _ = try WorkspaceRevisionStore(containerRoot: fixture.root, workspaceID: fixture.document.workspaceID,
                deviceID: WorkspaceObjectID())
        }
        var missingAncestor = fixture.document
        missingAncestor.revision.parentIDs = [WorkspaceObjectID()]
        missingAncestor = try WorkspaceDocumentCoding.seal(missingAncestor)
        #expect(throws: WorkspaceRevisionStoreError.missingAncestry) {
            try fixture.store.initialize(document: missingAncestor, device: fixture.device)
        }
        #expect(try fixture.store.snapshot()?.document == fixture.document)
    }

    @Test func danglingHeadAndHistoryMutationCannotMasqueradeAsAnEmptyLibrary() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        #expect(throws: TestDatabaseError.self) { try fixture.sql("DELETE FROM revisions") }
        try fixture.sql("UPDATE workspace_head SET revision_id = 'missing'")
        #expect(throws: WorkspaceRevisionStoreError.corruptState) { _ = try fixture.store.snapshot() }
        #expect(throws: WorkspaceRevisionStoreError.corruptState) {
            try fixture.store.initialize(document: fixture.document, device: fixture.device)
        }
        #expect(try fixture.scalar("SELECT COUNT(*) FROM revisions") == 1)
    }

    @Test func storeRefusesSymlinkedDatabaseAndVersionedDirectory() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "revision-path-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let outside = root.appending(path: "outside")
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: root.appending(path: "workspaces-v1"), withDestinationURL: outside)
        #expect(throws: WorkspaceRevisionStoreError.unsafeStorePath) {
            _ = try WorkspaceRevisionStore(containerRoot: root, workspaceID: WorkspaceObjectID(), deviceID: WorkspaceObjectID())
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: outside.path).isEmpty)
    }

    private func attempt(_ service: WorkspaceApplicationService, _ command: RenameArtifactCommand) async
        -> Result<WorkspaceCommandReceipt, WorkspaceRevisionStoreError> {
        do { return .success(try await service.renameArtifact(command)) }
        catch let error as WorkspaceRevisionStoreError { return .failure(error) }
        catch { Issue.record("Unexpected error: \(error)"); return .failure(.corruptState) }
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
            root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appending(path: "revision-store-\(UUID())")
            document = try WorkspaceDocumentCoding.seal(PortableWorkspaceDocument(
                revision: WorkspaceRevision(writerID: writerID), artifacts: [ArtifactRecord(
                    identity: ArtifactIdentity(id: artifactID, kind: .skill, displayName: "Original",
                        aliases: [ExternalAlias(namespace: "legacy.skill", value: "shared-instructions")]),
                    authority: .centralPersonal, declaredName: "shared-instructions")]))
            device = DeviceWorkspaceState(workspaceID: document.workspaceID)
            store = try WorkspaceRevisionStore(containerRoot: root, workspaceID: document.workspaceID, deviceID: device.deviceID)
            try store.initialize(document: document, device: device)
            service = WorkspaceApplicationService(store: store, writerID: writerID)
        }

        func rename(_ name: String) -> RenameArtifactCommand {
            .init(expectedRevisionID: document.revision.id, artifactID: artifactID, displayName: name)
        }
        func anotherStore() throws -> WorkspaceRevisionStore {
            try WorkspaceRevisionStore(containerRoot: root, workspaceID: document.workspaceID, deviceID: device.deviceID)
        }
        func remove() { try? FileManager.default.removeItem(at: root) }
        func sql(_ command: String) throws {
            try withDatabase { database in
                guard sqlite3_exec(database, command, nil, nil, nil) == SQLITE_OK else { throw TestDatabaseError.failed }
            }
        }
        func scalar(_ command: String) throws -> Int32 {
            try withDatabase { database in
                var statement: OpaquePointer?
                defer { sqlite3_finalize(statement) }
                guard sqlite3_prepare_v2(database, command, -1, &statement, nil) == SQLITE_OK,
                    sqlite3_step(statement) == SQLITE_ROW else { throw TestDatabaseError.failed }
                return sqlite3_column_int(statement, 0)
            }
        }
        private func withDatabase<T>(_ body: (OpaquePointer) throws -> T) throws -> T {
            var database: OpaquePointer?
            guard sqlite3_open(store.databaseURL.path, &database) == SQLITE_OK, let database else { throw TestDatabaseError.failed }
            defer { sqlite3_close(database) }
            return try body(database)
        }
    }

    private enum TestDatabaseError: Error { case failed }
}
