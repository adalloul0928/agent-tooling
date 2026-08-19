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
            try migrate()
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

    private func migrate() throws {
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
            ]
            for (version, sql) in migrations {
                if try !migrationExists(version, database: database) {
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

public enum WorkspaceStoreError: LocalizedError, Sendable {
    case openDatabase(String)
    case closed
    case query(String)
    case recordTooLarge(String)
    case invalidKey
    case unsafePath(String)

    public var errorDescription: String? {
        switch self {
        case .openDatabase(let path): "Unable to open Agent Tooling's local database at \(path)."
        case .closed: "The local workspace database is closed."
        case .query(let details): "The local workspace database could not complete the request: \(details)"
        case .recordTooLarge(let key): "The local workspace record \(key) exceeds the supported size limit."
        case .invalidKey: "The local workspace record key is empty, unsafe, or too long."
        case .unsafePath(let path): "The local workspace path is not a safe, direct file-system location: \(path)"
        }
    }
}

private extension JSONEncoder {
    static func agentTooling() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }
}

private extension JSONDecoder {
    static func agentTooling() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
