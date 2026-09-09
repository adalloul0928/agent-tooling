import Foundation
import Testing

@testable import AgentToolingCore

/// Returning to an earlier state moves the workspace forward to it. History is
/// never rewound, and a deletion that already travelled between Macs is not
/// quietly reversed by going back.
@Suite("Workspace restore points")
struct WorkspaceRestorePointsTests {
    @Test func historyIsOfferedFromWhereTheWorkspaceIsNowBackwards() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let start = fixture.head()
        let first = try fixture.commit { $0.artifacts = [Fixture.artifact(Self.alpha, "Alpha")] }
        let second = try fixture.commit {
            $0.artifacts = [Fixture.artifact(Self.alpha, "Alpha"), Fixture.artifact(Self.beta, "Beta")]
        }

        let points = try WorkspaceRestorePoints.available(in: fixture.store)

        #expect(points.map(\.revisionID) == [second, first, start])
        #expect(points.map(\.itemCount) == [2, 1, 0])
        // Exactly one point is where the workspace is: the rest are places it
        // could go back to.
        #expect(points.map(\.isCurrent) == [true, false, false])
    }

    @Test func onlyTheAskedForNumberOfPointsIsRead() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        for index in 0..<5 {
            _ = try fixture.commit { $0.artifacts = [Fixture.artifact(Self.alpha, "Alpha \(index)")] }
        }

        #expect(try WorkspaceRestorePoints.available(in: fixture.store, limit: 2).count == 2)
        #expect(try WorkspaceRestorePoints.available(in: fixture.store).count == 6)
    }

    @Test func aMemberOfAPackageIsNotCountedAsItsOwnItem() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        _ = try fixture.commit {
            var member = Fixture.artifact(Self.beta, "Bundled skill")
            member.identity.parentPackageID = Self.alpha
            member.declaredName = "bundled"
            $0.artifacts = [Fixture.artifact(Self.alpha, "A package", kind: .nativePlugin), member]
        }

        // Two records, one thing a person would say they have.
        #expect(try WorkspaceRestorePoints.available(in: fixture.store).first?.itemCount == 1)
    }

    @Test func thePreviewNamesWhatComesBackWhatGoesAndWhatChanges() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let before = try fixture.commit {
            $0.artifacts = [Fixture.artifact(Self.alpha, "Alpha"), Fixture.artifact(Self.beta, "Beta")]
            $0.assignments = [.init(artifactID: Self.alpha, destination: Fixture.codex, reason: .manual),
                              .init(artifactID: Self.beta, destination: Fixture.codex, reason: .manual)]
        }
        // Alpha is dropped, Beta is renamed, and something new arrives.
        _ = try fixture.commit {
            $0.artifacts = [Fixture.artifact(Self.beta, "Beta, renamed"),
                            Fixture.artifact(Self.gamma, "Gamma")]
            $0.assignments = [.init(artifactID: Self.beta, destination: Fixture.codex, reason: .manual)]
        }

        let preview = try #require(try WorkspaceRestorePoints.preview(restoring: before, in: fixture.store))

        #expect(preview.restoredItems == ["Alpha"])
        #expect(preview.removedItems == ["Gamma"])
        #expect(preview.changedItems == ["Beta"])
        #expect(preview.deletedSinceItems.isEmpty)
        #expect(preview.assignmentDifference == 1)
        #expect(!preview.isEmpty)
    }

    @Test func goingBackToWhereYouAlreadyAreChangesNothing() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let head = try fixture.commit { $0.artifacts = [Fixture.artifact(Self.alpha, "Alpha")] }

        let preview = try #require(try WorkspaceRestorePoints.preview(restoring: head, in: fixture.store))

        #expect(preview.isEmpty)
        #expect(preview.assignmentDifference == 0)
    }

    @Test func restoringMovesForwardToTheOldStateRatherThanRewindingHistory() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let before = try fixture.commit {
            $0.artifacts = [Fixture.artifact(Self.alpha, "Alpha")]
            $0.assignments = [.init(artifactID: Self.alpha, destination: Fixture.codex, reason: .manual)]
        }
        let regretted = try fixture.commit { $0.artifacts = []; $0.assignments = [] }

        let receipt = try WorkspaceRestorePoints.restore(
            before, in: fixture.store, expectedRevisionID: regretted, writerID: fixture.writerID)

        let snapshot = try #require(try fixture.store.snapshot())
        #expect(snapshot.document.revision.id == receipt.committedRevisionID)
        // A new revision, not the old one made current again.
        #expect(snapshot.document.revision.id != before)
        #expect(snapshot.document.revision.parentIDs == [regretted])
        #expect(snapshot.document.artifacts.map(\.identity.displayName) == ["Alpha"])
        #expect(snapshot.document.assignments.map(\.artifactID) == [Self.alpha])
        #expect(receipt.affectedArtifactIDs == [Self.alpha])
        // Both of the states it passed through are still readable.
        #expect(try fixture.store.revision(before) != nil)
        #expect(try fixture.store.revision(regretted) != nil)
    }

    @Test func somethingDeletedSinceIsNamedAndStillNotBroughtBack() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let before = try fixture.commit {
            $0.artifacts = [Fixture.artifact(Self.alpha, "Alpha"), Fixture.artifact(Self.beta, "Beta")]
            $0.assignments = [.init(artifactID: Self.alpha, destination: Fixture.codex, reason: .manual)]
        }
        // Alpha is deleted the way a deletion travels between Macs.
        let deletion = try fixture.commit { document in
            document.artifacts = [Fixture.artifact(Self.beta, "Beta")]
            document.assignments = []
            document.tombstones = [.init(artifactID: Self.alpha, deletedInRevisionID: document.revision.id)]
        }

        let preview = try #require(try WorkspaceRestorePoints.preview(restoring: before, in: fixture.store))
        #expect(preview.deletedSinceItems == ["Alpha"])
        #expect(preview.restoredItems.isEmpty)

        _ = try WorkspaceRestorePoints.restore(before, in: fixture.store,
                                               expectedRevisionID: deletion, writerID: fixture.writerID)

        let document = try #require(try fixture.store.snapshot()).document
        #expect(document.artifacts.map(\.identity.id) == [Self.beta])
        // The deletion is still recorded, so it still travels.
        #expect(document.tombstones.map(\.artifactID) == [Self.alpha])
        // And the assignment that only existed for the deleted item is not
        // smuggled back in alongside it.
        #expect(document.assignments.isEmpty)
        #expect(deletion != document.revision.id)
    }

    @Test func aRetryAfterALostAnswerRestoresOnceRatherThanTwice() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let before = try fixture.commit { $0.artifacts = [Fixture.artifact(Self.alpha, "Alpha")] }
        let head = try fixture.commit { $0.artifacts = [] }
        let key = WorkspaceObjectID()

        let first = try WorkspaceRestorePoints.restore(
            before, in: fixture.store, expectedRevisionID: head,
            writerID: fixture.writerID, idempotencyKey: key)
        // The caller never heard the answer, so it asks again in the same terms.
        let second = try WorkspaceRestorePoints.restore(
            before, in: fixture.store, expectedRevisionID: head,
            writerID: fixture.writerID, idempotencyKey: key)

        #expect(first == second)
        #expect(try #require(try fixture.store.snapshot()).document.revision.id == first.committedRevisionID)
        // One restore, one new revision: the second did not stack another.
        #expect(try WorkspaceRestorePoints.available(in: fixture.store).count == 4)
    }

    @Test func aRestoreDecidedAgainstAStateThatHasMovedOnIsRefused() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let before = try fixture.commit { $0.artifacts = [Fixture.artifact(Self.alpha, "Alpha")] }
        let seen = try fixture.commit { $0.artifacts = [] }
        // Something else changed the workspace between the preview and the tap.
        _ = try fixture.commit { $0.artifacts = [Fixture.artifact(Self.gamma, "Gamma")] }

        #expect(throws: (any Error).self) {
            _ = try WorkspaceRestorePoints.restore(
                before, in: fixture.store, expectedRevisionID: seen, writerID: fixture.writerID)
        }
        #expect(try #require(try fixture.store.snapshot()).document
            .artifacts.map(\.identity.id) == [Self.gamma])
    }

    @Test func aPointThisWorkspaceNeverHadIsNotAPlaceItCanGo() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let stranger = WorkspaceObjectID()

        #expect(try WorkspaceRestorePoints.preview(restoring: stranger, in: fixture.store) == nil)
        #expect(throws: WorkspaceRevisionStoreError.missingArtifact) {
            _ = try WorkspaceRestorePoints.restore(stranger, in: fixture.store,
                                                   expectedRevisionID: fixture.head(),
                                                   writerID: fixture.writerID)
        }
    }

    @Test func twoDifferentRestoresAreNotMistakenForARepeatOfEachOther() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let first = try fixture.commit { $0.artifacts = [Fixture.artifact(Self.alpha, "Alpha")] }
        let second = try fixture.commit {
            $0.artifacts = [Fixture.artifact(Self.alpha, "Alpha"), Fixture.artifact(Self.beta, "Beta")]
        }

        // Same head and the same key, different destination: the recorded
        // inputs must differ, or the second would silently replay the first's
        // result instead of being refused as a reused key.
        let key = WorkspaceObjectID()
        #expect(WorkspaceRestorePoints.inputDigest(first, second, key)
            != WorkspaceRestorePoints.inputDigest(second, second, key))
    }

    private static let alpha = ArtifactID(UUID(uuidString: "00000000-0000-0000-0000-0000000000a1")!)
    private static let beta = ArtifactID(UUID(uuidString: "00000000-0000-0000-0000-0000000000b2")!)
    private static let gamma = ArtifactID(UUID(uuidString: "00000000-0000-0000-0000-0000000000c3")!)

    private struct Fixture {
        static let codex = PortableDestination(surface: .codexCLI, scope: .user)
        let root: URL
        let store: WorkspaceRevisionStore
        let writerID = WorkspaceObjectID()

        init() throws {
            root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
                .appending(path: "restore-points-\(UUID())")
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700])
            let document = try WorkspaceDocumentCoding.seal(.init(
                workspaceID: WorkspaceObjectID(), revision: .init(writerID: WorkspaceObjectID())))
            let device = DeviceWorkspaceState(workspaceID: document.workspaceID)
            store = try WorkspaceRevisionStore(containerRoot: root.appending(path: "store"),
                workspaceID: document.workspaceID, deviceID: device.deviceID)
            try store.initialize(document: document, device: device)
        }

        static func artifact(
            _ id: ArtifactID, _ name: String, kind: ArtifactKind = .skill
        ) -> ArtifactRecord {
            .init(identity: .init(id: id, kind: kind, displayName: name), authority: .trackedOnly)
        }

        func head() -> WorkspaceObjectID {
            (try? store.snapshot())?.document.revision.id ?? WorkspaceObjectID()
        }

        /// Edits the workspace through the store's own command path and returns
        /// the revision that edit produced.
        @discardableResult
        func commit(_ mutation: @escaping (inout PortableWorkspaceDocument) -> Void) throws -> WorkspaceObjectID {
            try store.commitMetadata(
                expectedRevisionID: head(), idempotencyKey: WorkspaceObjectID(),
                inputDigest: String(repeating: "b", count: 64), writerID: writerID
            ) { document in
                mutation(&document)
                return document.artifacts.map(\.identity.id).sorted()
            }.committedRevisionID
        }

        func remove() { try? FileManager.default.removeItem(at: root) }
    }
}
