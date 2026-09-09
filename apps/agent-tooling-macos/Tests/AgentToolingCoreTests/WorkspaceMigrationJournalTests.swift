import Foundation
import SQLite3
import Testing

@testable import AgentToolingCore

struct WorkspaceMigrationJournalTests {
    @Test func preparedRecordIsDurableReplayableAndBlocksOrdinaryBootstrap() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let record = try fixture.record()

        #expect(try fixture.store.preflightMigration(record) == nil)
        #expect(try fixture.store.prepareMigration(record).phase == .prepared)
        #expect(try fixture.store.migration(record.manifest.attemptID)?.record == record)
        #expect(try fixture.reopen().preflightMigration(record)?.phase == .prepared)
        #expect(throws: WorkspaceMigrationError.preparationPending) {
            try fixture.store.initialize(document: record.document, device: record.device)
        }
    }

    @Test func oneAttemptIDCannotBeReusedForAlteredReviewInputs() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let attemptID = WorkspaceObjectID()
        let original = try fixture.record(attemptID: attemptID, checkpointByte: "a")
        let altered = try fixture.record(attemptID: attemptID, checkpointByte: "b")
        _ = try fixture.store.prepareMigration(original)

        #expect(throws: WorkspaceMigrationError.preparationConflict) {
            try fixture.reopen().preflightMigration(altered)
        }
        #expect(throws: WorkspaceMigrationError.preparationConflict) {
            try fixture.reopen().prepareMigration(altered)
        }
        #expect(throws: WorkspaceMigrationError.preparationConflict) {
            try fixture.reopen().initializeMigration(
                attemptID: attemptID,
                inputDigest: altered.inputDigest)
        }
        #expect(try fixture.store.migration(attemptID)?.record == original)
    }

    @Test func independentConnectionsSerializeSameAttemptReplayAndConflictingCAS() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let attemptID = WorkspaceObjectID()
        let original = try fixture.record(attemptID: attemptID, checkpointByte: "a")
        let altered = try fixture.record(attemptID: attemptID, checkpointByte: "b")
        let first = try fixture.reopen()
        let second = try fixture.reopen()

        async let left = prepareOutcome(first, original)
        async let right = prepareOutcome(second, altered)
        let outcomes = await [left, right]

        #expect(outcomes.filter { $0 == .prepared }.count == 1)
        #expect(outcomes.filter { $0 == .conflict }.count == 1)
        let persisted = try #require(try fixture.store.migration(attemptID))
        #expect(persisted.record == original || persisted.record == altered)
    }

    @Test func initializationAndCompletionMarkerCommitAtomicallyAndReplayAcrossConnections() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let record = try fixture.record()
        _ = try fixture.store.prepareMigration(record)
        let other = try fixture.reopen()

        let initialized = try other.initializeMigration(
            attemptID: record.manifest.attemptID,
            inputDigest: record.inputDigest
        )
        #expect(initialized.phase == .initialized)
        #expect(try fixture.store.snapshot()?.document == record.document)
        #expect(try fixture.store.migration(record.manifest.attemptID)?.phase == .initialized)
        #expect(try fixture.store.initializeMigration(
            attemptID: record.manifest.attemptID,
            inputDigest: record.inputDigest
        ) == initialized)
    }

    @Test func injectedBootstrapFailureLeavesPreparedJournalAndEmptyHeadForRetry() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let record = try fixture.record()
        _ = try fixture.store.prepareMigration(record)
        // Fail after the revision, device and head insert statements have run.
        // The enclosing transaction must roll all of them back with the phase.
        try fixture.sql("CREATE TRIGGER reject_migration_completion BEFORE UPDATE OF phase ON migration_attempts WHEN NEW.phase = 'initialized' BEGIN SELECT RAISE(ABORT, 'injected'); END;")

        #expect(throws: WorkspaceRevisionStoreError.self) {
            try fixture.store.initializeMigration(
                attemptID: record.manifest.attemptID,
                inputDigest: record.inputDigest
            )
        }
        #expect(try fixture.store.snapshot() == nil)
        #expect(try fixture.store.migration(record.manifest.attemptID)?.phase == .prepared)
        #expect(try fixture.scalar("SELECT COUNT(*) FROM revisions") == 0)
        #expect(try fixture.scalar("SELECT COUNT(*) FROM device_state") == 0)

        try fixture.sql("DROP TRIGGER reject_migration_completion")
        #expect(try fixture.store.initializeMigration(
            attemptID: record.manifest.attemptID,
            inputDigest: record.inputDigest
        ).phase == .initialized)
    }

    @Test(arguments: ["payload", "document", "device"])
    func corruptImmutableJournalBlobCannotReplay(_ column: String) throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let record = try fixture.record()
        _ = try fixture.store.prepareMigration(record)
        try fixture.sql("DROP TRIGGER migration_inputs_immutable")
        try fixture.sql("UPDATE migration_attempts SET \(column) = X'7B'")

        #expect(throws: WorkspaceRevisionStoreError.corruptState) {
            _ = try fixture.reopen().migration(record.manifest.attemptID)
        }
    }

    @Test func journalInputsAndCompletionPhaseAreImmutable() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let record = try fixture.record()
        _ = try fixture.store.prepareMigration(record)

        #expect(throws: WorkspaceRevisionStoreError.corruptState) {
            try fixture.sql("UPDATE migration_attempts SET payload = X'7B'")
        }
        #expect(throws: WorkspaceRevisionStoreError.corruptState) {
            try fixture.sql("UPDATE migration_attempts SET phase = 'prepared'")
        }
        _ = try fixture.store.initializeMigration(
            attemptID: record.manifest.attemptID,
            inputDigest: record.inputDigest)
        #expect(throws: WorkspaceRevisionStoreError.corruptState) {
            try fixture.sql("UPDATE migration_attempts SET phase = 'prepared'")
        }
        #expect(throws: WorkspaceRevisionStoreError.corruptState) {
            try fixture.sql("DELETE FROM migration_attempts")
        }
    }

    @Test func explicitVersionOneUpgradePreservesInitializedRowsAndAddsAnEmptyJournal() throws {
        let fixture = try Fixture(createStore: false)
        defer { fixture.remove() }
        let record = try fixture.record()
        try fixture.createVersionOneStore(document: record.document, device: record.device)

        #expect(throws: WorkspaceRevisionStoreError.unsupportedStoreFormat) {
            _ = try fixture.open(formatUpgrade: .none)
        }
        let upgraded = try fixture.open(formatUpgrade: .version1To2)
        #expect(try upgraded.snapshot()?.document == record.document)
        #expect(try upgraded.snapshot()?.device == record.device)
        #expect(try fixture.scalar("PRAGMA user_version") == 2)
        #expect(try fixture.scalar("SELECT COUNT(*) FROM migration_attempts") == 0)
    }

    @Test func upgradeRefusesWrongIdentityAndNonVersionOneFormats() throws {
        let wrong = try Fixture(createStore: false)
        defer { wrong.remove() }
        let record = try wrong.record()
        try wrong.createVersionOneStore(
            document: record.document,
            device: record.device,
            storedWorkspaceID: WorkspaceObjectID()
        )
        #expect(throws: WorkspaceRevisionStoreError.wrongWorkspaceOrDevice) {
            _ = try wrong.open(formatUpgrade: .version1To2)
        }
        #expect(try wrong.scalar("PRAGMA user_version") == 1)

        let future = try Fixture(createStore: false)
        defer { future.remove() }
        try future.createVersionOneStore(document: record.document, device: record.device, version: 3)
        #expect(throws: WorkspaceRevisionStoreError.unsupportedStoreFormat) {
            _ = try future.open(formatUpgrade: .version1To2)
        }
        #expect(try future.scalar("PRAGMA user_version") == 3)

        let older = try Fixture(createStore: false)
        defer { older.remove() }
        let olderRecord = try older.record()
        try older.createVersionOneStore(document: olderRecord.document, device: olderRecord.device, version: 0)
        #expect(throws: WorkspaceRevisionStoreError.unsupportedStoreFormat) {
            _ = try older.open(formatUpgrade: .version1To2)
        }
        #expect(try older.scalar("PRAGMA user_version") == 0)
    }

    private enum PrepareOutcome: Equatable { case prepared, conflict, unexpected }

    private func prepareOutcome(
        _ store: WorkspaceRevisionStore,
        _ record: WorkspaceMigrationRecord
    ) async -> PrepareOutcome {
        do {
            _ = try store.prepareMigration(record)
            return .prepared
        } catch WorkspaceMigrationError.preparationConflict {
            return .conflict
        } catch {
            Issue.record("Unexpected migration preparation error: \(error)")
            return .unexpected
        }
    }

    private struct Fixture {
        let root: URL
        let workspaceID: WorkspaceObjectID
        let deviceID: WorkspaceObjectID
        let writerID: WorkspaceObjectID
        let store: WorkspaceRevisionStore

        init(createStore: Bool = true) throws {
            root = FileManager.default.temporaryDirectory.appending(
                path: "migration-journal-\(UUID().uuidString)", directoryHint: .isDirectory)
            workspaceID = WorkspaceObjectID()
            deviceID = WorkspaceObjectID()
            writerID = WorkspaceObjectID()
            if createStore {
                store = try WorkspaceRevisionStore(
                    containerRoot: root, workspaceID: workspaceID, deviceID: deviceID)
            } else {
                // A placeholder instance is never used. Swift stored properties
                // still need initialization before the raw v1 fixture is created.
                let placeholder = root.appending(path: "placeholder", directoryHint: .isDirectory)
                store = try WorkspaceRevisionStore(
                    containerRoot: placeholder, workspaceID: workspaceID, deviceID: deviceID)
            }
        }

        func remove() { try? FileManager.default.removeItem(at: root) }

        func open(formatUpgrade: WorkspaceStoreFormatUpgrade = .none) throws -> WorkspaceRevisionStore {
            try WorkspaceRevisionStore(
                containerRoot: root,
                workspaceID: workspaceID,
                deviceID: deviceID,
                formatUpgrade: formatUpgrade)
        }

        func reopen() throws -> WorkspaceRevisionStore { try open() }

        func record(
            attemptID: WorkspaceObjectID = WorkspaceObjectID(),
            checkpointByte: Character = "a"
        ) throws -> WorkspaceMigrationRecord {
            let revision = WorkspaceRevision(
                id: WorkspaceObjectID(),
                writerID: writerID,
                createdAt: Date(timeIntervalSince1970: 1_700_000_000))
            let document = try WorkspaceDocumentCoding.seal(PortableWorkspaceDocument(
                workspaceID: workspaceID,
                revision: revision))
            let device = DeviceWorkspaceState(workspaceID: workspaceID, deviceID: deviceID)
            let documentBytes = try WorkspaceDocumentCoding.encode(document)
            let deviceBytes = try WorkspaceDocumentCoding.encodeDeviceState(device)
            let manifest = WorkspaceMigrationManifest(
                formatVersion: 1,
                attemptID: attemptID,
                workspaceID: workspaceID,
                deviceID: deviceID,
                initialRevisionID: document.revision.id,
                legacyDatabasePath: root.appending(path: "legacy.sqlite").path,
                checkpointSHA256: String(repeating: String(checkpointByte), count: 64),
                documentSHA256: WorkspaceMigrationRecord.hash(documentBytes),
                deviceSHA256: WorkspaceMigrationRecord.hash(deviceBytes),
                content: [],
                sourceCaptures: [],
                deploymentNames: [])
            let record = WorkspaceMigrationRecord(manifest: manifest, document: document, device: device)
            try record.validate()
            return record
        }

        func createVersionOneStore(
            document: PortableWorkspaceDocument,
            device: DeviceWorkspaceState,
            storedWorkspaceID: WorkspaceObjectID? = nil,
            version: Int32 = 1
        ) throws {
            let directory = root.appending(
                path: "workspaces-v1/\(workspaceID.rawValue.uuidString.lowercased())",
                directoryHint: .isDirectory)
            try FileManager.default.createDirectory(
                at: directory, withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700])
            let databaseURL = directory.appending(path: "revisions.sqlite")
            try withDatabase(at: databaseURL) { database in
                try execute("""
                    PRAGMA application_id = \(WorkspaceRevisionStore.databaseApplicationID);
                    PRAGMA user_version = \(version);
                    CREATE TABLE store_identity(id INTEGER PRIMARY KEY CHECK(id = 1), workspace_id TEXT NOT NULL, device_id TEXT NOT NULL);
                    CREATE TABLE revisions(id TEXT PRIMARY KEY NOT NULL, payload BLOB NOT NULL);
                    CREATE TABLE workspace_head(id INTEGER PRIMARY KEY CHECK(id = 1), revision_id TEXT NOT NULL REFERENCES revisions(id));
                    CREATE TABLE device_state(id INTEGER PRIMARY KEY CHECK(id = 1), payload BLOB NOT NULL);
                    CREATE TABLE command_receipts(idempotency_key TEXT PRIMARY KEY NOT NULL, revision_id TEXT NOT NULL REFERENCES revisions(id), payload BLOB NOT NULL);
                    CREATE TRIGGER revisions_immutable_update BEFORE UPDATE ON revisions BEGIN SELECT RAISE(ABORT, 'Revision history is immutable'); END;
                    CREATE TRIGGER revisions_immutable_delete BEFORE DELETE ON revisions BEGIN SELECT RAISE(ABORT, 'Revision history is immutable'); END;
                    """, database)
                try insert(
                    "INSERT INTO store_identity(id, workspace_id, device_id) VALUES(1, ?, ?)",
                    text: [storedWorkspaceID ?? workspaceID, deviceID].map { $0.rawValue.uuidString.lowercased() },
                    blobs: [], database: database)
                try insert(
                    "INSERT INTO revisions(id, payload) VALUES(?, ?)",
                    text: [document.revision.id.rawValue.uuidString.lowercased()],
                    blobs: [try WorkspaceDocumentCoding.encode(document)], database: database)
                try insert(
                    "INSERT INTO device_state(id, payload) VALUES(1, ?)",
                    text: [], blobs: [try WorkspaceDocumentCoding.encodeDeviceState(device)], database: database)
                try insert(
                    "INSERT INTO workspace_head(id, revision_id) VALUES(1, ?)",
                    text: [document.revision.id.rawValue.uuidString.lowercased()], blobs: [], database: database)
            }
        }

        func sql(_ command: String) throws {
            try withDatabase(at: store.databaseURL) { try execute(command, $0) }
        }

        func scalar(_ query: String) throws -> Int32 {
            let databaseURL = root.appending(
                path: "workspaces-v1/\(workspaceID.rawValue.uuidString.lowercased())/revisions.sqlite")
            return try withDatabase(at: databaseURL) { database in
                var statement: OpaquePointer?
                defer { sqlite3_finalize(statement) }
                guard sqlite3_prepare_v2(database, query, -1, &statement, nil) == SQLITE_OK,
                      sqlite3_step(statement) == SQLITE_ROW else {
                    throw WorkspaceRevisionStoreError.corruptState
                }
                return sqlite3_column_int(statement, 0)
            }
        }

        private func withDatabase<T>(at url: URL, _ body: (OpaquePointer) throws -> T) throws -> T {
            var database: OpaquePointer?
            guard sqlite3_open(url.path, &database) == SQLITE_OK, let database else {
                throw WorkspaceRevisionStoreError.databaseUnavailable
            }
            defer { sqlite3_close(database) }
            return try body(database)
        }

        private func execute(_ sql: String, _ database: OpaquePointer) throws {
            guard sqlite3_exec(database, sql, nil, nil, nil) == SQLITE_OK else {
                throw WorkspaceRevisionStoreError.corruptState
            }
        }

        private func insert(
            _ sql: String,
            text: [String],
            blobs: [Data],
            database: OpaquePointer
        ) throws {
            var statement: OpaquePointer?
            defer { sqlite3_finalize(statement) }
            guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else {
                throw WorkspaceRevisionStoreError.corruptState
            }
            var index: Int32 = 1
            for value in text {
                guard sqlite3_bind_text(statement, index, value, -1, journalSQLiteTransient) == SQLITE_OK else {
                    throw WorkspaceRevisionStoreError.corruptState
                }
                index += 1
            }
            for value in blobs {
                let status = value.withUnsafeBytes {
                    sqlite3_bind_blob(statement, index, $0.baseAddress, Int32(value.count), journalSQLiteTransient)
                }
                guard status == SQLITE_OK else { throw WorkspaceRevisionStoreError.corruptState }
                index += 1
            }
            guard sqlite3_step(statement) == SQLITE_DONE else {
                throw WorkspaceRevisionStoreError.corruptState
            }
        }
    }
}

private let journalSQLiteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
