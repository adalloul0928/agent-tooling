import Foundation
import SQLite3
import Darwin

public enum WorkspaceStoreFormatUpgrade: Sendable {
    case none, version1To2
}

public enum WorkspaceRevisionStoreAccess: Sendable {
    case readWrite, existingReadOnly, existingReadWrite
}

/// New-format state has its own versioned location and database name. Old
/// WorkspaceStore binaries can only write the retained legacy database; no
/// backward-compatible shadow of the new authority is written there.
///
/// SQLite serializes writers across app/service processes. An actor per
/// process alone would not protect compare-and-save or idempotency receipts.
public final class WorkspaceRevisionStore: @unchecked Sendable {
    public static let storeFormatVersion: Int32 = 2
    public static let databaseApplicationID: Int32 = 0x41545731 // ATW1

    public let databaseURL: URL
    public let workspaceID: WorkspaceObjectID
    public let deviceID: WorkspaceObjectID
    private let databasePath: String
    private let access: WorkspaceRevisionStoreAccess
    private let authorityBinding: AuthorityBinding?

    private struct AuthorityBinding {
        let legacyRoot: URL
        let selection: WorkspaceAuthoritySelection
    }

    private let queue = DispatchQueue(label: "com.agenttooling.workspace-revisions")
    private var database: OpaquePointer?
    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    /// Opening does not import legacy state or initialize a workspace. The
    /// caller explicitly supplies a container and enrolled workspace/device.
    public convenience init(containerRoot: URL, workspaceID: WorkspaceObjectID, deviceID: WorkspaceObjectID,
                formatUpgrade: WorkspaceStoreFormatUpgrade = .none,
                access: WorkspaceRevisionStoreAccess = .readWrite) throws {
        try self.init(containerRoot: containerRoot, workspaceID: workspaceID, deviceID: deviceID,
                      formatUpgrade: formatUpgrade, access: access, authorityBinding: nil)
    }

    /// For a trusted writable app session after explicit authority selection.
    /// This never creates or upgrades a database. Unbound stores remain reserved
    /// for migration/recovery and isolated fixtures, not active application writes.
    public static func openSelected(legacyRoot: URL, selection: WorkspaceAuthoritySelection) throws -> WorkspaceRevisionStore {
        try WorkspaceAuthorityStore.withVersionedWriteAccess(legacyRoot: legacyRoot, selection: selection) {
            let target = selection.target
            let store = try WorkspaceRevisionStore(
                containerRoot: URL(fileURLWithPath: target.containerRootPath, isDirectory: true),
                workspaceID: target.workspaceID, deviceID: target.deviceID,
                formatUpgrade: .none, access: .existingReadWrite,
                authorityBinding: .init(legacyRoot: legacyRoot, selection: selection))
            guard let entry = try store.migration(target.attemptID), entry.phase == .initialized,
                  entry.record.manifest.checkpointSHA256 == selection.checkpointSHA256,
                  entry.record.manifest.initialRevisionID == selection.versionedRevisionID,
                  URL(fileURLWithPath: entry.record.manifest.legacyDatabasePath).standardizedFileURL.resolvingSymlinksInPath()
                    == legacyRoot.appending(path: "agent-tooling.sqlite").standardizedFileURL.resolvingSymlinksInPath(),
                  try store.snapshot() != nil else {
                throw WorkspaceAuthorityServiceError.invalidSelection
            }
            return store
        }
    }

