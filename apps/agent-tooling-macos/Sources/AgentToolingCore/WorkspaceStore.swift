import Foundation
import SQLite3

private let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

/// The local source of truth for Agent Tooling. This intentionally does not
/// depend on a Git checkout, a GitHub account, or any client cache.
public final class WorkspaceStore: @unchecked Sendable {
    public static let applicationFolderName = "Agent Tooling"
    private static let maximumRecordBytes = 128 * 1_024 * 1_024
    private static let maximumKeyCharacters = 256

    public let rootURL: URL
    public let libraryURL: URL
    public let profilesURL: URL
    public let sourcesURL: URL
    public let receiptsURL: URL
    public let cacheURL: URL
    public let databaseURL: URL

    private var database: OpaquePointer?
    private let queue = DispatchQueue(label: "com.agenttooling.workspace-store")

    public init(rootURL: URL? = nil, fileManager: FileManager = .default) throws {
        let requestedBase =
            (rootURL
            ?? fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appending(path: Self.applicationFolderName, directoryHint: .isDirectory)).standardizedFileURL
        guard requestedBase.isFileURL,
            requestedBase.path(percentEncoded: false).hasPrefix("/"),
            !Self.isProtectedRoot(requestedBase, fileManager: fileManager)
        else {
            throw WorkspaceStoreError.unsafePath(requestedBase.absoluteString)
        }
        try Self.refuseSymbolicLink(at: requestedBase, fileManager: fileManager)
        try fileManager.createDirectory(at: requestedBase, withIntermediateDirectories: true)
        let base = requestedBase.resolvingSymlinksInPath().standardizedFileURL
        self.rootURL = base
        self.libraryURL = base.appending(path: "library", directoryHint: .isDirectory)
        self.profilesURL = base.appending(path: "profiles", directoryHint: .isDirectory)
        self.sourcesURL = base.appending(path: "sources", directoryHint: .isDirectory)
        self.receiptsURL = base.appending(path: "receipts", directoryHint: .isDirectory)
        self.cacheURL = base.appending(path: "cache", directoryHint: .isDirectory)
        self.databaseURL = base.appending(path: "agent-tooling.sqlite", directoryHint: .notDirectory)

        for url in [base, libraryURL, profilesURL, sourcesURL, receiptsURL, cacheURL] {
            try Self.refuseSymbolicLink(at: url, fileManager: fileManager)
            try fileManager.createDirectory(at: url, withIntermediateDirectories: true)
            let resolved = url.resolvingSymlinksInPath().standardizedFileURL
            guard Self.contains(resolved, within: base),
                (try resolved.resourceValues(forKeys: [.isDirectoryKey])).isDirectory == true
            else {
                throw WorkspaceStoreError.unsafePath(url.path(percentEncoded: false))
            }
            try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: resolved.path(percentEncoded: false))
        }

        try Self.refuseSymbolicLink(at: databaseURL, fileManager: fileManager)

