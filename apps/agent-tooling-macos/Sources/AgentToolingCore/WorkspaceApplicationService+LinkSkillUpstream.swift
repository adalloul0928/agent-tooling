import Foundation

extension WorkspaceApplicationService {
    /// Records that a skill this library maintains now follows a repository.
    ///
    /// Nothing is fetched here and nothing is published: the preparation was
    /// fetched and reviewed before this call, and the service does not re-fetch
    /// between review and apply, so what was reviewed is what lands. The bytes
    /// the lock approves are the bytes this workspace already holds, which is
    /// why they are read back before the write — a lock this store cannot
    /// supply content for would be approved content nobody can deploy.
    ///
    /// The receipt records that the skill now follows a repository. It is not a
    /// claim that the repository is reachable now, and it fetches nothing later.
    public func linkSkillUpstream(
        _ command: LinkSkillUpstreamCommand, prepared: PreparedStandaloneSkill
    ) async throws -> WorkspaceCommandReceipt {
        try Task.checkCancellation()
        guard command.content == prepared.review else { throw LinkSkillUpstreamRefusal.reviewMismatch }
        let digest = try command.inputDigest()
        if let replay = try store.preflightMetadata(
            expectedRevisionID: command.expectedRevisionID, idempotencyKey: command.idempotencyKey,
            inputDigest: digest, mutation: { try command.apply(to: &$0) }
        ) {
            return replay
        }
        guard let contentStore else { throw WorkspaceSkillCommandError.contentStoreUnavailable }
        // The library's own copy, not the fetched one. Approving a lock over
        // content this store cannot read would leave every later update
        // diffing against something nobody can produce.
        _ = try await contentStore.read(command.expectedContentDigest)
        return try store.commitMetadata(
            expectedRevisionID: command.expectedRevisionID, idempotencyKey: command.idempotencyKey,
            inputDigest: digest, writerID: writerID
        ) { document in
            try Task.checkCancellation()
            return try command.apply(to: &document)
        }
    }
}
