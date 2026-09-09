import CryptoKit
import Darwin
import Foundation
import SQLite3

public enum WorkspaceLegacyCheckpointError: Error, Equatable, Sendable {
    case invalidDatabase, unsupportedSchema, invalidSnapshot, unsafePath, changedSource
    case tooLarge, busy, interrupted, digestMismatch, missingSnapshot
}

/// One self-contained SQLite backup image, including unknown tables and original
/// payload bytes. This is not a copy of the physical main/WAL/SHM file layout.
/// Capturing or interpreting it never initializes or normalizes the source store.
public struct WorkspaceLegacyCheckpoint: Sendable {
    public static let maximumDatabaseBytes = 128 * 1_024 * 1_024
    public let databaseBytes: Data
    public let sha256: String

    private init(bytes: Data) {
        databaseBytes = bytes
        sha256 = Self.digest(bytes)
    }

    public static func capture(databaseURL: URL) async throws -> Self {
        try await capture(databaseURL: databaseURL, afterSnapshotPinned: nil)
    }

    /// Internal deterministic concurrency seam; production runs no caller callback.
    static func capture(
        databaseURL: URL, afterSnapshotPinned: (@Sendable () throws -> Void)?
    ) async throws -> Self {
        try Task.checkCancellation()
        let worker = Task.detached {
            try captureSynchronously(databaseURL: databaseURL, afterSnapshotPinned: afterSnapshotPinned)
        }
        do {
            let value = try await withTaskCancellationHandler { try await worker.value } onCancel: { worker.cancel() }
            try Task.checkCancellation()
            return value
        } catch {
            try Task.checkCancellation()
            throw error
        }
    }

    public static func reopen(bytes: Data, expectedSHA256: String) throws -> Self {
        try validateSize(bytes.count)
        guard expectedSHA256.count == 64, expectedSHA256 == digest(bytes) else {
            throw WorkspaceLegacyCheckpointError.digestMismatch
        }
        let value = Self(bytes: bytes)
        try value.withDatabase { try checkIntegrity($0) }
        return value
    }

    public func workspaceSnapshot() throws -> WorkspaceSnapshot? {
        try withDatabase { try WorkspaceLegacySnapshotReader.read($0) }
    }

    /// Ties the candidate to the archived database; source trees/native evidence remain
    /// separate reviewed inputs and require their own final freshness checks.
    public func preview(
        context: WorkspaceMigrationContext, decisions: WorkspaceMigrationDecisions
    ) throws -> WorkspaceCheckpointMigrationPreview {
        guard let snapshot = try workspaceSnapshot() else { throw WorkspaceLegacyCheckpointError.missingSnapshot }
        return .init(checkpointSHA256: sha256, assembly: WorkspaceMigrationAssembly.preview(
            snapshot: snapshot, context: context, decisions: decisions))
    }

