import Darwin
import Foundation
import Testing

@testable import AgentToolingCore

/// Linking a skill this library already holds to the repository that publishes
/// it.
///
/// The command writes three things and republishes nothing, so almost every
/// test here is about what did *not* move: the content digest, the display
/// name, the aliases, the saved placements, and the edits of a skill that
/// cannot be linked at all.
struct LinkSkillUpstreamCommandTests {
    // MARK: - The one it is for

    @Test func linkingMatchingBytesRecordsTheSourceLockAndOwnershipAndDisturbsNothingElse() async throws {
        let fixture = try await Fixture()
        defer { fixture.remove() }
        let before = try #require(try fixture.store.snapshot()).document
        let published = try Self.published(fixture.tree)
        #expect(published.review.contentDigest == fixture.digest)
        let ids = StandaloneSkillUpstreamIDs()
        let command = try fixture.link(published, ids: ids)

        let receipt = try await fixture.service.linkSkillUpstream(command, prepared: published)
        #expect(receipt.affectedArtifactIDs == [fixture.skillID])
        #expect(receipt.previousRevisionID == fixture.head)

        let after = try #require(try fixture.store.snapshot()).document
        let artifact = try #require(after.artifacts.first { $0.identity.id == fixture.skillID })
        #expect(artifact.authority == .centralUpstream(subscriptionID: ids.subscriptionID))
        // Linking is a statement about where the next version comes from, not a
        // new version. Everything the artifact already said stays said.
        #expect(artifact.contentDigest == fixture.digest)
        #expect(artifact.identity == before.artifacts[0].identity)
        #expect(artifact.declaredName == "release-readiness")
        #expect(after.assignments == before.assignments)
        #expect(!after.assignments.isEmpty)

        let source = try #require(after.sources.first)
        #expect(after.sources.count == 1)
        #expect(source.id == ids.sourceID)
        #expect(source.role == .publisherRepository)
        #expect(source.repositoryURL == "https://github.com/publisher/skills")
        #expect(source.requestedRef == "main")
        #expect(source.packageRelativePaths == ["skills/release-readiness"])

        let subscription = try #require(after.subscriptions.first)
        #expect(after.subscriptions.count == 1)
        #expect(subscription.id == ids.subscriptionID)
        #expect(subscription.artifactID == fixture.skillID)
        #expect(subscription.sourceID == ids.sourceID)
        #expect(subscription.lock.publisherID == "github:publisher")
        #expect(subscription.lock.sourceRootID == ids.sourceID)
        #expect(subscription.lock.requestedRef == "main")
        #expect(subscription.lock.approvedRevision.value == String(repeating: "a", count: 40))
        // The lock approves the bytes the library holds, not the fetched copy's
        // separate identity: they are the same bytes, which is the whole
        // precondition for linking at all.
        #expect(subscription.lock.approvedContent == fixture.digest)
        #expect(subscription.lock.packageRelativePath == "skills/release-readiness")

        // Nothing was published: the one stored object is still the one the
        // skill was admitted with.
        #expect(try fixture.objectNames() == [fixture.digest.value])
        let serialized = String(decoding: try WorkspaceDocumentCoding.encode(after), as: UTF8.self)
        #expect(!serialized.contains(fixture.root.path))
        #expect(!serialized.contains("Published instructions"))
    }

    /// The read-back the Skills screen does after linking: the recorded source
    /// and lock describe the repository the person chose.
    @Test func theRecordedSourceAndLockDescribeTheRepositoryThatWasLinked() async throws {
        let fixture = try await Fixture()
        defer { fixture.remove() }
        let published = try Self.published(fixture.tree)
        let ids = StandaloneSkillUpstreamIDs()
        _ = try await fixture.service.linkSkillUpstream(try fixture.link(published, ids: ids), prepared: published)

        let document = try #require(try fixture.store.snapshot()).document
        let subscription = try #require(document.subscriptions.first { $0.id == ids.subscriptionID })
        let source = try #require(document.sources.first { $0.id == subscription.sourceID })
        let binding = try SkillRepositoryBinding(
            repositoryURL: try #require(source.repositoryURL), ref: subscription.lock.requestedRef,
            subdirectory: subscription.lock.packageRelativePath)
        #expect(binding.repositoryURL == "https://github.com/publisher/skills")
        #expect(binding.ref == "main")
        #expect(binding.subdirectory == "skills/release-readiness")
        #expect(subscription.lock.approvedRevision.value == String(repeating: "a", count: 40))
    }

