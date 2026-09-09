import Foundation
import Testing

@testable import AgentToolingCore

/// Choosing a side answers exactly one conflict. Nothing is invented, nothing
/// unanswered is decided, and the merge engine's own rules still produce the
/// result.
@Suite("Workspace conflict resolution")
struct WorkspaceConflictResolutionTests {
    @Test func choosingASideResolvesThatRenameAndKeepsTheOtherMacsUnrelatedWork() throws {
        let base = try Self.document(alpha: "Shared", beta: "Second")
        var local = try Self.document(alpha: "A's name", beta: "Second")
        var remote = try Self.document(alpha: "B's name", beta: "Renamed on B")
        local.revision = .init(id: Self.localRevision, parentIDs: [base.revision.id], writerID: Self.writerID)
        remote.revision = .init(id: Self.remoteRevision, parentIDs: [base.revision.id], writerID: Self.writerID)
        let conflicts = WorkspaceMergeEngine.merge(base: base, local: local, remote: remote,
                                                   writerID: Self.writerID).conflicts
        #expect(conflicts.count == 1)

        for (choice, expected) in [(WorkspaceConflictChoice.keepLocal, "A's name"),
                                   (.takeRemote, "B's name")] {
            let result = WorkspaceConflictResolver.resolve(
                base: base, local: local, remote: remote, conflicts: conflicts,
                resolutions: [.init(kind: .artifactField, artifactID: Self.alpha, choice: choice)],
                writerID: Self.writerID)

            #expect(result.isResolved, "\(result.remaining)")
            let document = try #require(result.document)
            #expect(Self.name(document, Self.alpha) == expected)
            // The other Mac's unrelated rename survives either choice.
            #expect(Self.name(document, Self.beta) == "Renamed on B")
        }
    }

    @Test func aConflictWithNoDecisionKeepsTheWholeResultUnavailable() throws {
        let base = try Self.document(alpha: "Shared", beta: "Second")
        var local = try Self.document(alpha: "A's name", beta: "A's second")
        var remote = try Self.document(alpha: "B's name", beta: "B's second")
        local.revision = .init(id: Self.localRevision, parentIDs: [base.revision.id], writerID: Self.writerID)
        remote.revision = .init(id: Self.remoteRevision, parentIDs: [base.revision.id], writerID: Self.writerID)
        let conflicts = WorkspaceMergeEngine.merge(base: base, local: local, remote: remote,
                                                   writerID: Self.writerID).conflicts
        #expect(conflicts.count == 2)

        let partial = WorkspaceConflictResolver.resolve(
            base: base, local: local, remote: remote, conflicts: conflicts,
            resolutions: [.init(kind: .artifactField, artifactID: Self.alpha, choice: .keepLocal)],
            writerID: Self.writerID)

        #expect(partial.document == nil)
        #expect(partial.remaining.map(\.artifactID) == [Self.beta])
    }

    @Test func keepingAnItemTheOtherMacRemovedResolvesADeleteVersusEdit() throws {
        let base = try Self.document(alpha: "Shared", beta: "Second")
        var local = try Self.document(alpha: "Still in use", beta: "Second")
        local.revision = .init(id: Self.localRevision, parentIDs: [base.revision.id], writerID: Self.writerID)
        var remote = base
        remote.artifacts.removeAll { $0.identity.id == Self.alpha }
        remote.tombstones = [.init(artifactID: Self.alpha, deletedInRevisionID: Self.remoteRevision)]
        remote.revision = .init(id: Self.remoteRevision, parentIDs: [base.revision.id], writerID: Self.writerID)
        remote = try WorkspaceDocumentCoding.seal(remote)
        let conflicts = WorkspaceMergeEngine.merge(base: base, local: local, remote: remote,
                                                   writerID: Self.writerID).conflicts
        #expect(conflicts.map(\.kind) == [.deleteVersusEdit])

        let result = WorkspaceConflictResolver.resolve(
            base: base, local: local, remote: remote, conflicts: conflicts,
            resolutions: [.init(kind: .deleteVersusEdit, artifactID: Self.alpha, choice: .keepLocal)],
            writerID: Self.writerID)

        #expect(result.isResolved, "\(result.remaining)")
        let document = try #require(result.document)
        #expect(Self.name(document, Self.alpha) == "Still in use")
        #expect(document.tombstones.isEmpty)
    }