    private init(containerRoot: URL, workspaceID: WorkspaceObjectID, deviceID: WorkspaceObjectID,
                 formatUpgrade: WorkspaceStoreFormatUpgrade, access: WorkspaceRevisionStoreAccess,
                 authorityBinding: AuthorityBinding?) throws {
        self.workspaceID = workspaceID
        self.deviceID = deviceID
        self.access = access
        self.authorityBinding = authorityBinding
        guard access == .readWrite || formatUpgrade == .none else {
            throw WorkspaceRevisionStoreError.readOnly
        }
        let directory = try Self.prepareDirectory(containerRoot: containerRoot, workspaceID: workspaceID,
                                                  create: access == .readWrite)
        databaseURL = directory.appending(path: "revisions.sqlite")
        // Foundation deliberately abbreviates /private/var as /var on macOS,
        // even after resolvingSymlinksInPath. SQLite's NOFOLLOW also rejects
        // symlinked ancestors, so retain the POSIX real path as a string for
        // opening instead of round-tripping it through URL normalization.
        guard let realDirectory = realpath(directory.path, nil) else { throw WorkspaceRevisionStoreError.unsafeStorePath }
        databasePath = String(cString: realDirectory) + "/revisions.sqlite"
        free(realDirectory)
        for suffix in ["", "-wal", "-shm"] {
            try Self.checkRegularFileIfPresent(URL(fileURLWithPath: databaseURL.path + suffix))
        }
        var handle: OpaquePointer?
        let flags: Int32 = switch access {
        case .readWrite: SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE
        case .existingReadWrite: SQLITE_OPEN_READWRITE
        case .existingReadOnly: SQLITE_OPEN_READONLY
        }
        let status = sqlite3_open_v2(databasePath, &handle,
            flags | SQLITE_OPEN_FULLMUTEX | SQLITE_OPEN_NOFOLLOW, nil)
        guard status == SQLITE_OK, let handle else {
            if let handle { sqlite3_close(handle) }
            throw WorkspaceRevisionStoreError.databaseUnavailable
        }
        do {
            database = handle
            guard sqlite3_busy_timeout(handle, 5_000) == SQLITE_OK else { throw sqlError(handle) }
            if access == .existingReadOnly {
                try validateFormat(handle)
                try execute("PRAGMA query_only = ON", handle)
            } else if access == .readWrite {
                try initializeSchema(handle, upgrade: formatUpgrade)
                try execute("PRAGMA journal_mode = WAL", handle)
                try execute("PRAGMA synchronous = FULL", handle)
            } else {
                try validateFormat(handle)
                try execute("PRAGMA synchronous = FULL", handle)
            }
            try execute("PRAGMA foreign_keys = ON", handle)
            try execute("PRAGMA trusted_schema = OFF", handle)
            for suffix in access == .readWrite ? ["", "-wal", "-shm"] : [] {
                let url = URL(fileURLWithPath: databaseURL.path + suffix)
                if FileManager.default.fileExists(atPath: url.path) {
                    try Self.checkRegularFileIfPresent(url)
                    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
                }
            }
        } catch {
            database = nil
            sqlite3_close(handle)
            throw error
        }
    }

    deinit { if let database { sqlite3_close(database) } }

    /// Explicit bootstrap for a reviewed migration or a newly created library.
    /// An existing head is never replaced. No client/content files are touched.
    public func initialize(document: PortableWorkspaceDocument, device: DeviceWorkspaceState) throws {
        let documentBytes = try WorkspaceDocumentCoding.encode(document)
        try device.validateStructure(against: document)
        let deviceBytes = try WorkspaceDocumentCoding.encodeDeviceState(device)
        guard document.workspaceID == workspaceID, device.workspaceID == workspaceID, device.deviceID == deviceID else {
            throw WorkspaceRevisionStoreError.wrongWorkspaceOrDevice
        }
        guard document.revision.parentIDs.isEmpty else { throw WorkspaceRevisionStoreError.missingAncestry }
        try transaction(write: true) { database in
            guard try readSnapshot(database) == nil else { throw WorkspaceRevisionStoreError.alreadyInitialized }
            guard try scalar("SELECT COUNT(*) FROM migration_attempts", database) == 0 else {
                throw WorkspaceMigrationError.preparationPending
            }
            try insertRevision(document, bytes: documentBytes, database)
            try run("INSERT INTO device_state(id, payload) VALUES(1, ?)", [.data(deviceBytes)], database)
            try run("INSERT INTO workspace_head(id, revision_id) VALUES(1, ?)", [.text(document.revision.id.storageKey)], database)
        }
    }

    public func snapshot() throws -> WorkspaceApplicationSnapshot? {
        try transaction(write: false) { try readSnapshot($0) }
    }

    public func revision(_ id: WorkspaceObjectID) throws -> PortableWorkspaceDocument? {
        try transaction(write: false) { database in
            guard let bytes = try blob("SELECT payload FROM revisions WHERE id = ?", [.text(id.storageKey)], database) else { return nil }
            let document = try decodeDocument(bytes)
            guard document.workspaceID == workspaceID, document.revision.id == id else {
                throw WorkspaceRevisionStoreError.corruptState
            }
            return document
        }
    }

    public func migration(_ attemptID: WorkspaceObjectID) throws -> WorkspaceMigrationJournalEntry? {
        try transaction(write: false) { try readMigration(attemptID, $0) }
    }

