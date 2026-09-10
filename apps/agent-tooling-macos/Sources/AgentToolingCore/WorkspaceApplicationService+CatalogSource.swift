import Foundation

extension WorkspaceApplicationService {
    /// Adds a catalog to the list this workspace records, or takes one off it.
    ///
    /// Both halves of a catalog source move in one transaction: the record and
    /// its identity-map allocation portably, this Mac's folder row locally. The
    /// document refuses a record without an allocation and refuses an
    /// allocation whose object is gone, so a command that wrote one without the
    /// other would roll back rather than leave a workspace that cannot be
    /// opened.
    ///
    /// This changes where this app will look. It reads no catalog, fetches no
    /// package and installs nothing, and the receipt names no artifact —
    /// a catalog source is a workspace object, not a library item.
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
