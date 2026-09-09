import Darwin
import Foundation
import Testing

@testable import AgentToolingCore

struct WorkspaceUpstreamSkillCommandTests {
    @Test func intakeAndUpdateRetainRepositoryOwnershipAndEveryPreviousVersion() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let original = try prepared(body: "Original")
        let ids = StandaloneSkillUpstreamIDs()
        let command = fixture.intake(original, ids: ids)
        let receipt = try await fixture.service.intakeStandaloneSkill(command, prepared: original)
        let first = try #require(try fixture.store.snapshot())
        let artifact = try #require(first.document.artifacts.first)
        #expect(artifact.identity.id == command.artifactID)
        #expect(artifact.identity.displayName == "Reviewed skill")
        #expect(artifact.declaredName == "publisher-skill")
        #expect(artifact.authority == .centralUpstream(subscriptionID: ids.subscriptionID))
        #expect(first.document.subscriptions[0].lock.approvedContent == original.tree.digest)
        #expect(first.document.subscriptions[0].lock.approvedRevision.value == String(repeating: "a", count: 40))
        #expect(first.document.subscriptions[0].lock.approvedRevision.value != original.tree.digest.value)
        #expect(first.document.sources[0].repositoryURL == "https://github.com/publisher/skills")
        #expect(first.document.sources[0].requestedRef == "main")
        #expect(first.document.sources[0].packageRelativePaths == ["skills/publisher-skill"])
        #expect(first.document.assignments.isEmpty)
        #expect(first.device == fixture.device)

