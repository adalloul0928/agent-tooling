import Foundation
import SQLite3
import Testing

@testable import AgentToolingCore

struct WorkspaceLegacyCheckpointTests {
    @Test func capturesNormalizedStateInsteadOfItsStaleCompatibilityShadow() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let expected = fixture.snapshot(named: "normalized")
        try fixture.store.saveWorkspaceSnapshot(expected)
        try fixture.store.save(WorkspaceSnapshot(), for: "workspace.snapshot")
        let wal = URL(fileURLWithPath: fixture.store.databaseURL.path + "-wal")
        #expect((try FileManager.default.attributesOfItem(atPath: wal.path)[.size] as? NSNumber)?.intValue ?? 0 > 32)

        let checkpoint = try await WorkspaceLegacyCheckpoint.capture(databaseURL: fixture.store.databaseURL)

        #expect(try checkpoint.workspaceSnapshot()?.profiles.map(\.id) == ["normalized"])
        #expect(try WorkspaceLegacyCheckpoint.reopen(
            bytes: checkpoint.databaseBytes, expectedSHA256: checkpoint.sha256
        ).workspaceSnapshot()?.sources.map(\.name) == ["Source normalized"])
    }

    @Test func pinsTheRawDatabaseBeforeAConcurrentWriterCommits() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let before = fixture.snapshot(named: "before")
        let after = fixture.snapshot(named: "after")
        try fixture.store.saveWorkspaceSnapshot(before)

        let checkpoint = try await WorkspaceLegacyCheckpoint.capture(
            databaseURL: fixture.store.databaseURL,
            afterSnapshotPinned: {
                let other = try WorkspaceStore(rootURL: fixture.root)
                try other.saveWorkspaceSnapshot(after)
            }
        )

        #expect(try checkpoint.workspaceSnapshot()?.profiles.map(\.id) == ["before"])
        #expect(try fixture.store.loadWorkspaceSnapshot()?.profiles.map(\.id) == ["after"])
    }

    @Test func preservesBlobOnlyBytesAndUnknownStateWithoutNormalizingCapture() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let snapshot = fixture.snapshot(named: "blob")
        try fixture.store.save(snapshot, for: "workspace.snapshot")
        let original = try fixture.payload(key: "workspace.snapshot")
        let altered = try fixture.addUnknownJSONField(to: original)
        try fixture.replacePayload(key: "workspace.snapshot", with: altered)
        try fixture.sql("CREATE TABLE opaque_records (id TEXT PRIMARY KEY, payload BLOB NOT NULL)")
        try fixture.insertOpaque(id: "opaque", payload: Data([0, 1, 2, 3]))

        let checkpoint = try await WorkspaceLegacyCheckpoint.capture(databaseURL: fixture.store.databaseURL)

        #expect(try checkpoint.workspaceSnapshot()?.profiles.map(\.id) == ["blob"])
        #expect(try fixture.payload(key: "workspace.snapshot") == altered)
        #expect(try fixture.store.loadEntity("blob", domain: .profiles, as: ToolingProfile.self) == nil)
        try fixture.withCapturedDatabase(checkpoint.databaseBytes) { (db: OpaquePointer) throws -> Void in
            #expect(try fixture.payload(key: "workspace.snapshot", database: db) == altered)
            #expect(try fixture.opaquePayload(id: "opaque", database: db) == Data([0, 1, 2, 3]))
            #expect(try fixture.scalar("SELECT COUNT(*) FROM workspace_metadata", database: db) == 0)
        }
    }

    @Test func retainsFutureSchemaBytesButRefusesTypedInterpretation() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.sql("INSERT INTO schema_migrations(version, applied_at) VALUES(5, 0)")

        let checkpoint = try await WorkspaceLegacyCheckpoint.capture(databaseURL: fixture.store.databaseURL)

        do {
            _ = try checkpoint.workspaceSnapshot()
            Issue.record("A future schema must remain raw-only.")
        } catch let error as WorkspaceLegacyCheckpointError {
            #expect(error == .unsupportedSchema)
        } catch {
            Issue.record("Unexpected future-schema error: \(error)")
        }
        try fixture.withCapturedDatabase(checkpoint.databaseBytes) { (db: OpaquePointer) throws -> Void in
            #expect(try fixture.scalar("SELECT MAX(version) FROM schema_migrations", database: db) == 5)
        }
    }

    @Test func malformedNormalizedMetadataNeverFallsBackToTheValidShadow() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.store.saveWorkspaceSnapshot(fixture.snapshot(named: "normalized"))
        try fixture.sql("UPDATE workspace_metadata SET payload = X'7B' WHERE id = 1")

        let checkpoint = try await WorkspaceLegacyCheckpoint.capture(databaseURL: fixture.store.databaseURL)

        do {
            _ = try checkpoint.workspaceSnapshot()
            Issue.record("Malformed normalized metadata must not use workspace.snapshot as a fallback.")
        } catch let error as WorkspaceLegacyCheckpointError {
            #expect(error == .invalidSnapshot)
        } catch {
            Issue.record("Unexpected malformed-metadata error: \(error)")
        }
    }

    @Test func reopenChecksTheDigestBeforeAnyTypedRead() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.store.save(fixture.snapshot(named: "blob"), for: "workspace.snapshot")
        let checkpoint = try await WorkspaceLegacyCheckpoint.capture(databaseURL: fixture.store.databaseURL)
        var tampered = checkpoint.databaseBytes
        tampered[tampered.startIndex] ^= 0x01

        do {
            _ = try WorkspaceLegacyCheckpoint.reopen(bytes: tampered, expectedSHA256: checkpoint.sha256)
            Issue.record("A modified checkpoint must not reopen.")
        } catch let error as WorkspaceLegacyCheckpointError {
            #expect(error == .digestMismatch)
        } catch {
            Issue.record("Unexpected digest error: \(error)")
        }
    }

    @Test func rejectsUnsafeSourcesAndAnInterruptedPin() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let target = fixture.root.appending(path: "target.sqlite")
        try Data().write(to: target)
        let link = fixture.root.appending(path: "source.sqlite")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)

        do {
            _ = try await WorkspaceLegacyCheckpoint.capture(databaseURL: link)
            Issue.record("A symlinked source database must be rejected.")
        } catch let error as WorkspaceLegacyCheckpointError {
            #expect(error == .unsafePath)
        } catch {
            Issue.record("Unexpected unsafe-source error: \(error)")
        }
        do {
            _ = try await WorkspaceLegacyCheckpoint.capture(databaseURL: fixture.root)
            Issue.record("A directory cannot be captured as a database.")
        } catch let error as WorkspaceLegacyCheckpointError {
            #expect(error == .unsafePath)
        } catch {
            Issue.record("Unexpected directory-source error: \(error)")
        }
        do {
            _ = try await WorkspaceLegacyCheckpoint.capture(
                databaseURL: fixture.store.databaseURL,
                afterSnapshotPinned: { throw CancellationError() }
            )
            Issue.record("Cancellation at the pin seam must abort capture.")
        } catch is CancellationError {
            // Cancellation remains cancellation, including the detached capture worker.
        } catch {
            Issue.record("Unexpected pin-cancellation error: \(error)")
        }
    }

    @Test func absentNormalizedAndBlobSnapshotRemainsAbsent() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let checkpoint = try await WorkspaceLegacyCheckpoint.capture(databaseURL: fixture.store.databaseURL)
        #expect(try checkpoint.workspaceSnapshot() == nil)
    }

    @Test func candidateIsBoundToCapturedDataEvenAfterLiveChanges() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.store.saveWorkspaceSnapshot(fixture.snapshot(named: "reviewed"))
        let checkpoint = try await WorkspaceLegacyCheckpoint.capture(databaseURL: fixture.store.databaseURL)
        try fixture.store.saveWorkspaceSnapshot(fixture.snapshot(named: "later"))
        let context = WorkspaceMigrationContext(workspaceID: .init(), deviceID: .init(),
            revision: .init(id: .init(), writerID: .init(), createdAt: Date(timeIntervalSince1970: 1_700_000_000)))
        let preview = try checkpoint.preview(context: context, decisions: .init())
        let candidate = try #require(preview.assembly.candidate)
        #expect(preview.checkpointSHA256 == checkpoint.sha256)
        #expect(candidate.legacySnapshot.profiles.map(\.id) == ["reviewed"])
        #expect(candidate.document.configurationState?.configurations.map(\.name) == ["reviewed"])
    }

    @Test func brokenNormalizedTablesAndRowIdentitiesDoNotUseTheShadow() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.store.saveWorkspaceSnapshot(fixture.snapshot(named: "normalized"))
        try fixture.sql("UPDATE profiles SET id = 'wrong-key'")
        let badKey = try await WorkspaceLegacyCheckpoint.capture(databaseURL: fixture.store.databaseURL)
        #expect(throws: WorkspaceLegacyCheckpointError.invalidDatabase) { try badKey.workspaceSnapshot() }
        try fixture.sql("DROP TABLE profiles")
        let missingTable = try await WorkspaceLegacyCheckpoint.capture(databaseURL: fixture.store.databaseURL)
        #expect(throws: WorkspaceLegacyCheckpointError.invalidDatabase) { try missingTable.workspaceSnapshot() }
    }

    @Test func sourceReplacementAfterPinCannotProduceAReadyCapture() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.store.saveWorkspaceSnapshot(fixture.snapshot(named: "before"))
        let path = fixture.store.databaseURL
        let moved = fixture.root.appending(path: "moved.sqlite")
        await #expect(throws: WorkspaceLegacyCheckpointError.changedSource) {
            try await WorkspaceLegacyCheckpoint.capture(databaseURL: path, afterSnapshotPinned: {
                try FileManager.default.moveItem(at: path, to: moved)
                try Data().write(to: path)
            })
        }
    }

    @Test func readsTheOldSchemaWithoutAddingMigrationVersions() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.store.save(fixture.snapshot(named: "old"), for: "workspace.snapshot")
        try fixture.sql("DELETE FROM schema_migrations WHERE version > 1")
        let checkpoint = try await WorkspaceLegacyCheckpoint.capture(databaseURL: fixture.store.databaseURL)
        #expect(try checkpoint.workspaceSnapshot()?.activeProfileID == "old")
        try fixture.withCapturedDatabase(checkpoint.databaseBytes) { (db: OpaquePointer) throws -> Void in
            #expect(try fixture.scalar("SELECT MAX(version) FROM schema_migrations", database: db) == 1)
        }
    }

    private struct Fixture: Sendable {
        let root: URL
        let store: WorkspaceStore

        init() throws {
            root = FileManager.default.temporaryDirectory.appending(
                path: "legacy-checkpoint-\(UUID().uuidString)", directoryHint: .isDirectory
            )
            store = try WorkspaceStore(rootURL: root)
        }

        func remove() { try? FileManager.default.removeItem(at: root) }

        func snapshot(named id: String) -> WorkspaceSnapshot {
            WorkspaceSnapshot(
                profiles: [.init(id: id, name: id, summary: "Fixture", checks: [], enabledPlugins: [], requiredMCPs: [])],
                sources: [.init(name: "Source \(id)", kind: .localFolder, location: "/tmp/\(id)")],
                activeProfileID: id
            )
        }

        func sql(_ query: String) throws {
            try withDatabase(at: store.databaseURL) { db in
                guard sqlite3_exec(db, query, nil, nil, nil) == SQLITE_OK else {
                    throw WorkspaceLegacyCheckpointError.invalidDatabase
                }
            }
        }

        func payload(key: String, database: OpaquePointer? = nil) throws -> Data {
            if let database { return try payload(key: key, database: database) }
            return try withDatabase(at: store.databaseURL) { try payload(key: key, database: $0) }
        }

        func payload(key: String, database: OpaquePointer) throws -> Data {
            var statement: OpaquePointer?
            defer { sqlite3_finalize(statement) }
            guard sqlite3_prepare_v2(database, "SELECT payload FROM state_records WHERE key = ?", -1, &statement, nil) == SQLITE_OK,
                  sqlite3_bind_text(statement, 1, key, -1, sqliteTransient) == SQLITE_OK,
                  sqlite3_step(statement) == SQLITE_ROW,
                  let bytes = sqlite3_column_blob(statement, 0) else {
                throw WorkspaceLegacyCheckpointError.invalidDatabase
            }
            return Data(bytes: bytes, count: Int(sqlite3_column_bytes(statement, 0)))
        }

        func replacePayload(key: String, with data: Data) throws {
            try withDatabase(at: store.databaseURL) { db in
                var statement: OpaquePointer?
                defer { sqlite3_finalize(statement) }
                guard sqlite3_prepare_v2(db, "UPDATE state_records SET payload = ? WHERE key = ?", -1, &statement, nil) == SQLITE_OK,
                      data.withUnsafeBytes({ sqlite3_bind_blob(statement, 1, $0.baseAddress, Int32(data.count), sqliteTransient) }) == SQLITE_OK,
                      sqlite3_bind_text(statement, 2, key, -1, sqliteTransient) == SQLITE_OK,
                      sqlite3_step(statement) == SQLITE_DONE else {
                    throw WorkspaceLegacyCheckpointError.invalidDatabase
                }
            }
        }

        func insertOpaque(id: String, payload: Data) throws {
            try withDatabase(at: store.databaseURL) { db in
                var statement: OpaquePointer?
                defer { sqlite3_finalize(statement) }
                guard sqlite3_prepare_v2(db, "INSERT INTO opaque_records(id, payload) VALUES(?, ?)", -1, &statement, nil) == SQLITE_OK,
                      sqlite3_bind_text(statement, 1, id, -1, sqliteTransient) == SQLITE_OK,
                      payload.withUnsafeBytes({ sqlite3_bind_blob(statement, 2, $0.baseAddress, Int32(payload.count), sqliteTransient) }) == SQLITE_OK,
                      sqlite3_step(statement) == SQLITE_DONE else {
                    throw WorkspaceLegacyCheckpointError.invalidDatabase
                }
            }
        }

        func opaquePayload(id: String, database: OpaquePointer) throws -> Data {
            var statement: OpaquePointer?
            defer { sqlite3_finalize(statement) }
            guard sqlite3_prepare_v2(database, "SELECT payload FROM opaque_records WHERE id = ?", -1, &statement, nil) == SQLITE_OK,
                  sqlite3_bind_text(statement, 1, id, -1, sqliteTransient) == SQLITE_OK,
                  sqlite3_step(statement) == SQLITE_ROW,
                  let bytes = sqlite3_column_blob(statement, 0) else {
                throw WorkspaceLegacyCheckpointError.invalidDatabase
            }
            return Data(bytes: bytes, count: Int(sqlite3_column_bytes(statement, 0)))
        }

        func scalar(_ query: String, database: OpaquePointer) throws -> Int32 {
            var statement: OpaquePointer?
            defer { sqlite3_finalize(statement) }
            guard sqlite3_prepare_v2(database, query, -1, &statement, nil) == SQLITE_OK,
                  sqlite3_step(statement) == SQLITE_ROW else { throw WorkspaceLegacyCheckpointError.invalidDatabase }
            return sqlite3_column_int(statement, 0)
        }

        func addUnknownJSONField(to data: Data) throws -> Data {
            var object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
            object["unknownCheckpointField"] = ["retained", 7] as [Any]
            return try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        }

        func withCapturedDatabase(_ bytes: Data, _ body: (OpaquePointer) throws -> Void) throws {
            let url = root.appending(path: "captured-\(UUID().uuidString).sqlite")
            defer { try? FileManager.default.removeItem(at: url) }
            try bytes.write(to: url, options: .atomic)
            try withDatabase(at: url, body)
        }

        private func withDatabase<T>(at url: URL, _ body: (OpaquePointer) throws -> T) throws -> T {
            var database: OpaquePointer?
            guard sqlite3_open_v2(url.path(percentEncoded: false), &database, SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK,
                  let database else { throw WorkspaceLegacyCheckpointError.invalidDatabase }
            defer { sqlite3_close(database) }
            return try body(database)
        }
    }
}

private let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