        var handle: OpaquePointer?
        let result = sqlite3_open_v2(
            databaseURL.path(percentEncoded: false),
            &handle,
            SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX,
            nil
        )
        guard result == SQLITE_OK, let handle else {
            defer { if handle != nil { sqlite3_close(handle) } }
            throw WorkspaceStoreError.openDatabase(databaseURL.path(percentEncoded: false))
        }
        do {
            database = handle
            guard sqlite3_busy_timeout(handle, 5_000) == SQLITE_OK else {
                throw WorkspaceStoreError.query(message(handle))
            }
            try migrate(fileManager: fileManager)
            for url in [
                databaseURL,
                URL(fileURLWithPath: databaseURL.path(percentEncoded: false) + "-wal"),
                URL(fileURLWithPath: databaseURL.path(percentEncoded: false) + "-shm"),
            ] where fileManager.fileExists(atPath: url.path(percentEncoded: false)) {
                try Self.refuseSymbolicLink(at: url, fileManager: fileManager)
                try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path(percentEncoded: false))
            }
        } catch {
            database = nil
            sqlite3_close(handle)
            throw error
        }
    }

    deinit {
        if let database { sqlite3_close(database) }
    }

    public func load<Value: Decodable>(_ key: String, as type: Value.Type) throws -> Value? {
        try Self.validateKey(key)
        return try queue.sync {
            guard let database else { throw WorkspaceStoreError.closed }
            var statement: OpaquePointer?
            defer { sqlite3_finalize(statement) }
            try prepare("SELECT payload FROM state_records WHERE key = ? LIMIT 1", database: database, statement: &statement)
            try bindText(key, at: 1, to: statement, database: database)
            let result = sqlite3_step(statement)
            if result == SQLITE_DONE { return nil }
            guard result == SQLITE_ROW, let bytes = sqlite3_column_blob(statement, 0) else {
                throw WorkspaceStoreError.query(message(database))
            }
            let count = Int(sqlite3_column_bytes(statement, 0))
            guard count >= 0, count <= Self.maximumRecordBytes else {
                throw WorkspaceStoreError.recordTooLarge(key)
            }
            let data = Data(bytes: bytes, count: count)
            return try JSONDecoder.agentTooling().decode(Value.self, from: data)
        }
    }

    public func save<Value: Encodable>(_ value: Value, for key: String) throws {
        try Self.validateKey(key)
        let data = try JSONEncoder.agentTooling().encode(value)
        guard data.count <= Self.maximumRecordBytes else { throw WorkspaceStoreError.recordTooLarge(key) }
        try queue.sync {
            guard let database else { throw WorkspaceStoreError.closed }
            var statement: OpaquePointer?
            defer { sqlite3_finalize(statement) }
            try prepare(
                "INSERT INTO state_records(key, payload, updated_at) VALUES(?, ?, ?) "
                    + "ON CONFLICT(key) DO UPDATE SET payload = excluded.payload, updated_at = excluded.updated_at",
                database: database,
                statement: &statement
            )
            try bindText(key, at: 1, to: statement, database: database)
            let blobResult = data.withUnsafeBytes { raw in
                sqlite3_bind_blob(statement, 2, raw.baseAddress, Int32(data.count), sqliteTransient)
            }
            guard blobResult == SQLITE_OK,
                sqlite3_bind_double(statement, 3, Date.now.timeIntervalSince1970) == SQLITE_OK
            else {
                throw WorkspaceStoreError.query(message(database))
            }
            guard sqlite3_step(statement) == SQLITE_DONE else {
                throw WorkspaceStoreError.query(message(database))
            }
        }
    }

    public func remove(_ key: String) throws {
        try Self.validateKey(key)
        try queue.sync {
            guard let database else { throw WorkspaceStoreError.closed }
            var statement: OpaquePointer?
            defer { sqlite3_finalize(statement) }
            try prepare("DELETE FROM state_records WHERE key = ?", database: database, statement: &statement)
            try bindText(key, at: 1, to: statement, database: database)
            guard sqlite3_step(statement) == SQLITE_DONE else {
                throw WorkspaceStoreError.query(message(database))
            }
        }
    }

    public func loadEntity<Value: Decodable>(
        _ id: String,
        domain: WorkspaceEntityDomain,
        as type: Value.Type
    ) throws -> Value? {
        try Self.validateKey(id)
        return try queue.sync {
            guard let database else { throw WorkspaceStoreError.closed }
            var statement: OpaquePointer?
            defer { sqlite3_finalize(statement) }
            try prepare(
                "SELECT payload FROM \(domain.tableName) WHERE id = ? LIMIT 1",
                database: database,
                statement: &statement
            )
            try bindText(id, at: 1, to: statement, database: database)
            let result = sqlite3_step(statement)
            if result == SQLITE_DONE { return nil }
            guard result == SQLITE_ROW else { throw WorkspaceStoreError.query(message(database)) }
            return try decodeColumn(statement: statement, key: "\(domain.rawValue).\(id)", as: type)
        }
    }

    public func listEntities<Value: Decodable>(
        domain: WorkspaceEntityDomain,
        as type: Value.Type
    ) throws -> [Value] {
        try queue.sync {
            guard let database else { throw WorkspaceStoreError.closed }
            var statement: OpaquePointer?
            defer { sqlite3_finalize(statement) }
            try prepare(
                "SELECT id, payload FROM \(domain.tableName) ORDER BY id",
                database: database,
                statement: &statement
            )
            var values: [Value] = []
            while sqlite3_step(statement) == SQLITE_ROW {
                let id = sqlite3_column_text(statement, 0).map { String(cString: $0) } ?? "unknown"
                values.append(try decodeColumn(statement: statement, column: 1, key: "\(domain.rawValue).\(id)", as: type))
            }
            guard sqlite3_errcode(database) == SQLITE_OK || sqlite3_errcode(database) == SQLITE_DONE else {
                throw WorkspaceStoreError.query(message(database))
            }
            return values
        }
    }

    public func saveEntity<Value: Encodable>(
        _ value: Value,
        id: String,
        domain: WorkspaceEntityDomain
    ) throws {
        try Self.validateKey(id)
        let data = try JSONEncoder.agentTooling().encode(value)
        guard data.count <= Self.maximumRecordBytes else {
            throw WorkspaceStoreError.recordTooLarge("\(domain.rawValue).\(id)")
        }
        try queue.sync {
            guard let database else { throw WorkspaceStoreError.closed }
            var statement: OpaquePointer?
            defer { sqlite3_finalize(statement) }
            try prepare(
                "INSERT INTO \(domain.tableName)(id, payload, updated_at) VALUES(?, ?, ?) "
                    + "ON CONFLICT(id) DO UPDATE SET payload = excluded.payload, updated_at = excluded.updated_at",
                database: database,
                statement: &statement
            )
            try bindText(id, at: 1, to: statement, database: database)
            try bindData(data, at: 2, to: statement, database: database)
            guard sqlite3_bind_double(statement, 3, Date.now.timeIntervalSince1970) == SQLITE_OK,
                sqlite3_step(statement) == SQLITE_DONE
            else {
                throw WorkspaceStoreError.query(message(database))
            }
        }
    }

    public func removeEntity(_ id: String, domain: WorkspaceEntityDomain) throws {
        try Self.validateKey(id)
        try queue.sync {
            guard let database else { throw WorkspaceStoreError.closed }
            var statement: OpaquePointer?
            defer { sqlite3_finalize(statement) }
            try prepare("DELETE FROM \(domain.tableName) WHERE id = ?", database: database, statement: &statement)
            try bindText(id, at: 1, to: statement, database: database)
            guard sqlite3_step(statement) == SQLITE_DONE else {
                throw WorkspaceStoreError.query(message(database))
            }
        }
    }

    /// Persists the workspace as normalized entity rows in one transaction.
    /// A legacy snapshot shadow is retained for one compatibility cycle so an
    /// older app can still open the workspace during the migration canary.
    public func saveWorkspaceSnapshot(_ snapshot: WorkspaceSnapshot) throws {
        let metadata = WorkspaceMetadata(snapshot: snapshot)
        let packageRecords: [StoredWorkspacePackage] =
            snapshot.skills.map(StoredWorkspacePackage.skill)
            + snapshot.mcpServers.map(StoredWorkspacePackage.mcpServer)
            + snapshot.plugins.map(StoredWorkspacePackage.plugin)
            + snapshot.marketplacePackages.map(StoredWorkspacePackage.marketplace)
        let bindingRecords: [StoredTargetBinding] =
            snapshot.accountSurfaces.map(StoredTargetBinding.account)
            + snapshot.connectors.map(StoredTargetBinding.connector)
        let locks = snapshot.marketplacePackages.compactMap { package -> StoredEntityValue<SourceLock>? in
            guard let lock = package.provenance?.lock else { return nil }
            return StoredEntityValue(id: "marketplace:\(package.id)", value: lock)
        }
        let entityRecords: [WorkspaceEntityDomain: [StoredEntityPayload]] = [
            .packages: try packageRecords.map { try entityPayload($0, id: $0.stableID) },
            .sources: try snapshot.sources.map {
                try entityPayload($0, id: $0.id.uuidString.lowercased())
            },
            .sourceLocks: try locks.map { try entityPayload($0.value, id: $0.id) },
            .profiles: try snapshot.profiles.map { try entityPayload($0, id: $0.id) },
            .targetBindings: try bindingRecords.map { try entityPayload($0, id: $0.stableID) },
            .observedStates: try snapshot.targetObservations.map { try entityPayload($0, id: $0.id) },
            .receipts: try snapshot.operationReceipts.map {
                try entityPayload($0, id: $0.id.uuidString.lowercased())
            },
        ]
        let metadataData = try encodeRecord(metadata)
        let compatibilityData = try encodeRecord(snapshot)

        try queue.sync {
            guard let database else { throw WorkspaceStoreError.closed }
            try execute("BEGIN IMMEDIATE", database: database)
            do {
                for domain in WorkspaceEntityDomain.allCases where domain != .plans {
                    try replaceEntities(entityRecords[domain] ?? [], domain: domain, database: database)
                }
                try upsertWorkspaceMetadata(metadataData, database: database)
                try upsertStateRecord(key: "workspace.snapshot", data: compatibilityData, database: database)
                try execute("COMMIT", database: database)
            } catch {
                try? execute("ROLLBACK", database: database)
                throw error
            }
        }
    }

    /// Loads normalized state first. Existing blob-only workspaces are
    /// migrated transactionally on first open and remain import-compatible.
    public func loadWorkspaceSnapshot() throws -> WorkspaceSnapshot? {
        guard let metadata: WorkspaceMetadata = try loadWorkspaceMetadata() else {
            guard let legacy = try load("workspace.snapshot", as: WorkspaceSnapshot.self) else { return nil }
            try WorkspaceSnapshotValidator.validate(legacy, mode: .localState)
            try saveWorkspaceSnapshot(legacy)
            return legacy
        }
        let packageRecords = try listEntities(domain: .packages, as: StoredWorkspacePackage.self)
        let bindings = try listEntities(domain: .targetBindings, as: StoredTargetBinding.self)
        return WorkspaceSnapshot(
            skills: packageRecords.compactMap(\.skill),
            mcpServers: packageRecords.compactMap(\.mcpServer),
            plugins: packageRecords.compactMap(\.plugin),
            profiles: try listEntities(domain: .profiles, as: ToolingProfile.self),
            activities: metadata.activities,
            operationReceipts: try listEntities(domain: .receipts, as: OperationReceipt.self),
            targetObservations: try listEntities(domain: .observedStates, as: TargetObservation.self),
            sources: try listEntities(domain: .sources, as: ToolingSource.self),
            marketplacePackages: packageRecords.compactMap(\.marketplace),
            accountSurfaces: bindings.compactMap(\.account),
            connectors: bindings.compactMap(\.connector),
            activeProfileID: metadata.activeProfileID,
            importedRepositoryPath: metadata.importedRepositoryPath,
            backupConfiguration: metadata.backupConfiguration,
            encryptedSyncConfiguration: metadata.encryptedSyncConfiguration,
            preferences: metadata.preferences,
            managedPolicies: metadata.managedPolicies,
            collections: metadata.collections,
            tagAssignments: metadata.tagAssignments
        )
    }

    private func migrate(fileManager: FileManager) throws {
        try queue.sync {
            guard let database else { throw WorkspaceStoreError.closed }
            try execute("PRAGMA journal_mode = WAL", database: database)
            try execute("PRAGMA synchronous = FULL", database: database)
            try execute("PRAGMA foreign_keys = ON", database: database)
            try execute("PRAGMA trusted_schema = OFF", database: database)
            try execute(
                "CREATE TABLE IF NOT EXISTS schema_migrations (version INTEGER PRIMARY KEY, applied_at REAL NOT NULL)", database: database)
            let migrations = [
                (
                    1,
                    "CREATE TABLE IF NOT EXISTS state_records (key TEXT PRIMARY KEY NOT NULL, payload BLOB NOT NULL, updated_at REAL NOT NULL)"
                ),
                (2, "CREATE INDEX IF NOT EXISTS state_records_updated_at ON state_records(updated_at DESC)"),
                (
                    3,
                    WorkspaceEntityDomain.allCases.map { domain in
                        "CREATE TABLE IF NOT EXISTS \(domain.tableName) "
                            + "(id TEXT PRIMARY KEY NOT NULL, payload BLOB NOT NULL, updated_at REAL NOT NULL);"
                            + "CREATE INDEX IF NOT EXISTS \(domain.tableName)_updated_at "
                            + "ON \(domain.tableName)(updated_at DESC);"
                    }.joined()
                ),
                (
                    4,
                    "CREATE TABLE IF NOT EXISTS workspace_metadata "
                        + "(id INTEGER PRIMARY KEY NOT NULL CHECK(id = 1), payload BLOB NOT NULL, updated_at REAL NOT NULL)"
                ),
            ]
            for (version, sql) in migrations {
                if try !migrationExists(version, database: database) {
                    if version >= 3, try stateRecordsExist(database: database) {
                        try createMigrationBackup(version: version, database: database, fileManager: fileManager)
                    }
                    try execute("BEGIN IMMEDIATE", database: database)
                    do {
                        try execute(sql, database: database)
                        try execute(
                            "INSERT INTO schema_migrations(version, applied_at) VALUES(\(version), \(Date.now.timeIntervalSince1970))",
                            database: database)
                        try execute("COMMIT", database: database)
                    } catch {
                        try? execute("ROLLBACK", database: database)
                        throw error
                    }
                }
            }
        }
    }

    private func stateRecordsExist(database: OpaquePointer) throws -> Bool {
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        try prepare("SELECT 1 FROM state_records LIMIT 1", database: database, statement: &statement)
        let result = sqlite3_step(statement)
        if result == SQLITE_ROW { return true }
        if result == SQLITE_DONE { return false }
        throw WorkspaceStoreError.query(message(database))
    }

    private func createMigrationBackup(
        version: Int,
        database: OpaquePointer,
        fileManager: FileManager
    ) throws {
        let backupURL = rootURL.appending(path: "agent-tooling.pre-migration-v\(version).sqlite")
        try Self.refuseSymbolicLink(at: backupURL, fileManager: fileManager)
        if fileManager.fileExists(atPath: backupURL.path(percentEncoded: false)) { return }

        var backupDatabase: OpaquePointer?
        guard
            sqlite3_open_v2(
                backupURL.path(percentEncoded: false),
                &backupDatabase,
                SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX,
                nil
            ) == SQLITE_OK, let backupDatabase
        else {
            if let backupDatabase { sqlite3_close(backupDatabase) }
            throw WorkspaceStoreError.migrationBackup(backupURL.path(percentEncoded: false))
        }
        defer { sqlite3_close(backupDatabase) }
        guard let backup = sqlite3_backup_init(backupDatabase, "main", database, "main") else {
            throw WorkspaceStoreError.migrationBackup(backupURL.path(percentEncoded: false))
        }
        let stepResult = sqlite3_backup_step(backup, -1)
        let finishResult = sqlite3_backup_finish(backup)
        guard stepResult == SQLITE_DONE, finishResult == SQLITE_OK else {
            throw WorkspaceStoreError.migrationBackup(backupURL.path(percentEncoded: false))
        }
        try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: backupURL.path(percentEncoded: false))
    }

    private func migrationExists(_ version: Int, database: OpaquePointer) throws -> Bool {
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        try prepare("SELECT 1 FROM schema_migrations WHERE version = ?", database: database, statement: &statement)
        guard sqlite3_bind_int(statement, 1, Int32(version)) == SQLITE_OK else {
            throw WorkspaceStoreError.query(message(database))
        }
        let result = sqlite3_step(statement)
        if result == SQLITE_ROW { return true }
        if result == SQLITE_DONE { return false }
        throw WorkspaceStoreError.query(message(database))
    }

    private func execute(_ sql: String, database: OpaquePointer) throws {
        var error: UnsafeMutablePointer<CChar>?
        guard sqlite3_exec(database, sql, nil, nil, &error) == SQLITE_OK else {
            let details = error.map { String(cString: $0) } ?? message(database)
            sqlite3_free(error)
            throw WorkspaceStoreError.query(details)
        }
    }

    private func replaceEntities(
        _ records: [StoredEntityPayload],
        domain: WorkspaceEntityDomain,
        database: OpaquePointer
    ) throws {
        try execute("DELETE FROM \(domain.tableName)", database: database)
        for record in records {
            var statement: OpaquePointer?
            defer { sqlite3_finalize(statement) }
            try prepare(
                "INSERT INTO \(domain.tableName)(id, payload, updated_at) VALUES(?, ?, ?)",
                database: database,
                statement: &statement
            )
            try bindText(record.id, at: 1, to: statement, database: database)
            try bindData(record.payload, at: 2, to: statement, database: database)
            guard sqlite3_bind_double(statement, 3, Date.now.timeIntervalSince1970) == SQLITE_OK,
                sqlite3_step(statement) == SQLITE_DONE
            else { throw WorkspaceStoreError.query(message(database)) }
        }
    }

    private func upsertWorkspaceMetadata(_ data: Data, database: OpaquePointer) throws {
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        try prepare(
            "INSERT INTO workspace_metadata(id, payload, updated_at) VALUES(1, ?, ?) "
                + "ON CONFLICT(id) DO UPDATE SET payload = excluded.payload, updated_at = excluded.updated_at",
            database: database,
            statement: &statement
        )
        try bindData(data, at: 1, to: statement, database: database)
        guard sqlite3_bind_double(statement, 2, Date.now.timeIntervalSince1970) == SQLITE_OK,
            sqlite3_step(statement) == SQLITE_DONE
        else { throw WorkspaceStoreError.query(message(database)) }
    }

    private func upsertStateRecord(key: String, data: Data, database: OpaquePointer) throws {
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        try prepare(
            "INSERT INTO state_records(key, payload, updated_at) VALUES(?, ?, ?) "
                + "ON CONFLICT(key) DO UPDATE SET payload = excluded.payload, updated_at = excluded.updated_at",
            database: database,
            statement: &statement
        )
        try bindText(key, at: 1, to: statement, database: database)
        try bindData(data, at: 2, to: statement, database: database)
        guard sqlite3_bind_double(statement, 3, Date.now.timeIntervalSince1970) == SQLITE_OK,
            sqlite3_step(statement) == SQLITE_DONE
        else { throw WorkspaceStoreError.query(message(database)) }
    }

    private func loadWorkspaceMetadata() throws -> WorkspaceMetadata? {
        try queue.sync {
            guard let database else { throw WorkspaceStoreError.closed }
            var statement: OpaquePointer?
            defer { sqlite3_finalize(statement) }
            try prepare("SELECT payload FROM workspace_metadata WHERE id = 1", database: database, statement: &statement)
            let result = sqlite3_step(statement)
            if result == SQLITE_DONE { return nil }
            guard result == SQLITE_ROW else { throw WorkspaceStoreError.query(message(database)) }
            return try decodeColumn(statement: statement, key: "workspace.metadata", as: WorkspaceMetadata.self)
        }
    }

    private func encodeRecord<Value: Encodable>(_ value: Value) throws -> Data {
        let data = try JSONEncoder.agentTooling().encode(value)
        guard data.count <= Self.maximumRecordBytes else { throw WorkspaceStoreError.recordTooLarge("normalized entity") }
        return data
    }

    private func entityPayload<Value: Encodable>(_ value: Value, id: String) throws -> StoredEntityPayload {
        try Self.validateKey(id)
        return StoredEntityPayload(id: id, payload: try encodeRecord(value))
    }

    private func prepare(_ sql: String, database: OpaquePointer, statement: inout OpaquePointer?) throws {
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else {
            throw WorkspaceStoreError.query(message(database))
        }
    }

    private func bindText(_ value: String, at index: Int32, to statement: OpaquePointer?, database: OpaquePointer) throws {
        guard sqlite3_bind_text(statement, index, value, -1, sqliteTransient) == SQLITE_OK else {
            throw WorkspaceStoreError.query(message(database))
        }
    }

    private func bindData(_ data: Data, at index: Int32, to statement: OpaquePointer?, database: OpaquePointer) throws {
        let result = data.withUnsafeBytes { raw in
            sqlite3_bind_blob(statement, index, raw.baseAddress, Int32(data.count), sqliteTransient)
        }
        guard result == SQLITE_OK else { throw WorkspaceStoreError.query(message(database)) }
    }

    private func decodeColumn<Value: Decodable>(
        statement: OpaquePointer?,
        column: Int32 = 0,
        key: String,
        as type: Value.Type
    ) throws -> Value {
        let count = Int(sqlite3_column_bytes(statement, column))
        guard count >= 0, count <= Self.maximumRecordBytes else {
            throw WorkspaceStoreError.recordTooLarge(key)
        }
        let data: Data
        if count == 0 {
            data = Data()
        } else if let bytes = sqlite3_column_blob(statement, column) {
            data = Data(bytes: bytes, count: count)
        } else {
            throw WorkspaceStoreError.query("Missing payload for \(key).")
        }
        return try JSONDecoder.agentTooling().decode(Value.self, from: data)
    }

    private func message(_ database: OpaquePointer) -> String {
        String(cString: sqlite3_errmsg(database))
    }

    private static func validateKey(_ key: String) throws {
        guard !key.isEmpty,
            key.count <= maximumKeyCharacters,
            !key.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
        else {
            throw WorkspaceStoreError.invalidKey
        }
    }

    private static func refuseSymbolicLink(at url: URL, fileManager: FileManager) throws {
        guard fileManager.fileExists(atPath: url.path(percentEncoded: false)) else { return }
        let values = try url.resourceValues(forKeys: [.isSymbolicLinkKey])
        guard values.isSymbolicLink != true else {
            throw WorkspaceStoreError.unsafePath(url.path(percentEncoded: false))
        }
    }

    private static func contains(_ child: URL, within root: URL) -> Bool {
        let rootPath = root.path(percentEncoded: false).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let childPath = child.path(percentEncoded: false).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return childPath == rootPath || childPath.hasPrefix(rootPath + "/")
    }

    private static func isProtectedRoot(_ url: URL, fileManager: FileManager) -> Bool {
        let candidate = url.resolvingSymlinksInPath().standardizedFileURL.path(percentEncoded: false)
        let home = fileManager.homeDirectoryForCurrentUser.resolvingSymlinksInPath().standardizedFileURL.path(percentEncoded: false)
        let applicationSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .resolvingSymlinksInPath().standardizedFileURL.path(percentEncoded: false)
        return candidate == "/"
            || candidate == home
            || candidate == applicationSupport
            || url.pathComponents.count < 3
    }
}

