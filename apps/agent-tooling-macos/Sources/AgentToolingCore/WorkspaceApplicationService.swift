import CryptoKit
import Foundation

/// A consistent portable/device snapshot read from one database transaction.
public struct WorkspaceApplicationSnapshot: Sendable, Equatable {
    public let document: PortableWorkspaceDocument
    public let device: DeviceWorkspaceState

    public init(document: PortableWorkspaceDocument, device: DeviceWorkspaceState) {
        self.document = document
        self.device = device
    }
}

/// Local metadata commands are distinct from install/update plans. This actor
/// is not an authorization boundary: MCP must continue to submit review
/// requests, not acquire an instance of the operator service.
public actor WorkspaceApplicationService: WorkspaceLibraryServing {
    private let store: WorkspaceRevisionStore
    private let writerID: WorkspaceObjectID
    private let contentStore: CentralPackageContentStore?

    public init(store: WorkspaceRevisionStore, writerID: WorkspaceObjectID, contentStore: CentralPackageContentStore? = nil) {
        self.store = store
        self.writerID = writerID
        self.contentStore = contentStore
    }

    public func snapshot() throws -> WorkspaceApplicationSnapshot? {
        try store.snapshot()
    }

    /// Validation and indexing run on the service actor, outside SwiftUI layout.
    public func libraryState() throws -> WorkspaceLibraryState {
        try Task.checkCancellation()
        guard let snapshot = try store.snapshot() else { throw WorkspaceRevisionStoreError.notInitialized }
        let state = try WorkspaceLibraryState(snapshot: snapshot)
        try Task.checkCancellation()
        return state
    }

    public func previewAssignmentBatch(_ command: WorkspaceAssignmentBatchCommand) throws -> WorkspaceAssignmentBatchPreview {
        guard let snapshot = try store.snapshot() else { throw WorkspaceRevisionStoreError.notInitialized }
        return try command.preview(document: snapshot.document)
    }

    /// Saves requested placements atomically. Installation/removal requires the
    /// separate native plan; a metadata receipt cannot report those postconditions.
    public func applyAssignmentBatch(_ command: WorkspaceAssignmentBatchCommand) throws -> WorkspaceCommandReceipt {
        try Task.checkCancellation()
        return try store.commitMetadata(expectedRevisionID: command.expectedRevisionID,
            idempotencyKey: command.idempotencyKey, inputDigest: command.inputDigest(), writerID: writerID) { document in
            try command.apply(to: &document)
        }
    }

    /// Reads one immutable revision and verifies its complete content object.
    /// An editor can replace selected entries in this tree, then prepare/apply a
    /// personal update; missing historical bytes never fall back to native files.
    public func skillContent(artifactID: ArtifactID, revisionID: WorkspaceObjectID) async throws -> WorkspaceSkillContentSnapshot {
        guard let contentStore else { throw WorkspaceSkillCommandError.contentStoreUnavailable }
        guard let document = try store.revision(revisionID),
              let artifact = document.artifacts.first(where: { $0.identity.id == artifactID }) else {
            throw WorkspaceRevisionStoreError.missingArtifact
        }
        try requireCentralStandaloneSkill(artifact)
        guard let digest = artifact.contentDigest else { throw WorkspaceSkillCommandError.missingContent }
        let tree = try await contentStore.read(digest)
        return .init(revisionID: revisionID, artifact: artifact, tree: tree)
    }

    /// Admits a new standalone skill into the central library. Immutable bytes
    /// publish before the revision references them. No assignments are created
    /// and no native/source folders are changed by this command.
    public func intakeStandaloneSkill(
        _ command: StandaloneSkillIntakeCommand, prepared: PreparedStandaloneSkill
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

    /// Updates central content only. Publisher changes require a fetched commit
    /// with the existing repository/ref/path; personal edits cannot overwrite an
    /// upstream or native-owned item. Existing deployments remain observations
    /// until a separately reviewed assignment/reconciliation plan is applied.
    public func updateStandaloneSkill(
        _ command: StandaloneSkillUpdateCommand, prepared: PreparedStandaloneSkill
    ) async throws -> WorkspaceCommandReceipt {
        try Task.checkCancellation()
        guard command.content == prepared.review else { throw WorkspaceSkillCommandError.reviewMismatch }
        let digest = try command.inputDigest()
        if let replay = try store.preflightMetadata(
            expectedRevisionID: command.expectedRevisionID, idempotencyKey: command.idempotencyKey, inputDigest: digest,
            mutation: { try command.apply(to: &$0, declaredName: prepared.frontmatter.name) }
        ) { return replay }
        guard let contentStore else { throw WorkspaceSkillCommandError.contentStoreUnavailable }
        // Preserve a usable prior revision for review/restore. Do not silently
        // repair a damaged old object while accepting an unrelated new version.
        _ = try await contentStore.read(command.expectedContentDigest)
        try await publishReviewedSkill(prepared)
        return try store.commitMetadata(
            expectedRevisionID: command.expectedRevisionID, idempotencyKey: command.idempotencyKey,
            inputDigest: digest, writerID: writerID
        ) { document in
            try Task.checkCancellation()
            return try command.apply(to: &document, declaredName: prepared.frontmatter.name)
        }
    }

    private func publishReviewedSkill(_ prepared: PreparedStandaloneSkill) async throws {
        guard let contentStore else { throw WorkspaceSkillCommandError.contentStoreUnavailable }
        let stored = try await contentStore.store(prepared.tree)
        guard stored.digest == prepared.review.contentDigest else { throw WorkspaceSkillCommandError.reviewMismatch }
        try Task.checkCancellation()
        // Publication may survive a subsequent cancellation, CAS failure or
        // crash as an unreferenced complete object. Never delete/GC it here.
    }

    /// Changes the library label only. The declared package name, aliases,
    /// content, native route and physical destinations remain intact.
    /// What would change on this device for the committed intent, with the
    /// content this workspace can actually supply. Nothing is assumed already
    /// present: without fresh observations every requirement is proposed, and
    /// the existing reviewed operation path still checks each destination.
    ///
    /// This returns a request for that path. It installs nothing and proves
    /// nothing about whether an adapter will accept an item.
    public func deploymentPlan(
        targets: [ResolvedAssignmentTarget],
        observations: [WorkspaceDeploymentObservation] = [],
        provenInstalls: Set<WorkspaceDeploymentInstallKey> = [],
        nativeInstallRoutes: Set<NativePackageRoute> = []
    ) async throws -> WorkspaceDeploymentPlan {
        guard let snapshot = try store.snapshot() else {
            throw WorkspaceRevisionStoreError.notInitialized
        }
        var available: [AssignmentContentEvidence] = []
        if let contentStore {
            for artifact in snapshot.document.artifacts {
                guard let digest = artifact.contentDigest else { continue }
                // Only content this store can actually read counts as held.
                guard (try? await contentStore.read(digest)) != nil else { continue }
                available.append(.init(artifactID: artifact.identity.id, digest: digest))
            }
        }
        return WorkspaceDeploymentPlanner.plan(
            document: snapshot.document, device: snapshot.device, targets: targets,
            availableContent: available, observations: observations,
            provenInstalls: provenInstalls, nativeInstallRoutes: nativeInstallRoutes)
    }

    /// Registers a folder this person already authors in. The folder is not
    /// copied, not rewritten and stays the only editable version; this workspace
    /// records that it exists and where it is on this Mac.
    public func attachAuthoringRoot(_ command: AttachedAuthoringIntakeCommand) throws -> WorkspaceCommandReceipt {
        try store.commitMetadata(
            expectedRevisionID: command.expectedRevisionID,
            idempotencyKey: command.idempotencyKey,
            inputDigest: command.inputDigest(),
            writerID: writerID,
            deviceMutation: { try command.bind(&$0) },
            mutation: { try command.apply(to: &$0) })
    }

    /// Stops managing an attached item. Nothing in the folder is changed.
    public func detachAuthoringRoot(_ command: AttachedAuthoringDetachCommand) throws -> WorkspaceCommandReceipt {
        var removedSourceID: WorkspaceObjectID?
        return try store.commitMetadata(
            expectedRevisionID: command.expectedRevisionID,
            idempotencyKey: command.idempotencyKey,
            inputDigest: command.inputDigest(),
            writerID: writerID,
            deviceMutation: { device in
                guard let removedSourceID else { return }
                device.sourceLocations.removeAll { $0.sourceRootID == removedSourceID }
            },
            mutation: { document in
                let result = try command.apply(to: &document)
                // Only unbind the folder when the document no longer names it.
                removedSourceID = document.sources.contains(where: { $0.id == result.sourceID })
                    ? nil : result.sourceID
                return result.affected
            })
    }

    /// Applies exactly the changes a linked preset's reviewed catch-up named.
    ///
    /// The digest covers every change that was shown, so an update computed
    /// against a different membership cannot be replayed under the same key as
    /// one the person actually saw.
    public func applyLinkedPresetUpdate(
        _ update: LinkedPresetUpdate,
        expectedRevisionID: WorkspaceObjectID,
        idempotencyKey: WorkspaceObjectID = WorkspaceObjectID()
    ) throws -> WorkspaceCommandReceipt {
        try store.commitMetadata(
            expectedRevisionID: expectedRevisionID,
            idempotencyKey: idempotencyKey,
            inputDigest: WorkspaceLinkedPresetResolver.inputDigest(update),
            writerID: writerID
        ) { document in
            WorkspaceLinkedPresetResolver.apply(update, to: &document)
        }
    }

    /// Records a change to this device's own state, with the portable document
    /// left exactly as it is.
    ///
    /// Device state is where paths live — checkouts, project folders, the
    /// destinations this Mac writes somewhere else — and none of it belongs in
    /// portable bytes. Going through a command keeps the change in the same
    /// transaction and under the same head check as everything else, so it
    /// cannot be applied against a workspace that moved.
    @discardableResult
    public func commitDeviceChange(
        expectedRevisionID: WorkspaceObjectID,
        idempotencyKey: WorkspaceObjectID = WorkspaceObjectID(),
        inputDigest: String = String(repeating: "0", count: 64),
        _ mutation: @escaping @Sendable (inout DeviceWorkspaceState) throws -> Void
    ) throws -> WorkspaceCommandReceipt {
        try store.commitMetadata(
            expectedRevisionID: expectedRevisionID,
            idempotencyKey: idempotencyKey,
            inputDigest: inputDigest,
            writerID: writerID,
            deviceMutation: mutation,
            mutation: { _ in [] })
    }

    public func renameArtifact(_ command: RenameArtifactCommand) throws -> WorkspaceCommandReceipt {
        let digest = try command.inputDigest()
        return try store.commitMetadata(
            expectedRevisionID: command.expectedRevisionID,
            idempotencyKey: command.idempotencyKey,
            inputDigest: digest,
            writerID: writerID
        ) { document in
            guard let index = document.artifacts.firstIndex(where: { $0.identity.id == command.artifactID }) else {
                throw WorkspaceRevisionStoreError.missingArtifact
            }
            try WorkspaceDomainValidation.requireText(command.displayName, field: "artifact.displayName", maximum: 512)
            document.artifacts[index].identity.displayName = command.displayName
            // Project/preset names are the same label in the corresponding
            // records; retaining two conflicting labels would break rename.
            if let index = document.logicalProjects.firstIndex(where: { $0.id == command.artifactID }) {
                document.logicalProjects[index].name = command.displayName
            }
            if let index = document.presets.firstIndex(where: { $0.id == command.artifactID }) {
                document.presets[index].name = command.displayName
            }
            return [command.artifactID]
        }
    }
}

public struct RenameArtifactCommand: Codable, Sendable, Equatable {
    public let expectedRevisionID: WorkspaceObjectID
    public let idempotencyKey: WorkspaceObjectID
    public let artifactID: ArtifactID
    public let displayName: String

    public init(
        expectedRevisionID: WorkspaceObjectID, idempotencyKey: WorkspaceObjectID = WorkspaceObjectID(),
        artifactID: ArtifactID, displayName: String
    ) {
        self.expectedRevisionID = expectedRevisionID
        self.idempotencyKey = idempotencyKey
        self.artifactID = artifactID
        self.displayName = displayName
    }

    func inputDigest() throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        // Domain separation prevents future command types with a similar
        // payload from accidentally sharing an idempotency identity.
        var bytes = Data("agent-tooling.rename-artifact.v1\n".utf8)
        bytes.append(try encoder.encode(self))
        return SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
    }
}

/// A durable result for metadata work, never proof of a native installation.
public struct WorkspaceCommandReceipt: Codable, Sendable, Equatable {
    public let idempotencyKey: WorkspaceObjectID
    public let inputDigest: String
    public let previousRevisionID: WorkspaceObjectID
    public let committedRevisionID: WorkspaceObjectID
    public let affectedArtifactIDs: [ArtifactID]
}
