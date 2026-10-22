import Foundation

extension WorkspaceApplicationService {
    /// Atomically records the connection, device-local helper binding and requested
    /// apps. Recomputes against a moved head for up to three attempts. The receipt
    /// records library intent; only the subsequent reviewed plan registers clients.
    public func connectAgentTooling(_ command: ConnectAgentToolingCommand) throws -> WorkspaceCommandReceipt {
        try Task.checkCancellation()
        var head = command.expectedRevisionID
        var attempt = 1
        while true {
            do {
                return try commitConnection(command, at: head)
            } catch WorkspaceRevisionStoreError.staleRevision(let current) where attempt < 3 {
                attempt += 1
                head = current
            }
        }
    }

    private func commitConnection(_ command: ConnectAgentToolingCommand, at head: WorkspaceObjectID) throws
        -> WorkspaceCommandReceipt
    {
        let deviceID = store.deviceID
        var connection: ArtifactID?
        return try store.commitMetadata(
            expectedRevisionID: head, idempotencyKey: command.idempotencyKey, inputDigest: command.inputDigest(),
            writerID: writerID,
            deviceMutation: { device in try command.bind(&device, connection: connection) },
            mutation: { document in
                connection = try command.apply(to: &document, deviceID: deviceID)
                return connection.map { [$0] } ?? []
            })
    }
}
