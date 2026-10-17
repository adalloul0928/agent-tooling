import Foundation

extension WorkspaceApplicationService {
    /// Records a new preset — a named set of library items — in one transaction.
    ///
    /// The artifact and the preset record are written together because the
    /// document permits neither without the other: a `PresetRecord` must name a
    /// live `.preset` artifact, and that artifact exists only to be named. The
    /// receipt records that the preset now exists; it asserts nothing about its
    /// members being in place, which is the separate act of following it.
    public func createPreset(_ command: CreatePresetCommand) throws -> WorkspaceCommandReceipt {
        try Task.checkCancellation()
        return try store.commitMetadata(
            expectedRevisionID: command.expectedRevisionID,
            idempotencyKey: command.idempotencyKey,
            inputDigest: command.inputDigest(),
            writerID: writerID,
            mutation: { try command.apply(to: &$0) })
    }

    /// Changes a preset's name only. Its identity, revision and members are
    /// untouched, so following Macs see a renamed preset rather than a new one.
    public func renamePreset(_ command: RenamePresetCommand) throws -> WorkspaceCommandReceipt {
        try Task.checkCancellation()
        return try store.commitMetadata(
            expectedRevisionID: command.expectedRevisionID,
            idempotencyKey: command.idempotencyKey,
            inputDigest: command.inputDigest(),
            writerID: writerID,
            mutation: { try command.apply(to: &$0) })
    }

    /// Removes a preset and only the assignments it alone produced. The
    /// members stay wherever they already are.
    public func deletePreset(_ command: DeletePresetCommand) throws -> WorkspaceCommandReceipt {
        try Task.checkCancellation()
        return try store.commitMetadata(
            expectedRevisionID: command.expectedRevisionID,
            idempotencyKey: command.idempotencyKey,
            inputDigest: command.inputDigest(),
            writerID: writerID,
            mutation: { try command.apply(to: &$0) })
    }
}
