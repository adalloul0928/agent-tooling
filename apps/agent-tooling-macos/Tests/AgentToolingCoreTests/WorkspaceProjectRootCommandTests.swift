import AgentToolingTestSupport
import Foundation
import Testing

@testable import AgentToolingCore

/// Binding a project to a folder on this Mac, and the refusals that keep a
/// binding honest: it must name a real project, a real directory that is not a
/// link, and a folder no other project already claims.
@Suite("Workspace project root command")
struct WorkspaceProjectRootCommandTests {
    @Test func bindingRecordsTheFolderForTheProject() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        var device = fixture.device()

        try WorkspaceProjectRootCommand.bind(
            projectID: Fixture.projectA, rootPath: fixture.folderA.path,
            document: fixture.document, into: &device)

        #expect(device.projectRoots?.count == 1)
        #expect(device.projectRoots?.first?.projectID == Fixture.projectA)
        #expect(device.projectRoots?.first?.rootPath == fixture.folderA.path)
        // A binding accepted here must survive the device state's own validation
        // against the document, or the store would refuse to commit it.
        try device.validateStructure(against: fixture.document)
    }

    @Test func rebindingReplacesTheProjectsFolderRatherThanAddingASecond() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        var device = fixture.device()

        try WorkspaceProjectRootCommand.bind(
            projectID: Fixture.projectA, rootPath: fixture.folderA.path,
            document: fixture.document, into: &device)
        try WorkspaceProjectRootCommand.bind(
            projectID: Fixture.projectA, rootPath: fixture.folderB.path,
            document: fixture.document, into: &device)

        // One project, one folder: the new folder replaces the old one.
        #expect(device.projectRoots?.count == 1)
        #expect(device.projectRoots?.first?.rootPath == fixture.folderB.path)
        try device.validateStructure(against: fixture.document)
    }

    @Test func unbindingRemovesTheProjectsFolder() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        var device = fixture.device()
        try WorkspaceProjectRootCommand.bind(
            projectID: Fixture.projectA, rootPath: fixture.folderA.path,
            document: fixture.document, into: &device)

        WorkspaceProjectRootCommand.unbind(projectID: Fixture.projectA, into: &device)

        #expect(device.projectRoots?.isEmpty == true)
        try device.validateStructure(against: fixture.document)
    }

    @Test func unbindingAProjectWithNoFolderIsHarmless() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        var device = fixture.device()

        WorkspaceProjectRootCommand.unbind(projectID: Fixture.projectA, into: &device)

        #expect(device.projectRoots?.isEmpty == true)
    }

    @Test func aRelativePathIsRefused() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        var device = fixture.device()

        #expect(throws: WorkspaceProjectRootError.relativePath) {
            try WorkspaceProjectRootCommand.bind(
                projectID: Fixture.projectA, rootPath: "work/project-a",
                document: fixture.document, into: &device)
        }
        #expect(device.projectRoots?.isEmpty == true)
    }

    @Test func aMissingFolderIsRefused() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        var device = fixture.device()

        #expect(throws: WorkspaceProjectRootError.missing) {
            try WorkspaceProjectRootCommand.bind(
                projectID: Fixture.projectA,
                rootPath: fixture.root.appending(path: "nowhere").path,
                document: fixture.document, into: &device)
        }
    }

    @Test func aFileIsNotAFolder() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        var device = fixture.device()
        let file = fixture.root.appending(path: "a-file")
        try Data("x".utf8).write(to: file)

        #expect(throws: WorkspaceProjectRootError.notADirectory) {
            try WorkspaceProjectRootCommand.bind(
                projectID: Fixture.projectA, rootPath: file.path,
                document: fixture.document, into: &device)
        }
    }

    @Test func aSymlinkAtTheLeafIsRefused() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        var device = fixture.device()
        let link = fixture.root.appending(path: "link-to-a")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: fixture.folderA)

        // The real directory would be fine; a link standing in for it is not,
        // so a later write cannot be redirected somewhere nobody chose.
        #expect(throws: WorkspaceProjectRootError.symlink) {
            try WorkspaceProjectRootCommand.bind(
                projectID: Fixture.projectA, rootPath: link.path,
                document: fixture.document, into: &device)
        }
    }

    @Test func anUnknownProjectIsRefused() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        var device = fixture.device()

        #expect(throws: WorkspaceProjectRootError.unknownProject) {
            try WorkspaceProjectRootCommand.bind(
                projectID: ArtifactID(), rootPath: fixture.folderA.path,
                document: fixture.document, into: &device)
        }
    }

    @Test func aFolderAlreadyUsedByAnotherProjectIsRefusedByName() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        var device = fixture.device()
        try WorkspaceProjectRootCommand.bind(
            projectID: Fixture.projectA, rootPath: fixture.folderA.path,
            document: fixture.document, into: &device)

        #expect(throws: WorkspaceProjectRootError.folderInUse(otherProjectName: "Project A")) {
            try WorkspaceProjectRootCommand.bind(
                projectID: Fixture.projectB, rootPath: fixture.folderA.path,
                document: fixture.document, into: &device)
        }
        // The refused binding left Project B without a folder.
        #expect(device.projectRoots?.contains { $0.projectID == Fixture.projectB } == false)
    }

    @Test func theSameProjectMayKeepItsOwnFolderOnRebind() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        var device = fixture.device()
        try WorkspaceProjectRootCommand.bind(
            projectID: Fixture.projectA, rootPath: fixture.folderA.path,
            document: fixture.document, into: &device)

        // Binding a project to the folder it already has is a replacement, not a
        // clash with itself.
        try WorkspaceProjectRootCommand.bind(
            projectID: Fixture.projectA, rootPath: fixture.folderA.path,
            document: fixture.document, into: &device)

        #expect(device.projectRoots?.count == 1)
    }

    private struct Fixture {
        static let projectA = ArtifactID(fixtureUUID("00000000-0000-0000-0000-0000000000a1"))
        static let projectB = ArtifactID(fixtureUUID("00000000-0000-0000-0000-0000000000b2"))
        let root: URL
        let folderA: URL
        let folderB: URL
        let document: PortableWorkspaceDocument

        init() throws {
            root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
                .appending(path: "project-root-command-\(UUID())", directoryHint: .isDirectory)
            folderA = root.appending(path: "project-a", directoryHint: .isDirectory)
            folderB = root.appending(path: "project-b", directoryHint: .isDirectory)
            for directory in [root, folderA, folderB] {
                try FileManager.default.createDirectory(
                    at: directory, withIntermediateDirectories: true,
                    attributes: [.posixPermissions: 0o700])
            }
            document = try WorkspaceDocumentCoding.seal(
                .init(
                    workspaceID: WorkspaceObjectID(), revision: .init(writerID: WorkspaceObjectID()),
                    artifacts: [
                        .init(
                            identity: .init(id: Self.projectA, kind: .logicalProject, displayName: "Project A"),
                            authority: .centralPersonal),
                        .init(
                            identity: .init(id: Self.projectB, kind: .logicalProject, displayName: "Project B"),
                            authority: .centralPersonal),
                    ],
                    logicalProjects: [
                        .init(id: Self.projectA, name: "Project A"),
                        .init(id: Self.projectB, name: "Project B"),
                    ]))
        }

        /// A device state for this document's workspace, with no folder bound
        /// yet, at the current schema version so `projectRoots` is present.
        func device() -> DeviceWorkspaceState {
            DeviceWorkspaceState(workspaceID: document.workspaceID)
        }

        func remove() { try? FileManager.default.removeItem(at: root) }
    }
}