    /// Recovery must discover persisted attempts after process memory is gone.
    /// UUID ordering is deterministic and intentionally makes no chronology claim.
    public func migrationJournal() throws -> [WorkspaceMigrationJournalEntry] {
        try transaction(write: false) { database in
            let row = try prepare("SELECT attempt_id FROM migration_attempts ORDER BY attempt_id LIMIT 1001", [], database)
            defer { sqlite3_finalize(row) }
            var result: [WorkspaceMigrationJournalEntry] = []
            while true {
                let status = sqlite3_step(row)
                if status == SQLITE_DONE { return result }
                guard status == SQLITE_ROW, result.count < 1_000,
                      let raw = sqlite3_column_text(row, 0),
                      let uuid = UUID(uuidString: String(cString: raw)),
                      uuid.uuidString.lowercased() == String(cString: raw),
                      let entry = try readMigration(WorkspaceObjectID(uuid), database) else {
                    throw WorkspaceRevisionStoreError.corruptState
                }
                result.append(entry)
            }
        }
    }

    /// Reserve this database's writer while publishing the independent authority
    /// choice. The callback changes no revision-store rows, so a crash after the
    /// registry's atomic publication cannot leave a half-applied database change.
    /// Lock order is authority registry, revision database, legacy database.
    func withAuthoritySelectionSnapshot<T>(
        expectedRevisionID: WorkspaceObjectID, attemptID: WorkspaceObjectID,
        _ body: (WorkspaceApplicationSnapshot, WorkspaceMigrationJournalEntry) throws -> T
    ) throws -> T {
        try transaction(write: true) { database in
            guard let current = try readSnapshot(database) else { throw WorkspaceRevisionStoreError.notInitialized }
            guard current.document.revision.id == expectedRevisionID else {
                throw WorkspaceRevisionStoreError.staleRevision(current: current.document.revision.id)
            }
            guard let entry = try readMigration(attemptID, database), entry.phase == .initialized else {
                throw WorkspaceMigrationError.missingPreparation
            }
            return try body(current, entry)
        }
    }

    /// Replay/identity checks before potentially expensive immutable staging.
    func preflightMigration(_ record: WorkspaceMigrationRecord) throws -> WorkspaceMigrationJournalEntry? {
        try validateMigrationIdentity(record)
        return try transaction(write: false) { database in
            if let previous = try matchingMigration(record, database) { return previous }
            guard try readSnapshot(database) == nil else { throw WorkspaceRevisionStoreError.alreadyInitialized }
            return nil
        }
    }

    func prepareMigration(_ record: WorkspaceMigrationRecord) throws -> WorkspaceMigrationJournalEntry {
        try validateMigrationIdentity(record)
        let payload = try record.manifestBytes()
        let document = try WorkspaceDocumentCoding.encode(record.document)
        let device = try WorkspaceDocumentCoding.encodeDeviceState(record.device)
        return try transaction(write: true) { database in
            if let previous = try matchingMigration(record, database) { return previous }
            guard try readSnapshot(database) == nil else { throw WorkspaceRevisionStoreError.alreadyInitialized }
            guard try scalar("SELECT COUNT(*) FROM migration_attempts", database) < 1_000 else {
                throw WorkspaceRevisionStoreError.recordTooLarge
            }
            try run("INSERT INTO migration_attempts(attempt_id, payload, document, device, phase) VALUES(?, ?, ?, ?, 'prepared')",
                [.text(record.manifest.attemptID.storageKey), .data(payload), .data(document), .data(device)], database)
            return .init(record: record, phase: .prepared)
        }
    }

    /// No filesystem work occurs inside this transaction. The service verifies
    /// archived/content prerequisites before invoking this trusted boundary.
    func initializeMigration(attemptID: WorkspaceObjectID, inputDigest: String) throws -> WorkspaceMigrationJournalEntry {
        try WorkspaceDomainValidation.requireDigest(inputDigest, field: "migration input")
        return try transaction(write: true) { database in
            guard let entry = try readMigration(attemptID, database) else { throw WorkspaceMigrationError.missingPreparation }
            guard try entry.record.inputDigest == inputDigest else { throw WorkspaceMigrationError.preparationConflict }
            if entry.phase == .initialized { return entry }
            guard try readSnapshot(database) == nil else { throw WorkspaceRevisionStoreError.alreadyInitialized }
            let record = entry.record
            try insertRevision(record.document, bytes: WorkspaceDocumentCoding.encode(record.document), database)
            try run("INSERT INTO device_state(id, payload) VALUES(1, ?)",
                [.data(try WorkspaceDocumentCoding.encodeDeviceState(record.device))], database)
            try run("INSERT INTO workspace_head(id, revision_id) VALUES(1, ?)",
                [.text(record.document.revision.id.storageKey)], database)
            try run("UPDATE migration_attempts SET phase = 'initialized' WHERE attempt_id = ? AND phase = 'prepared'",
                [.text(attemptID.storageKey)], database)
            guard sqlite3_changes(database) == 1 else { throw WorkspaceRevisionStoreError.corruptState }
            return .init(record: record, phase: .initialized)
        }
    }

