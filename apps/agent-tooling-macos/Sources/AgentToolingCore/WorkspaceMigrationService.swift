import Foundation

/// Trusted local migration staging. Not exposed through the request-only MCP.
/// App activation is a separate gate after native parity and read-model integration.
public actor WorkspaceMigrationService {
    private let store: WorkspaceRevisionStore
    private let checkpoints: WorkspaceLegacyCheckpointStore
    private let content: CentralPackageContentStore

    public init(store: WorkspaceRevisionStore, checkpoints: WorkspaceLegacyCheckpointStore, content: CentralPackageContentStore) {
        self.store = store
        self.checkpoints = checkpoints
        self.content = content
    }

    public func preparation(_ attemptID: WorkspaceObjectID) throws -> WorkspaceMigrationJournalEntry? {
        try store.migration(attemptID)
    }

    public func journal() throws -> [WorkspaceMigrationJournalEntry] {
        try store.migrationJournal()
    }

    /// Publish immutable prerequisites before the prepared record. A crash can
    /// leave unreferenced objects, never a journal entry claiming absent content.
    public func stage(_ preparation: WorkspaceMigrationPreparation) async throws -> WorkspaceMigrationJournalEntry {
        try Task.checkCancellation()
        let record = preparation.record
        try record.validate()
        if let previous = try store.preflightMigration(record) {
            try await verifyDurableInputs(previous.record)
            return previous
        }
        try await verifyFreshInputs(record)
        _ = try await checkpoints.save(preparation.checkpoint)
        var published = Set<ContentDigest>()
        for reference in record.manifest.content {
            try Task.checkCancellation()
            guard let tree = preparation.content[reference.artifactID], tree.digest == reference.digest else {
                throw WorkspaceMigrationError.missingContent
            }
            if published.insert(reference.digest).inserted { _ = try await content.store(tree) }
        }
        // Publication may take time. Ordinary source/database edits during it
        // require a new review instead of silently changing the prepared input.
        try await verifyFreshInputs(record)
        try Task.checkCancellation()
        return try store.prepareMigration(record)
    }

    /// Resumes using durable review inputs, without keeping the original preview
    /// alive. Head, device and completion marker commit in one SQLite transaction.
    public func initialize(attemptID: WorkspaceObjectID, inputDigest: String) async throws -> WorkspaceMigrationJournalEntry {
        try Task.checkCancellation()
        guard let entry = try store.migration(attemptID) else { throw WorkspaceMigrationError.missingPreparation }
        guard try entry.record.inputDigest == inputDigest else { throw WorkspaceMigrationError.preparationConflict }
        try await verifyDurableInputs(entry.record)
        // Completed replay is historical. Later legacy/source edits and newer
        // revision heads remain untouched; they do not trigger a second import.
        if entry.phase == .initialized { return entry }
        try await verifyFreshInputs(entry.record)
        try Task.checkCancellation()
        return try store.initializeMigration(attemptID: attemptID, inputDigest: inputDigest)
    }

    /// Authority selection must verify the initialized review again. Initialization
    /// replay alone is historical and deliberately does not perform this check.
    func validateForActivation(attemptID: WorkspaceObjectID) async throws -> WorkspaceMigrationJournalEntry {
        guard let entry = try store.migration(attemptID), entry.phase == .initialized else {
            throw WorkspaceMigrationError.missingPreparation
        }
        try await verifyDurableInputs(entry.record)
        try await verifyFreshInputs(entry.record)
        return entry
    }

    private func verifyDurableInputs(_ record: WorkspaceMigrationRecord) async throws {
        _ = try await checkpoints.read(record.manifest.checkpointSHA256)
        var checked = Set<ContentDigest>()
        for reference in record.manifest.content where checked.insert(reference.digest).inserted {
            try Task.checkCancellation()
            let tree = try await content.read(reference.digest)
            guard tree.digest == reference.digest else { throw WorkspaceMigrationError.missingContent }
        }
    }

    private func verifyFreshInputs(_ record: WorkspaceMigrationRecord) async throws {
        for source in record.manifest.sourceCaptures {
            try Task.checkCancellation()
            let tree = try await PackageTreeCapture().capture(directory: URL(fileURLWithPath: source.directoryPath))
            guard record.manifest.content.first(where: { $0.artifactID == source.artifactID })?.digest == tree.digest else {
                throw WorkspaceMigrationError.changedSource(source.artifactID)
            }
        }
        let current = try await WorkspaceLegacyCheckpoint.capture(databaseURL: URL(fileURLWithPath: record.manifest.legacyDatabasePath))
        guard current.sha256 == record.manifest.checkpointSHA256 else { throw WorkspaceMigrationError.changedLegacyStore }
        // These checks are bounded observations, not a lock across independently
        // mutable sources and the old writer. No app/native authority is switched.
    }
}
