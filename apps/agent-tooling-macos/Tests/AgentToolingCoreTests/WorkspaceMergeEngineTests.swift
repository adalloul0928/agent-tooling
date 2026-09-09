import Foundation
import Testing

@testable import AgentToolingCore

/// The merge contract from the implementation plan, case by case. Deletion is
/// decided by tombstones and ancestry, never by absence or by which Mac wrote
/// last.
@Suite("Workspace merge engine")
struct WorkspaceMergeEngineTests {
    @Test func independentChangesOnBothMacsCombine() throws {
        let base = try Self.document(artifacts: [Self.skill(Self.alpha, "Alpha"), Self.skill(Self.beta, "Beta")])
        var local = base
        local.artifacts[0].identity.displayName = "Alpha renamed"
        var remote = base
        remote.artifacts[1].identity.displayName = "Beta renamed"

        let result = Self.merge(base: base, local: local, remote: remote)

        #expect(result.isResolved, "\(result.conflicts)")
        let merged = try #require(result.document)
        #expect(Self.name(merged, Self.alpha) == "Alpha renamed")
        #expect(Self.name(merged, Self.beta) == "Beta renamed")
        #expect(merged.revision.parentIDs.count == 2)
    }

    @Test func aRenameOnOneMacAndAContentEditOnTheOtherCombine() throws {
        let base = try Self.document(artifacts: [Self.skill(Self.alpha, "Alpha")])
        var local = base
        local.artifacts[0].identity.displayName = "Alpha renamed"
        var remote = base
        remote.artifacts[0].contentDigest = Self.digest("b")

        let result = Self.merge(base: base, local: local, remote: remote)

        #expect(result.isResolved, "\(result.conflicts)")
        let merged = try #require(result.document)
        #expect(Self.name(merged, Self.alpha) == "Alpha renamed")
        #expect(merged.artifacts.first { $0.identity.id == Self.alpha }?.contentDigest == Self.digest("b"))
    }

    @Test func differentContentOnBothMacsIsAConflictThatKeepsTheRecord() throws {
        let base = try Self.document(artifacts: [Self.skill(Self.alpha, "Alpha")])
        var local = base
        local.artifacts[0].contentDigest = Self.digest("b")
        var remote = base
        remote.artifacts[0].contentDigest = Self.digest("c")

        let result = Self.merge(base: base, local: local, remote: remote)

        #expect(!result.isResolved)
        #expect(result.conflicts.contains { $0.kind == .artifactContent && $0.artifactID == Self.alpha })
        // Nothing is lost while the person decides.
        #expect((try #require(result.document)).artifacts.contains { $0.identity.id == Self.alpha })
    }

    @Test func deleteVersusEditIsExplicitAndKeepsTheItem() throws {
        let base = try Self.document(artifacts: [Self.skill(Self.alpha, "Alpha")])
        var local = base
        local.artifacts = []
        local.tombstones = [.init(artifactID: Self.alpha, deletedInRevisionID: local.revision.id)]
        var remote = base
        remote.artifacts[0].identity.displayName = "Still in use"

        let result = Self.merge(base: base, local: local, remote: remote)

        #expect(result.conflicts.contains { $0.kind == .deleteVersusEdit && $0.artifactID == Self.alpha })
        let merged = try #require(result.document)
        #expect(merged.artifacts.contains { $0.identity.id == Self.alpha })
        // The pending removal stays in the conflict; nothing reads this item as
        // both present and deleted while the person decides.
        #expect(merged.tombstones.isEmpty)
    }

    @Test func anAgreedDeletionRemovesTheItemAndItsRequests() throws {
        let base = try Self.document(artifacts: [Self.skill(Self.alpha, "Alpha")],
                                     assignments: [Self.assignment(Self.alpha)])
        var local = base
        local.artifacts = []
        local.assignments = []
        local.tombstones = [.init(artifactID: Self.alpha, deletedInRevisionID: local.revision.id)]
        let remote = local

        let result = Self.merge(base: base, local: local, remote: remote)

        #expect(result.isResolved, "\(result.conflicts)")
        let merged = try #require(result.document)
        #expect(merged.artifacts.isEmpty && merged.assignments.isEmpty)
        #expect(merged.tombstones.count == 1)
    }

