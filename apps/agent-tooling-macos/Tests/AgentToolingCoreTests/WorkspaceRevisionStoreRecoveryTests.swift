import Foundation
import SQLite3
import Testing

@testable import AgentToolingCore

struct WorkspaceRevisionStoreRecoveryTests {
    @Test func corruptReceiptReferencesAndPayloadDoNotReplayAsSuccess() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let command = fixture.command("first")
        _ = try await fixture.service.renameArtifact(command)
        try fixture.sql("UPDATE command_receipts SET revision_id = 'missing'")

        #expect(await attempt(fixture.service, command) == .failure(.corruptState))
    }

    @Test func bootstrapRollbackLeavesAnEmptyStoreThatCanRetry() throws {
        let fixture = try Fixture(bootstrap: false)
        defer { fixture.remove() }
        try fixture.sql("CREATE TRIGGER reject_device BEFORE INSERT ON device_state BEGIN SELECT RAISE(ABORT, 'injected'); END;")
        #expect(throws: WorkspaceRevisionStoreError.self) {
            try fixture.store.initialize(document: fixture.document, device: fixture.device)
        }
        #expect(try fixture.store.snapshot() == nil)
        try fixture.sql("DROP TRIGGER reject_device")
        try fixture.store.initialize(document: fixture.document, device: fixture.device)
        #expect(try fixture.store.snapshot()?.document == fixture.document)
    }

    @Test func simultaneousDifferentPayloadsWithOneKeyCommitOnlyOne() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let key = WorkspaceObjectID()
        let left = RenameArtifactCommand(expectedRevisionID: fixture.document.revision.id, idempotencyKey: key, artifactID: fixture.artifactID, displayName: "left")
        let right = RenameArtifactCommand(expectedRevisionID: fixture.document.revision.id, idempotencyKey: key, artifactID: fixture.artifactID, displayName: "right")
        let other = WorkspaceApplicationService(store: try fixture.reopen(), writerID: WorkspaceObjectID())
        async let a = attempt(fixture.service, left)
        async let b = attempt(other, right)
        let outcomes = await [a, b]
        #expect(outcomes.filter { if case .success = $0 { true } else { false } }.count == 1)
        #expect(outcomes.filter { if case .failure(.idempotencyKeyReused) = $0 { true } else { false } }.count == 1)
        #expect(try fixture.scalar("SELECT COUNT(*) FROM revisions") == 2)
    }

    @Test func corruptDocumentDeviceAndRevisionRowsAreRejected() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.sql("DROP TRIGGER revisions_immutable_update")
        try fixture.sql("UPDATE revisions SET payload = X'7B' WHERE id = (SELECT revision_id FROM workspace_head)")
        #expect(throws: WorkspaceRevisionStoreError.corruptState) { _ = try fixture.store.snapshot() }
    }

    @Test func corruptDeviceAndAbsentDeviceStateAreRejected() throws {
        let corrupt = try Fixture(); defer { corrupt.remove() }
        try corrupt.sql("UPDATE device_state SET payload = X'7B'")
        #expect(throws: WorkspaceRevisionStoreError.corruptState) { _ = try corrupt.store.snapshot() }
        let absent = try Fixture(); defer { absent.remove() }
        try absent.sql("DELETE FROM device_state")
        #expect(throws: WorkspaceRevisionStoreError.corruptState) { _ = try absent.store.snapshot() }
    }

    @Test func revisionRowAndSealedPayloadMismatchIsRejected() throws {
        let fixture = try Fixture(); defer { fixture.remove() }
        var other = fixture.document
        other.revision = WorkspaceRevision(writerID: fixture.writerID)
        other = try WorkspaceDocumentCoding.seal(other)
        try fixture.sql("DROP TRIGGER revisions_immutable_update")
        try fixture.updateHeadPayload(WorkspaceDocumentCoding.encode(other))
        #expect(throws: WorkspaceRevisionStoreError.corruptState) { _ = try fixture.store.snapshot() }
    }

    @Test func corruptReceiptPayloadIsRejected() async throws {
        let fixture = try Fixture(); defer { fixture.remove() }
        let command = fixture.command("first")
        _ = try await fixture.service.renameArtifact(command)
        try fixture.sql("UPDATE command_receipts SET payload = X'7B'")
        #expect(await attempt(fixture.service, command) == .failure(.corruptState))
    }

    @Test func symlinkedDatabaseSidecarsAndContainerAreRejected() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "revision-links-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let ids = (WorkspaceObjectID(), WorkspaceObjectID())
        let directory = root.appending(path: "workspaces-v1/\(ids.0.rawValue.uuidString.lowercased())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let outside = root.appending(path: "outside")
        try Data().write(to: outside)
        try FileManager.default.createSymbolicLink(at: directory.appending(path: "revisions.sqlite"), withDestinationURL: outside)
        #expect(throws: WorkspaceRevisionStoreError.unsafeStorePath) {
            _ = try WorkspaceRevisionStore(containerRoot: root, workspaceID: ids.0, deviceID: ids.1)
        }
    }

    @Test(arguments: ["revisions.sqlite", "revisions.sqlite-wal", "revisions.sqlite-shm"])
    func symlinkedDatabaseVariantsAreRejected(_ name: String) throws {
        try assertSymlinkedStorePathRejected(path: name)
    }

    @Test func danglingDatabaseAndContainerSymlinksAreRejected() throws {
        try assertSymlinkedStorePathRejected(path: "revisions.sqlite", dangling: true)
        let root = FileManager.default.temporaryDirectory.appending(path: "revision-container-link-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let outside = root.appending(path: "outside")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: root.appending(path: "container"), withDestinationURL: outside)
        #expect(throws: WorkspaceRevisionStoreError.unsafeStorePath) {
            _ = try WorkspaceRevisionStore(containerRoot: root.appending(path: "container"), workspaceID: WorkspaceObjectID(), deviceID: WorkspaceObjectID())
        }
    }

    private func assertSymlinkedStorePathRejected(path: String, dangling: Bool = false) throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "revision-link-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let ids = (WorkspaceObjectID(), WorkspaceObjectID())
        let directory = root.appending(path: "workspaces-v1/\(ids.0.rawValue.uuidString.lowercased())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let destination = root.appending(path: dangling ? "missing" : "outside")
        if !dangling { try Data().write(to: destination) }
        try FileManager.default.createSymbolicLink(at: directory.appending(path: path), withDestinationURL: destination)
        #expect(throws: WorkspaceRevisionStoreError.unsafeStorePath) {
            _ = try WorkspaceRevisionStore(containerRoot: root, workspaceID: ids.0, deviceID: ids.1)
        }
    }

    private func attempt(_ service: WorkspaceApplicationService, _ command: RenameArtifactCommand) async -> Result<WorkspaceCommandReceipt, WorkspaceRevisionStoreError> {
        do { return .success(try await service.renameArtifact(command)) }
        catch let error as WorkspaceRevisionStoreError { return .failure(error) }
        catch { Issue.record("Unexpected error: \(error)"); return .failure(.corruptState) }
    }

    private struct Fixture {
        let root: URL; let artifactID = ArtifactID(); let writerID = WorkspaceObjectID()
        let document: PortableWorkspaceDocument; let device: DeviceWorkspaceState
        let store: WorkspaceRevisionStore; let service: WorkspaceApplicationService
        init(bootstrap: Bool = true) throws {
            root = FileManager.default.temporaryDirectory.appending(path: "revision-recovery-\(UUID())")
            document = try WorkspaceDocumentCoding.seal(PortableWorkspaceDocument(revision: WorkspaceRevision(writerID: writerID), artifacts: [ArtifactRecord(identity: ArtifactIdentity(id: artifactID, kind: .skill, displayName: "original"), authority: .centralPersonal, declaredName: "skill")]))
            device = DeviceWorkspaceState(workspaceID: document.workspaceID)
            store = try WorkspaceRevisionStore(containerRoot: root, workspaceID: document.workspaceID, deviceID: device.deviceID)
            if bootstrap { try store.initialize(document: document, device: device) }
            service = WorkspaceApplicationService(store: store, writerID: writerID)
        }
        func command(_ name: String) -> RenameArtifactCommand { .init(expectedRevisionID: document.revision.id, artifactID: artifactID, displayName: name) }
        func reopen() throws -> WorkspaceRevisionStore { try WorkspaceRevisionStore(containerRoot: root, workspaceID: document.workspaceID, deviceID: device.deviceID) }
        func remove() { try? FileManager.default.removeItem(at: root) }
        func sql(_ sql: String) throws { try withDB { db in guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else { throw WorkspaceRevisionStoreError.corruptState } } }
        func scalar(_ sql: String) throws -> Int32 { try withDB { db in var s: OpaquePointer?; defer { sqlite3_finalize(s) }; guard sqlite3_prepare_v2(db, sql, -1, &s, nil) == SQLITE_OK, sqlite3_step(s) == SQLITE_ROW else { throw WorkspaceRevisionStoreError.corruptState }; return sqlite3_column_int(s, 0) } }
        func updateHeadPayload(_ payload: Data) throws { try withDB { db in var s: OpaquePointer?; defer { sqlite3_finalize(s) }; guard sqlite3_prepare_v2(db, "UPDATE revisions SET payload = ? WHERE id = (SELECT revision_id FROM workspace_head)", -1, &s, nil) == SQLITE_OK else { throw WorkspaceRevisionStoreError.corruptState }; let status = payload.withUnsafeBytes { sqlite3_bind_blob(s, 1, $0.baseAddress, Int32(payload.count), unsafeBitCast(-1, to: sqlite3_destructor_type.self)) }; guard status == SQLITE_OK, sqlite3_step(s) == SQLITE_DONE else { throw WorkspaceRevisionStoreError.corruptState } } }
        private func withDB<T>(_ body: (OpaquePointer) throws -> T) throws -> T { var db: OpaquePointer?; guard sqlite3_open(store.databaseURL.path, &db) == SQLITE_OK, let db else { throw WorkspaceRevisionStoreError.databaseUnavailable }; defer { sqlite3_close(db) }; return try body(db) }
    }
}
