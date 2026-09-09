import Foundation
import SQLite3
import Darwin

public enum WorkspaceStoreFormatUpgrade: Sendable {
    case none, version1To2
}

public enum WorkspaceRevisionStoreAccess: Sendable {
    case readWrite, existingReadOnly, existingReadWrite
}

/// The workspace: immutable revisions, this device's own state, and the
/// operational records that belong to neither — receipts, the review queue and
/// the activity journal.
///
/// SQLite serializes writers across the app, the CLI and the MCP server. An
/// actor per process would not, and compare-and-save and idempotency receipts
/// both depend on it.
public final class WorkspaceRevisionStore: @unchecked Sendable {
    public static let storeFormatVersion: Int32 = 2
    /// How many receipts this device keeps. A record of what happened is worth
    /// keeping; every record this device ever made is a log, not a memory.
    public static let maximumReceipts = 500
    public static let databaseApplicationID: Int32 = 0x41545731 // ATW1
    /// Bounds ancestry walks so a long or damaged history cannot stall a read.
    static let ancestryLimit = 4_096

    public let databaseURL: URL
    public let workspaceID: WorkspaceObjectID
    public let deviceID: WorkspaceObjectID
    private let databasePath: String
    private let access: WorkspaceRevisionStoreAccess

    private let queue = DispatchQueue(label: "com.agenttooling.workspace-revisions")
    private var database: OpaquePointer?
    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    /// Opening does not import legacy state or initialize a workspace. The
    /// caller explicitly supplies a container and enrolled workspace/device.
    public init(containerRoot: URL, workspaceID: WorkspaceObjectID, deviceID: WorkspaceObjectID,
                formatUpgrade: WorkspaceStoreFormatUpgrade = .none,
                access: WorkspaceRevisionStoreAccess = .readWrite) throws {
        self.workspaceID = workspaceID
        self.deviceID = deviceID
        self.access = access
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

    /// Recovery must discover persisted attempts after process memory is gone.
    /// UUID ordering is deterministic and intentionally makes no chronology claim.
    // MARK: - Operational records

    /// The most recent receipts, newest first.
    ///
    /// Ordered by the time each was created rather than by insertion, so the
    /// list reads the way a person remembers doing things.
    public func operationReceipts(limit: Int = 50) throws -> [OperationReceipt] {
        try transaction(write: false) { database in
            let bounded = min(max(1, limit), Self.maximumReceipts)
            let row = try prepare(
                "SELECT payload FROM operation_receipts ORDER BY created_at DESC, id DESC LIMIT ?",
                [.integer(Int64(bounded))], database)
            defer { sqlite3_finalize(row) }
            var results: [OperationReceipt] = []
            while sqlite3_step(row) == SQLITE_ROW {
                guard let bytes = sqlite3_column_blob(row, 0) else {
                    throw WorkspaceRevisionStoreError.corruptState
                }
                let data = Data(bytes: bytes, count: Int(sqlite3_column_bytes(row, 0)))
                guard let receipt = try? AgentToolingCoding.decoder()
                    .decode(OperationReceipt.self, from: data) else {
                    throw WorkspaceRevisionStoreError.corruptState
                }
                results.append(receipt)
            }
            return results
        }
    }

    public func operationReceipt(_ id: UUID) throws -> OperationReceipt? {
        try transaction(write: false) { database in
            guard let data = try blob("SELECT payload FROM operation_receipts WHERE id = ?",
                                      [.text(id.uuidString.lowercased())], database) else { return nil }
            guard let receipt = try? AgentToolingCoding.decoder()
                .decode(OperationReceipt.self, from: data) else {
                throw WorkspaceRevisionStoreError.corruptState
            }
            return receipt
        }
    }

    /// Records what an operation did, and notes it in this device's own state.
    ///
    /// The write and the device-state note happen in one transaction: a receipt
    /// the device does not know about, or a reference with no receipt behind it,
    /// would each be a record that cannot be trusted.
    public func recordOperationReceipt(_ receipt: OperationReceipt) throws {
        try transaction(write: true) { database in
            guard try scalar("SELECT COUNT(*) FROM operation_receipts WHERE id = ?",
                             [.text(receipt.id.uuidString.lowercased())], database) == 0 else {
                // Receipts are immutable, so a repeat is a no-op rather than an
                // error: replaying a completed operation must not fail here.
                return
            }
            let payload = try AgentToolingCoding.encoder().encode(receipt)
            try run("INSERT INTO operation_receipts(id, created_at, payload) VALUES(?, ?, ?)",
                [.text(receipt.id.uuidString.lowercased()),
                 .double(receipt.createdAt.timeIntervalSince1970), .data(payload)], database)
            guard var device = try readSnapshot(database)?.device else {
                throw WorkspaceRevisionStoreError.notInitialized
            }
            let reference = WorkspaceObjectID(receipt.id)
            if !device.receiptIDs.contains(reference) {
                device.receiptIDs.append(reference)
                // Bounded, so a long-lived workspace does not carry every
                // reference it ever made in its device state.
                if device.receiptIDs.count > Self.maximumReceipts {
                    device.receiptIDs.removeFirst(device.receiptIDs.count - Self.maximumReceipts)
                }
                try run("UPDATE device_state SET payload = ? WHERE id = 1",
                    [.data(try WorkspaceDocumentCoding.encodeDeviceState(device))], database)
                guard sqlite3_changes(database) == 1 else {
                    throw WorkspaceRevisionStoreError.corruptState
                }
            }
            // Oldest first, so the cap keeps what a person is most likely to
            // still be asking about.
            try run("""
                DELETE FROM operation_receipts WHERE id IN (
                    SELECT id FROM operation_receipts ORDER BY created_at DESC, id DESC LIMIT -1 OFFSET ?)
                """, [.integer(Int64(Self.maximumReceipts))], database)
        }
    }

    /// What agents have asked this person to review.
    public func pendingRequestQueue() throws -> PendingAgentRequestQueue {
        try transaction(write: false) { database in
            try readQueue(database)
        }
    }

    /// Reads, changes and writes the queue in one transaction, so two callers
    /// cannot each admit a request against the same remaining capacity.
    @discardableResult
    public func updatePendingRequestQueue<Value>(
        _ update: (inout PendingAgentRequestQueue) throws -> Value
    ) throws -> Value {
        try transaction(write: true) { database in
            var queue = try readQueue(database)
            let result = try update(&queue)
            let payload = try AgentToolingCoding.encoder().encode(queue)
            try run("INSERT INTO pending_requests(id, payload) VALUES(1, ?) "
                + "ON CONFLICT(id) DO UPDATE SET payload = excluded.payload", [.data(payload)], database)
            return result
        }
    }

    /// Every tool call an agent made, including the reads. See the journal's own
    /// documentation for why reads are recorded.
    public func activityJournal<Value: Codable>(as type: Value.Type, default fallback: Value) throws -> Value {
        try transaction(write: false) { database in
            guard let data = try blob("SELECT payload FROM activity_journal WHERE id = 1", [], database) else {
                return fallback
            }
            guard let value = try? AgentToolingCoding.decoder().decode(Value.self, from: data) else {
                throw WorkspaceRevisionStoreError.corruptState
            }
            return value
        }
    }

    public func saveActivityJournal(_ journal: some Encodable) throws {
        try transaction(write: true) { database in
            let payload = try AgentToolingCoding.encoder().encode(journal)
            try run("INSERT INTO activity_journal(id, payload) VALUES(1, ?) "
                + "ON CONFLICT(id) DO UPDATE SET payload = excluded.payload", [.data(payload)], database)
        }
    }

    // MARK: - Managed library on disk

    /// Where this app keeps content it owns, beside the workspace it belongs to.
    ///
    /// The executor refuses to copy from anywhere but here, which is what stops
    /// a deployment installing whatever happens to be lying around. Putting it
    /// beside the store rather than in a shared folder means one workspace's
    /// content moves with that workspace and cannot be confused with another's.
    public var libraryURL: URL {
        databaseURL.deletingLastPathComponent()
            .appending(path: "library", directoryHint: .isDirectory).standardizedFileURL
    }

    public var receiptsURL: URL {
        databaseURL.deletingLastPathComponent()
            .appending(path: "receipts", directoryHint: .isDirectory).standardizedFileURL
    }

    public var managedRootURL: URL {
        databaseURL.deletingLastPathComponent().standardizedFileURL
    }

    /// Creates the folders the executor writes into. Called before an operation
    /// rather than at open time, so opening a workspace to read it never makes
    /// directories on someone's disk.
    public func prepareManagedDirectories() throws {
        for url in [libraryURL, receiptsURL] {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
        }
    }

    /// What this app has proof it installed, and where.
    public func managedInstallLedger() throws -> ManagedInstallLedger {
        try transaction(write: false) { database in
            guard let data = try blob("SELECT payload FROM managed_installs WHERE id = 1", [], database) else {
                return ManagedInstallLedger()
            }
            guard let ledger = try? AgentToolingCoding.decoder()
                .decode(ManagedInstallLedger.self, from: data) else {
                throw WorkspaceRevisionStoreError.corruptState
            }
            return ledger
        }
    }

    public func saveManagedInstallLedger(_ ledger: ManagedInstallLedger) throws {
        try transaction(write: true) { database in
            let payload = try AgentToolingCoding.encoder().encode(ledger)
            try run("INSERT INTO managed_installs(id, payload) VALUES(1, ?) "
                + "ON CONFLICT(id) DO UPDATE SET payload = excluded.payload", [.data(payload)], database)
        }
    }

    /// The payload behind a queued request that needs one.
    ///
    /// Kept beside the queue rather than inside it: a review row is small and
    /// read constantly, and a draft is neither. A row whose draft is missing is
    /// a row that can never open, so the two are written and discarded together
    /// by the queue service.
    public func requestDraft<Value: Decodable>(_ id: UUID, as type: Value.Type) throws -> Value? {
        try transaction(write: false) { database in
            guard let data = try blob("SELECT payload FROM request_drafts WHERE id = ?",
                                      [.text(id.uuidString.lowercased())], database) else { return nil }
            guard let value = try? AgentToolingCoding.decoder().decode(Value.self, from: data) else {
                throw WorkspaceRevisionStoreError.corruptState
            }
            return value
        }
    }

    public func saveRequestDraft(_ id: UUID, _ draft: some Encodable) throws {
        try transaction(write: true) { database in
            let payload = try AgentToolingCoding.encoder().encode(draft)
            try run("INSERT INTO request_drafts(id, payload) VALUES(?, ?) "
                + "ON CONFLICT(id) DO UPDATE SET payload = excluded.payload",
                [.text(id.uuidString.lowercased()), .data(payload)], database)
        }
    }

    public func deleteRequestDraft(_ id: UUID) throws {
        try transaction(write: true) { database in
            try run("DELETE FROM request_drafts WHERE id = ?",
                    [.text(id.uuidString.lowercased())], database)
        }
    }

    private func readQueue(_ database: OpaquePointer) throws -> PendingAgentRequestQueue {
        guard let data = try blob("SELECT payload FROM pending_requests WHERE id = 1", [], database) else {
            return .init()
        }
        guard let queue = try? AgentToolingCoding.decoder()
            .decode(PendingAgentRequestQueue.self, from: data) else {
            throw WorkspaceRevisionStoreError.corruptState
        }
        return queue
    }


    /// Records a revision received from another device so its ancestry can be
    /// resolved here later. It never becomes the head and never changes device
    /// state: receiving shared intent is not evidence that anything was applied.
    public func importRemoteRevision(_ document: PortableWorkspaceDocument) throws {
        guard document.workspaceID == workspaceID else {
            throw WorkspaceRevisionStoreError.wrongWorkspaceOrDevice
        }
        let bytes = try WorkspaceDocumentCoding.encode(document)
        try transaction(write: true) { database in
            guard try readSnapshot(database) != nil else { throw WorkspaceRevisionStoreError.notInitialized }
            guard try blob("SELECT payload FROM revisions WHERE id = ?",
                           [.text(document.revision.id.storageKey)], database) == nil else {
                // History is immutable; an already-known revision is complete.
                return
            }
            try insertRevision(document, bytes: bytes, database)
        }
    }

    /// The newest revision this store holds that both the current head and the
    /// supplied remote revision descend from. `nil` means the two histories
    /// share nothing here, which is not evidence that either side deleted
    /// anything.
    public func commonAncestor(withRemote remote: PortableWorkspaceDocument) throws -> PortableWorkspaceDocument? {
        guard remote.workspaceID == workspaceID else {
            throw WorkspaceRevisionStoreError.wrongWorkspaceOrDevice
        }
        return try transaction(write: false) { database in
            guard let current = try readSnapshot(database) else {
                throw WorkspaceRevisionStoreError.notInitialized
            }
            let local = try ancestry(of: [current.document.revision.id], database)
            var visited = Set<WorkspaceObjectID>()
            var queue = remote.revision.parentIDs
            if local.contains(remote.revision.id) { return remote }
            var depth = 0
            while !queue.isEmpty, depth < Self.ancestryLimit {
                depth += 1
                var next: [WorkspaceObjectID] = []
                for id in queue where visited.insert(id).inserted {
                    if local.contains(id),
                       let payload = try blob("SELECT payload FROM revisions WHERE id = ?",
                                              [.text(id.storageKey)], database) {
                        return try decodeDocument(payload)
                    }
                    if let payload = try blob("SELECT payload FROM revisions WHERE id = ?",
                                              [.text(id.storageKey)], database) {
                        next += try decodeDocument(payload).revision.parentIDs
                    }
                }
                queue = next
            }
            return nil
        }
    }

    /// Moves the head onto a revision already recorded here that descends from
    /// the current head. Adopting shared intent keeps the revision's own
    /// identity, so two devices that agree end up on the same head rather than
    /// each minting a new one and chasing the other forever.
    public func fastForward(
        to revisionID: WorkspaceObjectID,
        expectedLocalHead: WorkspaceObjectID,
        idempotencyKey: WorkspaceObjectID,
        inputDigest: String
    ) throws -> WorkspaceCommandReceipt {
        try WorkspaceDomainValidation.requireDigest(inputDigest, field: "command input digest")
        return try transaction(write: true) { database in
            if let receipt = try readReceipt(idempotencyKey: idempotencyKey, inputDigest: inputDigest, database) {
                return receipt
            }
            guard let current = try readSnapshot(database) else { throw WorkspaceRevisionStoreError.notInitialized }
            guard current.document.revision.id == expectedLocalHead else {
                throw WorkspaceRevisionStoreError.staleRevision(current: current.document.revision.id)
            }
            guard let payload = try blob("SELECT payload FROM revisions WHERE id = ?",
                                         [.text(revisionID.storageKey)], database) else {
                throw WorkspaceRevisionStoreError.missingAncestry
            }
            let target = try decodeDocument(payload)
            // Only a descendant may become the head; this never rewinds history
            // and never adopts an unrelated revision.
            guard try ancestry(of: target.revision.parentIDs, database).contains(expectedLocalHead) else {
                throw WorkspaceRevisionStoreError.missingAncestry
            }
            try current.device.validateStructure(against: target)
            let receipt = WorkspaceCommandReceipt(
                idempotencyKey: idempotencyKey, inputDigest: inputDigest,
                previousRevisionID: expectedLocalHead, committedRevisionID: target.revision.id,
                affectedArtifactIDs: target.artifacts.map(\.identity.id).sorted())
            try run("UPDATE workspace_head SET revision_id = ? WHERE id = 1 AND revision_id = ?",
                [.text(target.revision.id.storageKey), .text(expectedLocalHead.storageKey)], database)
            guard sqlite3_changes(database) == 1 else { throw WorkspaceRevisionStoreError.corruptState }
            try run("INSERT INTO command_receipts(idempotency_key, revision_id, payload) VALUES(?, ?, ?)",
                [.text(idempotencyKey.storageKey), .text(target.revision.id.storageKey),
                 .data(try JSONEncoder().encode(receipt))], database)
            return receipt
        }
    }

    /// Commits a revision that combines the local head with a revision accepted
    /// from another device. The merged document's parents must be exactly those
    /// two, so a merge can never be recorded as if it were a local edit.
    public func commitMerge(
        document: PortableWorkspaceDocument,
        expectedLocalHead: WorkspaceObjectID,
        remoteRevisionID: WorkspaceObjectID,
        idempotencyKey: WorkspaceObjectID,
        inputDigest: String
    ) throws -> WorkspaceCommandReceipt {
        try WorkspaceDomainValidation.requireDigest(inputDigest, field: "command input digest")
        let expectedParents = Set([expectedLocalHead, remoteRevisionID])
        guard Set(document.revision.parentIDs) == expectedParents,
              document.revision.parentIDs.count == expectedParents.count,
              document.workspaceID == workspaceID else {
            throw WorkspaceRevisionStoreError.missingAncestry
        }
        return try transaction(write: true) { database in
            if let receipt = try readReceipt(idempotencyKey: idempotencyKey, inputDigest: inputDigest, database) {
                return receipt
            }
            guard let current = try readSnapshot(database) else { throw WorkspaceRevisionStoreError.notInitialized }
            guard current.document.revision.id == expectedLocalHead else {
                throw WorkspaceRevisionStoreError.staleRevision(current: current.document.revision.id)
            }
            // The remote side must already be recorded here, so the merged
            // revision's ancestry is resolvable from this store alone.
            let remoteKnown = try blob("SELECT payload FROM revisions WHERE id = ?",
                                       [.text(remoteRevisionID.storageKey)], database) != nil
            guard expectedLocalHead == remoteRevisionID || remoteKnown else {
                throw WorkspaceRevisionStoreError.missingAncestry
            }
            let sealed = try WorkspaceDocumentCoding.seal(document)
            try current.device.validateStructure(against: sealed)
            let bytes = try WorkspaceDocumentCoding.encode(sealed)
            let receipt = WorkspaceCommandReceipt(
                idempotencyKey: idempotencyKey, inputDigest: inputDigest,
                previousRevisionID: expectedLocalHead, committedRevisionID: sealed.revision.id,
                affectedArtifactIDs: sealed.artifacts.map(\.identity.id).sorted())
            try insertRevision(sealed, bytes: bytes, database)
            try run("UPDATE workspace_head SET revision_id = ? WHERE id = 1 AND revision_id = ?",
                [.text(sealed.revision.id.storageKey), .text(expectedLocalHead.storageKey)], database)
            guard sqlite3_changes(database) == 1 else { throw WorkspaceRevisionStoreError.corruptState }
            try run("INSERT INTO command_receipts(idempotency_key, revision_id, payload) VALUES(?, ?, ?)",
                [.text(idempotencyKey.storageKey), .text(sealed.revision.id.storageKey),
                 .data(try JSONEncoder().encode(receipt))], database)
            return receipt
        }
    }

    /// Every revision reachable from these ids through stored history.
    private func ancestry(
        of roots: [WorkspaceObjectID], _ database: OpaquePointer
    ) throws -> Set<WorkspaceObjectID> {
        var seen = Set<WorkspaceObjectID>()
        var queue = roots
        var depth = 0
        while !queue.isEmpty, depth < Self.ancestryLimit {
            depth += 1
            var next: [WorkspaceObjectID] = []
            for id in queue where seen.insert(id).inserted {
                guard let payload = try blob("SELECT payload FROM revisions WHERE id = ?",
                                             [.text(id.storageKey)], database) else { continue }
                next += try decodeDocument(payload).revision.parentIDs
            }
            queue = next
        }
        return seen
    }

    /// Internal service boundary for pure portable metadata. Content staging,
    /// native operations and their recovery journal are separate later APIs.
    /// `deviceMutation` runs in the same transaction, for commands whose intent
    /// is portable but whose location is not — an attached folder, for example.
    /// Device state never becomes portable bytes because of it.
    func commitMetadata(
        expectedRevisionID: WorkspaceObjectID, idempotencyKey: WorkspaceObjectID,
        inputDigest: String, writerID: WorkspaceObjectID,
        deviceMutation: ((inout DeviceWorkspaceState) throws -> Void)? = nil,
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
            var device = current.device
            if let deviceMutation {
                try deviceMutation(&device)
                guard device.workspaceID == workspaceID, device.deviceID == current.device.deviceID else {
                    throw WorkspaceRevisionStoreError.wrongWorkspaceOrDevice
                }
            }
            try device.validateStructure(against: updated)
            let bytes = try WorkspaceDocumentCoding.encode(updated)
            let receipt = WorkspaceCommandReceipt(
                idempotencyKey: idempotencyKey, inputDigest: inputDigest,
                previousRevisionID: expectedRevisionID, committedRevisionID: updated.revision.id,
                affectedArtifactIDs: affected.sorted())
            try insertRevision(updated, bytes: bytes, database)
            if deviceMutation != nil {
                try run("UPDATE device_state SET payload = ? WHERE id = 1",
                    [.data(try WorkspaceDocumentCoding.encodeDeviceState(device))], database)
                guard sqlite3_changes(database) == 1 else { throw WorkspaceRevisionStoreError.corruptState }
            }
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

    /// One store, so a write needs no lease held against a second one.
    private func transaction<T>(write: Bool, _ body: (OpaquePointer) throws -> T) throws -> T {
        try databaseTransaction(write: write, body)
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
                try createOperationalSchema(database)
            } else if version == 1 && application == Self.databaseApplicationID,
                      case .version1To2 = upgrade {
                // Deliberate additive upgrade; opening a v1 store normally does
                // not modify it. Old v1 connections refuse writes after this.
                try validateIdentity(database)
                _ = try readSnapshot(database)
                try createOperationalSchema(database)
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

    /// What this device did, and what an agent has asked it to do.
    ///
    /// These are device-local operational records, not portable intent: a
    /// receipt describes something that happened on this Mac, and a queued
    /// request is waiting for this person. Neither belongs in the portable
    /// document, which is why `DeviceWorkspaceState` reserved `receiptIDs` and
    /// `pendingPlanIDs` for them from the start. This is where their bodies
    /// live.
    ///
    /// Receipts are append-only and immutable for the same reason revisions
    /// are: a record of what happened is worth nothing if it can be edited
    /// afterwards. The queue and the journal are mutable — a request is
    /// answered and a journal is trimmed.
    private func createOperationalSchema(_ database: OpaquePointer) throws {
        try execute("""
            CREATE TABLE operation_receipts(id TEXT PRIMARY KEY NOT NULL, created_at REAL NOT NULL, payload BLOB NOT NULL);
            CREATE INDEX operation_receipts_recent ON operation_receipts(created_at DESC);
            CREATE TRIGGER operation_receipts_immutable_update BEFORE UPDATE ON operation_receipts
                BEGIN SELECT RAISE(ABORT, 'Receipts are immutable'); END;
            CREATE TABLE pending_requests(id INTEGER PRIMARY KEY CHECK(id = 1), payload BLOB NOT NULL);
            CREATE TABLE activity_journal(id INTEGER PRIMARY KEY CHECK(id = 1), payload BLOB NOT NULL);
            CREATE TABLE request_drafts(id TEXT PRIMARY KEY NOT NULL, payload BLOB NOT NULL);
            CREATE TABLE managed_installs(id INTEGER PRIMARY KEY CHECK(id = 1), payload BLOB NOT NULL);
            PRAGMA user_version = \(Self.storeFormatVersion);
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

    private enum SQLValue { case text(String), data(Data), integer(Int64), double(Double) }

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
                case .integer(let value):
                    status = sqlite3_bind_int64(statement, Int32(index + 1), value)
                case .double(let value):
                    status = sqlite3_bind_double(statement, Int32(index + 1), value)
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
        try scalar(sql, [], database)
    }

    private func scalar(_ sql: String, _ values: [SQLValue], _ database: OpaquePointer) throws -> Int32 {
        let statement = try prepare(sql, values, database)
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
