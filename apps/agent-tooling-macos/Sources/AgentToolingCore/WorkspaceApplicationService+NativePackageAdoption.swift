import Foundation

extension WorkspaceApplicationService {
    /// Records a catalog listing as an item in this library.
    ///
    /// One metadata write, in the same transaction and under the same head
    /// check as every other command here. It contacts no catalog, runs no
    /// client tool, writes no file a client owns and touches no device state.
    ///
    /// The receipt records that the library changed. It says nothing about
    /// installation, and a screen must not present it as one: after this lands,
    /// the row's next step is assignment, and installing is a third act after
    /// that.
    ///
    /// Replaying the exact command returns its original receipt, because the
    /// store resolves a repeated idempotency key before it reads the head. A
    /// *second* adoption of the same package under a new key is refused by
    /// name rather than duplicated.
    public func adoptNativePackage(
        _ command: NativePackageAdoptionCommand
    ) throws -> WorkspaceCommandReceipt {
        try Task.checkCancellation()
        return try store.commitMetadata(
            expectedRevisionID: command.expectedRevisionID,
            idempotencyKey: command.idempotencyKey,
            inputDigest: command.inputDigest(),
            writerID: writerID
        ) { document in
            try command.apply(to: &document)
        }
    }
}