    static func captureSynchronously(
        databaseURL: URL, afterSnapshotPinned: (@Sendable () throws -> Void)? = nil
    ) throws -> Self {
        try Task.checkCancellation()
        let source = try LegacyCheckpointSource(databaseURL)
        let db = try openDatabase(source.path, flags: SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX | SQLITE_OPEN_NOFOLLOW)
        defer { sqlite3_close(db) }
        guard sqlite3_db_readonly(db, "main") == 1 else { throw WorkspaceLegacyCheckpointError.unsafePath }
        try source.validate()
        let budget = LegacyCheckpointBudget()
        configure(db, budget: budget)
        defer { withExtendedLifetime(budget) { sqlite3_progress_handler(db, 0, nil, nil) } }
        let sql = LegacyCheckpointSQL(db)
        try sql.execute("PRAGMA trusted_schema = OFF")
        try sql.execute("PRAGMA query_only = ON")
        try sql.execute("BEGIN")
        defer { try? sql.execute("ROLLBACK") }
        // BEGIN alone is deferred; this actual schema read pins the WAL snapshot.
        _ = try sql.integers("SELECT count(*) FROM sqlite_schema")
        let pages = try sql.integers("PRAGMA page_count").first ?? 0
        let pageSize = try sql.integers("PRAGMA page_size").first ?? 0
        guard pages > 0, pageSize > 0, pageSize <= 65_536,
              pages <= maximumDatabaseBytes / pageSize else { throw WorkspaceLegacyCheckpointError.tooLarge }
        try afterSnapshotPinned?()
        try source.validate()
        try Task.checkCancellation()
        let destination = try openDatabase(":memory:", flags: SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX)
        defer { sqlite3_close(destination) }
        configure(destination, budget: budget)
        defer { withExtendedLifetime(budget) { sqlite3_progress_handler(destination, 0, nil, nil) } }
        try LegacyCheckpointSQL(destination).execute("PRAGMA trusted_schema = OFF")
        guard let backup = sqlite3_backup_init(destination, "main", db, "main") else {
            throw WorkspaceLegacyCheckpointError.invalidDatabase
        }
        var finished = false
        defer { if !finished { sqlite3_backup_finish(backup) } }
        while true {
            try budget.check()
            let result = sqlite3_backup_step(backup, 64)
            if result == SQLITE_DONE { break }
            if result == SQLITE_BUSY || result == SQLITE_LOCKED { throw WorkspaceLegacyCheckpointError.busy }
            guard result == SQLITE_OK else { throw WorkspaceLegacyCheckpointError.invalidDatabase }
        }
        let result = sqlite3_backup_finish(backup)
        finished = true
        guard result == SQLITE_OK else { throw WorkspaceLegacyCheckpointError.invalidDatabase }
        try checkIntegrity(destination)
        try source.validate()
        try budget.check()
        var count: sqlite3_int64 = 0
        guard let bytes = sqlite3_serialize(destination, "main", &count, 0) else {
            throw WorkspaceLegacyCheckpointError.invalidDatabase
        }
        defer { sqlite3_free(bytes) }
        guard count > 0, count <= maximumDatabaseBytes else { throw WorkspaceLegacyCheckpointError.tooLarge }
        let checkpoint = Self(bytes: Data(bytes: bytes, count: Int(count)))
        // Exercise the persisted representation before returning a capturable receipt.
        try checkpoint.withDatabase { try checkIntegrity($0) }
        try source.validate()
        try Task.checkCancellation()
        return checkpoint
    }

    /// Reserve the existing legacy SQLite writer while a final capture and
    /// authority publication run. No rows are changed and no database is created.
    /// This also excludes older SQLite writers that do not know our registry lock.
    static func withWriteBarrier<T>(databaseURL: URL, _ body: () throws -> T) throws -> T {
        try Task.checkCancellation()
        let source = try LegacyCheckpointSource(databaseURL)
        let db = try openDatabase(source.path, flags: SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX | SQLITE_OPEN_NOFOLLOW)
        defer { sqlite3_close(db) }
        let budget = LegacyCheckpointBudget()
        configure(db, budget: budget)
        defer { withExtendedLifetime(budget) { sqlite3_progress_handler(db, 0, nil, nil) } }
        let sql = LegacyCheckpointSQL(db)
        try sql.execute("PRAGMA trusted_schema = OFF")
        try source.validate()
        try sql.execute("BEGIN IMMEDIATE")
        defer { try? sql.execute("ROLLBACK") }
        try source.validate()
        return try body()
    }

    private func withDatabase<Result>(_ body: (OpaquePointer) throws -> Result) throws -> Result {
        try Task.checkCancellation()
        try Self.validateSize(databaseBytes.count)
        let db = try Self.openDatabase(":memory:", flags: SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX)
        defer { sqlite3_close(db) }
        guard let allocation = sqlite3_malloc64(UInt64(databaseBytes.count)) else {
            throw WorkspaceLegacyCheckpointError.tooLarge
        }
        let buffer = allocation.assumingMemoryBound(to: UInt8.self)
        databaseBytes.copyBytes(to: buffer, count: databaseBytes.count)
        // SQLite's documented deserialize contract cannot read a WAL-mode page-1
        // header. Adapt this private query buffer only; archive bytes/hash stay exact.
        // The backup already contains every committed WAL page from its pinned read.
        if buffer[18] == 2, buffer[19] == 2 { buffer[18] = 1; buffer[19] = 1 }
        guard sqlite3_deserialize(db, "main", buffer, Int64(databaseBytes.count), Int64(databaseBytes.count),
                                 UInt32(SQLITE_DESERIALIZE_FREEONCLOSE | SQLITE_DESERIALIZE_READONLY)) == SQLITE_OK else {
            // FREEONCLOSE also frees the buffer on deserialize failure.
            throw WorkspaceLegacyCheckpointError.invalidDatabase
        }
        let budget = LegacyCheckpointBudget()
        Self.configure(db, budget: budget)
        defer { withExtendedLifetime(budget) { sqlite3_progress_handler(db, 0, nil, nil) } }
        try LegacyCheckpointSQL(db).execute("PRAGMA trusted_schema = OFF")
        try LegacyCheckpointSQL(db).execute("PRAGMA query_only = ON")
        do {
            let result = try body(db)
            try budget.check()
            return result
        } catch {
            try Task.checkCancellation()
            throw error
        }
    }

