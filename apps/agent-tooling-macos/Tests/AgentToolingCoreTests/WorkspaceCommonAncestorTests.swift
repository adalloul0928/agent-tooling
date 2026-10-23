import AgentToolingTestSupport
import Foundation
import Testing

@testable import AgentToolingCore

struct WorkspaceCommonAncestorTests {
    @Test(arguments: [true, false])
    func aDescendantWinsOverItsRedundantOlderParent(olderParentSortsFirst: Bool) throws {
        let original = try Self.document(olderParentSortsFirst ? 1 : 9)
        let intermediate = try Self.document(2, parents: [original])
        let local = try Self.document(olderParentSortsFirst ? 9 : 1, parents: [intermediate])
        let remote = try Self.document(10, parents: [original, local])
        let fixture = try Fixture(head: local, ancestors: [original, intermediate])
        defer { fixture.remove() }
        try fixture.store.importRemoteRevisions(remote, ancestors: [original, intermediate, local])

        #expect(try fixture.store.commonAncestor(withRemote: remote) == local)
        _ = try fixture.store.fastForward(
            to: remote.revision.id, expectedLocalHead: local.revision.id,
            idempotencyKey: WorkspaceObjectID(), inputDigest: String(repeating: "a", count: 64))
        #expect(try fixture.store.snapshot()?.document == remote)
        #expect(try fixture.store.commonAncestor(withRemote: local) == local)
    }

    @Test func aDeeperSharedDescendantIsTheBaseForIndependentEdits() throws {
        let original = try Self.document(1, name: "Before")
        let shared = try Self.document(9, parents: [original], name: "Shared rename")
        let local = try Self.document(10, parents: [shared], name: "Shared rename", declaredName: "local-skill")
        let bridge = try Self.document(11, parents: [shared], name: "Shared rename")
        let remote = try Self.document(12, parents: [original, bridge], name: "Remote rename")
        let fixture = try Fixture(head: local, ancestors: [original, shared])
        defer { fixture.remove() }
        try fixture.store.importRemoteRevisions(remote, ancestors: [original, shared, bridge])

        let base = try fixture.store.commonAncestor(withRemote: remote)
        #expect(base == shared)
        let result = WorkspaceMergeEngine.merge(base: base, local: local, remote: remote, writerID: WorkspaceObjectID())
        #expect(result.isResolved, "The shared rename is unchanged locally and must not conflict with the remote rename")
        let merged = try #require(result.document)
        #expect(merged.artifacts.first?.identity.displayName == "Remote rename")
        #expect(merged.artifacts.first?.declaredName == "local-skill")
    }

    @Test func incomparableBestBasesUseTheSameChoiceWhenDevicesSwap() throws {
        let original = try Self.document(1)
        let left = try Self.document(4, parents: [original])
        let right = try Self.document(8, parents: [original])
        let bridge = try Self.document(9, parents: [left])
        let local = try Self.document(10, parents: [left, right])
        let remote = try Self.document(11, parents: [right, bridge])
        let first = try Fixture(head: local, ancestors: [original, left, right])
        let second = try Fixture(head: remote, ancestors: [original, left, right, bridge])
        defer {
            first.remove()
            second.remove()
        }
        try first.store.importRemoteRevisions(remote, ancestors: [original, left, right, bridge])
        try second.store.importRemoteRevisions(local, ancestors: [original, left, right])

        #expect(try first.store.commonAncestor(withRemote: remote) == left)
        #expect(try second.store.commonAncestor(withRemote: local) == left)
    }

    @Test func completeUnrelatedHistoriesHaveNoCommonAncestor() throws {
        let local = try Self.document(1)
        let remote = try Self.document(2)
        let fixture = try Fixture(head: local, ancestors: [])
        defer { fixture.remove() }
        try fixture.store.importRemoteRevisions(remote, ancestors: [])

        #expect(try fixture.store.commonAncestor(withRemote: remote) == nil)
    }

