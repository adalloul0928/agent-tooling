import CryptoKit
import Foundation

public enum WorkspaceSkillCommandError: Error, Equatable, Sendable {
    case contentStoreUnavailable, reviewMismatch, unsupportedAuthority, missingContent
    case identityCollision, sourceIdentityConflict, upstreamAlreadyManaged, upstreamBindingChanged
}

/// Allocate these once when reviewing intake, or reuse an existing source ID for
/// another skill in the same repository/ref. A subscription belongs to one root.
public struct StandaloneSkillUpstreamIDs: Codable, Equatable, Sendable {
    public let sourceID: WorkspaceObjectID
    public let subscriptionID: WorkspaceObjectID

    public init(sourceID: WorkspaceObjectID = WorkspaceObjectID(), subscriptionID: WorkspaceObjectID = WorkspaceObjectID()) {
        self.sourceID = sourceID
        self.subscriptionID = subscriptionID
    }
}

/// Portable review payload only: the command does not embed source paths or file
/// bytes. Apply supplies the immutable preparation whose digest/provenance match.
public struct StandaloneSkillIntakeCommand: Codable, Equatable, Sendable {
    public let expectedRevisionID: WorkspaceObjectID
    public let idempotencyKey: WorkspaceObjectID
    public let artifactID: ArtifactID
    public let displayName: String
    public let aliases: [ExternalAlias]
    public let content: StandaloneSkillContentReview
    public let upstreamIDs: StandaloneSkillUpstreamIDs?

    public init(
        expectedRevisionID: WorkspaceObjectID, idempotencyKey: WorkspaceObjectID = WorkspaceObjectID(),
        artifactID: ArtifactID = ArtifactID(), displayName: String, aliases: [ExternalAlias] = [],
        prepared: PreparedStandaloneSkill, upstreamIDs: StandaloneSkillUpstreamIDs? = nil
    ) {
        self.expectedRevisionID = expectedRevisionID
        self.idempotencyKey = idempotencyKey
        self.artifactID = artifactID
        self.displayName = displayName
        self.aliases = aliases
        self.content = prepared.review
        self.upstreamIDs = upstreamIDs
    }

    func inputDigest() throws -> String { try skillCommandDigest(self, operation: "intake") }

    func apply(to document: inout PortableWorkspaceDocument, declaredName: String) throws -> [ArtifactID] {
        guard !document.artifacts.contains(where: { $0.identity.id == artifactID }),
              !document.tombstones.contains(where: { $0.artifactID == artifactID }),
              !document.sources.contains(where: { $0.id.rawValue == artifactID.rawValue }),
              !document.subscriptions.contains(where: { $0.id.rawValue == artifactID.rawValue }) else {
            throw WorkspaceSkillCommandError.identityCollision
        }
        let authority: ContentAuthority
        switch (content.upstream, upstreamIDs) {
        case (nil, nil):
            authority = .centralPersonal
        case (.some(let upstream), .some(let ids)):
            guard ids.sourceID != ids.subscriptionID,
                  ids.sourceID.rawValue != artifactID.rawValue, ids.subscriptionID.rawValue != artifactID.rawValue,
                  !document.artifacts.contains(where: { [ids.sourceID.rawValue, ids.subscriptionID.rawValue].contains($0.identity.id.rawValue) }),
                  !document.tombstones.contains(where: { [ids.sourceID.rawValue, ids.subscriptionID.rawValue].contains($0.artifactID.rawValue) }),
                  !document.subscriptions.contains(where: { $0.id == ids.subscriptionID || $0.id == ids.sourceID }),
                  !document.sources.contains(where: { $0.id == ids.subscriptionID }) else {
                throw WorkspaceSkillCommandError.identityCollision
            }
            // Recognized source roots are shared explicitly. Do not manufacture
            // a second source identity for the same repository/ref on intake.
            guard !document.sources.contains(where: {
                $0.role == .publisherRepository && $0.repositoryURL == upstream.repositoryURL
                    && $0.requestedRef == upstream.requestedRef && $0.id != ids.sourceID
            }) else { throw WorkspaceSkillCommandError.sourceIdentityConflict }
            guard !document.subscriptions.contains(where: {
                $0.sourceID == ids.sourceID && $0.lock.packageRelativePath == upstream.packageRelativePath
            }) else { throw WorkspaceSkillCommandError.upstreamAlreadyManaged }
            if let index = document.sources.firstIndex(where: { $0.id == ids.sourceID }) {
                let source = document.sources[index]
                guard source.role == .publisherRepository, source.repositoryURL == upstream.repositoryURL,
                      source.requestedRef == upstream.requestedRef else {
                    throw WorkspaceSkillCommandError.sourceIdentityConflict
                }
                if !source.packageRelativePaths.contains(upstream.packageRelativePath) {
                    document.sources[index].packageRelativePaths.append(upstream.packageRelativePath)
                }
            } else {
                document.sources.append(.init(id: ids.sourceID, role: .publisherRepository,
                    repositoryURL: upstream.repositoryURL, requestedRef: upstream.requestedRef,
                    packageRelativePaths: [upstream.packageRelativePath]))
            }
            document.subscriptions.append(.init(id: ids.subscriptionID, artifactID: artifactID, sourceID: ids.sourceID,
                lock: .init(publisherID: upstream.publisherID, sourceRootID: ids.sourceID,
                    requestedRef: upstream.requestedRef, approvedRevision: upstream.revision,
                    approvedContent: content.contentDigest, packageRelativePath: upstream.packageRelativePath)))
            authority = .centralUpstream(subscriptionID: ids.subscriptionID)
        default:
            throw WorkspaceSkillCommandError.reviewMismatch
        }
        document.artifacts.append(.init(
            identity: .init(id: artifactID, kind: .skill, displayName: displayName, aliases: aliases),
            authority: authority, declaredName: declaredName, contentDigest: content.contentDigest))
        return [artifactID]
    }
}

