import CryptoKit
import Foundation

/// Why a skill cannot start following a repository, in the words the screen
/// shows. Each one is a statement about this library's own records; none of
/// them says anything about the repository being reachable or correct.
public enum LinkSkillUpstreamRefusal: LocalizedError, Equatable, Sendable {
    /// The library's bytes are not the bytes the repository publishes.
    case contentDiffersFromUpstream
    case alreadyFollowingRepository
    case attachedAuthoring
    case bundled
    /// Native-owned, tracked, or anything else whose content lives elsewhere.
    case contentNotHeldHere
    case missingContent
    case sourceIdentityConflict
    case upstreamAlreadyManaged
    case reviewMismatch
    case identityCollision

    public var errorDescription: String? { reason }

    /// Shown verbatim. A screen must not paraphrase one of these: the two
    /// honest routes out of `contentDiffersFromUpstream` are named in it.
    public var reason: String {
        switch self {
        case .contentDiffersFromUpstream:
            "The version in your library is not the version this repository publishes. Review the repository's version as an update, or keep this skill as your own."
        case .alreadyFollowingRepository:
            "This skill already follows a repository."
        case .attachedAuthoring:
            "You author this folder yourself, so its own repository is where it is published from."
        case .bundled:
            "Bundled tools follow their package. Manage the whole package instead."
        case .contentNotHeldHere:
            "This library does not hold this skill's content, so it cannot follow a repository for it."
        case .missingContent:
            "This skill has no recorded content to compare with the repository."
        case .sourceIdentityConflict:
            "This workspace already records a different entry for that repository and branch. Use the one it has."
        case .upstreamAlreadyManaged:
            "Another skill in your library already follows that folder in that repository."
        case .reviewMismatch:
            "The repository changed while this was being reviewed. Check it again."
        case .identityCollision:
            "That identity is already used in this workspace."
        }
    }
}

/// Turns a skill this library holds as the person's own into one that follows a
/// published repository.
///
/// It is a statement about where the *next* version comes from, never a new
/// version: no content is published, and the artifact's `contentDigest` does not
/// move. That is only representable because the library's bytes already are the
/// publisher's bytes — `centralUpstream` means the approved central tree
/// supplies deployments, so a lock describing bytes this library does not hold
/// would make every later update diff against a fiction. A skill with local
/// edits is therefore refused, and nothing is done to those edits.
///
/// Portable review payload only: the command carries no file bytes and no path
/// on this Mac. Apply supplies the immutable preparation it was built from.
public struct LinkSkillUpstreamCommand: Codable, Equatable, Sendable {
    public let expectedRevisionID: WorkspaceObjectID
    public let idempotencyKey: WorkspaceObjectID
    public let artifactID: ArtifactID
    /// The digest the library holds for this skill, as the reviewer saw it.
    public let expectedContentDigest: ContentDigest
    public let upstreamIDs: StandaloneSkillUpstreamIDs
    public let content: StandaloneSkillContentReview

    /// Refuses a preparation that is not this skill's own bytes, and one that
    /// did not come from a repository at all. Building the command is where a
    /// fetch is refused; applying it is where the library is.
    public init(
        expectedRevisionID: WorkspaceObjectID, idempotencyKey: WorkspaceObjectID = WorkspaceObjectID(),
        artifactID: ArtifactID, expectedContentDigest: ContentDigest, prepared: PreparedStandaloneSkill,
        upstreamIDs: StandaloneSkillUpstreamIDs = .init()
    ) throws {
        guard prepared.review.upstream != nil else { throw LinkSkillUpstreamRefusal.reviewMismatch }
        guard prepared.review.contentDigest == expectedContentDigest else {
            throw LinkSkillUpstreamRefusal.contentDiffersFromUpstream
        }
        self.expectedRevisionID = expectedRevisionID
        self.idempotencyKey = idempotencyKey
        self.artifactID = artifactID
        self.expectedContentDigest = expectedContentDigest
        self.upstreamIDs = upstreamIDs
        self.content = prepared.review
    }

