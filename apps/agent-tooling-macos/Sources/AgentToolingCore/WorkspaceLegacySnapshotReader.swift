import Foundation
import SQLite3

/// Reads only the supplied checkpoint connection. Never initializes, upgrades,
/// normalizes, or consults the live WorkspaceStore or its compatibility cache.
enum WorkspaceLegacySnapshotReader {
    static func read(_ db: OpaquePointer) throws -> WorkspaceSnapshot? {
        let sql = LegacyCheckpointSQL(db)
        let versions = try sql.integers("SELECT version FROM schema_migrations ORDER BY version")
        guard let version = versions.last, (1...4).contains(version),
              versions == Array(1...version) else { throw WorkspaceLegacyCheckpointError.unsupportedSchema }
        if version == 4, let metadata: WorkspaceMetadata = try sql.one(
            "SELECT payload FROM workspace_metadata WHERE id = 1", as: WorkspaceMetadata.self) {
            let packages = try sql.entities(.packages, as: StoredWorkspacePackage.self, identity: { $0.stableID })
            let bindings = try sql.entities(.targetBindings, as: StoredTargetBinding.self, identity: { $0.stableID })
            let snapshot = WorkspaceSnapshot(
                skills: packages.compactMap(\.skill),
                mcpServers: packages.compactMap(\.mcpServer),
                plugins: packages.compactMap(\.plugin),
                profiles: try sql.entities(.profiles, as: ToolingProfile.self, identity: { $0.id }),
                activities: metadata.activities,
                operationReceipts: try sql.entities(.receipts, as: OperationReceipt.self,
                                                   identity: { $0.id.uuidString.lowercased() }),
                targetObservations: try sql.entities(.observedStates, as: TargetObservation.self, identity: { $0.id }),
                sources: try sql.entities(.sources, as: ToolingSource.self, identity: { $0.id.uuidString.lowercased() }),
                marketplacePackages: packages.compactMap(\.marketplace),
                accountSurfaces: bindings.compactMap(\.account),
                connectors: bindings.compactMap(\.connector),
                activeProfileID: metadata.activeProfileID,
                importedRepositoryPath: metadata.importedRepositoryPath,
                backupConfiguration: metadata.backupConfiguration,
                encryptedSyncConfiguration: metadata.encryptedSyncConfiguration,
                preferences: metadata.preferences,
                managedPolicies: metadata.managedPolicies,
                collections: metadata.collections,
                tagAssignments: metadata.tagAssignments)
            try WorkspaceSnapshotValidator.validate(snapshot, mode: .localState)
            return snapshot
        }
        // Absence of normalized metadata is the only admitted compatibility fallback.
        // A malformed normalized record never falls through to the old shadow blob.
        let snapshot: WorkspaceSnapshot? = try sql.one(
            "SELECT payload FROM state_records WHERE key = 'workspace.snapshot'", as: WorkspaceSnapshot.self)
        if let snapshot { try WorkspaceSnapshotValidator.validate(snapshot, mode: .localState) }
        return snapshot
    }
}

struct LegacyCheckpointSQL {
    let db: OpaquePointer
    init(_ db: OpaquePointer) { self.db = db }

    func execute(_ query: String) throws {
        guard sqlite3_exec(db, query, nil, nil, nil) == SQLITE_OK else { throw failure() }
    }

    func statement(_ query: String) throws -> OpaquePointer {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, query, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw failure()
        }
        guard sqlite3_stmt_readonly(statement) != 0 else {
            sqlite3_finalize(statement)
            throw WorkspaceLegacyCheckpointError.invalidDatabase
        }
        return statement
    }

    func next(_ statement: OpaquePointer) throws -> Bool {
        try Task.checkCancellation()
        switch sqlite3_step(statement) {
        case SQLITE_ROW: return true
        case SQLITE_DONE: return false
        default: throw failure()
        }
    }

    func integers(_ query: String) throws -> [Int] {
        let statement = try statement(query)
        defer { sqlite3_finalize(statement) }
        var result: [Int] = []
        while try next(statement) {
            guard result.count < 100_000, sqlite3_column_type(statement, 0) == SQLITE_INTEGER else {
                throw WorkspaceLegacyCheckpointError.invalidDatabase
            }
            result.append(Int(sqlite3_column_int64(statement, 0)))
        }
        return result
    }

    func one<Value: Decodable>(_ query: String, as: Value.Type) throws -> Value? {
        let statement = try statement(query)
        defer { sqlite3_finalize(statement) }
        guard try next(statement) else { return nil }
        let value = try decode(statement, column: 0, as: Value.self)
        guard try !next(statement) else { throw WorkspaceLegacyCheckpointError.invalidDatabase }
        return value
    }

    func entities<Value: Decodable>(
        _ domain: WorkspaceEntityDomain, as: Value.Type, identity: (Value) -> String
    ) throws -> [Value] {
        let statement = try statement("SELECT id, payload FROM \(domain.tableName) ORDER BY id")
        defer { sqlite3_finalize(statement) }
        var result: [Value] = []
        while try next(statement) {
            guard result.count < 100_000, let id = sqlite3_column_text(statement, 0),
                  sqlite3_column_type(statement, 0) == SQLITE_TEXT else {
                throw WorkspaceLegacyCheckpointError.invalidDatabase
            }
            let value = try decode(statement, column: 1, as: Value.self)
            let idBytes = Data(bytes: id, count: Int(sqlite3_column_bytes(statement, 0)))
            guard idBytes == Data(identity(value).utf8) else { throw WorkspaceLegacyCheckpointError.invalidDatabase }
            result.append(value)
        }
        return result
    }

    private func decode<Value: Decodable>(_ statement: OpaquePointer, column: Int32, as: Value.Type) throws -> Value {
        let count = Int(sqlite3_column_bytes(statement, column))
        guard count > 0, count <= WorkspaceLegacyCheckpoint.maximumDatabaseBytes,
              sqlite3_column_type(statement, column) == SQLITE_BLOB,
              let bytes = sqlite3_column_blob(statement, column) else {
            throw WorkspaceLegacyCheckpointError.invalidDatabase
        }
        do { return try JSONDecoder.agentTooling().decode(Value.self, from: Data(bytes: bytes, count: count)) }
        catch { throw WorkspaceLegacyCheckpointError.invalidSnapshot }
    }

    private func failure() -> WorkspaceLegacyCheckpointError {
        switch sqlite3_errcode(db) {
        case SQLITE_BUSY, SQLITE_LOCKED: .busy
        case SQLITE_INTERRUPT: .interrupted
        default: .invalidDatabase
        }
    }
}