    private func validateMigrationIdentity(_ record: WorkspaceMigrationRecord) throws {
        try record.validate()
        guard record.manifest.workspaceID == workspaceID, record.manifest.deviceID == deviceID else {
            throw WorkspaceRevisionStoreError.wrongWorkspaceOrDevice
        }
    }

    private func matchingMigration(_ record: WorkspaceMigrationRecord, _ database: OpaquePointer) throws -> WorkspaceMigrationJournalEntry? {
        guard let previous = try readMigration(record.manifest.attemptID, database) else { return nil }
        guard previous.record == record else { throw WorkspaceMigrationError.preparationConflict }
        return previous
    }

    private func readMigration(_ id: WorkspaceObjectID, _ database: OpaquePointer) throws -> WorkspaceMigrationJournalEntry? {
        let values: [SQLValue] = [.text(id.storageKey)]
        guard let payload = try blob("SELECT payload FROM migration_attempts WHERE attempt_id = ?", values, database) else { return nil }
        guard let document = try blob("SELECT document FROM migration_attempts WHERE attempt_id = ?", values, database),
              let device = try blob("SELECT device FROM migration_attempts WHERE attempt_id = ?", values, database) else {
            throw WorkspaceRevisionStoreError.corruptState
        }
        let record: WorkspaceMigrationRecord
        do {
            record = try WorkspaceMigrationRecord.decode(manifest: payload, document: document, device: device)
            try validateMigrationIdentity(record)
        } catch WorkspaceDomainValidationError.unsupportedVersion { throw WorkspaceRevisionStoreError.unsupportedStoreFormat }
        catch { throw WorkspaceRevisionStoreError.corruptState }
        guard record.manifest.attemptID == id else { throw WorkspaceRevisionStoreError.corruptState }
        let row = try prepare("SELECT phase FROM migration_attempts WHERE attempt_id = ?", values, database)
        defer { sqlite3_finalize(row) }
        guard sqlite3_step(row) == SQLITE_ROW, let raw = sqlite3_column_text(row, 0),
              let phase = WorkspaceMigrationPhase(rawValue: String(cString: raw)) else {
            throw WorkspaceRevisionStoreError.corruptState
        }
        if phase == .initialized {
            // Compare to the initial historical revision, not today's head. A
            // valid later edit must not turn an old completion into a new import.
            guard let initial = try blob("SELECT payload FROM revisions WHERE id = ?",
                    [.text(record.manifest.initialRevisionID.storageKey)], database), initial == document,
                  try readSnapshot(database) != nil else { throw WorkspaceRevisionStoreError.corruptState }
        }
        return .init(record: record, phase: phase)
    }

    /// Internal service boundary for pure portable metadata. Content staging,
    /// native operations and their recovery journal are separate later APIs.
    func commitMetadata(
        expectedRevisionID: WorkspaceObjectID, idempotencyKey: WorkspaceObjectID,
        inputDigest: String, writerID: WorkspaceObjectID,
        mutation: (inout PortableWorkspaceDocument) throws -> [ArtifactID]
    ) throws -> WorkspaceCommandReceipt {
        try WorkspaceDomainValidation.requireDigest(inputDigest, field: "command input digest")
        return try transaction(write: true) { database in
            // Resolve replay first, including after other commands advanced
            // the head. A repeated command returns its original durable result.
            if let receipt = try readReceipt(idempotencyKey: idempotencyKey, inputDigest: inputDigest, database) {
                return receipt
            }
            guard let current = try readSnapshot(database) else { throw WorkspaceRevisionStoreError.notInitialized }
            guard current.document.revision.id == expectedRevisionID else {
                throw WorkspaceRevisionStoreError.staleRevision(current: current.document.revision.id)
            }
            var updated = current.document
            let affected = try mutation(&updated)
            guard updated.workspaceID == workspaceID else { throw WorkspaceRevisionStoreError.wrongWorkspaceOrDevice }
            updated.revision = WorkspaceRevision(parentIDs: [expectedRevisionID], writerID: writerID)
            updated = try WorkspaceDocumentCoding.seal(updated)
            try current.device.validateStructure(against: updated)
            let bytes = try WorkspaceDocumentCoding.encode(updated)
            let receipt = WorkspaceCommandReceipt(
                idempotencyKey: idempotencyKey, inputDigest: inputDigest,
                previousRevisionID: expectedRevisionID, committedRevisionID: updated.revision.id,
                affectedArtifactIDs: affected.sorted())
            try insertRevision(updated, bytes: bytes, database)
            try run("UPDATE workspace_head SET revision_id = ? WHERE id = 1 AND revision_id = ?",
                [.text(updated.revision.id.storageKey), .text(expectedRevisionID.storageKey)], database)
            guard sqlite3_changes(database) == 1 else { throw WorkspaceRevisionStoreError.corruptState }
            try run("INSERT INTO command_receipts(idempotency_key, revision_id, payload) VALUES(?, ?, ?)",
                [.text(idempotencyKey.storageKey), .text(updated.revision.id.storageKey),
                 .data(try JSONEncoder().encode(receipt))], database)
            return receipt
        }
    }

