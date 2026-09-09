import Foundation

public enum WorkspaceAuthorityServiceError: LocalizedError, Equatable, Sendable {
    case alreadySelected, notVersioned, wrongTarget, needsReconciliation, invalidSelection

    public var errorDescription: String? {
        switch self {
        case .alreadySelected: "A workspace has already been selected. Refresh before choosing again."
        case .notVersioned: "The new workspace is not currently selected."
        case .wrongTarget: "The reviewed workspace does not match this migration."
        case .needsReconciliation: "This workspace has later changes. Reconcile them before selecting it again."
        case .invalidSelection: "The saved workspace choice does not match this review."
        }
    }
}

/// Trusted local authority selection, deliberately absent from the MCP operator.
/// It never initializes a migration or deploys content to a native client.
public actor WorkspaceAuthorityService {
    private let registry: WorkspaceAuthorityStore
    private let store: WorkspaceRevisionStore
    private let migration: WorkspaceMigrationService
    private let legacyDatabase: URL
    private let containerRoot: URL

    public init(legacyRoot: URL, store: WorkspaceRevisionStore,
                checkpoints: WorkspaceLegacyCheckpointStore, content: CentralPackageContentStore) throws {
        registry = try WorkspaceAuthorityStore(legacyRoot: legacyRoot)
        self.store = store
        migration = WorkspaceMigrationService(store: store, checkpoints: checkpoints, content: content)
        legacyDatabase = legacyRoot.appending(path: "agent-tooling.sqlite")
        containerRoot = store.databaseURL.deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
    }

    /// Only the reviewed initial migration can be activated by this first-cutover
    /// command. Returning after rollback requires explicit reconciliation later.
    public func prepareActivation(attemptID: WorkspaceObjectID) async throws -> WorkspaceAuthoritySelection {
        try Task.checkCancellation()
        if let current = try registry.read() {
            throw current.choice == .legacy ? WorkspaceAuthorityServiceError.needsReconciliation : .alreadySelected
        }
        let entry = try await migration.validateForActivation(attemptID: attemptID)
        try validate(entry: entry)
        guard let snapshot = try store.snapshot() else { throw WorkspaceRevisionStoreError.notInitialized }
        guard snapshot.document.revision.id == entry.record.manifest.initialRevisionID else {
            throw WorkspaceAuthorityServiceError.needsReconciliation
        }
        return WorkspaceAuthoritySelection(id: WorkspaceObjectID(), previousID: nil, choice: .versioned,
            target: target(attemptID: attemptID), checkpointSHA256: entry.record.manifest.checkpointSHA256,
            versionedRevisionID: snapshot.document.revision.id, selectedAt: Date())
    }

    /// Rollback means opening the retained legacy store. Both stores' later
    /// revisions remain intact; the checkpoint archive is never restored here.
    public func prepareRollback() async throws -> WorkspaceAuthoritySelection {
        try Task.checkCancellation()
        guard let current = try registry.read(), current.choice == .versioned else {
            throw WorkspaceAuthorityServiceError.notVersioned
        }
        try validate(target: current.target)
        guard let entry = try store.migration(current.target.attemptID), entry.phase == .initialized else {
            throw WorkspaceMigrationError.missingPreparation
        }
        try validate(entry: entry)
        let checkpoint = try await WorkspaceLegacyCheckpoint.capture(databaseURL: legacyDatabase)
        guard let snapshot = try store.snapshot() else { throw WorkspaceRevisionStoreError.notInitialized }
        return WorkspaceAuthoritySelection(id: WorkspaceObjectID(), previousID: current.id, choice: .legacy,
            target: current.target, checkpointSHA256: checkpoint.sha256,
            versionedRevisionID: snapshot.document.revision.id, selectedAt: Date())
    }

    public func apply(_ selection: WorkspaceAuthoritySelection) async throws -> WorkspaceAuthoritySelection {
        try Task.checkCancellation()
        if let receipt = try registry.lookup(selection.id) {
            guard receipt == selection else { throw WorkspaceAuthorityServiceError.invalidSelection }
            return receipt
        }
        try validate(target: selection.target)
        if selection.choice == .versioned {
            guard selection.previousID == nil else { throw WorkspaceAuthorityServiceError.needsReconciliation }
            let entry = try await migration.validateForActivation(attemptID: selection.target.attemptID)
            try validate(entry: entry)
            guard entry.record.manifest.checkpointSHA256 == selection.checkpointSHA256,
                  entry.record.manifest.initialRevisionID == selection.versionedRevisionID else {
                throw WorkspaceAuthorityServiceError.invalidSelection
            }
        }
        try Task.checkCancellation()
        return try registry.withExclusiveAccess { authority in
            // Recheck replay and current authority under the interprocess lock.
            if let receipt = authority.lookup(selection.id) {
                guard receipt == selection else { throw WorkspaceAuthorityServiceError.invalidSelection }
                return receipt
            }
            let current = authority.read()
            switch selection.choice {
            case .versioned:
                guard current == nil else { throw WorkspaceAuthorityServiceError.alreadySelected }
            case .legacy:
                guard let current, current.choice == .versioned,
                      current.id == selection.previousID, current.target == selection.target else {
                    throw WorkspaceAuthorityServiceError.invalidSelection
                }
            }
            return try store.withAuthoritySelectionSnapshot(
                expectedRevisionID: selection.versionedRevisionID, attemptID: selection.target.attemptID
            ) { _, entry in
                try validate(entry: entry)
                return try WorkspaceLegacyCheckpoint.withWriteBarrier(databaseURL: legacyDatabase) {
                    let checkpoint = try WorkspaceLegacyCheckpoint.captureSynchronously(databaseURL: legacyDatabase)
                    guard checkpoint.sha256 == selection.checkpointSHA256 else {
                        throw WorkspaceMigrationError.changedLegacyStore
                    }
                    try Task.checkCancellation()
                    return try authority.commit(selection, expectedSelectionID: selection.previousID)
                }
            }
        }
    }

    private func target(attemptID: WorkspaceObjectID) -> WorkspaceAuthorityTarget {
        WorkspaceAuthorityTarget(containerRootPath: containerRoot.path, workspaceID: store.workspaceID,
                                 deviceID: store.deviceID, attemptID: attemptID)
    }

    private func validate(target: WorkspaceAuthorityTarget) throws {
        guard target.workspaceID == store.workspaceID, target.deviceID == store.deviceID,
              Self.samePath(URL(fileURLWithPath: target.containerRootPath), containerRoot) else {
            throw WorkspaceAuthorityServiceError.wrongTarget
        }
    }

    private func validate(entry: WorkspaceMigrationJournalEntry) throws {
        let manifest = entry.record.manifest
        guard entry.phase == .initialized, manifest.workspaceID == store.workspaceID,
              manifest.deviceID == store.deviceID,
              Self.samePath(URL(fileURLWithPath: manifest.legacyDatabasePath), legacyDatabase) else {
            throw WorkspaceAuthorityServiceError.wrongTarget
        }
    }

    private static func samePath(_ lhs: URL, _ rhs: URL) -> Bool {
        lhs.standardizedFileURL.resolvingSymlinksInPath().path
            == rhs.standardizedFileURL.resolvingSymlinksInPath().path
    }
}
