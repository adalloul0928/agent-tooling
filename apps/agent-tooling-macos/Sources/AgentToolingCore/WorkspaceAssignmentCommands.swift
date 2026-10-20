import CryptoKit
import Foundation

public enum WorkspaceAssignmentCommandError: Error, Equatable, Sendable {
    case emptyBatch, duplicateSelection, unsupportedArtifact, nativeChild, unsupportedReason
    case contributionConflict, missingContribution, presetChanged, invalidPresetReview
}

/// Captures membership when Apply once is reviewed. It is not a subscription to
/// subsequent edits of the preset, and is checked again inside the writer transaction.
public struct WorkspacePresetApplicationReview: Codable, Equatable, Sendable {
    public let presetID: ArtifactID
    public let revision: UInt64
    public let memberArtifactIDs: [ArtifactID]

    public init(presetID: ArtifactID, revision: UInt64, memberArtifactIDs: [ArtifactID]) {
        self.presetID = presetID
        self.revision = revision
        self.memberArtifactIDs = memberArtifactIDs
    }
}

/// A batch changes portable assignment intent only. Applying it neither installs
/// tools nor removes native files. Native reconciliation has its own reviewed plan.
public struct WorkspaceAssignmentBatchCommand: Codable, Equatable, Sendable {
    public let expectedRevisionID: WorkspaceObjectID
    public let idempotencyKey: WorkspaceObjectID
    public let additions: [AssignmentContribution]
    public let removalIDs: [WorkspaceObjectID]
    public let presetApplications: [WorkspacePresetApplicationReview]

    public init(
        expectedRevisionID: WorkspaceObjectID, idempotencyKey: WorkspaceObjectID = WorkspaceObjectID(),
        additions: [AssignmentContribution] = [], removalIDs: [WorkspaceObjectID] = [],
        presetApplications: [WorkspacePresetApplicationReview] = []
    ) {
        self.expectedRevisionID = expectedRevisionID
        self.idempotencyKey = idempotencyKey
        self.additions = additions
        self.removalIDs = removalIDs
        self.presetApplications = presetApplications
    }

    public static func assign(
        document: PortableWorkspaceDocument, artifactIDs: [ArtifactID], destinations: [PortableDestination],
        desiredEnabled: Bool? = nil, idempotencyKey: WorkspaceObjectID = WorkspaceObjectID()
    ) throws -> Self {
        try document.validateStructure()
        let command = Self(
            expectedRevisionID: document.revision.id, idempotencyKey: idempotencyKey,
            additions: try contributions(
                artifactIDs: artifactIDs, destinations: destinations,
                reason: .manual, desiredEnabled: desiredEnabled))
        _ = try command.preview(document: document)
        return command
    }

    /// Builds explicit item/destination pairs. Existing requests are returned in
    /// `alreadyRequested`; matching withdrawn contributions are retained and the
    /// rest removed. Missing withdrawals are ignored. Additions are manual.
    /// Throws `.emptyBatch` for no change and `.duplicateSelection` for repeated
    /// pairs. The library session exposes this through `reviewPlacements`.
    static func place(
        document: PortableWorkspaceDocument, placements: [WorkspacePlacement], withdrawing: [WorkspaceObjectID] = [],
        idempotencyKey: WorkspaceObjectID = WorkspaceObjectID()
    ) throws -> (command: Self, alreadyRequested: [WorkspacePlacement]) {
        try document.validateStructure()
        let changes = try placementChanges(document: document, placements: placements, withdrawing: withdrawing)
        let command = Self(
            expectedRevisionID: document.revision.id, idempotencyKey: idempotencyKey, additions: changes.additions,
            removalIDs: changes.removalIDs)
        _ = try command.preview(document: document)
        return (command, changes.alreadyRequested)
    }

    /// What `place` would add and remove, and what it would pass over as
    /// already asked for, without checking the batch itself.
    static func placementChanges(
        document: PortableWorkspaceDocument, placements: [WorkspacePlacement], withdrawing: [WorkspaceObjectID]
    ) throws -> (additions: [AssignmentContribution], removalIDs: [WorkspaceObjectID], alreadyRequested: [WorkspacePlacement]) {
        let wanted = placements.map(\.canonical)
        guard wanted.count <= 10_000, Set(wanted).count == wanted.count else {
            throw WorkspaceAssignmentCommandError.duplicateSelection
        }
        let withdrawable = Set(withdrawing)
        let own = document.assignments.filter { withdrawable.contains($0.id) }
        let others = document.assignments.filter { !withdrawable.contains($0.id) }
        var kept = Set<WorkspaceObjectID>()
        var additions: [AssignmentContribution] = []
        var alreadyRequested: [WorkspacePlacement] = []
        for placement in wanted {
            if others.contains(where: placement.isAsked(by:)) {
                alreadyRequested.append(placement)
            } else if let mine = own.first(where: { placement.isAsked(by: $0) && !kept.contains($0.id) }) {
                kept.insert(mine.id)
            } else {
                additions.append(.init(artifactID: placement.artifactID, destination: placement.destination, reason: .manual))
            }
        }
        return (additions, own.map(\.id).filter { !kept.contains($0) }.sorted(), alreadyRequested)
    }