    /// Read-only admission before immutable content publication. Replay is checked
    /// in the same transaction as the expected head and candidate validation.
    /// Commit repeats these checks because another writer may advance the head.
    func preflightMetadata(
        expectedRevisionID: WorkspaceObjectID, idempotencyKey: WorkspaceObjectID, inputDigest: String,
        mutation: (inout PortableWorkspaceDocument) throws -> [ArtifactID]
    ) throws -> WorkspaceCommandReceipt? {
        try WorkspaceDomainValidation.requireDigest(inputDigest, field: "command input digest")
        return try transaction(write: false) { database in
            if let receipt = try readReceipt(idempotencyKey: idempotencyKey, inputDigest: inputDigest, database) {
                return receipt
            }
            guard let current = try readSnapshot(database) else { throw WorkspaceRevisionStoreError.notInitialized }
            guard current.document.revision.id == expectedRevisionID else {
                throw WorkspaceRevisionStoreError.staleRevision(current: current.document.revision.id)
            }
            var candidate = current.document
            _ = try mutation(&candidate)
            try candidate.validateStructure()
            try current.device.validateStructure(against: candidate)
            return nil
        }
    }

    private func readReceipt(
        idempotencyKey: WorkspaceObjectID, inputDigest: String, _ database: OpaquePointer
    ) throws -> WorkspaceCommandReceipt? {
        if let bytes = try blob("SELECT payload FROM command_receipts WHERE idempotency_key = ?",
            [.text(idempotencyKey.storageKey)], database) {
            let receipt: WorkspaceCommandReceipt
            do { receipt = try JSONDecoder().decode(WorkspaceCommandReceipt.self, from: bytes) }
            catch { throw WorkspaceRevisionStoreError.corruptState }
            guard receipt.idempotencyKey == idempotencyKey else { throw WorkspaceRevisionStoreError.corruptState }
            guard receipt.inputDigest == inputDigest else {
                throw WorkspaceRevisionStoreError.idempotencyKeyReused
            }
            let row = try prepare("SELECT revision_id FROM command_receipts WHERE idempotency_key = ?",
                [.text(idempotencyKey.storageKey)], database)
            defer { sqlite3_finalize(row) }
            guard sqlite3_step(row) == SQLITE_ROW, let rowRevision = sqlite3_column_text(row, 0),
                String(cString: rowRevision) == receipt.committedRevisionID.storageKey,
                let revisionBytes = try blob("SELECT payload FROM revisions WHERE id = ?",
                    [.text(receipt.committedRevisionID.storageKey)], database),
                let previousBytes = try blob("SELECT payload FROM revisions WHERE id = ?",
                    [.text(receipt.previousRevisionID.storageKey)], database) else {
                throw WorkspaceRevisionStoreError.corruptState
            }
            let committed = try decodeDocument(revisionBytes)
            let previous = try decodeDocument(previousBytes)
            guard committed.workspaceID == workspaceID, previous.workspaceID == workspaceID,
                committed.revision.id == receipt.committedRevisionID,
                previous.revision.id == receipt.previousRevisionID,
                committed.revision.parentIDs == [receipt.previousRevisionID],
                Set(receipt.affectedArtifactIDs).count == receipt.affectedArtifactIDs.count,
                Set(receipt.affectedArtifactIDs).isSubset(of: Set(committed.artifacts.map(\.identity.id))) else {
                throw WorkspaceRevisionStoreError.corruptState
            }
            return receipt
        }
        return nil
    }

