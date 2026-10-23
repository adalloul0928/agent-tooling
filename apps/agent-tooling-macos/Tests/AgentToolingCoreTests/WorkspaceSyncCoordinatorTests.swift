import AgentToolingTestSupport
import Foundation
import Testing

@testable import AgentToolingCore

/// Two isolated stores and two checkouts of one real local repository stand in
/// for two Macs. This is a convergence suite, not a two-Mac pilot: nothing here
/// runs a native client or touches a real setup.
@Suite("Workspace sync coordinator")
struct WorkspaceSyncCoordinatorTests {
    @Test func aDeviceWithNoLocalEditsAdoptsTheSharedRevisionWhole() async throws {
        let fixture = try await Fixture()
        defer { fixture.remove() }
        guard case .published = try await fixture.a.sync() else {
            Issue.record("The first device must publish into an empty repository.")
            return
        }
        // Both devices start from the same revision, so there is nothing to do.
        guard case .upToDate = try await fixture.b.sync() else {
            Issue.record("Matching revisions need no work.")
            return
        }

        try fixture.rename(store: fixture.storeA, artifact: Fixture.alpha, to: "Renamed on A")
        _ = try await fixture.a.sync()
        let outcome = try await fixture.b.sync()

        guard case .adopted(let receipt) = outcome else {
            Issue.record("A device with no local edits must adopt, got \(outcome).")
            return
        }
        let adopted = try #require(try fixture.storeB.snapshot())
        #expect(adopted.document.revision.id == receipt.committedRevisionID)
        #expect(adopted.document.artifacts.contains { $0.identity.displayName == "Renamed on A" })
        // Adoption keeps the shared revision's identity, so both heads agree.
        #expect(
            adopted.document.revision.id
                == (try #require(try fixture.storeA.snapshot())).document.revision.id)
    }

    @Test func independentEditsOnBothDevicesConverge() async throws {
        let fixture = try await Fixture()
        defer { fixture.remove() }
        _ = try await fixture.a.sync()
        _ = try await fixture.b.sync()

        try fixture.rename(store: fixture.storeA, artifact: Fixture.alpha, to: "Renamed on A")
        try fixture.rename(store: fixture.storeB, artifact: Fixture.beta, to: "Renamed on B")

        _ = try await fixture.a.sync()
        let merged = try await fixture.b.sync()
        guard case .merged = merged else {
            Issue.record("Expected a merge on the second device, got \(merged).")
            return
        }
        _ = try await fixture.a.sync()

        for store in [fixture.storeA, fixture.storeB] {
            let names = Set((try #require(try store.snapshot())).document.artifacts.map(\.identity.displayName))
            #expect(names == ["Renamed on A", "Renamed on B"])
        }
        #expect(
            try #require(try fixture.storeA.snapshot()).document.revision.id
                == (try #require(try fixture.storeB.snapshot())).document.revision.id)
    }

    @Test func unpublishedIntermediateRevisionsArriveBeforeFastForward() async throws {
        let fixture = try await Fixture()
        defer { fixture.remove() }
        _ = try await fixture.a.sync()
        _ = try await fixture.b.sync()
        try fixture.rename(store: fixture.storeA, artifact: Fixture.alpha, to: "First offline edit")
        let intermediate = try #require(try fixture.storeA.snapshot()).document.revision.id
        try fixture.rename(store: fixture.storeA, artifact: Fixture.alpha, to: "Second offline edit")
        _ = try await fixture.a.sync()

        guard case .adopted = try await fixture.b.sync() else {
            Issue.record("A lagging device must fast-forward through unpublished intermediate revisions")
            return
        }
        #expect(try fixture.storeB.revision(intermediate) != nil)
        #expect(try fixture.storeA.snapshot()?.document == fixture.storeB.snapshot()?.document)
    }

    @Test func severalOfflineEditsDoNotTurnAnUntouchedFieldIntoAConflict() async throws {
        let fixture = try await Fixture()
        defer { fixture.remove() }
        _ = try await fixture.a.sync()
        _ = try await fixture.b.sync()
        try fixture.rename(store: fixture.storeA, artifact: Fixture.alpha, to: "First A edit")
        try fixture.rename(store: fixture.storeA, artifact: Fixture.alpha, to: "Final A edit")
        try fixture.rename(store: fixture.storeB, artifact: Fixture.beta, to: "B edit")
        _ = try await fixture.a.sync()
        guard case .merged = try await fixture.b.sync() else {
            Issue.record("Independent edits must merge against their actual shared ancestor")
            return
        }
        _ = try await fixture.a.sync()
        let names = Set(try #require(try fixture.storeB.snapshot()).document.artifacts.map(\.identity.displayName))
        #expect(names == ["Final A edit", "B edit"])
        #expect(try fixture.storeA.snapshot()?.document == fixture.storeB.snapshot()?.document)
    }

    @Test func completeRemoteHistoryRepairsAnOldMergeWithMissingParents() async throws {
        // The redundant original parent must sort before the newer shared
        // parent, exposing any merge-base choice based on canonical UUID order.
        let originalID = WorkspaceObjectID(try #require(UUID(uuidString: "00000000-0000-0000-0000-000000000000")))
        let fixture = try await Fixture(initialRevisionID: originalID)
        defer { fixture.remove() }
        _ = try await fixture.a.sync()
        let original = try #require(try fixture.storeB.snapshot()).document
        try fixture.rename(store: fixture.storeA, artifact: Fixture.alpha, to: "First offline edit")
        let missing = try #require(try fixture.storeA.snapshot()).document.revision.id
        try fixture.rename(store: fixture.storeA, artifact: Fixture.alpha, to: "Final offline edit")
        let remote = try #require(try fixture.storeA.snapshot()).document
        let legacy = try fixture.recordLegacyMerge(local: original, remote: remote)
        #expect(try fixture.storeB.revision(missing) == nil)
        #expect(throws: WorkspaceRevisionStoreError.missingAncestry) {
            try fixture.storeB.revisionHistory(from: legacy.revision.id)
        }
        _ = try await fixture.a.sync()

        guard case .published = try await fixture.b.sync() else {
            Issue.record("Remote ancestry must repair the old merge before publishing its unchanged local head")
            return
        }
        #expect(try fixture.storeB.revision(missing) != nil)
        #expect(try fixture.storeB.snapshot()?.document == legacy)
        guard case .adopted = try await fixture.a.sync() else {
            Issue.record("A must adopt the repaired merge without minting another revision")
            return
        }
        #expect(try fixture.storeA.snapshot()?.document == legacy)
    }

    @Test func matchingRemoteHeadRepairsMissingLocalParentsBeforeReportingUpToDate() async throws {
        let fixture = try await Fixture()
        defer { fixture.remove() }
        _ = try await fixture.a.sync()
        let original = try #require(try fixture.storeB.snapshot()).document
        try fixture.rename(store: fixture.storeA, artifact: Fixture.alpha, to: "First offline edit")
        let missing = try #require(try fixture.storeA.snapshot()).document.revision.id
        try fixture.rename(store: fixture.storeA, artifact: Fixture.alpha, to: "Final offline edit")
        let remote = try #require(try fixture.storeA.snapshot()).document
        let legacy = try fixture.recordLegacyMerge(local: original, remote: remote)
        // A has the omitted intermediate revision and can publish the complete
        // history of the exact merge B already holds.
        try fixture.storeA.importRemoteRevision(legacy)
        _ = try fixture.storeA.fastForward(
            to: legacy.revision.id, expectedLocalHead: remote.revision.id,
            idempotencyKey: WorkspaceObjectID(), inputDigest: String(repeating: "b", count: 64))
        _ = try await fixture.a.sync()
        #expect(try fixture.storeB.revision(missing) == nil)

        guard case .upToDate = try await fixture.b.sync() else {
            Issue.record("Matching heads should repair immutable history without creating a new revision")
            return
        }
        #expect(try fixture.storeB.revision(missing) != nil)
        #expect(try fixture.storeB.revisionHistory(from: legacy.revision.id).count == 4)
        #expect(try fixture.storeB.snapshot()?.document == legacy)
    }

    @Test func aConflictStopsThePassWithoutCommittingOrPublishing() async throws {
        let fixture = try await Fixture()
        defer { fixture.remove() }
        _ = try await fixture.a.sync()
        _ = try await fixture.b.sync()

        // Both devices rename the same item differently.
        try fixture.rename(store: fixture.storeA, artifact: Fixture.alpha, to: "A's name")
        try fixture.rename(store: fixture.storeB, artifact: Fixture.alpha, to: "B's name")
        _ = try await fixture.a.sync()
        let headBefore = try #require(try fixture.storeB.snapshot()).document.revision.id
        let remoteBefore = try await fixture.transportB.remoteState().head

        let outcome = try await fixture.b.sync()

        guard case .needsResolution(let conflicts) = outcome else {
            Issue.record("Expected an unresolved merge, got \(outcome).")
            return
        }
        #expect(conflicts.contains { $0.kind == .artifactField })
        // Nothing was committed here and nothing was pushed.
        #expect(try #require(try fixture.storeB.snapshot()).document.revision.id == headBefore)
        #expect(try await fixture.transportB.remoteState().head == remoteBefore)
        #expect(
            try #require(try fixture.storeB.snapshot())
                .document.artifacts.contains { $0.identity.displayName == "B's name" })
    }

    @Test func decidingAConflictConvergesBothDevicesOnTheChosenResult() async throws {
        let fixture = try await Fixture()
        defer { fixture.remove() }
        _ = try await fixture.a.sync()
        _ = try await fixture.b.sync()
        try fixture.rename(store: fixture.storeA, artifact: Fixture.alpha, to: "A's name")
        try fixture.rename(store: fixture.storeB, artifact: Fixture.alpha, to: "B's name")
        _ = try await fixture.a.sync()

        guard case .needsResolution(let conflicts) = try await fixture.b.sync() else {
            Issue.record("Expected a conflict on the second device.")
            return
        }
        // Undecided conflicts change nothing.
        let undecided = try await fixture.b.resolve([])
        guard case .needsResolution = undecided else {
            Issue.record("An unanswered conflict must not be applied, got \(undecided).")
            return
        }

        let decided = try await fixture.b.resolve(
            conflicts.map {
                .init(kind: $0.kind, artifactID: $0.artifactID, objectID: $0.objectID, choice: .keepLocal)
            })
        guard case .merged = decided else {
            Issue.record("Expected the decision to be applied, got \(decided).")
            return
        }
        _ = try await fixture.a.sync()

        for store in [fixture.storeA, fixture.storeB] {
            let snapshot = try #require(try store.snapshot())
            #expect(
                snapshot.document.artifacts.first { $0.identity.id == Fixture.alpha }?
                    .identity.displayName == "B's name")
        }
        #expect(
            try #require(try fixture.storeA.snapshot()).document.revision.id
                == (try #require(try fixture.storeB.snapshot())).document.revision.id)
    }

    @Test func repeatingAPassReturnsItsOriginalResult() async throws {
        let fixture = try await Fixture()
        defer { fixture.remove() }
        _ = try await fixture.a.sync()
        try fixture.rename(store: fixture.storeA, artifact: Fixture.alpha, to: "Renamed on A")
        _ = try await fixture.a.sync()
        let key = WorkspaceObjectID()

        guard case .adopted(let first) = try await fixture.b.sync(idempotencyKey: key) else {
            Issue.record("Expected an adoption.")
            return
        }
        let repeated = try await fixture.b.sync(idempotencyKey: key)

        guard case .upToDate = repeated else {
            Issue.record("A settled device must report up to date, got \(repeated).")
            return
        }
        #expect(try #require(try fixture.storeB.snapshot()).document.revision.id == first.committedRevisionID)
    }

    private struct Fixture {
        static let alpha = ArtifactID(fixtureUUID("00000000-0000-0000-0000-0000000000a1"))
        static let beta = ArtifactID(fixtureUUID("00000000-0000-0000-0000-0000000000b2"))

        let root: URL
        let storeA: WorkspaceRevisionStore
        let storeB: WorkspaceRevisionStore
        let transportB: GitWorkspaceTransport
        let a: WorkspaceSyncCoordinator
        let b: WorkspaceSyncCoordinator

        init(initialRevisionID: WorkspaceObjectID = WorkspaceObjectID()) async throws {
            root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
                .appending(path: "workspace-sync-\(UUID())")
            let remote = root.appending(path: "remote.git")
            try FileManager.default.createDirectory(
                at: remote, withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700])
            try GitTestFixture.git(["init", "--bare", "--initial-branch", "main", remote.path], in: root)

            let workspaceID = WorkspaceObjectID(fixtureUUID("00000000-0000-0000-0000-0000000000e5"))
            let writerA = WorkspaceObjectID()
            let writerB = WorkspaceObjectID()
            let document = try WorkspaceDocumentCoding.seal(
                .init(
                    workspaceID: workspaceID, revision: .init(id: initialRevisionID, writerID: writerA),
                    artifacts: [
                        .init(
                            identity: .init(id: Self.alpha, kind: .skill, displayName: "From A"),
                            authority: .trackedOnly),
                        .init(
                            identity: .init(id: Self.beta, kind: .skill, displayName: "Second"),
                            authority: .trackedOnly),
                    ]))
            // Each device keeps its own store and its own device identity.
            storeA = try WorkspaceRevisionStore(
                containerRoot: root.appending(path: "store-a"),
                workspaceID: workspaceID, deviceID: WorkspaceObjectID())
            try storeA.initialize(
                document: document,
                device: .init(
                    workspaceID: workspaceID,
                    deviceID: storeA.deviceID))
            storeB = try WorkspaceRevisionStore(
                containerRoot: root.appending(path: "store-b"),
                workspaceID: workspaceID, deviceID: WorkspaceObjectID())
            try storeB.initialize(
                document: document,
                device: .init(
                    workspaceID: workspaceID,
                    deviceID: storeB.deviceID))

            let transportA = try await GitTestFixture.enroll(remote: remote, checkout: root.appending(path: "checkout-a"))
            transportB = try await GitTestFixture.enroll(remote: remote, checkout: root.appending(path: "checkout-b"))
            a = WorkspaceSyncCoordinator(store: storeA, transport: transportA, writerID: writerA)
            b = WorkspaceSyncCoordinator(store: storeB, transport: transportB, writerID: writerB)
        }

        /// A local edit through the store's own committed command path.
        func rename(store: WorkspaceRevisionStore, artifact: ArtifactID, to name: String) throws {
            guard let head = try store.snapshot()?.document.revision.id else { return }
            _ = try store.commitMetadata(
                expectedRevisionID: head, idempotencyKey: WorkspaceObjectID(),
                inputDigest: String(repeating: "a", count: 64), writerID: WorkspaceObjectID()
            ) { document in
                guard let index = document.artifacts.firstIndex(where: { $0.identity.id == artifact })
                else { return [] }
                document.artifacts[index].identity.displayName = name
                return [artifact]
            }
        }

        /// The old client imported only the advertised head, then recorded a
        /// merge whose parent chain could include unpublished, absent revisions.
        func recordLegacyMerge(
            local: PortableWorkspaceDocument, remote: PortableWorkspaceDocument
        ) throws -> PortableWorkspaceDocument {
            try storeB.importRemoteRevision(remote)
            var legacy = remote
            legacy.revision = .init(parentIDs: [local.revision.id, remote.revision.id], writerID: WorkspaceObjectID())
            legacy = try WorkspaceDocumentCoding.seal(legacy)
            let receipt = try storeB.commitMerge(
                document: legacy, expectedLocalHead: local.revision.id, remoteRevisionID: remote.revision.id,
                idempotencyKey: WorkspaceObjectID(), inputDigest: String(repeating: "c", count: 64))
            return try #require(try storeB.revision(receipt.committedRevisionID))
        }

        func remove() { try? FileManager.default.removeItem(at: root) }
    }
}