    func inputDigest() throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        // Domain separation, so a later command with a similar payload cannot
        // share an idempotency identity with this one.
        var bytes = Data("agent-tooling.link-skill-upstream.v1\n".utf8)
        bytes.append(try encoder.encode(self))
        guard bytes.count <= WorkspaceDocumentCoding.maximumDocumentBytes else {
            throw WorkspaceRevisionStoreError.recordTooLarge
        }
        return SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
    }

    /// Writes the publisher source, the subscription and its lock, and moves the
    /// artifact's authority. Nothing else about the artifact is touched: its
    /// display name, aliases, declared name, content digest and every saved
    /// assignment survive, because none of them is what linking decides.
    func apply(to document: inout PortableWorkspaceDocument) throws -> [ArtifactID] {
        guard let index = document.artifacts.firstIndex(where: { $0.identity.id == artifactID }) else {
            throw WorkspaceRevisionStoreError.missingArtifact
        }
        let artifact = document.artifacts[index]
        try Self.requireLinkable(artifact)
        // A decoded command never reaches the initializer, so the two facts it
        // established are re-established here rather than assumed.
        guard let upstream = content.upstream else { throw LinkSkillUpstreamRefusal.reviewMismatch }
        guard content.contentDigest == expectedContentDigest,
            artifact.contentDigest == expectedContentDigest
        else { throw LinkSkillUpstreamRefusal.contentDiffersFromUpstream }

        try requireFreeIdentities(in: document)
        // Recognized source roots are shared explicitly. A second identity for
        // one repository and ref is refused rather than manufactured, exactly
        // as standalone intake refuses it.
        guard
            !document.sources.contains(where: {
                $0.role == .publisherRepository && $0.repositoryURL == upstream.repositoryURL
                    && $0.requestedRef == upstream.requestedRef && $0.id != upstreamIDs.sourceID
            })
        else { throw LinkSkillUpstreamRefusal.sourceIdentityConflict }
        guard
            !document.subscriptions.contains(where: {
                $0.sourceID == upstreamIDs.sourceID && $0.lock.packageRelativePath == upstream.packageRelativePath
            })
        else { throw LinkSkillUpstreamRefusal.upstreamAlreadyManaged }

        if let existing = document.sources.firstIndex(where: { $0.id == upstreamIDs.sourceID }) {
            let source = document.sources[existing]
            guard source.role == .publisherRepository, source.repositoryURL == upstream.repositoryURL,
                source.requestedRef == upstream.requestedRef
            else { throw LinkSkillUpstreamRefusal.sourceIdentityConflict }
            if !source.packageRelativePaths.contains(upstream.packageRelativePath) {
                document.sources[existing].packageRelativePaths.append(upstream.packageRelativePath)
            }
        } else {
            document.sources.append(
                .init(
                    id: upstreamIDs.sourceID, role: .publisherRepository,
                    repositoryURL: upstream.repositoryURL, requestedRef: upstream.requestedRef,
                    packageRelativePaths: [upstream.packageRelativePath]))
        }
        // The lock approves the bytes the library already holds. The fetched
        // commit is recorded as the revision those bytes were seen at.
        document.subscriptions.append(
            .init(
                id: upstreamIDs.subscriptionID, artifactID: artifactID, sourceID: upstreamIDs.sourceID,
                lock: .init(
                    publisherID: upstream.publisherID, sourceRootID: upstreamIDs.sourceID,
                    requestedRef: upstream.requestedRef, approvedRevision: upstream.revision,
                    approvedContent: expectedContentDigest,
                    packageRelativePath: upstream.packageRelativePath)))
        document.artifacts[index].authority = .centralUpstream(subscriptionID: upstreamIDs.subscriptionID)
        return [artifactID]
    }

    /// One reason per ownership, because a person who cannot link this skill is
    /// owed the particular reason rather than a single refusal for five of them.
    /// The rule itself is still `requireCentralStandaloneSkill`'s.
    private static func requireLinkable(_ artifact: ArtifactRecord) throws {
        guard artifact.identity.parentPackageID == nil else { throw LinkSkillUpstreamRefusal.bundled }
        switch artifact.authority {
        case .centralPersonal: break
        case .centralUpstream: throw LinkSkillUpstreamRefusal.alreadyFollowingRepository
        case .attachedAuthoring: throw LinkSkillUpstreamRefusal.attachedAuthoring
        case .nativeOwned, .trackedOnly: throw LinkSkillUpstreamRefusal.contentNotHeldHere
        }
        do {
            try requireCentralStandaloneSkill(artifact)
        } catch WorkspaceSkillCommandError.missingContent {
            throw LinkSkillUpstreamRefusal.missingContent
        } catch {
            throw LinkSkillUpstreamRefusal.contentNotHeldHere
        }
    }

    /// A source and a subscription are workspace objects in the same namespace
    /// as an artifact and a tombstone. Neither may land on an identity anything
    /// else already holds.
    private func requireFreeIdentities(in document: PortableWorkspaceDocument) throws {
        let allocated = [upstreamIDs.sourceID.rawValue, upstreamIDs.subscriptionID.rawValue]
        guard upstreamIDs.sourceID != upstreamIDs.subscriptionID,
            !allocated.contains(artifactID.rawValue),
            !document.artifacts.contains(where: { allocated.contains($0.identity.id.rawValue) }),
            !document.tombstones.contains(where: { allocated.contains($0.artifactID.rawValue) }),
            !document.subscriptions.contains(where: {
                $0.id == upstreamIDs.subscriptionID || $0.id == upstreamIDs.sourceID
            }),
            !document.sources.contains(where: { $0.id == upstreamIDs.subscriptionID })
        else { throw LinkSkillUpstreamRefusal.identityCollision }
    }
}
