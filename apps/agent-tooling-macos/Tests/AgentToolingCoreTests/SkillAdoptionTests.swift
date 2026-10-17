import Foundation
import Testing

@testable import AgentToolingCore

/// Bringing an unmanaged skill into the library, and taking one app's copy
/// away: the two moves the setup wizard is built on.
@Suite("Adopt and remove skill copies")
struct SkillAdoptionTests {
    private struct Fixture {
        let root: URL
        let home: URL
        let writerID = WorkspaceObjectID()
        let store: WorkspaceRevisionStore
        let contentStore: CentralPackageContentStore
        let service: WorkspaceApplicationService
        let trackedID = ArtifactID()
        let personalID = ArtifactID()

        init() throws {
            root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
                .appending(path: "SkillAdoptionTests-\(UUID().uuidString)", directoryHint: .isDirectory)
            home = root.appending(path: "home", directoryHint: .isDirectory)
            let contentURL = root.appending(path: "content", directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: contentURL, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            try FileManager.default.createDirectory(at: home.appending(path: ".claude/skills"), withIntermediateDirectories: true)
            let document = try WorkspaceDocumentCoding.seal(
                PortableWorkspaceDocument(
                    workspaceID: WorkspaceObjectID(), revision: .init(writerID: writerID),
                    artifacts: [
                        .init(identity: .init(id: trackedID, kind: .skill, displayName: "Docx"), authority: .trackedOnly, declaredName: "docx"),
                        .init(identity: .init(id: ArtifactID(), kind: .nativePlugin, displayName: "Plugin"), authority: .nativeOwned, declaredName: "plugin"),
                        .init(identity: .init(id: personalID, kind: .skill, displayName: "Mine"), authority: .centralPersonal, declaredName: "mine"),
                    ]))
            let device = DeviceWorkspaceState(workspaceID: document.workspaceID)
            store = try WorkspaceRevisionStore(containerRoot: root.appending(path: "workspace"), workspaceID: document.workspaceID, deviceID: device.deviceID)
            try store.initialize(document: document, device: device)
            contentStore = try CentralPackageContentStore(directory: contentURL)
            service = WorkspaceApplicationService(store: store, writerID: writerID, contentStore: contentStore)
        }

        /// A skill folder as an app would hold it.
        func skillFolder(named name: String, in relativeRoot: String = ".claude/skills") throws -> URL {
            let folder = home.appending(path: relativeRoot, directoryHint: .isDirectory).appending(path: name, directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try "---\nname: \(name)\ndescription: A skill\n---\nUse it.\n".write(to: folder.appending(path: "SKILL.md"), atomically: true, encoding: .utf8)
            return folder
        }

        func head() throws -> WorkspaceObjectID { try #require(try store.snapshot()).document.revision.id }

        func remove() { try? FileManager.default.removeItem(at: root) }
    }

    // MARK: Adopt

    @Test func adoptingATrackedSkillMakesItPersonalInPlaceAndStoresItsFiles() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let folder = try fixture.skillFolder(named: "docx")
        let prepared = try await WorkspaceSkillPreparation.capturePersonal(directory: folder)

        let receipt = try await fixture.service.adoptTrackedSkill(
            .init(expectedRevisionID: fixture.head(), artifactID: fixture.trackedID, prepared: prepared), prepared: prepared)

        let saved = try #require(try fixture.store.snapshot())
        let artifact = try #require(saved.document.artifacts.first { $0.identity.id == fixture.trackedID })
        #expect(artifact.authority == .centralPersonal, "the same record, now yours")
        #expect(artifact.declaredName == "docx")
        #expect(artifact.contentDigest == prepared.tree.digest)
        #expect(saved.document.artifacts.count == 3, "no second record was made")
        let content = try await fixture.service.skillContent(artifactID: fixture.trackedID, revisionID: receipt.committedRevisionID)
        #expect(content.tree == prepared.tree)
        // The app's folder is exactly as it was.
        #expect(FileManager.default.fileExists(atPath: folder.appending(path: "SKILL.md").path(percentEncoded: false)))
    }

    @Test func adoptionRefusesWhatIsNotATrackedStandaloneSkillOrIsAnotherSkillsFiles() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let prepared = try await WorkspaceSkillPreparation.capturePersonal(directory: fixture.skillFolder(named: "docx"))

        // Already yours: nothing to adopt.
        await #expect(throws: WorkspaceSkillCommandError.unsupportedAuthority) {
            try await fixture.service.adoptTrackedSkill(
                .init(expectedRevisionID: fixture.head(), artifactID: fixture.personalID, prepared: prepared), prepared: prepared)
        }
        // A folder declaring a different name than the record: not this skill.
        let other = try await WorkspaceSkillPreparation.capturePersonal(directory: fixture.skillFolder(named: "other"))
        await #expect(throws: WorkspaceSkillCommandError.reviewMismatch) {
            try await fixture.service.adoptTrackedSkill(
                .init(expectedRevisionID: fixture.head(), artifactID: fixture.trackedID, prepared: other), prepared: other)
        }
        // Unknown record.
        await #expect(throws: WorkspaceRevisionStoreError.missingArtifact) {
            try await fixture.service.adoptTrackedSkill(
                .init(expectedRevisionID: fixture.head(), artifactID: ArtifactID(), prepared: prepared), prepared: prepared)
        }
        let saved = try #require(try fixture.store.snapshot())
        #expect(saved.document.artifacts.first { $0.identity.id == fixture.trackedID }?.authority == .trackedOnly, "a refusal changed nothing")
    }

    // MARK: Remove

    private func removal(_ path: String) -> OperationPlan {
        OperationPlan(
            kind: .installSkill, title: "Remove a copy", summary: "s",
            steps: [.init(kind: .removeUnmanagedSkillCopy, title: "Remove", detail: "d", destinationPath: path, isReversible: true)])
    }

    @Test func removingAFolderCopyMovesItToTheWorkspaceTrash() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let folder = try fixture.skillFolder(named: "docx")
        let engine = OperationEngine(store: fixture.store, homeURL: fixture.home)

        let receipt = await engine.execute(removal(folder.path(percentEncoded: false)))

        #expect(receipt.results.first?.status == .succeeded, Comment(rawValue: receipt.results.first?.output ?? ""))
        #expect(!FileManager.default.fileExists(atPath: folder.path(percentEncoded: false)))
        let trash = fixture.store.rootURL.appending(path: "trash")
        let kept = try FileManager.default.subpathsOfDirectory(atPath: trash.path(percentEncoded: false)).filter { $0.hasSuffix("docx/SKILL.md") }
        #expect(kept.count == 1, "the folder is in the trash, whole")
        #expect(receipt.results.first?.output.contains("trash") == true)
    }

    @Test func removingALinkedCopyRemovesOnlyTheLink() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let target = try fixture.skillFolder(named: "docx", in: "code/anthropic-skills/skills")
        let link = fixture.home.appending(path: ".claude/skills/docx")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        let engine = OperationEngine(store: fixture.store, homeURL: fixture.home)

        let receipt = await engine.execute(removal(link.path(percentEncoded: false)))

        #expect(receipt.results.first?.status == .succeeded, Comment(rawValue: receipt.results.first?.output ?? ""))
        #expect((try? link.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) != true)
        #expect(FileManager.default.fileExists(atPath: target.appending(path: "SKILL.md").path(percentEncoded: false)), "the target is untouched")
        #expect(receipt.results.first?.output.contains("not touched") == true)
    }

    @Test func removalRefusesAnythingOutsideASkillsFolder() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let engine = OperationEngine(store: fixture.store, homeURL: fixture.home)
        let elsewhere = try fixture.skillFolder(named: "docx", in: "Documents")
        let deeper = try fixture.skillFolder(named: "nested", in: ".claude/skills/docx")
        let library = fixture.store.libraryURL.path(percentEncoded: false)

        for path in [elsewhere.path(percentEncoded: false), deeper.path(percentEncoded: false), library, "/", fixture.home.appending(path: ".claude/skills").path(percentEncoded: false), fixture.home.appending(path: ".claude/skills/../../Documents").path(percentEncoded: false)] {
            let receipt = await engine.execute(removal(path))
            #expect(receipt.results.first?.status == .failed, "\(path) was accepted")
        }
        #expect(FileManager.default.fileExists(atPath: elsewhere.path(percentEncoded: false)))
        #expect(FileManager.default.fileExists(atPath: deeper.path(percentEncoded: false)))
    }

    @Test func removingWhatIsAlreadyGoneIsSkippedNotFailed() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let engine = OperationEngine(store: fixture.store, homeURL: fixture.home)
        let receipt = await engine.execute(removal(fixture.home.appending(path: ".claude/skills/absent").path(percentEncoded: false)))
        #expect(receipt.results.first?.status == .skipped)
    }
}