/// Both personal edits and upstream updates retain the existing artifact and
/// assignments. Changing ownership/source, forking, or deploying is a separate action.
public struct StandaloneSkillUpdateCommand: Codable, Equatable, Sendable {
    public let expectedRevisionID: WorkspaceObjectID
    public let idempotencyKey: WorkspaceObjectID
    public let artifactID: ArtifactID
    public let expectedContentDigest: ContentDigest
    public let content: StandaloneSkillContentReview

    public init(
        expectedRevisionID: WorkspaceObjectID, idempotencyKey: WorkspaceObjectID = WorkspaceObjectID(),
        artifactID: ArtifactID, expectedContentDigest: ContentDigest, prepared: PreparedStandaloneSkill
    ) {
        self.expectedRevisionID = expectedRevisionID
        self.idempotencyKey = idempotencyKey
        self.artifactID = artifactID
        self.expectedContentDigest = expectedContentDigest
        self.content = prepared.review
    }

    func inputDigest() throws -> String { try skillCommandDigest(self, operation: "update") }

    func apply(to document: inout PortableWorkspaceDocument, declaredName: String) throws -> [ArtifactID] {
        guard let index = document.artifacts.firstIndex(where: { $0.identity.id == artifactID }) else {
            throw WorkspaceRevisionStoreError.missingArtifact
        }
        let artifact = document.artifacts[index]
        try requireCentralStandaloneSkill(artifact)
        guard artifact.contentDigest == expectedContentDigest else { throw WorkspaceSkillCommandError.reviewMismatch }
        switch (artifact.authority, content.upstream) {
        case (.centralPersonal, nil): break
        case (.centralUpstream(let subscriptionID), .some(let upstream)):
            guard let subscriptionIndex = document.subscriptions.firstIndex(where: { $0.id == subscriptionID }) else {
                throw WorkspaceSkillCommandError.upstreamBindingChanged
            }
            let subscription = document.subscriptions[subscriptionIndex]
            guard let source = document.sources.first(where: { $0.id == subscription.sourceID }),
                  subscription.artifactID == artifactID, source.role == .publisherRepository,
                  source.repositoryURL == upstream.repositoryURL, source.requestedRef == upstream.requestedRef,
                  subscription.lock.sourceRootID == source.id,
                  subscription.lock.requestedRef == upstream.requestedRef,
                  subscription.lock.packageRelativePath == upstream.packageRelativePath,
                  subscription.lock.publisherID == upstream.publisherID,
                  subscription.lock.approvedContent == expectedContentDigest else {
                throw WorkspaceSkillCommandError.upstreamBindingChanged
            }
            document.subscriptions[subscriptionIndex].lock.approvedRevision = upstream.revision
            document.subscriptions[subscriptionIndex].lock.approvedContent = content.contentDigest
        default:
            throw WorkspaceSkillCommandError.unsupportedAuthority
        }
        document.artifacts[index].declaredName = declaredName
        document.artifacts[index].contentDigest = content.contentDigest
        return [artifactID]
    }
}

public struct WorkspaceSkillContentSnapshot: Sendable {
    public let revisionID: WorkspaceObjectID
    public let artifact: ArtifactRecord
    public let tree: CapturedPackageTree
}

func requireCentralStandaloneSkill(_ artifact: ArtifactRecord) throws {
    guard artifact.identity.kind == .skill, artifact.identity.parentPackageID == nil, artifact.nativeRoutes.isEmpty else {
        throw WorkspaceSkillCommandError.unsupportedAuthority
    }
    switch artifact.authority {
    case .centralPersonal, .centralUpstream: break
    default: throw WorkspaceSkillCommandError.unsupportedAuthority
    }
    guard artifact.contentDigest != nil else { throw WorkspaceSkillCommandError.missingContent }
}

private func skillCommandDigest<T: Encodable>(_ command: T, operation: String) throws -> String {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    var bytes = Data("agent-tooling.standalone-skill-\(operation).v1\n".utf8)
    bytes.append(try encoder.encode(command))
    guard bytes.count <= WorkspaceDocumentCoding.maximumDocumentBytes else { throw WorkspaceRevisionStoreError.recordTooLarge }
    return SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
}
