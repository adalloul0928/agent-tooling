import Darwin
import Foundation
import Testing

@testable import AgentToolingCore

/// An attached folder stays the only editable copy. Nothing is taken into the
/// library, nothing is written back, and detaching removes a registration
/// rather than someone's files.
@Suite("Workspace attached authoring")
struct WorkspaceAttachedAuthoringTests {
    @Test func attachingRecordsTheFolderWithoutCopyingOrChangingIt() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let before = try fixture.folderContents()
        let prepared = try await WorkspaceSkillPreparation.capturePersonal(directory: fixture.folder)

        let receipt = try await fixture.service.attachAuthoringRoot(.init(
            expectedRevisionID: fixture.head(), displayName: "My skill",
            prepared: prepared, directory: fixture.folder))

        let snapshot = try #require(try fixture.store.snapshot())
        #expect(snapshot.document.revision.id == receipt.committedRevisionID)
        let artifact = try #require(snapshot.document.artifacts.first)
        let source = try #require(snapshot.document.sources.first)
        #expect(artifact.authority == .attachedAuthoring(sourceRootID: source.id))
        #expect(source.role == .attachedAuthoring)
        // The workspace holds no copy that could drift from the folder.
        #expect(artifact.contentDigest == nil)
        #expect(artifact.declaredName == "personal")
        // The folder's own path is device-local, never portable.
        #expect(snapshot.device.sourceLocations.map(\.checkoutPath) == [fixture.folder.path])
        let portable = try WorkspaceDocumentCoding.encode(snapshot.document)
        #expect(!String(decoding: portable, as: UTF8.self).contains(fixture.folder.path))
        #expect(try fixture.folderContents() == before)
    }

    @Test func aFolderTrackingAPublisherIsNotAnAuthoringRoot() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        var prepared = try await WorkspaceSkillPreparation.capturePersonal(directory: fixture.folder)
        prepared = try Self.withUpstream(prepared)

        #expect(throws: WorkspaceAttachedAuthoringError.notAStandaloneSkill) {
            _ = try AttachedAuthoringIntakeCommand(
                expectedRevisionID: fixture.head(), displayName: "My skill",
                prepared: prepared, directory: fixture.folder)
        }
    }

    @Test func oneFolderCannotBecomeTwoEditableMasters() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let prepared = try await WorkspaceSkillPreparation.capturePersonal(directory: fixture.folder)
        _ = try await fixture.service.attachAuthoringRoot(.init(
            expectedRevisionID: fixture.head(), displayName: "My skill",
            prepared: prepared, directory: fixture.folder))

        await #expect(throws: WorkspaceAttachedAuthoringError.sourceIdentityConflict) {
            _ = try await fixture.service.attachAuthoringRoot(.init(
                expectedRevisionID: fixture.head(), displayName: "Again",
                prepared: prepared, directory: fixture.folder))
        }
        #expect(try #require(try fixture.store.snapshot()).document.artifacts.count == 1)
    }

    @Test func detachingRemovesTheRegistrationAndLeavesTheFolderAlone() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let prepared = try await WorkspaceSkillPreparation.capturePersonal(directory: fixture.folder)
        _ = try await fixture.service.attachAuthoringRoot(.init(
            expectedRevisionID: fixture.head(), displayName: "My skill",
            prepared: prepared, directory: fixture.folder))
        let artifactID = try #require(try fixture.store.snapshot()).document.artifacts.first?.identity.id
        let before = try fixture.folderContents()

        _ = try await fixture.service.detachAuthoringRoot(.init(
            expectedRevisionID: fixture.head(), artifactID: try #require(artifactID)))

        let snapshot = try #require(try fixture.store.snapshot())
        #expect(snapshot.document.artifacts.isEmpty)
        #expect(snapshot.document.sources.isEmpty)
        #expect(snapshot.device.sourceLocations.isEmpty)
        #expect(snapshot.document.tombstones.map(\.artifactID) == [artifactID])
        #expect(try fixture.folderContents() == before)
        #expect(FileManager.default.fileExists(atPath: fixture.folder.appending(path: "SKILL.md").path))
    }

    @Test func detachingSomethingThatIsNotAttachedIsRefused() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }

        await #expect(throws: WorkspaceAttachedAuthoringError.detachedItemMissing) {
            _ = try await fixture.service.detachAuthoringRoot(.init(
                expectedRevisionID: fixture.head(), artifactID: ArtifactID()))
        }
    }

    private static func withUpstream(_ prepared: PreparedStandaloneSkill) throws -> PreparedStandaloneSkill {
        try .init(tree: prepared.tree, upstream: .init(
            repositoryURL: "https://github.com/example/skills", requestedRef: "main",
            revision: .init(kind: .gitCommitSHA1, value: String(repeating: "a", count: 40)),
            packageRelativePath: "skills/personal", publisherID: "github:example"))
    }

    private struct Fixture {
        let root: URL
        let folder: URL
        let store: WorkspaceRevisionStore
        let service: WorkspaceApplicationService

        init() throws {
            root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
                .appending(path: "attached-authoring-\(UUID())")
            folder = root.appending(path: "my-repo/skills/personal")
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700])
            try Data("---\nname: personal\ndescription: An authored skill\n---\n\n# Personal\n".utf8)
                .write(to: folder.appending(path: "SKILL.md"))
            try Data("reference\n".utf8).write(to: folder.appending(path: "NOTES.md"))
            let writerID = WorkspaceObjectID()
            let document = try WorkspaceDocumentCoding.seal(.init(
                workspaceID: WorkspaceObjectID(), revision: .init(writerID: writerID)))
            let device = DeviceWorkspaceState(workspaceID: document.workspaceID)
            store = try WorkspaceRevisionStore(containerRoot: root.appending(path: "store"),
                workspaceID: document.workspaceID, deviceID: device.deviceID)
            try store.initialize(document: document, device: device)
            service = WorkspaceApplicationService(store: store, writerID: writerID)
        }

        func head() -> WorkspaceObjectID {
            (try? store.snapshot())?.document.revision.id ?? WorkspaceObjectID()
        }

        func folderContents() throws -> [String: Data] {
            var result: [String: Data] = [:]
            for name in try FileManager.default.contentsOfDirectory(atPath: folder.path) {
                result[name] = try Data(contentsOf: folder.appending(path: name))
            }
            return result
        }

        func remove() { try? FileManager.default.removeItem(at: root) }
    }
}