/// The same binding, but through the application service and a real store, so
/// the device commit and the head check the extension relies on are exercised
/// rather than only the pure command.
@Suite("Workspace project root service")
@MainActor
struct WorkspaceProjectRootServiceTests {
    @Test func bindingThroughTheServiceRecordsItAndUnbindingRemovesIt() async throws {
        let fixture = try StoreFixture()
        defer { fixture.remove() }

        let head = try #require(try fixture.store.snapshot()).document.revision.id
        _ = try await fixture.service.bindProjectRoot(
            projectID: StoreFixture.projectA, rootPath: fixture.folderA.path, expectedRevisionID: head)

        let bound = try #require(try fixture.store.snapshot()).device.projectRoots
        #expect(bound?.first?.rootPath == fixture.folderA.path)

        let next = try #require(try fixture.store.snapshot()).document.revision.id
        _ = try await fixture.service.unbindProjectRoot(
            projectID: StoreFixture.projectA, expectedRevisionID: next)

        #expect(try #require(try fixture.store.snapshot()).device.projectRoots?.isEmpty == true)
    }

    @Test func aFolderAnotherProjectHoldsIsRefusedThroughTheService() async throws {
        let fixture = try StoreFixture()
        defer { fixture.remove() }
        let head = try #require(try fixture.store.snapshot()).document.revision.id
        _ = try await fixture.service.bindProjectRoot(
            projectID: StoreFixture.projectA, rootPath: fixture.folderA.path, expectedRevisionID: head)

        let next = try #require(try fixture.store.snapshot()).document.revision.id
        await #expect(throws: WorkspaceProjectRootError.folderInUse(otherProjectName: "Project A")) {
            _ = try await fixture.service.bindProjectRoot(
                projectID: StoreFixture.projectB, rootPath: fixture.folderA.path, expectedRevisionID: next)
        }
    }

    @MainActor private struct StoreFixture {
        static let projectA = ArtifactID(fixtureUUID("00000000-0000-0000-0000-0000000000a1"))
        static let projectB = ArtifactID(fixtureUUID("00000000-0000-0000-0000-0000000000b2"))
        let root: URL
        let folderA: URL
        let store: WorkspaceRevisionStore
        let service: WorkspaceApplicationService

        init() throws {
            root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
                .appending(path: "project-root-service-\(UUID())", directoryHint: .isDirectory)
            folderA = root.appending(path: "project-a", directoryHint: .isDirectory)
            for directory in [root, folderA] {
                try FileManager.default.createDirectory(
                    at: directory, withIntermediateDirectories: true,
                    attributes: [.posixPermissions: 0o700])
            }
            let writerID = WorkspaceObjectID()
            let document = try WorkspaceDocumentCoding.seal(
                .init(
                    workspaceID: WorkspaceObjectID(), revision: .init(writerID: writerID),
                    artifacts: [
                        .init(
                            identity: .init(id: Self.projectA, kind: .logicalProject, displayName: "Project A"),
                            authority: .centralPersonal),
                        .init(
                            identity: .init(id: Self.projectB, kind: .logicalProject, displayName: "Project B"),
                            authority: .centralPersonal),
                    ],
                    logicalProjects: [
                        .init(id: Self.projectA, name: "Project A"),
                        .init(id: Self.projectB, name: "Project B"),
                    ]))
            let device = DeviceWorkspaceState(workspaceID: document.workspaceID)
            store = try WorkspaceRevisionStore(
                containerRoot: root.appending(path: "store"), workspaceID: document.workspaceID,
                deviceID: device.deviceID)
            try store.initialize(document: document, device: device)
            service = WorkspaceApplicationService(store: store, writerID: writerID)
        }

        func remove() { try? FileManager.default.removeItem(at: root) }
    }
}