    @Test func aSecondSkillFromOneRepositoryReusesTheSourceAndAddsItsPath() async throws {
        let fixture = try await Fixture()
        defer { fixture.remove() }
        let first = try Self.published(fixture.tree)
        let firstIDs = StandaloneSkillUpstreamIDs()
        let linked = try await fixture.service.linkSkillUpstream(
            try fixture.link(first, ids: firstIDs), prepared: first)

        let second = try await fixture.admit(named: "Another", body: "A second held skill", at: linked.committedRevisionID)
        let secondPublished = try Self.published(second.tree, path: "skills/another", revision: "b")
        let secondIDs = StandaloneSkillUpstreamIDs(sourceID: firstIDs.sourceID)
        _ = try await fixture.service.linkSkillUpstream(
            try LinkSkillUpstreamCommand(
                expectedRevisionID: second.revisionID, artifactID: second.artifactID,
                expectedContentDigest: second.tree.digest, prepared: secondPublished, upstreamIDs: secondIDs),
            prepared: secondPublished)

        let document = try #require(try fixture.store.snapshot()).document
        #expect(document.sources.count == 1)
        #expect(document.sources[0].packageRelativePaths == ["skills/another", "skills/release-readiness"])
        #expect(document.subscriptions.count == 2)
        #expect(document.subscriptions.allSatisfy { $0.sourceID == firstIDs.sourceID })
        #expect(document.artifacts.allSatisfy { $0.contentDigest != nil })
    }

    @Test func theSameCommandTwiceReturnsTheOriginalReceiptAndWritesNothingTwice() async throws {
        let fixture = try await Fixture()
        defer { fixture.remove() }
        let published = try Self.published(fixture.tree)
        let command = try fixture.link(published, ids: .init())

        let first = try await fixture.service.linkSkillUpstream(command, prepared: published)
        let document = try #require(try fixture.store.snapshot()).document
        let second = try await fixture.service.linkSkillUpstream(command, prepared: published)
        #expect(first == second)
        #expect(try fixture.store.snapshot()?.document == document)
        #expect(document.subscriptions.count == 1)
    }

    // MARK: - The bytes must already match