    private func readSnapshot(_ database: OpaquePointer) throws -> WorkspaceApplicationSnapshot? {
        guard let documentBytes = try blob(
            "SELECT revisions.payload FROM workspace_head JOIN revisions ON revisions.id = workspace_head.revision_id WHERE workspace_head.id = 1",
            [], database) else {
            // A dangling head or partial bootstrap is corruption, not an empty
            // library that may be overwritten by initialization.
            guard try scalar("SELECT COUNT(*) FROM workspace_head", database) == 0,
                try scalar("SELECT COUNT(*) FROM revisions", database) == 0,
                try scalar("SELECT COUNT(*) FROM device_state", database) == 0 else {
                throw WorkspaceRevisionStoreError.corruptState
            }
            return nil
        }
        guard let deviceBytes = try blob("SELECT payload FROM device_state WHERE id = 1", [], database) else {
            throw WorkspaceRevisionStoreError.corruptState
        }
        let document = try decodeDocument(documentBytes)
        let device: DeviceWorkspaceState
        do { device = try WorkspaceDocumentCoding.decodeDeviceState(deviceBytes, against: document) }
        catch WorkspaceDomainValidationError.unsupportedVersion { throw WorkspaceRevisionStoreError.unsupportedStoreFormat }
        catch { throw WorkspaceRevisionStoreError.corruptState }
        guard document.workspaceID == workspaceID, device.deviceID == deviceID else {
            throw WorkspaceRevisionStoreError.wrongWorkspaceOrDevice
        }
        let head = try prepare("SELECT revision_id FROM workspace_head WHERE id = 1", [], database)
        defer { sqlite3_finalize(head) }
        guard sqlite3_step(head) == SQLITE_ROW, let revisionID = sqlite3_column_text(head, 0),
            String(cString: revisionID) == document.revision.id.storageKey else {
            throw WorkspaceRevisionStoreError.corruptState
        }
        return WorkspaceApplicationSnapshot(document: document, device: device)
    }

    private func insertRevision(_ document: PortableWorkspaceDocument, bytes: Data, _ database: OpaquePointer) throws {
        try run("INSERT INTO revisions(id, payload) VALUES(?, ?)",
            [.text(document.revision.id.storageKey), .data(bytes)], database)
    }

    private func decodeDocument(_ data: Data) throws -> PortableWorkspaceDocument {
        do { return try WorkspaceDocumentCoding.decode(data) }
        catch WorkspaceDomainValidationError.unsupportedVersion { throw WorkspaceRevisionStoreError.unsupportedStoreFormat }
        catch { throw WorkspaceRevisionStoreError.corruptState }
    }

    private func transaction<T>(write: Bool, _ body: (OpaquePointer) throws -> T) throws -> T {
        if write, let authorityBinding {
            return try WorkspaceAuthorityStore.withVersionedWriteAccess(
                legacyRoot: authorityBinding.legacyRoot, selection: authorityBinding.selection
            ) { try databaseTransaction(write: write, body) }
        }
        return try databaseTransaction(write: write, body)
    }

    private func databaseTransaction<T>(write: Bool, _ body: (OpaquePointer) throws -> T) throws -> T {
        try queue.sync {
            guard !write || access != .existingReadOnly else { throw WorkspaceRevisionStoreError.readOnly }
            guard let database else { throw WorkspaceRevisionStoreError.databaseUnavailable }
            try execute(write ? "BEGIN IMMEDIATE" : "BEGIN", database)
            do {
                // Check on every transaction: another newer process may have
                // upgraded the format since this connection opened.
                try validateFormat(database)
                let result = try body(database)
                try execute("COMMIT", database)
                return result
            } catch {
                try? execute("ROLLBACK", database)
                throw error
            }
        }
    }

    private func initializeSchema(_ database: OpaquePointer, upgrade: WorkspaceStoreFormatUpgrade) throws {
        try execute("BEGIN IMMEDIATE", database)
        do {
            let version = try scalar("PRAGMA user_version", database)
            let application = try scalar("PRAGMA application_id", database)
            if version == 0 && application == 0 {
                guard try scalar("SELECT COUNT(*) FROM sqlite_master WHERE name NOT LIKE 'sqlite_%'", database) == 0 else {
                    throw WorkspaceRevisionStoreError.unsupportedStoreFormat
                }
                try execute("""
                    CREATE TABLE store_identity(id INTEGER PRIMARY KEY CHECK(id = 1), workspace_id TEXT NOT NULL, device_id TEXT NOT NULL);
                    CREATE TABLE revisions(id TEXT PRIMARY KEY NOT NULL, payload BLOB NOT NULL);
                    CREATE TABLE workspace_head(id INTEGER PRIMARY KEY CHECK(id = 1), revision_id TEXT NOT NULL REFERENCES revisions(id));
                    CREATE TABLE device_state(id INTEGER PRIMARY KEY CHECK(id = 1), payload BLOB NOT NULL);
                    CREATE TABLE command_receipts(idempotency_key TEXT PRIMARY KEY NOT NULL, revision_id TEXT NOT NULL REFERENCES revisions(id), payload BLOB NOT NULL);
                    CREATE TRIGGER revisions_immutable_update BEFORE UPDATE ON revisions BEGIN SELECT RAISE(ABORT, 'Revision history is immutable'); END;
                    CREATE TRIGGER revisions_immutable_delete BEFORE DELETE ON revisions BEGIN SELECT RAISE(ABORT, 'Revision history is immutable'); END;
                    PRAGMA application_id = \(Self.databaseApplicationID);
                    """, database)
                try run("INSERT INTO store_identity(id, workspace_id, device_id) VALUES(1, ?, ?)",
                    [.text(workspaceID.storageKey), .text(deviceID.storageKey)], database)
                try createMigrationSchema(database)
            } else if version == 1 && application == Self.databaseApplicationID,
                      case .version1To2 = upgrade {
                // Deliberate additive upgrade; opening a v1 store normally does
                // not modify it. Old v1 connections refuse writes after this.
                try validateIdentity(database)
                _ = try readSnapshot(database)
                try createMigrationSchema(database)
            }
            try validateFormat(database)
            try execute("COMMIT", database)
        } catch {
            try? execute("ROLLBACK", database)
            throw error
        }
    }

