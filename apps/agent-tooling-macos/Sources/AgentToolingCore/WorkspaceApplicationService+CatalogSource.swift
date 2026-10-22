import Foundation

extension WorkspaceApplicationService {
    /// Changes the catalog-source record and identity allocation atomically,
    /// together with this device's folder binding. Both portable records must
    /// remain consistent for document validation. This registers a location
    /// only; catalog reads, package fetches and installation happen separately.
    public func changeCatalogSource(
        _ command: WorkspaceCatalogSourceCommand
    ) throws -> WorkspaceCommandReceipt {
        var context = CatalogSourceCommandContext()
        return try store.commitMetadata(
            expectedRevisionID: command.expectedRevisionID,
            idempotencyKey: command.idempotencyKey,
            inputDigest: command.inputDigest(),
            writerID: writerID,
            deviceMutation: { try command.bind(&$0, context: context) },
            mutation: { try command.apply(to: &$0, context: &context) })
    }
}
