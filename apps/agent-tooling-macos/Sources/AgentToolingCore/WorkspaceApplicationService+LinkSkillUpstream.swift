import Foundation

extension WorkspaceApplicationService {
    /// Links a skill using its reviewed preparation without refetching.
    /// Rechecks that the workspace holds the approved bytes before recording
    /// the upstream lock, ensuring deployments can use that content. The
    /// receipt records the link, not current repository availability.
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
