import Foundation
import Testing

@testable import AgentToolingCore
@testable import AgentToolingApp

/// Writing a project's declaration and lock. Only what can actually be pinned
/// reaches the lock; the rest is named rather than written as a line that could
/// not bring back the same files.
@MainActor
struct WorkspaceProjectDeclarationSessionTests {
    @Test func whatTheProjectAsksForIsDeclaredAndWhatIsPinnedIsLocked() async throws {
        let fixture = try await Fixture()
        defer { fixture.remove() }
        let session = fixture.session()

        session.prepare(projectID: Fixture.projectID)

        let preview = try #require(session.preview)
        #expect(preview.declaration.entries.map(\.name) == ["auditor", "reviewer"])
        #expect(preview.lock?.entries.map(\.name) == ["reviewer"])
        // Asked for, and honestly named as unpinnable rather than left out.
        #expect(preview.unlocked == ["auditor"])
    }

    @Test func writingProducesBothFilesAndNothingElse() async throws {
        let fixture = try await Fixture()
        defer { fixture.remove() }
        let session = fixture.session()
        session.prepare(projectID: Fixture.projectID)

        await session.write(to: fixture.projectRoot)

        #expect(session.errorMessage == nil, "\(session.errorMessage ?? "")")
        #expect(session.writtenPaths.count == 2)
        let directory = fixture.projectRoot.appending(path: ".agent-tooling")
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path).sorted()
            == ["project-lock.json", "project.json"])
        // The project's own files are untouched.
        #expect(try Data(contentsOf: fixture.projectRoot.appending(path: "README.md"))
            == Data("theirs\n".utf8))
    }

    @Test func neitherFileCarriesAnythingFromThisMac() async throws {
        let fixture = try await Fixture()
        defer { fixture.remove() }
        let session = fixture.session()
        session.prepare(projectID: Fixture.projectID)
        await session.write(to: fixture.projectRoot)

        for path in session.writtenPaths {
            let text = String(decoding: try Data(contentsOf: URL(fileURLWithPath: path)), as: UTF8.self)
            #expect(!text.contains(fixture.root.path))
            #expect(!text.contains("deviceID") && !text.contains("observedAt"))
        }
    }

    @Test func whatComesBackFromDiskIsWhatWasShown() async throws {
        let fixture = try await Fixture()
        defer { fixture.remove() }
        let session = fixture.session()
        session.prepare(projectID: Fixture.projectID)
        let preview = try #require(session.preview)
        await session.write(to: fixture.projectRoot)

        let store = try WorkspaceProjectDeclarationStore(projectRoot: fixture.projectRoot)
        #expect(try store.readDeclaration() == preview.declaration)
        #expect(try store.readLock() == preview.lock)
    }

    @Test func someoneElsesFileOfTheSameNameIsLeftAlone() async throws {
        let fixture = try await Fixture()
        defer { fixture.remove() }
        let directory = fixture.projectRoot.appending(path: ".agent-tooling")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let theirs = Data(#"{"marker":"another-tool"}"#.utf8)
        try theirs.write(to: directory.appending(path: "project.json"))
        let session = fixture.session()
        session.prepare(projectID: Fixture.projectID)

        await session.write(to: fixture.projectRoot)

        #expect(session.errorMessage?.contains("did not write") == true,
                "\(session.errorMessage ?? "")")
        #expect(try Data(contentsOf: directory.appending(path: "project.json")) == theirs)
        #expect(!FileManager.default.fileExists(atPath: directory.appending(path: "project-lock.json").path))
    }

    @Test func aReadOnlyWorkspaceCannotWriteIntoAProjectFolder() async throws {
        let fixture = try await Fixture()
        defer { fixture.remove() }
        let readOnly = fixture.readOnly
        await readOnly.refresh()
        let session = WorkspaceProjectDeclarationSession(library: readOnly)
        session.prepare(projectID: Fixture.projectID)

        #expect(session.preview != nil)
        #expect(!session.canWrite)
        await session.write(to: fixture.projectRoot)
        #expect(!FileManager.default.fileExists(
            atPath: fixture.projectRoot.appending(path: ".agent-tooling").path))
    }

    @Test func aDeclarationAlreadyInTheFolderIsReadBackAgainstWhatYouHave() async throws {
        let fixture = try await Fixture()
        defer { fixture.remove() }
        let session = fixture.session()
        session.prepare(projectID: Fixture.projectID)
        await session.write(to: fixture.projectRoot)
        session.discard()

        session.readCommitted(projectRoot: fixture.projectRoot)

        let result = try #require(session.committed)
        #expect(session.committedMessage == nil)
        // This workspace wrote it, so it holds the pinned one and the unpinned
        // one, and says which is which.
        #expect(result.items.first { $0.name == "reviewer" }?.state == .matchesLock)
        #expect(result.items.first { $0.name == "auditor" }?.state == .heldUnpinned)
        #expect(!result.isFullySatisfied)
    }

    @Test func aProjectCarryingNoDeclarationSaysSoRatherThanShowingNothing() async throws {
        let fixture = try await Fixture()
        defer { fixture.remove() }
        let session = fixture.session()

        session.readCommitted(projectRoot: fixture.projectRoot)

        #expect(session.committed == nil)
        #expect(session.committedMessage?.contains("no Agent Tooling declaration") == true)
    }

    @Test func aDeclarationThisVersionCannotReadIsNotTreatedAsAskingForNothing() async throws {
        let fixture = try await Fixture()
        defer { fixture.remove() }
        let directory = fixture.projectRoot.appending(path: ".agent-tooling")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data(#"{"marker":"agent-tooling.project.v1","formatVersion":99,"entries":[]}"#.utf8)
            .write(to: directory.appending(path: "project.json"))
        let session = fixture.session()

        session.readCommitted(projectRoot: fixture.projectRoot)

        // Reporting nothing would look like the project asks for nothing.
        #expect(session.committed == nil)
        #expect(session.committedMessage?.contains("cannot read") == true)
    }

    @Test func readingBackInstallsNothing() async throws {
        let fixture = try await Fixture()
        defer { fixture.remove() }
        let session = fixture.session()
        session.prepare(projectID: Fixture.projectID)
        await session.write(to: fixture.projectRoot)
        let before = try #require(try fixture.store.snapshot()).document.revision.id

        session.readCommitted(projectRoot: fixture.projectRoot)

        #expect(session.committed != nil)
        // Answering "what do I have" changed nothing about what this Mac holds.
        #expect(try #require(try fixture.store.snapshot()).document.revision.id == before)
        #expect(try FileManager.default.contentsOfDirectory(
            atPath: fixture.projectRoot.appending(path: ".agent-tooling").path).count == 2)
    }

    @MainActor private struct Fixture {
        static let projectID = ArtifactID(UUID(uuidString: "00000000-0000-0000-0000-0000000000d4")!)
        static let pinned = ArtifactID(UUID(uuidString: "00000000-0000-0000-0000-0000000000a1")!)
        static let unpinned = ArtifactID(UUID(uuidString: "00000000-0000-0000-0000-0000000000b2")!)
        let root: URL
        let projectRoot: URL
        let store: WorkspaceRevisionStore
        let library: WorkspaceLibrarySession
        let service: WorkspaceApplicationService

        init() async throws {
            root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
                .appending(path: "project-declaration-session-\(UUID())")
            projectRoot = root.appending(path: "work")
            try FileManager.default.createDirectory(at: projectRoot, withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700])
            try Data("theirs\n".utf8).write(to: projectRoot.appending(path: "README.md"))

            let writerID = WorkspaceObjectID()
            let sourceID = WorkspaceObjectID()
            let destination = PortableDestination(surface: .codexCLI, scope: .project,
                                                  logicalProjectID: Self.projectID)
            let document = try WorkspaceDocumentCoding.seal(.init(
                workspaceID: WorkspaceObjectID(), revision: .init(writerID: writerID),
                artifacts: [
                    .init(identity: .init(id: Self.pinned, kind: .skill, displayName: "Reviewer"),
                          authority: .centralUpstream(subscriptionID: Self.subscriptionID),
                          declaredName: "reviewer",
                          contentDigest: .init(value: String(repeating: "b", count: 64))),
                    .init(identity: .init(id: Self.unpinned, kind: .skill, displayName: "Auditor"),
                          authority: .centralPersonal, declaredName: "auditor",
                          contentDigest: .init(value: String(repeating: "c", count: 64))),
                    .init(identity: .init(id: Self.projectID, kind: .logicalProject,
                                          displayName: "Work"),
                          authority: .centralPersonal),
                ],
                sources: [.init(id: sourceID, role: .publisherRepository,
                                repositoryURL: "https://github.com/you/skills",
                                requestedRef: "main", packageRelativePaths: ["skills/reviewer"])],
                subscriptions: [.init(id: Self.subscriptionID, artifactID: Self.pinned,
                                      sourceID: sourceID,
                                      lock: .init(publisherID: "github:you", sourceRootID: sourceID,
                                                  requestedRef: "main",
                                                  approvedRevision: .init(kind: .gitCommitSHA1,
                                                                          value: String(repeating: "a", count: 40)),
                                                  approvedContent: .init(value: String(repeating: "b", count: 64)),
                                                  packageRelativePath: "skills/reviewer"))],
                logicalProjects: [.init(id: Self.projectID, name: "Work")],
                assignments: [
                    .init(artifactID: Self.pinned, destination: destination, reason: .manual),
                    .init(artifactID: Self.unpinned, destination: destination, reason: .manual),
                ]))
            var device = DeviceWorkspaceState(workspaceID: document.workspaceID)
            device.projectRoots = [.init(projectID: Self.projectID, rootPath: projectRoot.path)]
            store = try WorkspaceRevisionStore(containerRoot: root.appending(path: "store"),
                workspaceID: document.workspaceID, deviceID: device.deviceID)
            try store.initialize(document: document, device: device)
            service = WorkspaceApplicationService(store: store, writerID: writerID)
            library = WorkspaceLibrarySession(service: service, workspaceID: document.workspaceID,
                                              deviceID: device.deviceID, access: .writable)
            await library.refresh()
        }

        static let subscriptionID = WorkspaceObjectID(UUID(uuidString: "00000000-0000-0000-0000-0000000000e5")!)

        func session(access: WorkspaceLibraryAccess = .writable) -> WorkspaceProjectDeclarationSession {
            WorkspaceProjectDeclarationSession(library: access == .writable ? library : readOnly)
        }

        /// A second session over the same store, opened for reading only.
        var readOnly: WorkspaceLibrarySession {
            let session = WorkspaceLibrarySession(service: service, workspaceID: store.workspaceID,
                                                  deviceID: store.deviceID, access: .readOnly)
            Task { await session.refresh() }
            return session
        }

        func remove() { try? FileManager.default.removeItem(at: root) }
    }
}