    @Test func aCollidingDestinationCannotBeSettledByPickingAMac() throws {
        var first = Self.skill(Self.alpha, "Alpha")
        first.declaredName = "review"
        var second = Self.skill(Self.beta, "Beta")
        second.declaredName = "Review"
        let base = try Self.seal(artifacts: [first, second], assignments: [])
        var local = try Self.seal(artifacts: [first, second], assignments: [Self.assignment(Self.alpha)])
        var remote = try Self.seal(artifacts: [first, second], assignments: [Self.assignment(Self.beta)])
        local.revision = .init(id: Self.localRevision, parentIDs: [base.revision.id], writerID: Self.writerID)
        remote.revision = .init(id: Self.remoteRevision, parentIDs: [base.revision.id], writerID: Self.writerID)
        let conflicts = WorkspaceMergeEngine.merge(base: base, local: local, remote: remote,
                                                   writerID: Self.writerID).conflicts
        let collision = try #require(conflicts.first { $0.kind == .destinationCollision })

        let result = WorkspaceConflictResolver.resolve(
            base: base, local: local, remote: remote, conflicts: conflicts,
            resolutions: [.init(kind: collision.kind, artifactID: collision.artifactID,
                                objectID: collision.objectID, choice: .keepLocal)],
            writerID: Self.writerID)

        // Answering it changes nothing: two items still want one place, and
        // that needs different intent rather than a winner.
        #expect(result.remaining.contains { $0.kind == .destinationCollision })
        #expect(!result.isResolved)
    }

    private static let alpha = ArtifactID(UUID(uuidString: "00000000-0000-0000-0000-0000000000a1")!)
    private static let beta = ArtifactID(UUID(uuidString: "00000000-0000-0000-0000-0000000000b2")!)
    private static let writerID = WorkspaceObjectID(UUID(uuidString: "00000000-0000-0000-0000-0000000000c3")!)
    private static let localRevision = WorkspaceObjectID(UUID(uuidString: "00000000-0000-0000-0000-00000000001a")!)
    private static let remoteRevision = WorkspaceObjectID(UUID(uuidString: "00000000-0000-0000-0000-00000000002b")!)

    private static func name(_ document: PortableWorkspaceDocument, _ id: ArtifactID) -> String? {
        document.artifacts.first { $0.identity.id == id }?.identity.displayName
    }

    private static func skill(_ id: ArtifactID, _ name: String) -> ArtifactRecord {
        .init(identity: .init(id: id, kind: .skill, displayName: name), authority: .trackedOnly)
    }

    private static func assignment(_ artifactID: ArtifactID) -> AssignmentContribution {
        .init(id: WorkspaceObjectID(UUID(uuidString: "00000000-0000-0000-0000-000000000"
            + String(artifactID.rawValue.uuidString.suffix(2)) + "1")!),
            artifactID: artifactID,
            destination: .init(surface: .codexCLI, scope: .user), reason: .manual)
    }

    private static func document(alpha alphaName: String, beta betaName: String) throws -> PortableWorkspaceDocument {
        try seal(artifacts: [skill(alpha, alphaName), skill(beta, betaName)], assignments: [])
    }

    private static func seal(
        artifacts: [ArtifactRecord], assignments: [AssignmentContribution]
    ) throws -> PortableWorkspaceDocument {
        try WorkspaceDocumentCoding.seal(.init(
            workspaceID: WorkspaceObjectID(UUID(uuidString: "00000000-0000-0000-0000-0000000000e5")!),
            revision: .init(id: WorkspaceObjectID(UUID(uuidString: "00000000-0000-0000-0000-00000000000b")!),
                            writerID: writerID),
            artifacts: artifacts, assignments: assignments))
    }
}
