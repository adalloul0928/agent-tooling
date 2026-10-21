import Foundation

extension WorkspaceApplicationService {
    /// How many times a batch of additions tries again when another writer
    /// moved the library on underneath it.
    static let libraryAdditionRetries = 3

    /// The rows of `batch` the library would refuse now, each with its
    /// reason, in the order the rows apply. Reads only.
    ///
    /// Each row is tried against the library as the rows before it leave it,
    /// so two rows adding the same listing name the second one.
    public func previewLibraryAdditions(
        _ batch: WorkspaceLibraryAdditionBatch, prepared: [ArtifactID: PreparedStandaloneSkill]
    ) throws -> [LibraryAdditionRefusal] {
        try Task.checkCancellation()
        guard let snapshot = try store.snapshot() else { throw WorkspaceRevisionStoreError.notInitialized }
        var document = snapshot.document
        var refusals: [LibraryAdditionRefusal] = []
        _ = batch.apply(to: &document, prepared: prepared, refusals: &refusals)
        return refusals
    }

    /// Publishes skill content before committing accepted rows in one revision.
    /// Refused rows may leave unreferenced content; an entirely refused batch raises
    /// `nothingToAdd`. Head conflicts retry up to three times with fresh transaction
    /// keys, while resubmitting a completed batch returns its receipt. This changes
    /// only the library and content store, without client writes or network calls.
    public func applyLibraryAdditions(
        _ batch: WorkspaceLibraryAdditionBatch, prepared: [ArtifactID: PreparedStandaloneSkill]
    ) async throws -> WorkspaceCommandReceipt {
        try await applyLibraryAdditions(batch, prepared: prepared, beforeCommit: nil)
    }

    /// The same, with `beforeCommit` run after the content is published and
    /// before each attempt writes, for a test to see the order or to move the
    /// library on underneath an attempt.
    func applyLibraryAdditions(
        _ batch: WorkspaceLibraryAdditionBatch, prepared: [ArtifactID: PreparedStandaloneSkill],
        beforeCommit: (@Sendable (_ attempt: Int) async throws -> Void)?
    ) async throws -> WorkspaceCommandReceipt {
        try Task.checkCancellation()
        guard !batch.isEmpty else { throw LibraryAdditionError.nothingToAdd([]) }
        var head = batch.expectedRevisionID
        var published = false
        var attempt = 0
        while true {
            let key = batch.idempotencyKey(forAttempt: attempt)
            let digest = try batch.inputDigest(prepared: prepared, attempt: attempt)
            do {
                let replay: WorkspaceCommandReceipt?
                do {
                    replay = try store.preflightMetadata(
                        expectedRevisionID: head, idempotencyKey: key, inputDigest: digest,
                        mutation: { try batch.landing(in: &$0, prepared: prepared) })
                } catch LibraryAdditionError.nothingToAdd(let refusals) {
                    // Every row is refused against this head. When an earlier
                    // call already wrote this batch under a later attempt's
                    // key, that revision is the answer.
                    if let earlier = try laterReceipt(of: batch, prepared: prepared, after: attempt) { return earlier }
                    throw LibraryAdditionError.nothingToAdd(refusals)
                }
                if let replay { return replay }
                if !published {
                    try await publishSkills(of: batch, prepared: prepared)
                    published = true
                }
                try await beforeCommit?(attempt)
                return try store.commitMetadata(
                    expectedRevisionID: head, idempotencyKey: key, inputDigest: digest, writerID: writerID
                ) { document in
                    try Task.checkCancellation()
                    return try batch.landing(in: &document, prepared: prepared)
                }
            } catch WorkspaceRevisionStoreError.staleRevision(let current) where attempt < Self.libraryAdditionRetries {
                head = current
                attempt += 1
            }
        }
    }

    /// Publishes the files of every skill the batch takes in, each once.
    private func publishSkills(
        of batch: WorkspaceLibraryAdditionBatch, prepared: [ArtifactID: PreparedStandaloneSkill]
    ) async throws {
        var stored = Set<ContentDigest>()
        let rows = batch.adoptions.map(\.artifactID) + batch.intakes.map(\.artifactID)
        for artifactID in rows {
            guard let skill = prepared[artifactID], stored.insert(skill.review.contentDigest).inserted else { continue }
            try await publishReviewedSkill(skill)
        }
    }

    /// The receipt a later attempt of `batch` left, if one did.
    private func laterReceipt(
        of batch: WorkspaceLibraryAdditionBatch, prepared: [ArtifactID: PreparedStandaloneSkill], after attempt: Int
    ) throws -> WorkspaceCommandReceipt? {
        guard attempt < Self.libraryAdditionRetries, let head = try store.snapshot()?.document.revision.id else { return nil }
        for later in (attempt + 1)...Self.libraryAdditionRetries {
            // The store answers a known key before it looks at the head, so a
            // read with a change that changes nothing finds the receipt, or
            // finds that there is none.
            if let receipt = try? store.preflightMetadata(
                expectedRevisionID: head, idempotencyKey: batch.idempotencyKey(forAttempt: later),
                inputDigest: try batch.inputDigest(prepared: prepared, attempt: later), mutation: { _ in [] })
            {
                return receipt
            }
        }
        return nil
    }
}