    private func validateFormat(_ database: OpaquePointer) throws {
        guard try scalar("PRAGMA user_version", database) == Self.storeFormatVersion,
            try scalar("PRAGMA application_id", database) == Self.databaseApplicationID else {
            throw WorkspaceRevisionStoreError.unsupportedStoreFormat
        }
        try validateIdentity(database)
    }

    private func createMigrationSchema(_ database: OpaquePointer) throws {
        try execute("""
            CREATE TABLE migration_attempts(attempt_id TEXT PRIMARY KEY NOT NULL, payload BLOB NOT NULL,
                document BLOB NOT NULL, device BLOB NOT NULL, phase TEXT NOT NULL CHECK(phase IN ('prepared', 'initialized')));
            CREATE UNIQUE INDEX one_initialized_migration ON migration_attempts(phase) WHERE phase = 'initialized';
            CREATE TRIGGER migration_inputs_immutable BEFORE UPDATE OF attempt_id, payload, document, device ON migration_attempts
                BEGIN SELECT RAISE(ABORT, 'Migration inputs are immutable'); END;
            CREATE TRIGGER migration_attempts_retained BEFORE DELETE ON migration_attempts
                BEGIN SELECT RAISE(ABORT, 'Migration attempts are retained'); END;
            CREATE TRIGGER migration_phase_forward BEFORE UPDATE OF phase ON migration_attempts
                WHEN OLD.phase != 'prepared' OR NEW.phase != 'initialized'
                BEGIN SELECT RAISE(ABORT, 'Migration completion is final'); END;
            PRAGMA user_version = 2;
            """, database)
    }

    private func validateIdentity(_ database: OpaquePointer) throws {
        let statement = try prepare("SELECT workspace_id, device_id FROM store_identity WHERE id = 1", [], database)
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW,
            let workspace = sqlite3_column_text(statement, 0), let device = sqlite3_column_text(statement, 1),
            String(cString: workspace) == workspaceID.storageKey, String(cString: device) == deviceID.storageKey else {
            throw WorkspaceRevisionStoreError.wrongWorkspaceOrDevice
        }
    }

    private enum SQLValue { case text(String), data(Data) }

    private func prepare(_ sql: String, _ values: [SQLValue], _ database: OpaquePointer) throws -> OpaquePointer {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK, let statement else { throw sqlError(database) }
        do {
            for (index, value) in values.enumerated() {
                let status: Int32
                switch value {
                case .text(let text):
                    status = sqlite3_bind_text(statement, Int32(index + 1), text, -1, Self.transient)
                case .data(let bytes):
                    guard bytes.count <= WorkspaceDocumentCoding.maximumDocumentBytes else { throw WorkspaceRevisionStoreError.recordTooLarge }
                    status = bytes.withUnsafeBytes { sqlite3_bind_blob(statement, Int32(index + 1), $0.baseAddress, Int32(bytes.count), Self.transient) }
                }
                guard status == SQLITE_OK else { throw sqlError(database) }
            }
            return statement
        } catch {
            sqlite3_finalize(statement)
            throw error
        }
    }

    private func run(_ sql: String, _ values: [SQLValue], _ database: OpaquePointer) throws {
        let statement = try prepare(sql, values, database)
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_DONE else { throw sqlError(database) }
    }