        let next = try prepared(body: "Updated by publisher", revision: "b")
        let update = StandaloneSkillUpdateCommand(expectedRevisionID: receipt.committedRevisionID,
            artifactID: command.artifactID, expectedContentDigest: original.tree.digest, prepared: next)
        let result = try await fixture.service.updateStandaloneSkill(update, prepared: next)
        let after = try #require(try fixture.store.snapshot())
        #expect(after.document.artifacts[0].identity == artifact.identity)
        #expect(after.document.artifacts[0].authority == artifact.authority)
        #expect(after.document.sources == first.document.sources)
        #expect(after.document.subscriptions[0].id == ids.subscriptionID)
        #expect(after.document.subscriptions[0].lock.approvedContent == next.tree.digest)
        #expect(after.document.subscriptions[0].lock.approvedRevision.value == String(repeating: "b", count: 40))
        #expect(try await fixture.service.skillContent(artifactID: command.artifactID,
            revisionID: receipt.committedRevisionID).tree == original.tree)
        #expect(try await fixture.service.skillContent(artifactID: command.artifactID,
            revisionID: result.committedRevisionID).tree == next.tree)
        #expect(try await fixture.service.updateStandaloneSkill(update, prepared: next) == result)

        let serialized = String(decoding: try WorkspaceDocumentCoding.encode(after.document), as: UTF8.self)
        #expect(!serialized.contains(fixture.root.path))
        #expect(!serialized.contains("Updated by publisher"))
    }

    @Test func aSharedSourceGainsAnotherPathWithoutDuplicatingOrRetargetingTheFirstSkill() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let first = try prepared()
        let firstIDs = StandaloneSkillUpstreamIDs()
        let firstCommand = fixture.intake(first, ids: firstIDs)
        let saved = try await fixture.service.intakeStandaloneSkill(firstCommand, prepared: first)
        let second = try prepared(path: "skills/another", body: "Another skill")
        let secondIDs = StandaloneSkillUpstreamIDs(sourceID: firstIDs.sourceID)
        let secondCommand = StandaloneSkillIntakeCommand(expectedRevisionID: saved.committedRevisionID,
            displayName: "Another", prepared: second, upstreamIDs: secondIDs)
        let result = try await fixture.service.intakeStandaloneSkill(secondCommand, prepared: second)
        let document = try #require(try fixture.store.snapshot()?.document)
        #expect(document.sources.count == 1)
        #expect(document.sources[0].packageRelativePaths == ["skills/another", "skills/publisher-skill"])
        #expect(document.subscriptions.count == 2)
        #expect(document.subscriptions.first(where: { $0.id == firstIDs.subscriptionID })?.lock.approvedContent == first.tree.digest)

        let duplicate = StandaloneSkillIntakeCommand(expectedRevisionID: result.committedRevisionID,
            displayName: "Duplicate", prepared: second, upstreamIDs: .init(sourceID: firstIDs.sourceID))
        await #expect(throws: WorkspaceSkillCommandError.upstreamAlreadyManaged) {
            try await fixture.service.intakeStandaloneSkill(duplicate, prepared: second)
        }
        let differentID = StandaloneSkillIntakeCommand(expectedRevisionID: result.committedRevisionID,
            displayName: "Duplicate source", prepared: second, upstreamIDs: .init())
        await #expect(throws: WorkspaceSkillCommandError.sourceIdentityConflict) {
            try await fixture.service.intakeStandaloneSkill(differentID, prepared: second)
        }
        #expect(try fixture.store.snapshot()?.document == document)
    }

    @Test func updatingCannotForkOrChangeAnUpstreamBinding() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let original = try prepared()
        let intake = fixture.intake(original, ids: .init())
        let receipt = try await fixture.service.intakeStandaloneSkill(intake, prepared: original)
        let personal = try WorkspaceSkillPreparation.personal(tree: original.tree)
        let personalUpdate = StandaloneSkillUpdateCommand(expectedRevisionID: receipt.committedRevisionID,
            artifactID: intake.artifactID, expectedContentDigest: original.tree.digest, prepared: personal)
        await #expect(throws: WorkspaceSkillCommandError.unsupportedAuthority) {
            try await fixture.service.updateStandaloneSkill(personalUpdate, prepared: personal)
        }
        let changes = [
            try prepared(repository: "https://github.com/another/skills"),
            try prepared(ref: "next"),
            try prepared(path: "skills/different"),
            try prepared(publisher: "github:another"),
        ]
        for change in changes {
            let update = StandaloneSkillUpdateCommand(expectedRevisionID: receipt.committedRevisionID,
                artifactID: intake.artifactID, expectedContentDigest: original.tree.digest, prepared: change)
            await #expect(throws: WorkspaceSkillCommandError.upstreamBindingChanged) {
                try await fixture.service.updateStandaloneSkill(update, prepared: change)
            }
        }
        #expect(try fixture.store.snapshot()?.document.revision.id == receipt.committedRevisionID)
    }

    @Test func upstreamIdentifiersMustBeExplicitAndCannotReplaceExistingIdentities() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let first = try prepared()
        let missingIDs = fixture.intake(first, ids: nil)
        await #expect(throws: WorkspaceSkillCommandError.reviewMismatch) {
            try await fixture.service.intakeStandaloneSkill(missingIDs, prepared: first)
        }
        let oneID = WorkspaceObjectID()
        let colliding = fixture.intake(first, ids: .init(sourceID: oneID, subscriptionID: oneID))
        await #expect(throws: WorkspaceSkillCommandError.identityCollision) {
            try await fixture.service.intakeStandaloneSkill(colliding, prepared: first)
        }
        let personal = try WorkspaceSkillPreparation.personal(tree: first.tree)
        let wrongKind = fixture.intake(personal, ids: .init())
        await #expect(throws: WorkspaceSkillCommandError.reviewMismatch) {
            try await fixture.service.intakeStandaloneSkill(wrongKind, prepared: personal)
        }
        #expect(try fixture.store.snapshot()?.document == fixture.document)
        #expect(try fixture.objectNames().isEmpty)
    }

    @Test func aStaleCommandDoesNotPublishUnreviewedContentOrCreateASubscription() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let first = try prepared()
        let receipt = try await fixture.service.intakeStandaloneSkill(fixture.intake(first, ids: .init()), prepared: first)
        let second = try prepared(path: "skills/second", body: "Not admitted")
        let stale = fixture.intake(second, ids: .init())
        await #expect(throws: WorkspaceRevisionStoreError.staleRevision(current: receipt.committedRevisionID)) {
            try await fixture.service.intakeStandaloneSkill(stale, prepared: second)
        }
        #expect(try fixture.objectNames() == [first.tree.digest.value])
        #expect(try fixture.store.snapshot()?.document.subscriptions.count == 1)
    }

    @Test func unchangedContentAtANewPublisherRevisionStillAdvancesTheLock() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let first = try prepared()
        let intake = fixture.intake(first, ids: .init())
        let saved = try await fixture.service.intakeStandaloneSkill(intake, prepared: first)
        let second = try prepared(revision: "c")
        #expect(first.tree.digest == second.tree.digest)
        let update = StandaloneSkillUpdateCommand(expectedRevisionID: saved.committedRevisionID,
            artifactID: intake.artifactID, expectedContentDigest: first.tree.digest, prepared: second)
        _ = try await fixture.service.updateStandaloneSkill(update, prepared: second)
        #expect(try fixture.store.snapshot()?.document.subscriptions[0].lock.approvedRevision == second.review.upstream?.revision)
        #expect(try fixture.objectNames().count == 1)
    }

    @Test func commandRoundTripRetainsReviewFactsAndContainsNoEmbeddedContentOrDevicePath() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let preparation = try prepared(body: "private body fixture")
        let command = fixture.intake(preparation, ids: .init())
        let encoded = try JSONEncoder().encode(command)
        let decoded = try JSONDecoder().decode(StandaloneSkillIntakeCommand.self, from: encoded)
        #expect(decoded == command)
        #expect(try decoded.inputDigest() == command.inputDigest())
        let text = String(decoding: encoded, as: UTF8.self)
        #expect(!text.contains(fixture.root.path))
        #expect(!text.contains("private body fixture"))
        #expect(text.contains(preparation.tree.digest.value))
    }

    // Internal test construction isolates command policy from network fetch. The
    // preparation suite separately verifies the only public upstream factory.
    private func prepared(
        repository: String = "https://github.com/publisher/skills", ref: String = "main",
        path: String = "skills/publisher-skill", body: String = "Published instructions",
        revision: Character = "a", publisher: String = "github:publisher"
    ) throws -> PreparedStandaloneSkill {
        let tree = try CapturedPackageTree(entries: [
            .init(relativePath: "SKILL.md", kind: .file(bytes: Data("""
                ---
                name: publisher-skill
                description: A useful published skill
                vendor-extension: preserved
                ---
                \(body)
                """.utf8), executable: false)),
            .init(relativePath: "resources", kind: .directory),
            .init(relativePath: "resources/data.bin", kind: .file(bytes: Data([0, 255, 42]), executable: false)),
        ])
        return try PreparedStandaloneSkill(tree: tree, upstream: .init(repositoryURL: repository,
            requestedRef: ref, revision: .init(kind: .gitCommitSHA1, value: String(repeating: revision, count: 40)),
            packageRelativePath: path, publisherID: publisher))
    }

    private struct Fixture {
        let root: URL
        let contentRoot: URL
        let document: PortableWorkspaceDocument
        let device: DeviceWorkspaceState
        let store: WorkspaceRevisionStore
        let service: WorkspaceApplicationService

        init() throws {
            root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appending(path: "upstream-command-\(UUID())")
            contentRoot = root.appending(path: "content")
            try FileManager.default.createDirectory(at: contentRoot, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let writerID = WorkspaceObjectID()
            document = try WorkspaceDocumentCoding.seal(.init(revision: .init(writerID: writerID)))
            device = .init(workspaceID: document.workspaceID)
            store = try .init(containerRoot: root, workspaceID: document.workspaceID, deviceID: device.deviceID)
            try store.initialize(document: document, device: device)
            service = .init(store: store, writerID: writerID, contentStore: try .init(directory: contentRoot))
        }

        func intake(_ prepared: PreparedStandaloneSkill, ids: StandaloneSkillUpstreamIDs?) -> StandaloneSkillIntakeCommand {
            .init(expectedRevisionID: document.revision.id, displayName: "Reviewed skill", prepared: prepared, upstreamIDs: ids)
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