    @Test func ownershipAndSourcePolicyChangesOnBothSidesStayExplicit() throws {
        let sourceID = WorkspaceObjectID()
        var base = try Self.document(artifacts: [Self.skill(Self.alpha, "Alpha")])
        base.sources = [.init(id: sourceID, role: .publisherRepository,
                              repositoryURL: "https://github.com/example/one",
                              requestedRef: "main", packageRelativePaths: ["."])]
        var local = base
        local.artifacts[0].authority = .trackedOnly
        local.sources[0].requestedRef = "release"
        var remote = base
        remote.artifacts[0].authority = .attachedAuthoring(sourceRootID: sourceID)
        remote.sources[0].requestedRef = "beta"

        let result = Self.merge(base: base, local: local, remote: remote)

        #expect(result.conflicts.contains { $0.kind == .ownership && $0.artifactID == Self.alpha })
        #expect(result.conflicts.contains { $0.kind == .sourcePolicy && $0.objectID == sourceID })
    }

    @Test func aDifferentEnableChoiceIsAConflictRatherThanTheLastWriteWinning() throws {
        let assignment = Self.assignment(Self.alpha, enabled: nil)
        let base = try Self.document(artifacts: [Self.skill(Self.alpha, "Alpha")], assignments: [assignment])
        var local = base
        local.assignments[0].desiredEnabled = true
        var remote = base
        remote.assignments[0].desiredEnabled = false

        let result = Self.merge(base: base, local: local, remote: remote)

        #expect(result.conflicts.contains { $0.kind == .assignmentEnablement && $0.objectID == assignment.id })
        // nil, true and false stay three distinct requests.
        var onlyOneSide = base
        onlyOneSide.assignments[0].desiredEnabled = true
        let combined = Self.merge(base: base, local: onlyOneSide, remote: base)
        #expect(combined.isResolved)
        #expect((try #require(combined.document)).assignments.first?.desiredEnabled == true)
    }

    @Test func presetMembershipCombinesWithoutResurrectingARemovedMember() throws {
        let presetID = ArtifactID()
        var base = try Self.document(artifacts: [
            Self.skill(Self.alpha, "Alpha"), Self.skill(Self.beta, "Beta"),
            .init(identity: .init(id: presetID, kind: .preset, displayName: "Starter"), authority: .centralPersonal),
        ])
        base.presets = [.init(id: presetID, name: "Starter", revision: 1, memberArtifactIDs: [Self.alpha])]
        var local = base
        local.presets[0].memberArtifactIDs = []
        local.presets[0].revision = 2
        var remote = base
        remote.presets[0].memberArtifactIDs = [Self.alpha, Self.beta]
        remote.presets[0].revision = 2

        let result = Self.merge(base: base, local: local, remote: remote)

        #expect(result.isResolved, "\(result.conflicts)")
        let merged = try #require(result.document)
        let preset = try #require(merged.presets.first)
        #expect(preset.memberArtifactIDs == [Self.beta])
        #expect(preset.revision == 2)
    }

    @Test func twoItemsCollidingAtOneDestinationBlockThatMaterialization() throws {
        var first = Self.skill(Self.alpha, "Alpha")
        first.declaredName = "review"
        var second = Self.skill(Self.beta, "Beta")
        second.declaredName = "Review"
        let base = try Self.document(artifacts: [first, second])
        var local = base
        local.assignments = [Self.assignment(Self.alpha)]
        var remote = base
        remote.assignments = [Self.assignment(Self.beta)]

        let result = Self.merge(base: base, local: local, remote: remote)

        #expect(result.conflicts.contains { $0.kind == .destinationCollision })
        // Both records survive; only the shared destination is blocked.
        #expect((try #require(result.document)).artifacts.count == 2)
    }

    @Test func aMissingAncestorNeverImpliesADeletion() throws {
        let local = try Self.document(artifacts: [Self.skill(Self.alpha, "Alpha")])
        var remote = try Self.document(artifacts: [Self.skill(Self.beta, "Beta")])
        remote.workspaceID = local.workspaceID

        let result = Self.merge(base: nil, local: local, remote: remote)

        #expect(result.isResolved, "\(result.conflicts)")
        let merged = try #require(result.document)
        #expect(Set(merged.artifacts.map(\.identity.id)) == [Self.alpha, Self.beta])
        #expect(merged.tombstones.isEmpty)
    }

