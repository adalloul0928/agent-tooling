import Foundation
import Testing

@testable import AgentToolingApp
@testable import AgentToolingCore

/// Projects come from folders on this Mac, and a project is known by its
/// repository: a clone on another Mac is the same project.
@Suite("Project discovery") @MainActor
struct WorkspaceProjectDiscoverySessionTests {
    /// A checkout under the fixture's root (not its home), with an `origin`.
    private func checkout(_ fixture: ShellRenderFixture, _ name: String, remote: String?, skills: [String] = []) throws -> URL {
        let folder = fixture.home.deletingLastPathComponent().appending(path: "src/\(name)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder.appending(path: ".git"), withIntermediateDirectories: true)
        try Data("ref: refs/heads/main\n".utf8).write(to: folder.appending(path: ".git/HEAD"))
        if let remote {
            try Data("[remote \"origin\"]\n\turl = \(remote)\n".utf8).write(to: folder.appending(path: ".git/config"))
        }
        for skill in skills {
            let dir = folder.appending(path: ".claude/skills/\(skill)", directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try Data("---\nname: \(skill)\n---\n".utf8).write(to: dir.appending(path: "SKILL.md"))
        }
        return folder
    }

    private func scanRoot(_ fixture: ShellRenderFixture) -> URL {
        fixture.home.deletingLastPathComponent().appending(path: "src", directoryHint: .isDirectory)
    }

    @Test func aCheckoutOfAnUnattachedProjectsRepositoryIsRecognised() async throws {
        let fixture = try await ShellRenderFixture()
        defer { fixture.remove() }
        // The fixture's Project A names https://github.com/acme/project and has no folder here.
        _ = try checkout(fixture, "project", remote: "git@github.com:acme/project.git", skills: ["release-check"])
        _ = try checkout(fixture, "unrelated", remote: "https://github.com/someone/else")
        _ = try checkout(fixture, "no-remote", remote: nil)
        let discovery = fixture.workspace.projectDiscovery
        try await fixture.workspace.device.setProjectScanRoots([scanRoot(fixture).path(percentEncoded: false)])

        await discovery.refresh()

        let byName = Dictionary(discovery.untrackedFolders.map { ($0.project.name, $0) }, uniquingKeysWith: { a, _ in a })
        #expect(byName["project"]?.standing == .matches(projectID: ShellRenderFixture.projectID))
        #expect(byName["unrelated"]?.standing == .untracked)
        #expect(byName["no-remote"]?.standing == .untracked)
        // Checkouts of the project come first: they have an obvious answer.
        #expect(discovery.untrackedFolders.first?.project.name == "project")
        #expect(discovery.candidates(for: ShellRenderFixture.projectID).map(\.name) == ["project"])
        #expect(byName["project"]?.project.skills.map(\.id) == ["release-check"])
    }

    @Test func attachingBindsTheFolderAndTheProjectKeepsItsRepository() async throws {
        let fixture = try await ShellRenderFixture()
        defer { fixture.remove() }
        let folder = try checkout(fixture, "project", remote: "https://github.com/acme/project.git")
        let discovery = fixture.workspace.projectDiscovery
        try await fixture.workspace.device.setProjectScanRoots([scanRoot(fixture).path(percentEncoded: false)])
        await discovery.refresh()
        let match = try #require(discovery.untrackedFolders.first { $0.project.name == "project" })

        #expect(await discovery.attach(match.project, to: ShellRenderFixture.projectID))

        #expect(discovery.errorMessage == nil)
        let roots = fixture.workspace.library.state?.snapshot.device.projectRoots ?? []
        #expect(
            roots.contains {
                $0.projectID == ShellRenderFixture.projectID
                    && ProjectPath.matches($0.rootPath, project: folder.path(percentEncoded: false))
            })
        // Now tracked: out of the found list, and the detail can read the folder.
        #expect(discovery.untrackedFolders.allSatisfy { $0.project.name != "project" })
        #expect(discovery.folder(for: ShellRenderFixture.projectID)?.name == "project")
        #expect(discovery.candidates(for: ShellRenderFixture.projectID).isEmpty)
        // The hint was already there; nothing was added twice.
        let project = fixture.workspace.library.state?.library.projects.first { $0.id == ShellRenderFixture.projectID }
        #expect(project?.repositoryHints == ["https://github.com/acme/project"])
    }

    @Test func attachingAFolderFromAnotherRemoteTeachesTheProjectThatRepository() async throws {
        let fixture = try await ShellRenderFixture()
        defer { fixture.remove() }
        let mirror = try checkout(fixture, "mirror", remote: "git@gitlab.com:acme/project-mirror.git")
        let discovery = fixture.workspace.projectDiscovery
        let folder = try #require(ProjectDiscovery.inspect(root: mirror, origins: [.pinned]))

        #expect(await discovery.attach(folder, to: ShellRenderFixture.projectID))

        let project = fixture.workspace.library.state?.library.projects.first { $0.id == ShellRenderFixture.projectID }
        #expect(project?.repositoryHints == ["https://github.com/acme/project", "https://gitlab.com/acme/project-mirror"])
    }

    @Test func trackingMakesAFolderAProjectNamedAfterItWithItsRepository() async throws {
        let fixture = try await ShellRenderFixture()
        defer { fixture.remove() }
        let folder = try checkout(fixture, "order-history", remote: "git@github.com:acme/order-history.git")
        let discovery = fixture.workspace.projectDiscovery
        try await fixture.workspace.device.setProjectScanRoots([scanRoot(fixture).path(percentEncoded: false)])
        await discovery.refresh()
        let match = try #require(discovery.untrackedFolders.first { $0.project.name == "order-history" })

        let projectID = try #require(await discovery.track(match.project))

        #expect(discovery.errorMessage == nil)
        let project = fixture.workspace.library.state?.library.projects.first { $0.id == projectID }
        #expect(project?.name == "order-history")
        #expect(project?.repositoryHints == ["https://github.com/acme/order-history"])
        let roots = fixture.workspace.library.state?.snapshot.device.projectRoots ?? []
        #expect(
            roots.contains { $0.projectID == projectID && ProjectPath.matches($0.rootPath, project: folder.path(percentEncoded: false)) })
        #expect(discovery.folder(for: projectID)?.name == "order-history")
        #expect(discovery.untrackedFolders.allSatisfy { $0.project.name != "order-history" })
    }