    @Test func aSkillWithLocalEditsIsRefusedAndItsEditsAreUntouched() async throws {
        let fixture = try await Fixture(body: "Edited here after it was admitted")
        defer { fixture.remove() }
        let before = try #require(try fixture.store.snapshot()).document
        let published = try Self.published(try Self.tree(body: "What the repository publishes"))
        #expect(published.review.contentDigest != fixture.digest)

        // Refused while the command is being built, so a caller cannot even
        // hold one that would replace the person's own bytes.
        #expect(throws: LinkSkillUpstreamRefusal.contentDiffersFromUpstream) {
            try fixture.link(published, ids: .init())
        }
        // And refused again on the way in, for a command that came from
        // somewhere other than that initializer.
        let forced = try Self.decoded(
            try fixture.link(try Self.published(fixture.tree), ids: .init()), replacing: published.review)
        await #expect(throws: LinkSkillUpstreamRefusal.contentDiffersFromUpstream) {
            try await fixture.service.linkSkillUpstream(forced, prepared: published)
        }
        #expect(try fixture.store.snapshot()?.document == before)
        #expect(try fixture.objectNames() == [fixture.digest.value])
    }

    /// The library moving on after the fetch was reviewed is the same refusal
    /// and the same two routes out of it.
    @Test func aLibraryEditedAfterTheFetchWasReviewedIsRefused() async throws {
        let fixture = try await Fixture()
        defer { fixture.remove() }
        let published = try Self.published(fixture.tree)
        let command = try fixture.link(published, ids: .init())

        let edited = try WorkspaceSkillPreparation.personal(tree: try Self.tree(body: "A local edit"))
        _ = try await fixture.service.updateStandaloneSkill(
            .init(
                expectedRevisionID: fixture.head, artifactID: fixture.skillID,
                expectedContentDigest: fixture.digest, prepared: edited), prepared: edited)
        let moved = try #require(try fixture.store.snapshot()).document

        await #expect(throws: WorkspaceRevisionStoreError.staleRevision(current: moved.revision.id)) {
            try await fixture.service.linkSkillUpstream(command, prepared: published)
        }
        let retried = try LinkSkillUpstreamCommand(
            expectedRevisionID: moved.revision.id, artifactID: fixture.skillID,
            expectedContentDigest: fixture.digest, prepared: published)
        await #expect(throws: LinkSkillUpstreamRefusal.contentDiffersFromUpstream) {
            try await fixture.service.linkSkillUpstream(retried, prepared: published)
        }
        #expect(try fixture.store.snapshot()?.document.subscriptions.isEmpty == true)
    }

    // MARK: - Everything that is not a personal skill

    @Test func everyOtherOwnershipIsRefusedInItsOwnWords() throws {
        let tree = try Self.tree()
        let published = try Self.published(tree)
        let authoringID = WorkspaceObjectID()
        // Each one is a workspace the document itself admits, so the refusal is
        // the command's rather than a document that could not have existed.
        let expected: [(PortableWorkspaceDocument, LinkSkillUpstreamRefusal)] = [
            (try Self.linked(try Self.held(digest: tree.digest), ids: .init(), tree: tree), .alreadyFollowingRepository),
            (
                try Self.held(
                    digest: tree.digest, authority: .attachedAuthoring(sourceRootID: authoringID),
                    sources: [.init(id: authoringID, role: .attachedAuthoring)]), .attachedAuthoring
            ),
            (try Self.held(digest: tree.digest, authority: .nativeOwned), .contentNotHeldHere),
            (try Self.held(digest: tree.digest, authority: .trackedOnly), .contentNotHeldHere),
        ]
        for (document, refusal) in expected {
            var candidate = document
            let command = try LinkSkillUpstreamCommand(
                expectedRevisionID: document.revision.id, artifactID: Self.skillID,
                expectedContentDigest: tree.digest, prepared: published)
            #expect(throws: refusal) { try command.apply(to: &candidate) }
            #expect(candidate == document)
        }
    }

    @Test func aBundledSkillAndOneDeliveredByAClientAreRefused() throws {
        let tree = try Self.tree()
        let published = try Self.published(tree)
        var bundled = try Self.held(digest: tree.digest)
        bundled.artifacts[0].identity.parentPackageID = ArtifactID()
        var routed = try Self.held(digest: tree.digest)
        routed.artifacts[0].nativeRoutes = [.init(client: .claude, externalPluginID: "pack")]
        let command = try LinkSkillUpstreamCommand(
            expectedRevisionID: bundled.revision.id, artifactID: Self.skillID,
            expectedContentDigest: tree.digest, prepared: published)

        #expect(throws: LinkSkillUpstreamRefusal.bundled) { try command.apply(to: &bundled) }
        #expect(throws: LinkSkillUpstreamRefusal.contentNotHeldHere) { try command.apply(to: &routed) }
    }

    @Test func aSkillWithNoRecordedContentIsRefused() throws {
        let tree = try Self.tree()
        let published = try Self.published(tree)
        var document = try Self.held(digest: tree.digest)
        document.artifacts[0].contentDigest = nil
        let command = try LinkSkillUpstreamCommand(
            expectedRevisionID: document.revision.id, artifactID: Self.skillID,
            expectedContentDigest: tree.digest, prepared: published)

        #expect(throws: LinkSkillUpstreamRefusal.missingContent) { try command.apply(to: &document) }
    }

    @Test func aSkillThisWorkspaceDoesNotHaveIsNotSilentlyCreated() throws {
        let tree = try Self.tree()
        let published = try Self.published(tree)
        var document = try Self.held(digest: tree.digest)
        let command = try LinkSkillUpstreamCommand(
            expectedRevisionID: document.revision.id, artifactID: ArtifactID(),
            expectedContentDigest: tree.digest, prepared: published)

        #expect(throws: WorkspaceRevisionStoreError.missingArtifact) { try command.apply(to: &document) }
        #expect(document.sources.isEmpty)
    }

    // MARK: - One repository, one entry

    @Test func aSecondIdentityForOneRepositoryAndRefIsRefused() async throws {
        let fixture = try await Fixture()
        defer { fixture.remove() }
        let first = try Self.published(fixture.tree)
        let linked = try await fixture.service.linkSkillUpstream(
            try fixture.link(first, ids: .init()), prepared: first)
        let second = try await fixture.admit(named: "Another", body: "A second held skill", at: linked.committedRevisionID)
        let secondPublished = try Self.published(second.tree, path: "skills/another")

        await #expect(throws: LinkSkillUpstreamRefusal.sourceIdentityConflict) {
            try await fixture.service.linkSkillUpstream(
                try LinkSkillUpstreamCommand(
                    expectedRevisionID: second.revisionID, artifactID: second.artifactID,
                    expectedContentDigest: second.tree.digest, prepared: secondPublished),
                prepared: secondPublished)
        }
        #expect(try fixture.store.snapshot()?.document.sources.count == 1)
    }

    @Test func aFolderAnotherSkillAlreadyFollowsIsRefused() async throws {
        let fixture = try await Fixture()
        defer { fixture.remove() }
        let first = try Self.published(fixture.tree)
        let ids = StandaloneSkillUpstreamIDs()
        let linked = try await fixture.service.linkSkillUpstream(
            try fixture.link(first, ids: ids), prepared: first)
        let second = try await fixture.admit(named: "Another", body: "A second held skill", at: linked.committedRevisionID)
        let sameFolder = try Self.published(second.tree)

        await #expect(throws: LinkSkillUpstreamRefusal.upstreamAlreadyManaged) {
            try await fixture.service.linkSkillUpstream(
                try LinkSkillUpstreamCommand(
                    expectedRevisionID: second.revisionID, artifactID: second.artifactID,
                    expectedContentDigest: second.tree.digest, prepared: sameFolder,
                    upstreamIDs: .init(sourceID: ids.sourceID)),
                prepared: sameFolder)
        }
        #expect(try fixture.store.snapshot()?.document.subscriptions.count == 1)
    }

    @Test func anIdentityAlreadyInUseIsRefused() async throws {
        let fixture = try await Fixture()
        defer { fixture.remove() }
        let published = try Self.published(fixture.tree)
        let shared = WorkspaceObjectID()
        let collisions = [
            StandaloneSkillUpstreamIDs(sourceID: shared, subscriptionID: shared),
            StandaloneSkillUpstreamIDs(sourceID: WorkspaceObjectID(fixture.skillID.rawValue)),
            StandaloneSkillUpstreamIDs(subscriptionID: WorkspaceObjectID(fixture.skillID.rawValue)),
        ]
        for ids in collisions {
            await #expect(throws: LinkSkillUpstreamRefusal.identityCollision) {
                try await fixture.service.linkSkillUpstream(try fixture.link(published, ids: ids), prepared: published)
            }
        }
        #expect(try fixture.store.snapshot()?.document.revision.id == fixture.head)
    }

    // MARK: - A review this command did not see

    @Test func aPreparationThatDidNotComeFromARepositoryIsRefused() async throws {
        let fixture = try await Fixture()
        defer { fixture.remove() }
        let personal = try WorkspaceSkillPreparation.personal(tree: fixture.tree)

        #expect(throws: LinkSkillUpstreamRefusal.reviewMismatch) { try fixture.link(personal, ids: .init()) }
        let forced = try Self.decoded(
            try fixture.link(try Self.published(fixture.tree), ids: .init()), replacing: personal.review)
        await #expect(throws: LinkSkillUpstreamRefusal.reviewMismatch) {
            try await fixture.service.linkSkillUpstream(forced, prepared: personal)
        }
    }

    @Test func applyingSomethingOtherThanWhatWasReviewedIsRefused() async throws {
        let fixture = try await Fixture()
        defer { fixture.remove() }
        let reviewed = try Self.published(fixture.tree)
        let moved = try Self.published(fixture.tree, revision: "c")
        let command = try fixture.link(reviewed, ids: .init())

        await #expect(throws: LinkSkillUpstreamRefusal.reviewMismatch) {
            try await fixture.service.linkSkillUpstream(command, prepared: moved)
        }
        #expect(try fixture.store.snapshot()?.document.subscriptions.isEmpty == true)
    }

    @Test func aStaleExpectedRevisionIsRefusedBeforeAnythingIsWritten() async throws {
        let fixture = try await Fixture()
        defer { fixture.remove() }
        let published = try Self.published(fixture.tree)
        let stale = try LinkSkillUpstreamCommand(
            expectedRevisionID: WorkspaceObjectID(), artifactID: fixture.skillID,
            expectedContentDigest: fixture.digest, prepared: published)

        await #expect(throws: WorkspaceRevisionStoreError.staleRevision(current: fixture.head)) {
            try await fixture.service.linkSkillUpstream(stale, prepared: published)
        }
        #expect(try fixture.store.snapshot()?.document.sources.isEmpty == true)
    }

    @Test func theCommandCarriesNoFileBytesAndNoPathOnThisMac() async throws {
        let fixture = try await Fixture(body: "private body fixture")
        defer { fixture.remove() }
        let published = try Self.published(fixture.tree)
        let command = try fixture.link(published, ids: .init())

        let encoded = try JSONEncoder().encode(command)
        #expect(try JSONDecoder().decode(LinkSkillUpstreamCommand.self, from: encoded) == command)
        let text = String(decoding: encoded, as: UTF8.self)
        #expect(!text.contains(fixture.root.path))
        #expect(!text.contains("private body fixture"))
        #expect(text.contains(fixture.digest.value))
    }

    // MARK: - Merge and sync

    /// A workspace nobody has linked anything in must read, validate and merge
    /// exactly as it did before this command existed.
    @Test func aWorkspaceThatHasLinkedNothingReadsAndMergesUnchanged() throws {
        let document = try Self.held(digest: try Self.tree().digest)
        try document.validateStructure()
        try DeviceWorkspaceState(workspaceID: document.workspaceID).validateStructure(against: document)

        let merged = WorkspaceMergeEngine.merge(
            base: document, local: document, remote: document, writerID: WorkspaceObjectID())
        let result = try #require(merged.document)
        #expect(merged.conflicts.isEmpty)
        #expect(result.artifacts == document.artifacts)
        #expect(result.sources.isEmpty)
        #expect(result.subscriptions.isEmpty)
    }

    /// The ordinary case: one Mac links, the other has not.
    @Test func linkingOnOneMacAndNothingOnTheOtherFastForwards() throws {
        let tree = try Self.tree()
        let base = try Self.held(digest: tree.digest)
        let ids = StandaloneSkillUpstreamIDs()
        let local = try Self.linked(base, ids: ids, tree: tree)

        let merged = WorkspaceMergeEngine.merge(
            base: base, local: local, remote: base, writerID: WorkspaceObjectID())
        let result = try #require(merged.document)
        #expect(merged.conflicts.isEmpty)
        #expect(result.artifacts[0].authority == .centralUpstream(subscriptionID: ids.subscriptionID))
        #expect(result.sources.map(\.id) == [ids.sourceID])
        #expect(result.subscriptions.map(\.id) == [ids.subscriptionID])
        // Nothing on this side needs device state: a publisher source is
        // fetched into a cache, unlike an attached authoring folder.
        try DeviceWorkspaceState(workspaceID: result.workspaceID).validateStructure(against: result)
    }

    /// Both Macs linking the same skill separately. Each allocated its own
    /// subscription, only one of which the merged artifact can point at.
    ///
    /// The merge says which item that happened to rather than failing whole
    /// with nothing to name: the unnamed subscription is set aside, the rest of
    /// the merge is still readable, and the conflict stands until the person
    /// drops one side on the Mac that made it.
    @Test func bothMacsLinkingTheSameSkillIsNamedRatherThanLeftAsAnInvalidResult() throws {
        let tree = try Self.tree()
        let base = try Self.held(digest: tree.digest)
        let mine = StandaloneSkillUpstreamIDs()
        let theirs = StandaloneSkillUpstreamIDs()
        let local = try Self.linked(base, ids: mine, tree: tree)
        let remote = try Self.linked(base, ids: theirs, tree: tree, repository: "https://github.com/another/skills")

        let merged = WorkspaceMergeEngine.merge(
            base: base, local: local, remote: remote, writerID: WorkspaceObjectID())
        #expect(merged.conflicts.contains { $0.kind == .ownership })
        let named = try #require(merged.conflicts.first { $0.kind == .subscriptionOwnerCollision })
        #expect(named.detail == "Both Macs made this skill follow a repository separately.")
        #expect(named.artifactID == Self.skillID)
        #expect(named.objectID == theirs.subscriptionID)
        #expect(!merged.conflicts.contains { $0.kind == .invalidResult })
        // Everything else still combined, and the result is a document the
        // contract admits — it just must not be applied while this stands.
        let result = try #require(merged.document)
        #expect(!merged.isResolved)
        try result.validateStructure()
        #expect(result.artifacts[0].authority == .centralUpstream(subscriptionID: mine.subscriptionID))
        #expect(result.subscriptions.map(\.id) == [mine.subscriptionID])
        // The other Mac's repository is still recorded; only the subscription
        // nothing could name was set aside.
        #expect(Set(result.sources.map(\.id)) == [mine.sourceID, theirs.sourceID])
        // Neither Mac lost anything: both revisions still describe their own.
        #expect(local.subscriptions.map(\.id) == [mine.subscriptionID])
        #expect(remote.subscriptions.map(\.id) == [theirs.subscriptionID])
    }

    /// Both Macs made the same skill follow a repository, and there is no
    /// answer this Mac can give: dropping the other Mac's link is that Mac's
    /// act. The resolver declines it by name rather than pretending.
    @Test func theResolverDeclinesTwoSeparateLinksToOneSkill() throws {
        let tree = try Self.tree()
        let base = try Self.held(digest: tree.digest)
        let mine = StandaloneSkillUpstreamIDs()
        let theirs = StandaloneSkillUpstreamIDs()
        let local = try Self.linked(base, ids: mine, tree: tree)
        let remote = try Self.linked(base, ids: theirs, tree: tree, repository: "https://github.com/another/skills")
        let merged = WorkspaceMergeEngine.merge(
            base: base, local: local, remote: remote, writerID: WorkspaceObjectID())

        let resolved = WorkspaceConflictResolver.resolve(
            base: base, local: local, remote: remote, conflicts: merged.conflicts,
            resolutions: merged.conflicts.map {
                .init(kind: $0.kind, artifactID: $0.artifactID, objectID: $0.objectID, choice: .keepLocal)
            }, writerID: WorkspaceObjectID())
        #expect(!resolved.isResolved)
        #expect(resolved.remaining.map(\.kind) == [.subscriptionOwnerCollision])
        // And a screen must not offer a picker that cannot settle it.
        #expect(!WorkspaceMergeConflictKind.subscriptionOwnerCollision.isSettledByChoosingASide)
    }

    /// One Mac links while the other edits the content. Each side moved one
    /// fact only, so the ordinary rules would take the new authority and the
    /// new bytes together and leave the lock approving a version nobody holds.
    @Test func linkingWhileTheOtherMacEditsTheContentIsNamedRatherThanLeftAsAnInvalidResult() throws {
        let tree = try Self.tree()
        let base = try Self.held(digest: tree.digest)
        let ids = StandaloneSkillUpstreamIDs()
        let local = try Self.linked(base, ids: ids, tree: tree)
        let remote = try Self.edited(base)

        let merged = WorkspaceMergeEngine.merge(
            base: base, local: local, remote: remote, writerID: WorkspaceObjectID())
        let named = try #require(merged.conflicts.first { $0.kind == .subscriptionContentMismatch })
        #expect(named.detail == "One Mac made this skill follow a repository while the other changed its files.")
        #expect(named.artifactID == Self.skillID)
        #expect(named.objectID == ids.subscriptionID)
        #expect(!merged.conflicts.contains { $0.kind == .invalidResult })
        let result = try #require(merged.document)
        #expect(!merged.isResolved)
        try result.validateStructure()
        // The approved digest is put back rather than the lock being rewritten
        // to claim the publisher published the person's own edit.
        #expect(result.artifacts[0].contentDigest == tree.digest)
        #expect(result.subscriptions[0].lock.approvedContent == tree.digest)
    }

    /// Keeping the followed version: the approved bytes come back and the skill
    /// still follows the repository.
    @Test func resolvingALinkAgainstAnEditCanKeepTheFollowedVersion() throws {
        let tree = try Self.tree()
        let base = try Self.held(digest: tree.digest)
        let ids = StandaloneSkillUpstreamIDs()
        let local = try Self.linked(base, ids: ids, tree: tree)
        let remote = try Self.edited(base)
        let merged = WorkspaceMergeEngine.merge(
            base: base, local: local, remote: remote, writerID: WorkspaceObjectID())

        let resolved = WorkspaceConflictResolver.resolve(
            base: base, local: local, remote: remote, conflicts: merged.conflicts,
            resolutions: merged.conflicts.map {
                .init(kind: $0.kind, artifactID: $0.artifactID, objectID: $0.objectID, choice: .keepLocal)
            }, writerID: WorkspaceObjectID())
        let document = try #require(resolved.document)
        #expect(resolved.isResolved)
        #expect(document.artifacts[0].authority == .centralUpstream(subscriptionID: ids.subscriptionID))
        #expect(document.artifacts[0].contentDigest == tree.digest)
        #expect(document.subscriptions.map(\.id) == [ids.subscriptionID])
        #expect(WorkspaceMergeConflictKind.subscriptionContentMismatch.isSettledByChoosingASide)
    }

    /// Keeping the edit: the skill goes back to being the person's own, and the
    /// subscription goes with the authority that named it. The edited bytes are
    /// the ones the library holds afterwards.
    @Test func resolvingALinkAgainstAnEditCanKeepThePersonalEdit() throws {
        let tree = try Self.tree()
        let edit = try Self.tree(body: "Edited on the other Mac")
        let base = try Self.held(digest: tree.digest)
        let ids = StandaloneSkillUpstreamIDs()
        let local = try Self.linked(base, ids: ids, tree: tree)
        let remote = try Self.edited(base)
        let merged = WorkspaceMergeEngine.merge(
            base: base, local: local, remote: remote, writerID: WorkspaceObjectID())

        let resolved = WorkspaceConflictResolver.resolve(
            base: base, local: local, remote: remote, conflicts: merged.conflicts,
            resolutions: merged.conflicts.map {
                .init(kind: $0.kind, artifactID: $0.artifactID, objectID: $0.objectID, choice: .takeRemote)
            }, writerID: WorkspaceObjectID())
        let document = try #require(resolved.document)
        #expect(resolved.isResolved)
        #expect(document.artifacts[0].authority == .centralPersonal)
        #expect(document.artifacts[0].contentDigest == edit.digest)
        #expect(document.subscriptions.isEmpty)
    }

    // MARK: - Fixtures

    private static let skillID = ArtifactID()

    private static func tree(body: String = "Published instructions") throws -> CapturedPackageTree {
        try CapturedPackageTree(entries: [
            .init(
                relativePath: "SKILL.md",
                kind: .file(
                    bytes: Data(
                        """
                        ---
                        name: release-readiness
                        description: Check whether a release is ready to ship.
                        ---
                        \(body)
                        """.utf8), executable: false)),
            .init(relativePath: "references", kind: .directory),
            .init(
                relativePath: "references/reference.md",
                kind: .file(bytes: Data("# Reference\n".utf8), executable: false)),
        ])
    }

    /// Built here rather than fetched: the only public upstream factory runs
    /// `git`, and the preparation suite is where that is covered.
    private static func published(
        _ tree: CapturedPackageTree, repository: String = "https://github.com/publisher/skills",
        ref: String = "main", path: String = "skills/release-readiness",
        revision: Character = "a", publisher: String = "github:publisher"
    ) throws -> PreparedStandaloneSkill {
        try PreparedStandaloneSkill(
            tree: tree,
            upstream: .init(
                repositoryURL: repository, requestedRef: ref,
                revision: .init(kind: .gitCommitSHA1, value: String(repeating: revision, count: 40)),
                packageRelativePath: path, publisherID: publisher))
    }

    /// One skill this library holds, without a store behind it, for the
    /// refusals that are decided before anything is written.
    private static func held(
        digest: ContentDigest, authority: ContentAuthority = .centralPersonal,
        sources: [PortableSourceDescriptor] = []
    ) throws -> PortableWorkspaceDocument {
        try WorkspaceDocumentCoding.seal(
            .init(
                workspaceID: WorkspaceObjectID(), revision: .init(writerID: WorkspaceObjectID()),
                artifacts: [
                    .init(
                        identity: .init(id: skillID, kind: .skill, displayName: "Release Readiness"),
                        authority: authority, declaredName: "release-readiness", contentDigest: digest)
                ],
                sources: sources))
    }

    private static func linked(
        _ document: PortableWorkspaceDocument, ids: StandaloneSkillUpstreamIDs,
        tree: CapturedPackageTree, repository: String = "https://github.com/publisher/skills"
    ) throws -> PortableWorkspaceDocument {
        var linked = document
        let command = try LinkSkillUpstreamCommand(
            expectedRevisionID: document.revision.id, artifactID: skillID,
            expectedContentDigest: tree.digest, prepared: try published(tree, repository: repository),
            upstreamIDs: ids)
        _ = try command.apply(to: &linked)
        return try WorkspaceDocumentCoding.seal(linked)
    }

    /// The other Mac's version of the same held skill, with its files changed
    /// and nothing else touched.
    private static func edited(
        _ document: PortableWorkspaceDocument, body: String = "Edited on the other Mac"
    ) throws -> PortableWorkspaceDocument {
        var edited = document
        edited.artifacts[0].contentDigest = try Self.tree(body: body).digest
        return try WorkspaceDocumentCoding.seal(edited)
    }

    /// A command that never went through the initializer, which is the only way
    /// to reach the guards that re-establish what the initializer proved.
    private static func decoded(
        _ command: LinkSkillUpstreamCommand, replacing content: StandaloneSkillContentReview
    ) throws -> LinkSkillUpstreamCommand {
        let encoder = JSONEncoder()
        var fields = try #require(
            try JSONSerialization.jsonObject(with: try encoder.encode(command)) as? [String: Any])
        fields["content"] = try JSONSerialization.jsonObject(with: try encoder.encode(content))
        return try JSONDecoder().decode(
            LinkSkillUpstreamCommand.self, from: try JSONSerialization.data(withJSONObject: fields))
    }

    private struct Fixture {
        let root: URL
        let contentRoot: URL
        let store: WorkspaceRevisionStore
        let service: WorkspaceApplicationService
        let skillID: ArtifactID
        let tree: CapturedPackageTree
        let digest: ContentDigest
        /// The head after the skill was admitted and one placement saved.
        let head: WorkspaceObjectID

        init(body: String = "Published instructions") async throws {
            root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
                .appending(path: "link-upstream-\(UUID())")
            contentRoot = root.appending(path: "content")
            try FileManager.default.createDirectory(
                at: contentRoot, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let writerID = WorkspaceObjectID()
            let document = try WorkspaceDocumentCoding.seal(.init(revision: .init(writerID: writerID)))
            let device = DeviceWorkspaceState(workspaceID: document.workspaceID)
            store = try .init(containerRoot: root, workspaceID: document.workspaceID, deviceID: device.deviceID)
            try store.initialize(document: document, device: device)
            service = .init(store: store, writerID: writerID, contentStore: try .init(directory: contentRoot))

            tree = try LinkSkillUpstreamCommandTests.tree(body: body)
            digest = tree.digest
            skillID = ArtifactID()
            let personal = try WorkspaceSkillPreparation.personal(tree: tree)
            let admitted = try await service.intakeStandaloneSkill(
                .init(
                    expectedRevisionID: document.revision.id, artifactID: skillID,
                    displayName: "Release Readiness",
                    aliases: [.init(namespace: "claude.skill", value: "release-readiness")],
                    prepared: personal), prepared: personal)
            // One saved placement, so linking can be shown not to disturb it.
            guard let snapshot = try store.snapshot() else { throw WorkspaceRevisionStoreError.notInitialized }
            let placed = try await service.applyAssignmentBatch(
                try .assign(
                    document: snapshot.document, artifactIDs: [skillID],
                    destinations: [.init(surface: .claudeCode, scope: .user)]))
            _ = admitted
            head = placed.committedRevisionID
        }

        func link(
            _ prepared: PreparedStandaloneSkill, ids: StandaloneSkillUpstreamIDs
        ) throws -> LinkSkillUpstreamCommand {
            try .init(
                expectedRevisionID: head, artifactID: skillID, expectedContentDigest: digest,
                prepared: prepared, upstreamIDs: ids)
        }

        /// A second held skill, so one repository can be asked for two of them.
        func admit(
            named displayName: String, body: String, at revisionID: WorkspaceObjectID
        ) async throws -> (artifactID: ArtifactID, tree: CapturedPackageTree, revisionID: WorkspaceObjectID) {
            let tree = try LinkSkillUpstreamCommandTests.tree(body: body)
            let prepared = try WorkspaceSkillPreparation.personal(tree: tree)
            let artifactID = ArtifactID()
            let receipt = try await service.intakeStandaloneSkill(
                .init(
                    expectedRevisionID: revisionID, artifactID: artifactID, displayName: displayName,
                    prepared: prepared), prepared: prepared)
            return (artifactID, tree, receipt.committedRevisionID)
        }

        func objectNames() throws -> [String] {
            try FileManager.default.contentsOfDirectory(atPath: contentRoot.appending(path: "objects").path).sorted()
        }

        func remove() {
            Self.makeDirectoriesRemovable(root)
            try? FileManager.default.removeItem(at: root)
        }

        private static func makeDirectoriesRemovable(_ url: URL) {
            var value = stat()
            guard lstat(url.path, &value) == 0, value.st_mode & S_IFMT == S_IFDIR else { return }
            _ = chmod(url.path, 0o700)
            for child in (try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil)) ?? [] {
                makeDirectoriesRemovable(child)
            }
        }
    }
}