private struct WorkspaceMetadata: Codable {
    var activities: [ActivityReceipt]
    var activeProfileID: String
    var importedRepositoryPath: String?
    var backupConfiguration: BackupConfiguration
    var encryptedSyncConfiguration: EncryptedSyncConfiguration
    var preferences: WorkspacePreferences
    var managedPolicies: [ManagedPolicy]
    var collections: [ToolingCollection]
    var tagAssignments: [TagAssignment]

    init(snapshot: WorkspaceSnapshot) {
        activities = snapshot.activities
        activeProfileID = snapshot.activeProfileID
        importedRepositoryPath = snapshot.importedRepositoryPath
        backupConfiguration = snapshot.backupConfiguration
        encryptedSyncConfiguration = snapshot.encryptedSyncConfiguration
        preferences = snapshot.preferences
        managedPolicies = snapshot.managedPolicies
        collections = snapshot.collections
        tagAssignments = snapshot.tagAssignments
    }

    private enum CodingKeys: String, CodingKey {
        case activities, activeProfileID, importedRepositoryPath, backupConfiguration, encryptedSyncConfiguration, preferences,
            managedPolicies, collections, tagAssignments
    }

    /// Metadata written before collections shipped has neither key. Decoding
    /// them as absent keeps an existing workspace openable instead of failing
    /// the whole snapshot load.
    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        activities = try container.decodeIfPresent([ActivityReceipt].self, forKey: .activities) ?? []
        activeProfileID = try container.decodeIfPresent(String.self, forKey: .activeProfileID) ?? "local-library"
        importedRepositoryPath = try container.decodeIfPresent(String.self, forKey: .importedRepositoryPath)
        backupConfiguration = try container.decodeIfPresent(BackupConfiguration.self, forKey: .backupConfiguration) ?? .init()
        encryptedSyncConfiguration =
            try container.decodeIfPresent(EncryptedSyncConfiguration.self, forKey: .encryptedSyncConfiguration) ?? .init()
        preferences = try container.decodeIfPresent(WorkspacePreferences.self, forKey: .preferences) ?? .init()
        managedPolicies = try container.decodeIfPresent([ManagedPolicy].self, forKey: .managedPolicies) ?? []
        collections = try container.decodeIfPresent([ToolingCollection].self, forKey: .collections) ?? []
        tagAssignments = try container.decodeIfPresent([TagAssignment].self, forKey: .tagAssignments) ?? []
    }
}