    private static func openDatabase(_ path: String, flags: Int32) throws -> OpaquePointer {
        var db: OpaquePointer?
        guard sqlite3_open_v2(path, &db, flags, nil) == SQLITE_OK, let db else {
            if let db { sqlite3_close(db) }
            throw WorkspaceLegacyCheckpointError.invalidDatabase
        }
        return db
    }

    private static func configure(_ db: OpaquePointer, budget: LegacyCheckpointBudget) {
        sqlite3_busy_timeout(db, 100)
        sqlite3_limit(db, SQLITE_LIMIT_LENGTH, Int32(maximumDatabaseBytes))
        sqlite3_limit(db, SQLITE_LIMIT_ATTACHED, 0)
        sqlite3_progress_handler(db, 1_000, { context in
            guard let context else { return 1 }
            let budget = Unmanaged<LegacyCheckpointBudget>.fromOpaque(context).takeUnretainedValue()
            return budget.interrupted ? 1 : 0
        }, Unmanaged.passUnretained(budget).toOpaque())
    }

    private static func checkIntegrity(_ db: OpaquePointer) throws {
        let sql = LegacyCheckpointSQL(db)
        let statement = try sql.statement("PRAGMA quick_check(1)")
        defer { sqlite3_finalize(statement) }
        guard try sql.next(statement), let text = sqlite3_column_text(statement, 0),
              String(cString: text) == "ok", try !sql.next(statement) else {
            throw WorkspaceLegacyCheckpointError.invalidDatabase
        }
    }

    private static func validateSize(_ count: Int) throws {
        guard count >= 100 else { throw WorkspaceLegacyCheckpointError.invalidDatabase }
        guard count <= maximumDatabaseBytes else { throw WorkspaceLegacyCheckpointError.tooLarge }
    }

    private static func digest(_ bytes: Data) -> String {
        SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
    }
}

public struct WorkspaceCheckpointMigrationPreview: Sendable {
    public let checkpointSHA256: String
    public let assembly: WorkspaceMigrationAssemblyPreview
}

private final class LegacyCheckpointBudget {
    private let deadline = ContinuousClock.now.advanced(by: .seconds(10))
    var interrupted: Bool { Task.isCancelled || ContinuousClock.now >= deadline }
    func check() throws {
        try Task.checkCancellation()
        guard ContinuousClock.now < deadline else { throw WorkspaceLegacyCheckpointError.interrupted }
    }
}

private struct LegacyCheckpointSource {
    let path: String
    private let requestedPath: String
    private let device: dev_t
    private let inode: ino_t

    init(_ url: URL) throws {
        guard url.isFileURL, url.path.hasPrefix("/"),
              !url.path.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else {
            throw WorkspaceLegacyCheckpointError.unsafePath
        }
        let original = try Self.regularFile(url.path)
        guard let resolved = realpath(url.path, nil) else { throw WorkspaceLegacyCheckpointError.unsafePath }
        defer { free(resolved) }
        path = String(cString: resolved)
        requestedPath = url.path
        device = original.st_dev
        inode = original.st_ino
        try validate()
    }

    func validate() throws {
        let current = try Self.regularFile(path)
        let requested = try Self.regularFile(requestedPath)
        guard current.st_dev == device, current.st_ino == inode,
              requested.st_dev == device, requested.st_ino == inode else {
            throw WorkspaceLegacyCheckpointError.changedSource
        }
        for suffix in ["-wal", "-shm", "-journal"] {
            var status = stat()
            if lstat(path + suffix, &status) == 0 { _ = try Self.regularFile(path + suffix) }
            else if errno != ENOENT { throw WorkspaceLegacyCheckpointError.unsafePath }
        }
    }

    private static func regularFile(_ path: String) throws -> stat {
        var value = stat()
        guard lstat(path, &value) == 0, value.st_mode & S_IFMT == S_IFREG,
              value.st_nlink == 1, value.st_uid == geteuid() else {
            throw WorkspaceLegacyCheckpointError.unsafePath
        }
        return value
    }
}