    @Test func mergingInEitherDirectionProducesTheSameResult() throws {
        let base = try Self.document(artifacts: [Self.skill(Self.alpha, "Alpha"), Self.skill(Self.beta, "Beta")])
        var local = base
        local.artifacts[0].identity.displayName = "Alpha renamed"
        local.assignments = [Self.assignment(Self.alpha)]
        var remote = base
        remote.artifacts[1].contentDigest = Self.digest("c")
        remote.assignments = [Self.assignment(Self.beta)]

        let forward = Self.merge(base: base, local: local, remote: remote)
        let reverse = Self.merge(base: base, local: remote, remote: local)

        #expect(forward.isResolved && reverse.isResolved)
        let a = try #require(forward.document)
        let b = try #require(reverse.document)
        #expect(a.artifacts == b.artifacts)
        #expect(a.assignments == b.assignments)
        #expect(a.revision.parentIDs == b.revision.parentIDs)
    }

    @Test func aNewerDocumentFormatIsRefusedInsteadOfPartiallyMerged() throws {
        let base = try Self.document(artifacts: [Self.skill(Self.alpha, "Alpha")])
        var remote = base
        remote.schemaVersion = PortableWorkspaceDocument.currentSchemaVersion + 1
        remote.minimumReaderVersion = remote.schemaVersion
        remote.minimumWriterVersion = remote.schemaVersion

        let result = Self.merge(base: base, local: base, remote: remote)

        #expect(result.document == nil)
        #expect(result.conflicts.map(\.kind) == [.unsupportedVersion])
    }

    private static let alpha = ArtifactID(UUID(uuidString: "00000000-0000-0000-0000-0000000000a1")!)
    private static let beta = ArtifactID(UUID(uuidString: "00000000-0000-0000-0000-0000000000b2")!)
    private static let writerID = WorkspaceObjectID(UUID(uuidString: "00000000-0000-0000-0000-0000000000c3")!)

    /// Each side is its own revision, as two Macs would produce.
    private static func merge(
        base: PortableWorkspaceDocument?,
        local: PortableWorkspaceDocument,
        remote: PortableWorkspaceDocument
    ) -> WorkspaceMergeResult {
        var mine = local
        var theirs = remote
        mine.revision.id = WorkspaceObjectID(UUID(uuidString: "00000000-0000-0000-0000-00000000001a")!)
        theirs.revision.id = WorkspaceObjectID(UUID(uuidString: "00000000-0000-0000-0000-00000000002b")!)
        return WorkspaceMergeEngine.merge(base: base, local: mine, remote: theirs, writerID: writerID)
    }

    private static func name(_ document: PortableWorkspaceDocument, _ id: ArtifactID) -> String? {
        document.artifacts.first { $0.identity.id == id }?.identity.displayName
    }

    private static func digest(_ character: Character) -> ContentDigest {
        .init(algorithm: .sha256TreeV1, value: String(repeating: String(character), count: 64))
    }

    private static func skill(_ id: ArtifactID, _ name: String) -> ArtifactRecord {
        .init(identity: .init(id: id, kind: .skill, displayName: name), authority: .centralPersonal,
              declaredName: name.lowercased(), contentDigest: digest("a"))
    }

    /// Deterministic per item, so two Macs describing the same request agree.
    private static func assignment(_ artifactID: ArtifactID, enabled: Bool? = nil) -> AssignmentContribution {
        .init(id: WorkspaceObjectID(UUID(uuidString:
                "00000000-0000-0000-0000-0000000000" + String(artifactID.rawValue.uuidString.suffix(2)))!),
              artifactID: artifactID,
              destination: .init(surface: .codexCLI, scope: .user),
              reason: .manual, desiredPresence: true, desiredEnabled: enabled)
    }

    private static func document(
        artifacts: [ArtifactRecord],
        assignments: [AssignmentContribution] = []
    ) throws -> PortableWorkspaceDocument {
        var document = PortableWorkspaceDocument(
            workspaceID: WorkspaceObjectID(UUID(uuidString: "00000000-0000-0000-0000-0000000000e5")!),
            revision: .init(id: WorkspaceObjectID(), writerID: writerID),
            artifacts: artifacts, assignments: assignments)
        document = document.canonicalized()
        try document.validateStructure()
        return document
    }
}
