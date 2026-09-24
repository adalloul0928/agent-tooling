import Foundation

/// Binding a project to a folder on this Mac, and forgetting it.
///
/// Both go through `commitDeviceChange`, so the change is recorded in the same
/// transaction and under the same head check as everything else, and the
/// portable document is left exactly as it is — a project's folder is a fact
/// about this Mac, never a shared one.
extension WorkspaceApplicationService {
    /// Records that `projectID`'s folder on this Mac is `rootPath`, replacing
    /// any folder it was bound to before.
    ///
    /// The document is read once, under the head being committed, so the
    /// project-existence and folder-in-use checks run against the revision the
    /// binding lands on rather than one a view happened to be holding.
    @discardableResult
    public func bindProjectRoot(
        projectID: ArtifactID,
        rootPath: String,
        expectedRevisionID: WorkspaceObjectID,
        idempotencyKey: WorkspaceObjectID = WorkspaceObjectID()
    ) throws -> WorkspaceCommandReceipt {
        guard let document = try store.snapshot()?.document else {
            throw WorkspaceRevisionStoreError.notInitialized
        }
        return try commitDeviceChange(
            expectedRevisionID: expectedRevisionID, idempotencyKey: idempotencyKey
        ) { device in
            try WorkspaceProjectRootCommand.bind(
                projectID: projectID, rootPath: rootPath, document: document, into: &device)
        }
    }

    /// Removes `projectID`'s folder binding on this Mac. Nothing on disk is
    /// touched, and a project that had no binding is left unchanged.
    @discardableResult
    public func unbindProjectRoot(
        projectID: ArtifactID,
        expectedRevisionID: WorkspaceObjectID,
        idempotencyKey: WorkspaceObjectID = WorkspaceObjectID()
    ) throws -> WorkspaceCommandReceipt {
        try commitDeviceChange(
            expectedRevisionID: expectedRevisionID, idempotencyKey: idempotencyKey
        ) { device in
            WorkspaceProjectRootCommand.unbind(projectID: projectID, into: &device)
        }
    }
}
