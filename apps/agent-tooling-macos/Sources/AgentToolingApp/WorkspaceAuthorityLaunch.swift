import AgentToolingCore
import Darwin
import Foundation

/// Resolves an explicitly persisted local authority choice. This is deliberately
/// narrower than the app launcher: it never discovers stores, creates paths, or
/// constructs the retained legacy AppModel.
struct WorkspaceAuthorityLaunch {
    @MainActor static func openSession(legacyRoot: URL) throws -> WorkspaceLibrarySession? {
        guard let selection = try selectedAuthority(legacyRoot: legacyRoot) else { return nil }
        let target = selection.target
        let store = try WorkspaceRevisionStore(
            containerRoot: URL(fileURLWithPath: target.containerRootPath, isDirectory: true),
            workspaceID: target.workspaceID,
            deviceID: target.deviceID,
            access: .existingReadOnly
        )
        try validateSelectedStore(store, selection: selection, legacyRoot: legacyRoot)
        return makeSession(store: store, selection: selection, access: .readOnly)
    }

    /// The only writable selected launch. `openSelected` binds every later
    /// revision-store write to the persisted versioned authority lease.
    @MainActor static func openWritableSession(legacyRoot: URL) throws -> WorkspaceLibrarySession? {
        guard let selection = try selectedAuthority(legacyRoot: legacyRoot) else { return nil }
        let store = try WorkspaceRevisionStore.openSelected(legacyRoot: legacyRoot, selection: selection)
        try validateSelectedStore(store, selection: selection, legacyRoot: legacyRoot)
        return makeSession(store: store, selection: selection, access: .writable)
    }

    private static func selectedAuthority(legacyRoot: URL) throws -> WorkspaceAuthoritySelection? {
        guard let selection = try WorkspaceAuthorityStore.readIfPresent(legacyRoot: legacyRoot) else { return nil }
        guard selection.choice == .versioned else { return nil }
        return selection
    }

    @MainActor private static func makeSession(
        store: WorkspaceRevisionStore, selection: WorkspaceAuthoritySelection, access: WorkspaceLibraryAccess
    ) -> WorkspaceLibrarySession {
        let service = WorkspaceApplicationService(store: store, writerID: WorkspaceObjectID())
        return WorkspaceLibrarySession(
            service: service,
            workspaceID: selection.target.workspaceID,
            deviceID: selection.target.deviceID,
            access: access
        )
    }

    private static func validateSelectedStore(
        _ store: WorkspaceRevisionStore, selection: WorkspaceAuthoritySelection, legacyRoot: URL
    ) throws {
        let target = selection.target
        guard let migration = try store.migration(target.attemptID), migration.phase == .initialized,
              migration.record.manifest.initialRevisionID == selection.versionedRevisionID,
              migration.record.manifest.checkpointSHA256 == selection.checkpointSHA256,
              try canonicalLegacyDatabasePath(migration.record.manifest.legacyDatabasePath)
                == (try canonicalLegacyDatabasePath(for: legacyRoot)),
              let snapshot = try store.snapshot(),
              snapshot.document.workspaceID == target.workspaceID,
              snapshot.device.workspaceID == target.workspaceID,
              snapshot.device.deviceID == target.deviceID,
              let selectedRevision = try store.revision(selection.versionedRevisionID),
              selectedRevision.workspaceID == target.workspaceID,
              selectedRevision.revision.id == selection.versionedRevisionID
        else {
            throw WorkspaceAuthorityLaunchError.invalidSelection
        }
    }

    private static func canonicalLegacyDatabasePath(for root: URL) throws -> String {
        guard root.isFileURL, root.path.hasPrefix("/") else {
            throw WorkspaceAuthorityLaunchError.invalidSelection
        }
        guard let canonicalRoot = realpath(root.path, nil) else {
            throw WorkspaceAuthorityLaunchError.invalidSelection
        }
        defer { free(canonicalRoot) }
        let rootPath = String(cString: canonicalRoot)
        let values = try URL(fileURLWithPath: rootPath, isDirectory: true).resourceValues(forKeys: [.isDirectoryKey])
        guard values.isDirectory == true else { throw WorkspaceAuthorityLaunchError.invalidSelection }
        return try canonicalLegacyDatabasePath(
            URL(fileURLWithPath: rootPath, isDirectory: true).appending(path: "agent-tooling.sqlite").path
        )
    }

    private static func canonicalLegacyDatabasePath(_ path: String) throws -> String {
        guard path.hasPrefix("/"), let canonical = realpath(path, nil) else {
            throw WorkspaceAuthorityLaunchError.invalidSelection
        }
        defer { free(canonical) }
        return String(cString: canonical)
    }
}

enum WorkspaceAuthorityLaunchError: LocalizedError, Equatable {
    case invalidSelection

    var errorDescription: String? {
        "The selected workspace authority could not be validated. The retained legacy library was not opened automatically."
    }
}
