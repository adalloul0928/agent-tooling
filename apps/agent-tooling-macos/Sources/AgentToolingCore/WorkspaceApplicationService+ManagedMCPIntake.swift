import Foundation

extension WorkspaceApplicationService {
    /// Records how one MCP connection is reached.
    ///
    /// The artifact, the shared definition and this Mac's binding are written
    /// in one transaction, because the document does not permit any two of them
    /// without the third: a standalone personal `mcpServer` artifact must have a
    /// definition, and a binding must have one too. A failure in either half
    /// leaves the workspace exactly as it was.
    ///
    /// The receipt records that a declaration exists. It asserts nothing about
    /// the server running, being reachable, or being authenticated.
    public func intakeManagedMCPServer(
        _ command: ManagedMCPServerIntakeCommand
    ) throws -> WorkspaceCommandReceipt {
        try Task.checkCancellation()
        return try store.commitMetadata(
            expectedRevisionID: command.expectedRevisionID,
            idempotencyKey: command.idempotencyKey,
            inputDigest: command.inputDigest(),
            writerID: writerID,
            deviceMutation: { try command.bind(&$0) },
            mutation: { try command.apply(to: &$0) })
    }
}