private struct StoredEntityPayload {
    var id: String
    var payload: Data
}

private struct StoredEntityValue<Value> {
    var id: String
    var value: Value
}

private enum StoredWorkspacePackage: Codable {
    case skill(Skill)
    case mcpServer(MCPServer)
    case plugin(Plugin)
    case marketplace(MarketplacePackage)

    var skill: Skill? { if case .skill(let value) = self { value } else { nil } }
    var mcpServer: MCPServer? { if case .mcpServer(let value) = self { value } else { nil } }
    var plugin: Plugin? { if case .plugin(let value) = self { value } else { nil } }
    var marketplace: MarketplacePackage? { if case .marketplace(let value) = self { value } else { nil } }

    var stableID: String {
        switch self {
        case .skill(let value): "skill:\(value.id)"
        case .mcpServer(let value): "mcp:\(value.id)"
        case .plugin(let value): "plugin:\(value.id)"
        case .marketplace(let value): "marketplace:\(value.id)"
        }
    }
}

private enum StoredTargetBinding: Codable {
    case account(AccountSurface)
    case connector(ConnectorRecord)

    var account: AccountSurface? { if case .account(let value) = self { value } else { nil } }
    var connector: ConnectorRecord? { if case .connector(let value) = self { value } else { nil } }

    var stableID: String {
        switch self {
        case .account(let value): "account:\(value.id.uuidString.lowercased())"
        case .connector(let value): "connector:\(value.id.uuidString.lowercased())"
        }
    }
}