    @Test(arguments: [false, true])
    func missingOrCyclicHistoryDoesNotSelectAnOlderSharedRevision(cyclic: Bool) throws {
        let original = try Self.document(1)
        var remote = try Self.document(10, parents: [original])
        remote.revision.parentIDs.append(try Self.id(11))
        remote = try WorkspaceDocumentCoding.seal(remote)
        let fixture = try Fixture(head: original, ancestors: [])
        defer { fixture.remove() }
        try fixture.store.importRemoteRevision(remote)
        if cyclic {
            try fixture.store.importRemoteRevision(Self.document(11, parents: [remote]))
        }

        #expect(throws: WorkspaceRevisionStoreError.missingAncestry) {
            try fixture.store.commonAncestor(withRemote: remote)
        }
        #expect(try fixture.store.snapshot()?.document == original)
    }

    @Test func aSuppliedHeadCannotReplaceStoredRevisionContent() throws {
        let original = try Self.document(1)
        let remote = try Self.document(2, parents: [original])
        let fixture = try Fixture(head: original, ancestors: [])
        defer { fixture.remove() }
        try fixture.store.importRemoteRevisions(remote, ancestors: [original])
        var changed = remote
        changed.artifacts[0].identity.displayName = "Different contents under the same revision ID"
        changed = try WorkspaceDocumentCoding.seal(changed)

        #expect(throws: WorkspaceRevisionStoreError.corruptState) {
            try fixture.store.commonAncestor(withRemote: changed)
        }
        #expect(try fixture.store.revision(remote.revision.id) == remote)
    }

    @Test func incompleteAndConflictingImportsLeaveTheStoreUnchanged() throws {
        let original = try Self.document(1)
        let missing = try Self.document(2, parents: [original])
        let remote = try Self.document(3, parents: [missing])
        let fixture = try Fixture(head: original, ancestors: [])
        defer { fixture.remove() }
        #expect(throws: WorkspaceRevisionStoreError.missingAncestry) {
            try fixture.store.importRemoteRevisions(remote, ancestors: [])
        }
        #expect(try fixture.store.revision(remote.revision.id) == nil)
        var conflicting = original
        conflicting.artifacts[0].identity.displayName = "Changed under the same identity"
        conflicting = try WorkspaceDocumentCoding.seal(conflicting)
        #expect(throws: WorkspaceRevisionStoreError.corruptState) {
            try fixture.store.importRemoteRevisions(remote, ancestors: [conflicting, missing])
        }
        #expect(try fixture.store.revision(missing.revision.id) == nil)
        #expect(try fixture.store.revision(remote.revision.id) == nil)
        #expect(try fixture.store.snapshot()?.document == original)
    }

    @Test func aCompleteGraphOverTheRevisionLimitIsRejectedWithoutChangingTheStore() throws {
        let original = try Self.document(1)
        let fixture = try Fixture(head: original, ancestors: [])
        defer { fixture.remove() }
        var history = [original]
        for index in 2...(WorkspaceRevisionStore.ancestryLimit + 1) {
            history.append(try Self.document(index, parents: [#require(history.last)]))
        }
        let remote = try #require(history.last)

        #expect(throws: WorkspaceRevisionStoreError.archiveLimitExceeded) {
            try fixture.store.importRemoteRevisions(remote, ancestors: Array(history.dropLast()))
        }

        #expect(try fixture.store.snapshot()?.document == original)
        #expect(try fixture.store.revision(remote.revision.id) == nil)
        #expect(try fixture.store.revision(history[1].revision.id) == nil)
        #expect(WorkspaceRevisionStoreError.archiveLimitExceeded.errorDescription?.contains("Keep the existing libraries") == true)
    }

    @Test func archiveByteAndWireCountLimitsHaveDistinctPreservationGuidance() throws {
        #expect(throws: WorkspaceRevisionStoreError.archiveLimitExceeded) {
            try WorkspaceRevisionArchive.decode(Data(count: WorkspaceRevisionArchive.maximumBytes + 1))
        }
        let wire = try JSONSerialization.data(withJSONObject: [
            "formatVersion": 1, "documents": Array(repeating: "", count: WorkspaceRevisionStore.ancestryLimit + 1),
        ])
        #expect(throws: WorkspaceRevisionStoreError.archiveLimitExceeded) {
            try WorkspaceRevisionArchive.decode(wire)
        }
        #expect(WorkspaceRevisionStoreError.archiveLimitExceeded.errorDescription?.contains("missing history") == false)
        #expect(WorkspaceRevisionStoreError.missingAncestry.errorDescription?.contains("missing history") == true)
    }

    private static func document(
        _ value: Int, parents: [PortableWorkspaceDocument] = [],
        name: String = "Shared skill", declaredName: String? = nil
    ) throws -> PortableWorkspaceDocument {
        try WorkspaceDocumentCoding.seal(
            .init(
                workspaceID: id(100),
                revision: .init(id: id(value), parentIDs: parents.map(\.revision.id), writerID: id(101)),
                artifacts: [
                    .init(
                        identity: .init(id: ArtifactID(try id(102).rawValue), kind: .skill, displayName: name),
                        authority: .trackedOnly, declaredName: declaredName)
                ]))
    }

    private static func id(_ value: Int) throws -> WorkspaceObjectID {
        let uuid = try #require(UUID(uuidString: String(format: "00000000-0000-0000-0000-%012x", value)))
        return WorkspaceObjectID(uuid)
    }

    private struct Fixture {
        let root: URL
        let store: WorkspaceRevisionStore

        init(head: PortableWorkspaceDocument, ancestors: [PortableWorkspaceDocument]) throws {
            root = try TemporaryFolder("workspace-common-ancestor").url
            store = try WorkspaceRevisionStore(containerRoot: root, workspaceID: head.workspaceID, deviceID: WorkspaceObjectID())
            try store.initializeFromRemote(
                document: head, device: .init(workspaceID: head.workspaceID, deviceID: store.deviceID), ancestors: ancestors)
        }

        func remove() { try? FileManager.default.removeItem(at: root) }
    }
}