    @Test func trackingAFolderUnderANameThatExistsIsRefusedWithAWayOut() async throws {
        let fixture = try await ShellRenderFixture()
        defer { fixture.remove() }
        let folder = try checkout(fixture, "Project A", remote: nil)
        let discovery = fixture.workspace.projectDiscovery
        let found = try #require(ProjectDiscovery.inspect(root: folder, origins: [.pinned]))

        #expect(await discovery.track(found) == nil)

        #expect(discovery.errorMessage?.contains("already exists") == true)
        #expect(fixture.workspace.library.state?.library.projects.count == 1)
    }

    @Test func scanRootsAreRememberedOnThisMacAndBounded() async throws {
        let fixture = try await ShellRenderFixture()
        defer { fixture.remove() }
        let discovery = fixture.workspace.projectDiscovery
        let root = scanRoot(fixture)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        await discovery.addScanRoot(root)
        #expect(discovery.scanRoots == [ProjectPath.canonical(root)])
        #expect(
            fixture.workspace.library.state?.snapshot.device.applicationState?.preferences.projectScanRoots == [ProjectPath.canonical(root)]
        )

        await discovery.addScanRoot(root)
        #expect(discovery.scanRoots.count == 1)

        await discovery.addScanRoot(fixture.home.appending(path: "nowhere"))
        #expect(discovery.errorMessage == "That folder is not on this Mac.")

        await discovery.removeScanRoot(ProjectPath.canonical(root))
        #expect(discovery.scanRoots.isEmpty)
    }
}