public enum WorkspaceEntityDomain: String, Codable, CaseIterable, Sendable {
    case packages
    case sources
    case sourceLocks
    case profiles
    case targetBindings
    case observedStates
    case plans
    case receipts

    fileprivate var tableName: String {
        switch self {
        case .packages: "packages"
        case .sources: "sources"
        case .sourceLocks: "source_locks"
        case .profiles: "profiles"
        case .targetBindings: "target_bindings"
        case .observedStates: "observed_states"
        case .plans: "operation_plans"
        case .receipts: "operation_receipts"
        }
    }
}

enum WorkspaceStoreError: LocalizedError, Sendable {
    case openDatabase(String)
    case closed
    case query(String)
    case recordTooLarge(String)
    case invalidKey
    case unsafePath(String)
    case migrationBackup(String)

    var errorDescription: String? {
        switch self {
        case .openDatabase(let path): "Unable to open Agent Tooling's local database at \(path)."
        case .closed: "The local workspace database is closed."
        case .query(let details): "The local workspace database could not complete the request: \(details)"
        case .recordTooLarge(let key): "The local workspace record \(key) exceeds the supported size limit."
        case .invalidKey: "The local workspace record key is empty, unsafe, or too long."
        case .unsafePath(let path): "The local workspace path is not a safe, direct file-system location: \(path)"
        case .migrationBackup(let path): "The workspace migration stopped because a safety backup could not be created at \(path)."
        }
    }
}
