import Foundation
import SQLite3
import Testing

@testable import AgentToolingCore

struct WorkspaceAuthorityServiceTests {
    @Test func initializedMigrationActivatesVersionedAuthorityWithExactTarget() async throws {
        let fixture = try await Fixture.ready()
        defer { fixture.remove() }
        #expect(try WorkspaceAuthorityStore.readIfPresent(legacyRoot: fixture.legacy.rootURL) == nil)
        let authority = try fixture.authority()
        let selection = try await authority.prepareActivation(attemptID: fixture.preparation.record.manifest.attemptID)
        let applied = try await authority.apply(selection)

        #expect(applied == selection)
        #expect(applied.choice == .versioned)
        #expect(applied.target.workspaceID == fixture.context.workspaceID)
        #expect(applied.target.deviceID == fixture.context.deviceID)
        #expect(applied.target.attemptID == fixture.preparation.record.manifest.attemptID)
        #expect(applied.versionedRevisionID == fixture.preparation.record.manifest.initialRevisionID)
        #expect(try WorkspaceAuthorityStore.readIfPresent(legacyRoot: fixture.legacy.rootURL) == selection)
        #expect(try Data(contentsOf: fixture.nativeSentinel) == Data("native remains unmanaged".utf8))
    }

    @Test func changedLegacyAfterReviewRejectsActivation() async throws {
        let fixture = try await Fixture.ready()
        defer { fixture.remove() }
        let authority = try fixture.authority()
        let selection = try await authority.prepareActivation(attemptID: fixture.preparation.record.manifest.attemptID)
        try fixture.legacy.saveWorkspaceSnapshot(fixture.snapshot(label: "changed"))

        await #expect(throws: WorkspaceMigrationError.changedLegacyStore) {
            try await authority.apply(selection)
        }
        #expect(try WorkspaceAuthorityStore.readIfPresent(legacyRoot: fixture.legacy.rootURL) == nil)
    }

    @Test func changedSourceAfterReviewRejectsActivation() async throws {
        let fixture = try await Fixture.ready()
        defer { fixture.remove() }
        let authority = try fixture.authority()
        let selection = try await authority.prepareActivation(attemptID: fixture.preparation.record.manifest.attemptID)
        try Data("changed source\n".utf8).write(to: fixture.source.appending(path: "SKILL.md"))

        do {
            _ = try await authority.apply(selection)
            Issue.record("Changing the reviewed source must reject activation.")
        } catch let error as WorkspaceMigrationError {
            guard case .changedSource = error else {
                Issue.record("Expected changedSource, got \(error)")
                return
            }
        }
        #expect(try WorkspaceAuthorityStore.readIfPresent(legacyRoot: fixture.legacy.rootURL) == nil)
    }

    @Test func rollbackAcceptsLaterLegacyEditsAndReplayIsIdempotent() async throws {
        let fixture = try await Fixture.ready()
        defer { fixture.remove() }
        let authority = try fixture.authority()
        let activation = try await authority.prepareActivation(attemptID: fixture.preparation.record.manifest.attemptID)
        let appliedActivation = try await authority.apply(activation)
        // Simulate a retained older binary that does not honor the new registry.
        _ = try legacySQL("CREATE TABLE later_legacy_edit(value INTEGER)", fixture.legacy.databaseURL)
        _ = try legacySQL("INSERT INTO later_legacy_edit VALUES(42)", fixture.legacy.databaseURL)
        let store = try fixture.revisionStore()
        let current = try #require(try store.snapshot())
        _ = try store.commitMetadata(expectedRevisionID: current.document.revision.id,
            idempotencyKey: WorkspaceObjectID(), inputDigest: String(repeating: "b", count: 64), writerID: WorkspaceObjectID()) { document in
                document.artifacts[0].identity.displayName = "new store later"
                return [document.artifacts[0].identity.id]
            }
        let rollback = try await authority.prepareRollback()
        let applied = try await authority.apply(rollback)
        #expect(applied.choice == .legacy)
        #expect(try legacySQL("SELECT value FROM later_legacy_edit", fixture.legacy.databaseURL) == 42)
        #expect(rollback.checkpointSHA256 != activation.checkpointSHA256)
        #expect(try store.snapshot()?.document.artifacts[0].identity.displayName == "new store later")
        #expect(try await authority.apply(appliedActivation) == appliedActivation)
        #expect(try await authority.apply(rollback) == applied)
        #expect(try WorkspaceAuthorityStore.readIfPresent(legacyRoot: fixture.legacy.rootURL) == applied)
        try fixture.legacy.saveWorkspaceSnapshot(fixture.snapshot(label: "legacy after rollback"))
        #expect(try fixture.legacy.loadWorkspaceSnapshot()?.profiles.first?.id == "legacy after rollback")
        #expect(try store.snapshot()?.document.artifacts[0].identity.displayName == "new store later")
    }

    @Test func staleVersionedHeadRejectsSelectionWithoutRegistryMutation() async throws {
        let fixture = try await Fixture.ready()
        defer { fixture.remove() }
        let authority = try fixture.authority()
        let selection = try await authority.prepareActivation(attemptID: fixture.preparation.record.manifest.attemptID)
        let store = try fixture.revisionStore()
        let current = try #require(try store.snapshot())
        _ = try store.commitMetadata(expectedRevisionID: current.document.revision.id,
            idempotencyKey: WorkspaceObjectID(), inputDigest: String(repeating: "c", count: 64), writerID: WorkspaceObjectID()) { document in
                document.artifacts[0].identity.displayName = "drift"
                return [document.artifacts[0].identity.id]
            }
        await #expect(throws: WorkspaceRevisionStoreError.self) {
            try await authority.apply(selection)
        }
        #expect(try WorkspaceAuthorityStore.readIfPresent(legacyRoot: fixture.legacy.rootURL) == nil)
    }

    @Test func malformedSelectionLeavesRegistryUnchanged() async throws {
        let fixture = try await Fixture.ready()
        defer { fixture.remove() }
        let authority = try fixture.authority()
        let selection = try await authority.prepareActivation(attemptID: fixture.preparation.record.manifest.attemptID)
        let malformed = WorkspaceAuthoritySelection(id: selection.id, choice: .versioned, target: selection.target,
            checkpointSHA256: selection.checkpointSHA256, versionedRevisionID: WorkspaceObjectID(), selectedAt: selection.selectedAt)
        await #expect(throws: WorkspaceAuthorityServiceError.invalidSelection) {
            try await authority.apply(malformed)
        }
        #expect(try WorkspaceAuthorityStore.readIfPresent(legacyRoot: fixture.legacy.rootURL) == nil)
    }

    @Test func legacyWritersAreGatedAfterVersionedActivation() async throws {
        let fixture = try await Fixture.ready()
        defer { fixture.remove() }
        let authority = try fixture.authority()
        let selection = try await authority.prepareActivation(attemptID: fixture.preparation.record.manifest.attemptID)
        _ = try await authority.apply(selection)
        let legacy = fixture.legacy
        #expect(try legacy.loadWorkspaceSnapshot()?.profiles.first?.id == "reviewed")
        #expect(throws: WorkspaceAuthorityStoreError.versionedSelected) {
            _ = try WorkspaceStore(rootURL: legacy.rootURL)
        }
        #expect(throws: WorkspaceAuthorityStoreError.versionedSelected) {
            try legacy.save("blocked", for: "blocked")
        }
        #expect(throws: WorkspaceAuthorityStoreError.versionedSelected) {
            try legacy.remove("blocked")
        }
        #expect(throws: WorkspaceAuthorityStoreError.versionedSelected) {
            try legacy.saveEntity("blocked", id: "blocked", domain: .sources)
        }
        #expect(throws: WorkspaceAuthorityStoreError.versionedSelected) {
            try legacy.removeEntity("blocked", domain: .sources)
        }
        #expect(throws: WorkspaceAuthorityStoreError.versionedSelected) {
            try legacy.saveWorkspaceSnapshot(fixture.snapshot(label: "blocked"))
        }
        #expect(throws: WorkspaceAuthorityStoreError.versionedSelected) {
            try legacy.updatePendingAgentRequestQueue { _ in }
        }
        #expect(throws: WorkspaceAuthorityStoreError.versionedSelected) {
            try legacy.pruneOperationHistory(keepingPlanIDs: [])
        }
    }

    @Test func rollbackRejectsLegacyEditsAfterItsReviewWithoutChangingAuthority() async throws {
        let fixture = try await Fixture.ready()
        defer { fixture.remove() }
        let authority = try fixture.authority()
        let activation = try await authority.prepareActivation(attemptID: fixture.preparation.record.manifest.attemptID)
        _ = try await authority.apply(activation)
        let rollback = try await authority.prepareRollback()
        _ = try legacySQL("CREATE TABLE changed_during_rollback(value INTEGER)", fixture.legacy.databaseURL)
        await #expect(throws: WorkspaceMigrationError.changedLegacyStore) {
            _ = try await authority.apply(rollback)
        }
        #expect(try WorkspaceAuthorityStore.readIfPresent(legacyRoot: fixture.legacy.rootURL) == activation)
        #expect(try legacySQL("SELECT count(*) FROM changed_during_rollback", fixture.legacy.databaseURL) == 0)
    }

    @Test func missingCentralContentRejectsActivationWithoutSelectingIt() async throws {
        let fixture = try await Fixture.ready()
        defer { fixture.remove() }
        let authority = try fixture.authority()
        let selection = try await authority.prepareActivation(attemptID: fixture.preparation.record.manifest.attemptID)
        try FileManager.default.moveItem(at: fixture.base.root.appending(path: "content"),
                                        to: fixture.base.root.appending(path: "content-offline"))
        await #expect(throws: CentralPackageStoreError.self) {
            _ = try await authority.apply(selection)
        }
        #expect(try WorkspaceAuthorityStore.readIfPresent(legacyRoot: fixture.legacy.rootURL) == nil)
        #expect(try fixture.revisionStore().snapshot()?.document.revision.id == selection.versionedRevisionID)
    }

    @Test func legacyBarrierBlocksAnUncoordinatedSQLiteWriterButAllowsFinalCapture() async throws {
        let fixture = try await Fixture.ready()
        defer { fixture.remove() }
        _ = try legacySQL("CREATE TABLE barrier_probe(value INTEGER)", fixture.legacy.databaseURL)
        let before = try await WorkspaceLegacyCheckpoint.capture(databaseURL: fixture.legacy.databaseURL)
        try WorkspaceLegacyCheckpoint.withWriteBarrier(databaseURL: fixture.legacy.databaseURL) {
            var competing: OpaquePointer?
            #expect(sqlite3_open_v2(fixture.legacy.databaseURL.path, &competing, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK)
            defer { sqlite3_close(competing) }
            #expect(sqlite3_exec(competing, "INSERT INTO barrier_probe VALUES(99)", nil, nil, nil) == SQLITE_BUSY)
            let captured = try WorkspaceLegacyCheckpoint.captureSynchronously(databaseURL: fixture.legacy.databaseURL)
            #expect(captured.sha256 == before.sha256)
        }
        _ = try legacySQL("INSERT INTO barrier_probe VALUES(99)", fixture.legacy.databaseURL)
        #expect(try legacySQL("SELECT value FROM barrier_probe", fixture.legacy.databaseURL) == 99)
    }

    private func legacySQL(_ sql: String, _ databaseURL: URL) throws -> Int32? {
        var db: OpaquePointer?
        guard sqlite3_open_v2(databaseURL.path, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK else {
            if let db { sqlite3_close(db) }
            throw WorkspaceAuthorityStoreError.unavailable
        }
        defer { sqlite3_close(db) }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw WorkspaceAuthorityStoreError.unavailable
        }
        defer { sqlite3_finalize(statement) }
        switch sqlite3_step(statement) {
        case SQLITE_ROW: return sqlite3_column_int(statement, 0)
        case SQLITE_DONE: return nil
        default: throw WorkspaceAuthorityStoreError.unavailable
        }
    }

    private struct Fixture {
        let base: WorkspaceMigrationServiceTests.Fixture
        let preparation: WorkspaceMigrationPreparation
        let legacy: WorkspaceStore
        let source: URL
        let context: WorkspaceMigrationContext
        let nativeSentinel: URL

        static func ready() async throws -> Self {
            let base = try WorkspaceMigrationServiceTests.Fixture()
            try base.legacy.saveWorkspaceSnapshot(base.snapshot(label: "reviewed"))
            let preparation = try await base.preparation()
            let migration = try base.service()
            _ = try await migration.stage(preparation)
            _ = try await migration.initialize(attemptID: preparation.record.manifest.attemptID,
                inputDigest: try preparation.record.inputDigest)
            return .init(base: base, preparation: preparation, legacy: base.legacy, source: base.source,
                context: base.context, nativeSentinel: base.nativeSentinel)
        }

        func revisionStore() throws -> WorkspaceRevisionStore { try base.revisionStore() }
        func authority() throws -> WorkspaceAuthorityService {
            try WorkspaceAuthorityService(legacyRoot: legacy.rootURL, store: revisionStore(),
                checkpoints: base.checkpointStore(), content: base.contentStore())
        }
        func snapshot(label: String) -> WorkspaceSnapshot { base.snapshot(label: label) }
        func remove() { base.remove() }
    }
}
