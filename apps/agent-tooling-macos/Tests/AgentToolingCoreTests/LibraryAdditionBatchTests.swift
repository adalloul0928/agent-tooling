import Foundation
import Testing

@testable import AgentToolingCore

/// One "Add to library": skills made yours, catalog listings and new skills,
/// in one revision, with each row refused on its own and the rest landing
/// together.
@Suite("Library addition batch")
struct LibraryAdditionBatchTests {
    // MARK: One revision

    @Test func threeAdoptionsAndOneCatalogListingLandInOneRevision() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let head = try fixture.head()
        let (batch, prepared) = try await fixture.batch(adopting: ["docx", "pdf", "xlsx"], adding: Fixture.listing())

        let receipt = try await fixture.service.applyLibraryAdditions(batch, prepared: prepared)

        let saved = try #require(try fixture.store.snapshot())
        #expect(saved.document.revision.id == receipt.committedRevisionID)
        #expect(saved.document.revision.parentIDs == [head], "exactly one revision on top of the head")
        #expect(receipt.previousRevisionID == head)
        #expect(Set(receipt.affectedArtifactIDs) == Set(batch.artifactIDs))
        for name in ["docx", "pdf", "xlsx"] {
            let artifact = try #require(saved.document.artifacts.first { $0.identity.id == fixture.tracked[name] })
            #expect(artifact.authority == .centralPersonal, "\(name) is yours, under the same record")
            #expect(artifact.contentDigest == prepared[artifact.identity.id]?.tree.digest)
            let content = try await fixture.service.skillContent(
                artifactID: artifact.identity.id, revisionID: receipt.committedRevisionID)
            #expect(content.tree == prepared[artifact.identity.id]?.tree)
        }
        let added = try #require(saved.document.artifacts.first { $0.identity.id == batch.catalogAdds[0].artifactID })
        #expect(added.authority == .nativeOwned)
        #expect(added.nativeRoutes == [.init(client: .claude, externalPluginID: "atlas@vendor")])
        #expect(saved.document.assignments.isEmpty, "adding to the library puts nothing in an app")
        #expect(saved.device == fixture.device, "nothing about this Mac changed")
        // The apps' folders are as they were.
        for name in ["docx", "pdf", "xlsx"] {
            #expect(FileManager.default.fileExists(atPath: fixture.folder(name).appending(path: "SKILL.md").path(percentEncoded: false)))
        }
    }

    @Test func aNewSkillTakenInLandsBesideTheOthers() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let folder = try fixture.skillFolder(named: "release-notes", in: "drafts")
        let skill = try await WorkspaceSkillPreparation.capturePersonal(directory: folder)
        let intake = StandaloneSkillIntakeCommand(expectedRevisionID: try fixture.head(), displayName: "Release Notes", prepared: skill)
        let (adoptions, prepared) = try await fixture.adoptions(["docx"])
        let batch = WorkspaceLibraryAdditionBatch(
            expectedRevisionID: try fixture.head(), adoptions: adoptions, intakes: [intake])

        let receipt = try await fixture.service.applyLibraryAdditions(
            batch, prepared: prepared.merging([intake.artifactID: skill]) { first, _ in first })

        #expect(Set(receipt.affectedArtifactIDs) == [fixture.tracked["docx"], intake.artifactID])
        let saved = try #require(try fixture.store.snapshot())
        let created = try #require(saved.document.artifacts.first { $0.identity.id == intake.artifactID })
        #expect(created.authority == .centralPersonal)
        #expect(created.declaredName == "release-notes")
    }

    @Test func eachCommandsOwnHeadAndKeyAreIgnored() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let stale = WorkspaceObjectID()
        let command = try NativePackageAdoptionCommand(
            expectedRevisionID: stale, idempotencyKey: WorkspaceObjectID(), package: Fixture.listing(), client: .claude)
        let batch = WorkspaceLibraryAdditionBatch(expectedRevisionID: try fixture.head(), catalogAdds: [command])

        let receipt = try await fixture.service.applyLibraryAdditions(batch, prepared: [:])

        #expect(receipt.affectedArtifactIDs == [command.artifactID])
        #expect(receipt.idempotencyKey == batch.idempotencyKey)
    }

    // MARK: Replay and retry

    @Test func theSameBatchHandedInAgainReturnsItsReceiptAndWritesNothingMore() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let (batch, prepared) = try await fixture.batch(adopting: ["docx", "pdf"], adding: Fixture.listing())

        let first = try await fixture.service.applyLibraryAdditions(batch, prepared: prepared)
        let again = try await fixture.service.applyLibraryAdditions(batch, prepared: prepared)

        #expect(again == first)
        #expect(try fixture.head() == first.committedRevisionID, "no second revision")
    }

    @Test func aHeadThatMovedBeforeTheBatchIsTriedAgainUnderAFreshKey() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let (batch, prepared) = try await fixture.batch(adopting: ["docx", "pdf"], adding: Fixture.listing())
        // Another writer moves the library on after the batch was built.
        let moved = try fixture.commitElsewhere()

        let receipt = try await fixture.service.applyLibraryAdditions(batch, prepared: prepared)

        #expect(receipt.previousRevisionID == moved, "written on the head as it stood")
        #expect(receipt.idempotencyKey != batch.idempotencyKey, "a retry never reuses the stale key")
        #expect(Set(receipt.affectedArtifactIDs) == Set(batch.artifactIDs))
        // The same batch again finds what its retry wrote.
        #expect(try await fixture.service.applyLibraryAdditions(batch, prepared: prepared) == receipt)
        #expect(try fixture.head() == receipt.committedRevisionID)
    }

    @Test func aHeadThatMovesWhileTheBatchWritesIsTriedAgainUnderAFreshKey() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let (batch, prepared) = try await fixture.batch(adopting: ["docx"], adding: Fixture.listing())
        let moves = AttemptLog()

        let receipt = try await fixture.service.applyLibraryAdditions(batch, prepared: prepared) { attempt in
            moves.record(attempt)
            // The first attempt finds the library moved on under it, after its
            // check passed and before it writes.
            if attempt == 0 { _ = try fixture.commitElsewhere() }
        }

        #expect(moves.attempts == [0, 1])
        #expect(receipt.idempotencyKey != batch.idempotencyKey)
        #expect(receipt.idempotencyKey == batch.idempotencyKey(forAttempt: 1))
        let saved = try #require(try fixture.store.snapshot())
        #expect(saved.document.artifacts.first { $0.identity.id == fixture.tracked["docx"] }?.authority == .centralPersonal)
    }

    @Test func aHeadThatKeepsMovingStopsAfterThreeRetries() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let (batch, prepared) = try await fixture.batch(adopting: ["docx"])
        let moves = AttemptLog()

        await #expect(throws: WorkspaceRevisionStoreError.self) {
            try await fixture.service.applyLibraryAdditions(batch, prepared: prepared) { attempt in
                moves.record(attempt)
                _ = try fixture.commitElsewhere()
            }
        }

        #expect(moves.attempts == [0, 1, 2, 3])
        let saved = try #require(try fixture.store.snapshot())
        #expect(saved.document.artifacts.first { $0.identity.id == fixture.tracked["docx"] }?.authority == .trackedOnly)
    }

    @Test func retryKeysAreDistinctAndDerivedFromTheBatchsKey() {
        let batch = WorkspaceLibraryAdditionBatch(expectedRevisionID: WorkspaceObjectID())
        let keys = (0...3).map(batch.idempotencyKey(forAttempt:))
        #expect(keys[0] == batch.idempotencyKey)
        #expect(Set(keys).count == 4)
        #expect(keys == (0...3).map(batch.idempotencyKey(forAttempt:)), "the same key every time it is asked for")
    }

    // MARK: Refusals, row by row

    @Test func aSkillMDThatNamesAnotherSkillIsRefusedAloneAndTheRestLand() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        // The record says frontend-design; the folder's SKILL.md says
        // frontend-ui.
        let mismatched = try fixture.skillFolder(named: "frontend-design", declaring: "frontend-ui")
        let other = try await WorkspaceSkillPreparation.capturePersonal(directory: mismatched)
        let (adoptions, prepared) = try await fixture.adoptions(["docx"])
        let designID = try #require(fixture.tracked["frontend-design"])
        let batch = WorkspaceLibraryAdditionBatch(
            expectedRevisionID: try fixture.head(),
            adoptions: adoptions + [.init(artifactID: designID, sourcePath: mismatched.path(percentEncoded: false))])
        let all = prepared.merging([designID: other]) { first, _ in first }

        let refusals = try await fixture.service.previewLibraryAdditions(batch, prepared: all)
        let receipt = try await fixture.service.applyLibraryAdditions(batch, prepared: all)

        #expect(refusals == [.declaredNameMismatch(designID, recorded: "frontend-design", found: "frontend-ui")])
        #expect(receipt.affectedArtifactIDs == [fixture.tracked["docx"]])
        let saved = try #require(try fixture.store.snapshot())
        #expect(saved.document.artifacts.first { $0.identity.id == designID }?.authority == .trackedOnly)
    }

    @Test func whatIsNotALooseTrackedSkillIsRefusedByName() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let copy = try await WorkspaceSkillPreparation.capturePersonal(directory: try fixture.skillFolder(named: "member"))
        let mine = try await WorkspaceSkillPreparation.capturePersonal(directory: try fixture.skillFolder(named: "mine"))
        let gone = ArtifactID()
        let unread = try #require(fixture.tracked["pdf"])
        let duplicate = try NativePackageAdoptionCommand(
            expectedRevisionID: try fixture.head(), package: Fixture.listing(), client: .claude)
        let again = try NativePackageAdoptionCommand(
            expectedRevisionID: try fixture.head(), package: Fixture.listing(), client: .claude)
        let batch = WorkspaceLibraryAdditionBatch(
            expectedRevisionID: try fixture.head(),
            adoptions: [
                .init(artifactID: fixture.memberID, sourcePath: "/member"), .init(artifactID: fixture.personalID, sourcePath: "/mine"),
                .init(artifactID: gone, sourcePath: "/gone"), .init(artifactID: unread, sourcePath: "/pdf"),
            ],
            catalogAdds: [duplicate, again])
        let prepared = [fixture.memberID: copy, fixture.personalID: mine, gone: mine]

        let refusals = try await fixture.service.previewLibraryAdditions(batch, prepared: prepared)

        #expect(refusals.count == 5)
        #expect(refusals[0] == .notAdoptable(fixture.memberID, .notALooseSkill), "a plugin's member is its plugin's")
        #expect(refusals[1] == .notAdoptable(fixture.personalID, .alreadyYours))
        #expect(refusals[2] == .notAdoptable(gone, .missing))
        #expect(refusals[3] == .notAdoptable(unread, .notRead))
        // The second listing of the same package finds the first one in the
        // library, as the rows before it left it.
        guard case .catalog(let id, .alreadyInLibrary(let match)) = refusals[4] else {
            Issue.record("the second listing is refused as already in the library: \(refusals[4])")
            return
        }
        #expect(id == again.artifactID)
        #expect(match.displayName == "Atlas")
        #expect(refusals.map(\.artifactID) == [fixture.memberID, fixture.personalID, gone, unread, again.artifactID])
    }

    @Test func aBatchWhoseEveryRowIsRefusedWritesNothing() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let head = try fixture.head()
        let batch = WorkspaceLibraryAdditionBatch(
            expectedRevisionID: head, adoptions: [.init(artifactID: fixture.personalID, sourcePath: "/mine")])
        let mine = try await WorkspaceSkillPreparation.capturePersonal(directory: try fixture.skillFolder(named: "mine"))

        await #expect(throws: LibraryAdditionError.nothingToAdd([.notAdoptable(fixture.personalID, .alreadyYours)])) {
            try await fixture.service.applyLibraryAdditions(batch, prepared: [fixture.personalID: mine])
        }
        await #expect(throws: LibraryAdditionError.nothingToAdd([])) {
            try await fixture.service.applyLibraryAdditions(.init(expectedRevisionID: head), prepared: [:])
        }
        #expect(try fixture.head() == head)
    }

    @Test func excludingRowsKeepsTheRestUnderANewKey() {
        let kept = WorkspaceLibraryAdditionBatch.Adoption(artifactID: ArtifactID(), sourcePath: "/a")
        let dropped = WorkspaceLibraryAdditionBatch.Adoption(artifactID: ArtifactID(), sourcePath: "/b")
        let batch = WorkspaceLibraryAdditionBatch(expectedRevisionID: WorkspaceObjectID(), adoptions: [kept, dropped])

        let rest = batch.excluding([dropped.artifactID])

        #expect(rest.adoptions == [kept])
        #expect(rest.expectedRevisionID == batch.expectedRevisionID)
        #expect(rest.idempotencyKey != batch.idempotencyKey, "a different edit is a different key")
    }

    // MARK: Content first

    @Test func everyTreeIsPublishedBeforeTheRevisionIsWritten() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let head = try fixture.head()
        let (batch, prepared) = try await fixture.batch(adopting: ["docx", "pdf", "xlsx"])
        let store = fixture.contentStore
        let revisionStore = fixture.store
        let checked = AttemptLog()

        _ = try await fixture.service.applyLibraryAdditions(batch, prepared: prepared) { attempt in
            // Nothing is written yet, and every skill's files are already in
            // the content store.
            let current = try revisionStore.snapshot()?.document.revision.id
            #expect(current == head)
            for skill in prepared.values {
                let stored = try await store.read(skill.tree.digest)
                #expect(stored == skill.tree)
            }
            checked.record(attempt)
        }

        #expect(checked.attempts == [0])
    }

    // MARK: - Fixture

    /// Attempts as they were seen, from a test's hook.
    private final class AttemptLog: @unchecked Sendable {
        private let lock = NSLock()
        private var seen: [Int] = []

        var attempts: [Int] { lock.withLock { seen } }

        func record(_ attempt: Int) {
            lock.withLock { seen.append(attempt) }
        }
    }

    private struct Fixture {
        let root: URL
        let home: URL
        let writerID = WorkspaceObjectID()
        let store: WorkspaceRevisionStore
        let contentStore: CentralPackageContentStore
        let service: WorkspaceApplicationService
        let device: DeviceWorkspaceState
        /// The tracked-only loose skills, by declared name.
        let tracked: [String: ArtifactID]
        let memberID = ArtifactID()
        let personalID = ArtifactID()

        init() throws {
            root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
                .appending(path: "LibraryAdditionBatchTests-\(UUID().uuidString)", directoryHint: .isDirectory)
            home = root.appending(path: "home", directoryHint: .isDirectory)
            let contentURL = root.appending(path: "content", directoryHint: .isDirectory)
            try FileManager.default.createDirectory(
                at: contentURL, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            var tracked: [String: ArtifactID] = [:]
            var artifacts: [ArtifactRecord] = []
            for name in ["docx", "pdf", "xlsx", "frontend-design"] {
                let id = ArtifactID()
                tracked[name] = id
                artifacts.append(
                    .init(identity: .init(id: id, kind: .skill, displayName: name.capitalized), authority: .trackedOnly, declaredName: name)
                )
            }
            let pluginID = ArtifactID()
            artifacts.append(
                .init(
                    identity: .init(id: pluginID, kind: .nativePlugin, displayName: "Pack"), authority: .trackedOnly,
                    declaredName: "pack"))
            artifacts.append(
                .init(
                    identity: .init(id: memberID, kind: .skill, displayName: "Member", parentPackageID: pluginID),
                    authority: .trackedOnly, declaredName: "member"))
            artifacts.append(
                .init(
                    identity: .init(id: personalID, kind: .skill, displayName: "Mine"), authority: .centralPersonal,
                    declaredName: "mine"))
            let document = try WorkspaceDocumentCoding.seal(
                PortableWorkspaceDocument(
                    workspaceID: WorkspaceObjectID(), revision: .init(writerID: writerID), artifacts: artifacts))
            let device = DeviceWorkspaceState(workspaceID: document.workspaceID)
            store = try WorkspaceRevisionStore(
                containerRoot: root.appending(path: "workspace"), workspaceID: document.workspaceID, deviceID: device.deviceID)
            try store.initialize(document: document, device: device)
            contentStore = try CentralPackageContentStore(directory: contentURL)
            service = WorkspaceApplicationService(store: store, writerID: writerID, contentStore: contentStore)
            self.device = device
            self.tracked = tracked
        }

        /// A listing Claude Code's catalog parser would leave, so the
        /// identity is recognized.
        static func listing() -> MarketplacePackage {
            MarketplacePackage(
                id: "claude:atlas@vendor", name: "Atlas", publisher: "vendor", summary: "A catalog listing.",
                sourceName: "vendor", revision: "1.4.0", components: [.plugin], supportedClients: [.claude],
                location: "https://example.com/atlas",
                nativeInstalls: [
                    NativeInstall(
                        client: .claude, executable: "claude",
                        arguments: ["plugin", "install", "atlas@vendor", "--scope", "user"],
                        removalArguments: ["plugin", "uninstall", "atlas@vendor"], scope: .user,
                        detail: "Installs through Claude Code's own plugin manager.")
                ])
        }

        func folder(_ name: String, in relativeRoot: String = ".claude/skills") -> URL {
            home.appending(path: relativeRoot, directoryHint: .isDirectory).appending(path: name, directoryHint: .isDirectory)
        }

        /// A skill folder as an app holds it, its SKILL.md declaring
        /// `declaring` (its own name unless told otherwise).
        func skillFolder(named name: String, declaring: String? = nil, in relativeRoot: String = ".claude/skills") throws -> URL {
            let folder = folder(name, in: relativeRoot)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try "---\nname: \(declaring ?? name)\ndescription: The \(name) skill\n---\nUse \(name).\n".write(
                to: folder.appending(path: "SKILL.md"), atomically: true, encoding: .utf8)
            return folder
        }

        /// Adoptions of the named tracked skills, each from a copy on disk.
        func adoptions(_ names: [String]) async throws -> ([WorkspaceLibraryAdditionBatch.Adoption], [ArtifactID: PreparedStandaloneSkill])
        {
            var adoptions: [WorkspaceLibraryAdditionBatch.Adoption] = []
            var prepared: [ArtifactID: PreparedStandaloneSkill] = [:]
            for name in names {
                let id = try #require(tracked[name])
                let folder = try skillFolder(named: name)
                adoptions.append(.init(artifactID: id, sourcePath: folder.path(percentEncoded: false)))
                prepared[id] = try await WorkspaceSkillPreparation.capturePersonal(directory: folder)
            }
            return (adoptions, prepared)
        }

        func batch(
            adopting names: [String], adding listing: MarketplacePackage? = nil
        ) async throws -> (WorkspaceLibraryAdditionBatch, [ArtifactID: PreparedStandaloneSkill]) {
            let (adoptions, prepared) = try await adoptions(names)
            let head = try head()
            let catalog = try listing.map { try NativePackageAdoptionCommand(expectedRevisionID: head, package: $0, client: .claude) }
            return (
                WorkspaceLibraryAdditionBatch(expectedRevisionID: head, adoptions: adoptions, catalogAdds: catalog.map { [$0] } ?? []),
                prepared
            )
        }

        func head() throws -> WorkspaceObjectID { try #require(try store.snapshot()).document.revision.id }

        /// Another writer's revision, which moves the head on and touches none
        /// of the batch's rows. Returns the new head.
        @discardableResult
        func commitElsewhere() throws -> WorkspaceObjectID {
            let receipt = try store.commitMetadata(
                expectedRevisionID: try head(), idempotencyKey: WorkspaceObjectID(),
                inputDigest: String(repeating: "b", count: 64), writerID: WorkspaceObjectID()
            ) { document in
                let id = ArtifactID()
                document.artifacts.append(
                    .init(
                        identity: .init(id: id, kind: .skill, displayName: "Elsewhere"), authority: .trackedOnly,
                        declaredName: "elsewhere-\(id.rawValue.uuidString.lowercased().prefix(8))"))
                return [id]
            }
            return receipt.committedRevisionID
        }

        func remove() { try? FileManager.default.removeItem(at: root) }
    }
}
