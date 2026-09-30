import Foundation

/// Makes an unmanaged skill yours: the library takes a copy of the files it
/// found in an app's folder and the tracked-only record becomes a personal
/// one, keeping its id so every screen that pointed at it still does.
///
/// Nothing in the app's folder changes. The app's copy is now one this library
/// can compare with, place elsewhere, edit here, or remove separately.
public struct AdoptTrackedSkillCommand: Codable, Equatable, Sendable {
    public let expectedRevisionID: WorkspaceObjectID
    public let idempotencyKey: WorkspaceObjectID
    public let artifactID: ArtifactID
    public let content: StandaloneSkillContentReview

    public init(
        expectedRevisionID: WorkspaceObjectID, idempotencyKey: WorkspaceObjectID = WorkspaceObjectID(),
        artifactID: ArtifactID, prepared: PreparedStandaloneSkill
    ) {
        self.expectedRevisionID = expectedRevisionID
        self.idempotencyKey = idempotencyKey
        self.artifactID = artifactID
        self.content = prepared.review
    }

    func inputDigest() throws -> String { try skillCommandDigest(self, operation: "adopt") }

    func apply(to document: inout PortableWorkspaceDocument, declaredName: String) throws -> [ArtifactID] {
        guard let index = document.artifacts.firstIndex(where: { $0.identity.id == artifactID }) else {
            throw WorkspaceRevisionStoreError.missingArtifact
        }
        let artifact = document.artifacts[index]
        guard artifact.identity.kind == .skill else { throw WorkspaceSkillCommandError.unsupportedAuthority }
        // Only a tracked-only standalone skill can be adopted. One inside a
        // plugin belongs to the plugin; one already yours has nothing to adopt.
        guard artifact.authority == .trackedOnly, artifact.identity.parentPackageID == nil else {
            throw WorkspaceSkillCommandError.unsupportedAuthority
        }
        guard content.upstream == nil else { throw WorkspaceSkillCommandError.reviewMismatch }
        // The files on disk must be the skill the record is for. A folder that
        // declares another name is not this skill, and is refused.
        if let recorded = artifact.declaredName, recorded != declaredName {
            throw WorkspaceSkillCommandError.reviewMismatch
        }
        document.artifacts[index].authority = .centralPersonal
        document.artifacts[index].declaredName = declaredName
        document.artifacts[index].contentDigest = content.contentDigest
        return [artifactID]
    }
}

extension WorkspaceApplicationService {
    /// Adopts a tracked-only skill: its files are copied into the content
    /// store and the record becomes personal. Observations of where the app's
    /// copy lives are untouched, so the library now knows both that it holds
    /// the skill and where a copy of it is.
    public func adoptTrackedSkill(
        _ command: AdoptTrackedSkillCommand, prepared: PreparedStandaloneSkill
    ) async throws -> WorkspaceCommandReceipt {
        try Task.checkCancellation()
        guard command.content == prepared.review else { throw WorkspaceSkillCommandError.reviewMismatch }
        let digest = try command.inputDigest()
        if let replay = try store.preflightMetadata(
            expectedRevisionID: command.expectedRevisionID, idempotencyKey: command.idempotencyKey, inputDigest: digest,
            mutation: { try command.apply(to: &$0, declaredName: prepared.frontmatter.name) }
        ) { return replay }
        try await publishReviewedSkill(prepared)
        return try store.commitMetadata(
            expectedRevisionID: command.expectedRevisionID, idempotencyKey: command.idempotencyKey,
            inputDigest: digest, writerID: writerID
        ) { document in
            try Task.checkCancellation()
            return try command.apply(to: &document, declaredName: prepared.frontmatter.name)
        }
    }
}