    private func blob(_ sql: String, _ values: [SQLValue], _ database: OpaquePointer) throws -> Data? {
        let statement = try prepare(sql, values, database)
        defer { sqlite3_finalize(statement) }
        let status = sqlite3_step(statement)
        if status == SQLITE_DONE { return nil }
        guard status == SQLITE_ROW, sqlite3_column_type(statement, 0) == SQLITE_BLOB,
            let bytes = sqlite3_column_blob(statement, 0) else { throw WorkspaceRevisionStoreError.corruptState }
        let count = Int(sqlite3_column_bytes(statement, 0))
        guard count > 0, count <= WorkspaceDocumentCoding.maximumDocumentBytes else { throw WorkspaceRevisionStoreError.recordTooLarge }
        return Data(bytes: bytes, count: count)
    }

    private func scalar(_ sql: String, _ database: OpaquePointer) throws -> Int32 {
        let statement = try prepare(sql, [], database)
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else { throw sqlError(database) }
        return sqlite3_column_int(statement, 0)
    }

    private func execute(_ sql: String, _ database: OpaquePointer) throws {
        guard sqlite3_exec(database, sql, nil, nil, nil) == SQLITE_OK else { throw sqlError(database) }
    }

    private func sqlError(_ database: OpaquePointer) -> WorkspaceRevisionStoreError {
        // Do not include SQL payloads or machine paths in portable receipts.
        .sqlite(code: sqlite3_extended_errcode(database))
    }

    private static func prepareDirectory(containerRoot: URL, workspaceID: WorkspaceObjectID, create: Bool) throws -> URL {
        guard containerRoot.isFileURL, containerRoot.path.hasPrefix("/"), containerRoot.standardizedFileURL.path != "/" else {
            throw WorkspaceRevisionStoreError.unsafeStorePath
        }
        let manager = FileManager.default
        let base = containerRoot.standardizedFileURL
        var current = base
        for name in ["", "workspaces-v1", workspaceID.storageKey] {
            if !name.isEmpty { current.append(path: name) }
            if let attributes = try? manager.attributesOfItem(atPath: current.path) {
                guard attributes[.type] as? FileAttributeType == .typeDirectory else {
                    throw WorkspaceRevisionStoreError.unsafeStorePath
                }
            } else if !create {
                throw WorkspaceRevisionStoreError.databaseUnavailable
            }
            if create {
                try manager.createDirectory(at: current, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            }
            // Only the versioned directories are owned by this store. Do not
            // chmod the caller's pre-existing container or home directory.
            if create, !name.isEmpty { try manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: current.path) }
        }
        return current.resolvingSymlinksInPath().standardizedFileURL
    }

    private static func checkRegularFileIfPresent(_ url: URL) throws {
        let manager = FileManager.default
        do {
            let attributes = try manager.attributesOfItem(atPath: url.path)
            guard attributes[.type] as? FileAttributeType == .typeRegular,
                (attributes[.referenceCount] as? NSNumber)?.intValue == 1 else { throw WorkspaceRevisionStoreError.unsafeStorePath }
        } catch let error as NSError where error.domain == NSCocoaErrorDomain && (error.code == NSFileReadNoSuchFileError || error.code == NSFileNoSuchFileError) {
            return
        }
    }
}

public enum WorkspaceRevisionStoreError: Error, Equatable, LocalizedError {
    case readOnly
    case databaseUnavailable, unsafeStorePath, unsupportedStoreFormat, wrongWorkspaceOrDevice
    case alreadyInitialized, notInitialized, missingAncestry, corruptState, recordTooLarge, missingArtifact
    case staleRevision(current: WorkspaceObjectID)
    case idempotencyKeyReused
    case sqlite(code: Int32)

    public var errorDescription: String? {
        switch self {
        case .readOnly: "This workspace is open for review. No changes can be saved."
        case .databaseUnavailable: "The versioned workspace database is unavailable."
        case .unsafeStorePath: "The workspace store location is not a private regular directory or file."
        case .unsupportedStoreFormat: "This workspace needs a different app version. No workspace changes were saved."
        case .wrongWorkspaceOrDevice: "The workspace or device identity does not match this store."
        case .alreadyInitialized: "A workspace already exists here. Its state was preserved."
        case .notInitialized: "Create or migrate the workspace before editing it."
        case .missingAncestry: "The initial workspace revision refers to history that was not imported."
        case .corruptState: "The workspace records are incomplete or inconsistent."
        case .recordTooLarge: "The workspace record exceeds the supported size."
        case .missingArtifact: "This item is no longer in the workspace."
        case .staleRevision: "The workspace changed. Refresh it before applying this edit."
        case .idempotencyKeyReused: "This request identifier was already used for a different edit."
        case .sqlite(let code): "The workspace transaction could not finish (SQLite \(code))."
        }
    }
}

private extension WorkspaceObjectID {
    var storageKey: String { rawValue.uuidString.lowercased() }
}