    public static func applyPresetOnce(
        document: PortableWorkspaceDocument, presetID: ArtifactID, destinations: [PortableDestination],
        desiredEnabled: Bool? = nil, idempotencyKey: WorkspaceObjectID = WorkspaceObjectID()
    ) throws -> Self {
        try document.validateStructure()
        guard let preset = document.presets.first(where: { $0.id == presetID }) else {
            throw WorkspaceAssignmentCommandError.presetChanged
        }
        let command = Self(
            expectedRevisionID: document.revision.id, idempotencyKey: idempotencyKey,
            additions: try contributions(
                artifactIDs: preset.memberArtifactIDs, destinations: destinations,
                reason: .preset(presetID: presetID), desiredEnabled: desiredEnabled),
            presetApplications: [
                .init(
                    presetID: presetID, revision: preset.revision,
                    memberArtifactIDs: preset.memberArtifactIDs)
            ])
        _ = try command.preview(document: document)
        return command
    }

    public func preview(document: PortableWorkspaceDocument) throws -> WorkspaceAssignmentBatchPreview {
        try document.validateStructure()
        guard document.revision.id == expectedRevisionID else {
            throw WorkspaceRevisionStoreError.staleRevision(current: document.revision.id)
        }
        var candidate = document
        let affected = try apply(to: &candidate)
        candidate = candidate.canonicalized()
        let addedIDs = Set(additions.map(\.id))
        let removed = document.assignments.filter { removalIDs.contains($0.id) }.sorted { $0.id < $1.id }
        return .init(
            expectedRevisionID: expectedRevisionID,
            additions: candidate.assignments.filter { addedIDs.contains($0.id) }, removals: removed,
            remainingContributions: candidate.assignments.filter { affected.contains($0.artifactID) }.sorted { $0.id < $1.id })
    }

    func inputDigest() throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        var bytes = Data("agent-tooling.assignment-batch.v1\n".utf8)
        bytes.append(try encoder.encode(self))
        return SHA256.hash(data: bytes).lowercaseHex
    }

    func apply(to document: inout PortableWorkspaceDocument) throws -> [ArtifactID] {
        guard !additions.isEmpty || !removalIDs.isEmpty else { throw WorkspaceAssignmentCommandError.emptyBatch }
        guard additions.count <= 10_000, removalIDs.count <= 10_000,
            Set(additions.map(\.id)).count == additions.count, Set(removalIDs).count == removalIDs.count,
            Set(additions.map(\.id)).isDisjoint(with: removalIDs),
            Set(presetApplications.map(\.presetID)).count == presetApplications.count
        else {
            throw WorkspaceAssignmentCommandError.duplicateSelection
        }
        let existing = Dictionary(uniqueKeysWithValues: document.assignments.map { ($0.id, $0) })
        guard removalIDs.allSatisfy({ existing[$0] != nil }) else { throw WorkspaceAssignmentCommandError.missingContribution }
        guard additions.allSatisfy({ existing[$0.id] == nil }) else { throw WorkspaceAssignmentCommandError.contributionConflict }
        let removed = Set(removalIDs)
        var semanticKeys = Set(document.assignments.filter { !removed.contains($0.id) }.map(AssignmentSemanticKey.init))
        for addition in additions {
            guard semanticKeys.insert(AssignmentSemanticKey(addition)).inserted else {
                throw WorkspaceAssignmentCommandError.contributionConflict
            }
        }
        let artifacts = Dictionary(uniqueKeysWithValues: document.artifacts.map { ($0.identity.id, $0) })
        let presets = Dictionary(uniqueKeysWithValues: document.presets.map { ($0.id, $0) })
        let reviews = Dictionary(uniqueKeysWithValues: presetApplications.map { ($0.presetID, $0) })
        var usedPresetIDs = Set<ArtifactID>()
        for contribution in additions {
            guard let artifact = artifacts[contribution.artifactID],
                [.skill, .mcpServer, .package, .nativePlugin].contains(artifact.identity.kind),
                artifact.authority != .trackedOnly
            else { throw WorkspaceAssignmentCommandError.unsupportedArtifact }
            if artifact.authority == .nativeOwned, artifact.identity.parentPackageID != nil {
                throw WorkspaceAssignmentCommandError.nativeChild
            }
            switch contribution.reason {
            case .manual: break
            case .preset(let presetID):
                guard let review = reviews[presetID], let preset = presets[presetID],
                    preset.revision == review.revision,
                    Set(review.memberArtifactIDs).count == review.memberArtifactIDs.count,
                    Set(preset.memberArtifactIDs) == Set(review.memberArtifactIDs)
                else {
                    throw WorkspaceAssignmentCommandError.presetChanged
                }
                guard review.memberArtifactIDs.contains(contribution.artifactID) else {
                    throw WorkspaceAssignmentCommandError.invalidPresetReview
                }
                usedPresetIDs.insert(presetID)
            case .onboarding, .projectDeclaration:
                // Those reasons are produced by their own migration/declaration
                // workflows, not manufactured by the everyday assignment sheet.
                throw WorkspaceAssignmentCommandError.unsupportedReason
            }
        }
        guard usedPresetIDs == Set(reviews.keys) else { throw WorkspaceAssignmentCommandError.invalidPresetReview }
        for presetID in usedPresetIDs {
            let grouped = Dictionary(grouping: additions.filter { $0.reason == .preset(presetID: presetID) }, by: \.destination)
            guard let review = reviews[presetID] else { throw WorkspaceAssignmentCommandError.invalidPresetReview }
            let members = Set(review.memberArtifactIDs)
            guard grouped.values.allSatisfy({ Set($0.map(\.artifactID)) == members && $0.count == members.count }) else {
                throw WorkspaceAssignmentCommandError.invalidPresetReview
            }
        }
        var candidate = document
        candidate.assignments.removeAll { removed.contains($0.id) }
        candidate.assignments += additions
        try candidate.validateStructure()
        let affected = Set(additions.map(\.artifactID) + removalIDs.compactMap { existing[$0]?.artifactID })
        document = candidate
        return affected.sorted()
    }

    private static func contributions(
        artifactIDs: [ArtifactID], destinations: [PortableDestination], reason: AssignmentReason, desiredEnabled: Bool?
    ) throws -> [AssignmentContribution] {
        guard !artifactIDs.isEmpty, !destinations.isEmpty else { throw WorkspaceAssignmentCommandError.emptyBatch }
        guard Set(artifactIDs).count == artifactIDs.count, Set(destinations).count == destinations.count,
            artifactIDs.count <= 10_000, destinations.count <= 10_000 / artifactIDs.count
        else {
            throw WorkspaceAssignmentCommandError.duplicateSelection
        }
        return artifactIDs.sorted().flatMap { id in
            destinations.map { .init(artifactID: id, destination: $0, reason: reason, desiredEnabled: desiredEnabled) }
        }
    }
}

