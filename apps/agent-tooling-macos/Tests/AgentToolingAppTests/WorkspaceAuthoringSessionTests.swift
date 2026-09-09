import Foundation
import Testing

@testable import AgentToolingCore
@testable import AgentToolingApp

/// Attaching reads a folder and records that it exists. It never copies the
/// folder in, never writes into it, and letting go removes a registration
/// rather than someone's files.
@MainActor
struct WorkspaceAuthoringSessionTests {
    @Test func inspectingReadsTheFolderAndChangesNothing() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let before = try fixture.folderContents()
        let session = fixture.session()

        await session.inspect(fixture.folder)

        #expect(session.errorMessage == nil, "\(session.errorMessage ?? "")")
        #expect(session.candidate?.declaredName == "personal")
        #expect(session.candidate?.fileCount == 2)
        #expect(try fixture.folderContents() == before)
        // Reading is not attaching.
        #expect(try #require(try fixture.store.snapshot()).document.artifacts.isEmpty)
    }

    @Test func attachingRecordsTheFolderWithoutTakingACopyOfIt() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let before = try fixture.folderContents()
        let session = fixture.session()
        await session.inspect(fixture.folder)

        await session.attach(displayName: "My own skill")

        #expect(session.errorMessage == nil, "\(session.errorMessage ?? "")")
        #expect(session.lastAttachedName == "My own skill")
        #expect(session.candidate == nil)
        let document = try #require(try fixture.store.snapshot()).document
        let artifact = try #require(document.artifacts.first)
        #expect(artifact.identity.displayName == "My own skill")
        // No copy exists that could drift from the folder.
        #expect(artifact.contentDigest == nil)
        #expect(try fixture.folderContents() == before)
        #expect(fixture.library.state?.library.rows.count == 1)
    }

    @Test func anEmptyNameKeepsTheNameTheFolderAlreadyGivesIt() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let session = fixture.session()
        await session.inspect(fixture.folder)

        await session.attach(displayName: "   ")

        #expect(session.lastAttachedName == "personal")
        #expect(try #require(try fixture.store.snapshot()).document
            .artifacts.first?.identity.displayName == "personal")
    }

    @Test func aFolderThatIsNotASkillIsRefusedInTermsAPersonCanActOn() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let empty = fixture.root.appending(path: "not-a-skill")
        try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: true)
        let session = fixture.session()

        await session.inspect(empty)

        #expect(session.candidate == nil)
        #expect(session.errorMessage?.contains("no SKILL.md") == true, "\(session.errorMessage ?? "")")
    }

    @Test func theSameFolderCannotBecomeTwoEditableMasters() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let session = fixture.session()
        await session.inspect(fixture.folder)
        await session.attach(displayName: "First")
        await session.inspect(fixture.folder)

        await session.attach(displayName: "Second")

        #expect(session.errorMessage?.contains("already the editable copy") == true,
                "\(session.errorMessage ?? "")")
        #expect(try #require(try fixture.store.snapshot()).document.artifacts.count == 1)
    }

    @Test func lettingGoRemovesTheRegistrationAndLeavesTheFolderAlone() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let session = fixture.session()
        await session.inspect(fixture.folder)
        await session.attach(displayName: "My own skill")
        let before = try fixture.folderContents()
        let artifactID = try #require(try fixture.store.snapshot()).document.artifacts.first?.identity.id

        await session.detach(try #require(artifactID), named: "My own skill")

        #expect(session.errorMessage == nil, "\(session.errorMessage ?? "")")
        #expect(session.lastDetachedName == "My own skill")
        let snapshot = try #require(try fixture.store.snapshot())
        #expect(snapshot.document.artifacts.isEmpty)
        #expect(snapshot.device.sourceLocations.isEmpty)
        #expect(try fixture.folderContents() == before)
    }

    @Test func aReadOnlyWorkspaceCanLookAtAFolderButNotAttachIt() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let session = fixture.session(access: .readOnly)
        await session.inspect(fixture.folder)

        #expect(session.candidate != nil)
        #expect(!session.canWrite)
        await session.attach(displayName: "My own skill")
        #expect(try #require(try fixture.store.snapshot()).document.artifacts.isEmpty)
    }

    @MainActor private struct Fixture {
        let root: URL
        let folder: URL
        let store: WorkspaceRevisionStore
        let service: WorkspaceApplicationService
        let library: WorkspaceLibrarySession

        init() throws {
            root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
                .appending(path: "authoring-session-\(UUID())")
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
            library = WorkspaceLibrarySession(service: service, workspaceID: document.workspaceID,
                                              deviceID: device.deviceID, access: .writable)
        }

        func session(access: WorkspaceLibraryAccess = .writable) -> WorkspaceAuthoringSession {
            let library = access == .writable
                ? self.library
                : WorkspaceLibrarySession(service: service, workspaceID: store.workspaceID,
                                          deviceID: store.deviceID, access: .readOnly)
            return WorkspaceAuthoringSession(service: service, library: library)
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
