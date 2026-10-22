import Foundation

extension WorkspaceApplicationService {
    /// Records a catalog item in one head-checked transaction without contacting
    /// clients or changing device state. The receipt confirms library adoption,
    /// not installation. Exact idempotency-key replay returns the original
    /// receipt; duplicate adoption under a new key is refused.
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