/// One item asked for at one destination: a cell of setup's placement grid,
/// and the unit `WorkspaceAssignmentBatchCommand.place` records.
public struct WorkspacePlacement: Hashable, Sendable {
    public let artifactID: ArtifactID
    public let destination: PortableDestination

    public init(artifactID: ArtifactID, destination: PortableDestination) {
        self.artifactID = artifactID
        self.destination = destination
    }

    /// What `contribution` asks for, whatever its reason.
    init(asking contribution: AssignmentContribution) {
        self.init(artifactID: contribution.artifactID, destination: contribution.destination)
        self = canonical
    }

    /// Whether `contribution` already asks for this placement: the same item
    /// at the same destination, its Macs named in any order, whatever its
    /// reason, and whether or not it reaches this Mac. `place` passes such a
    /// placement over, and a batch would refuse a second manual request for
    /// it, so setup's what-if plan never adds one either. Every contribution
    /// of a valid document asks for its placement: `validateStructure`
    /// refuses one whose `desiredPresence` is false.
    public func isAsked(by contribution: AssignmentContribution) -> Bool {
        WorkspacePlacement(asking: contribution) == canonical
    }

    /// The same placement with its device lists in order, so two that name
    /// the same Macs compare equal.
    var canonical: WorkspacePlacement {
        var destination = destination
        destination.deviceIDs?.sort()
        destination.excludedDeviceIDs?.sort()
        return WorkspacePlacement(artifactID: artifactID, destination: destination)
    }
}

private struct AssignmentSemanticKey: Hashable {
    let artifactID: ArtifactID
    let destination: PortableDestination
    let reason: AssignmentReason

    init(_ contribution: AssignmentContribution) {
        artifactID = contribution.artifactID
        var canonicalDestination = contribution.destination
        canonicalDestination.deviceIDs?.sort()
        destination = canonicalDestination
        reason = contribution.reason
    }
}

public struct WorkspaceAssignmentBatchPreview: Equatable, Sendable {
    public let expectedRevisionID: WorkspaceObjectID
    public let additions: [AssignmentContribution]
    public let removals: [AssignmentContribution]
    /// Other reasons remain visible after removing one manual/preset contribution.
    /// These are requested assignments, not installation or availability claims.
    public let remainingContributions: [AssignmentContribution]
}
