import Foundation
import SwiftUI
import Testing

@testable import AgentToolingApp
@testable import AgentToolingCore

/// Projects draw the logical projects this workspace holds.
@Suite("Projects renders")
@MainActor
struct ProjectsSectionRenderTests {
    @Test func theShellDrawsProjects() async throws {
        let fixture = try await ShellRenderFixture()
        defer { fixture.remove() }

        try expectDrawn(renderShell(.projects, fixture: fixture))
    }

    /// A project with something assigned to it and a folder on this device
    /// draws a populated row and clause rather than the "no folder yet" and
    /// "0 tools assigned" defaults every other project in the fixture has.
    @Test func theShellDrawsAProjectWithAssignedTools() async throws {
        let fixture = try await ShellRenderFixture()
        defer { fixture.remove() }
        try await fixture.assignSkillToFixtureProject()

        try expectDrawn(renderShell(.projects, fixture: fixture))
    }

    /// Nothing in the shell deep-links into one project today, so this
    /// exercises `ProjectDetailView` directly through the same
    /// `initialSelection` seam a future route could reuse — the tabs, the
    /// "In this project" / "Inherited from this Mac" cards, and the location
    /// text over a real device folder binding.
    @Test func theProjectDetailPaneDraws() async throws {
        let fixture = try await ShellRenderFixture()
        defer { fixture.remove() }
        try await fixture.assignSkillToFixtureProject()

        try expectDrawn(
            ProjectsView(workspace: fixture.workspace, initialSelection: ShellRenderFixture.projectID)
                .frame(width: shellWindowSize.width, height: shellWindowSize.height))
    }

    /// A project with no folder on this Mac draws its detail header with the
    /// "Choose folder…" button and the one-line explanation, rather than the
    /// bound-folder location text. The fixture's project has no binding, so
    /// selecting it straight away exercises the no-folder path.
    @Test func theProjectDetailPaneDrawsWithoutAFolder() async throws {
        let fixture = try await ShellRenderFixture()
        defer { fixture.remove() }

        try expectDrawn(
            ProjectsView(workspace: fixture.workspace, initialSelection: ShellRenderFixture.projectID)
                .frame(width: shellWindowSize.width, height: shellWindowSize.height))
    }
}

extension ProjectsSectionRenderTests {
    /// The list with a folder found on this Mac that matches the fixture's
    /// project by repository, and one that matches nothing.
    @Test func theListDrawsFoldersFoundOnThisMac() async throws {
        let fixture = try await ShellRenderFixture()
        defer { fixture.remove() }
        let src = fixture.home.deletingLastPathComponent().appending(path: "src", directoryHint: .isDirectory)
        for (name, remote) in [("project", "git@github.com:acme/project.git"), ("scratch", "https://github.com/someone/scratch")] {
            let folder = src.appending(path: name, directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: folder.appending(path: ".git"), withIntermediateDirectories: true)
            try Data("ref: refs/heads/main\n".utf8).write(to: folder.appending(path: ".git/HEAD"))
            try Data("[remote \"origin\"]\n\turl = \(remote)\n".utf8).write(to: folder.appending(path: ".git/config"))
        }
        try await fixture.workspace.device.setProjectScanRoots([src.path(percentEncoded: false)])
        await fixture.workspace.projectDiscovery.refresh()
        #expect(fixture.workspace.projectDiscovery.untrackedFolders.count == 2)

        try expectDrawn(
            ProjectsView(workspace: fixture.workspace)
                .frame(width: shellWindowSize.width, height: shellWindowSize.height))
        try expectDrawn(
            ProjectsView(workspace: fixture.workspace, initialSelection: ShellRenderFixture.projectID)
                .frame(width: shellWindowSize.width, height: shellWindowSize.height))
    }

    /// A bound folder's own agent files, read from disk, in the detail.
    @Test func theDetailDrawsWhatTheFolderHolds() async throws {
        let fixture = try await ShellRenderFixture()
        defer { fixture.remove() }
        try await fixture.assignSkillToFixtureProject()
        let folder = URL(fileURLWithPath: "/tmp/agent-tooling-render-fixture/project-a", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let skill = folder.appending(path: ".claude/skills/repo-skill", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: skill, withIntermediateDirectories: true)
        try Data("---\nname: repo-skill\n---\n".utf8).write(to: skill.appending(path: "SKILL.md"))
        try Data("# notes\n".utf8).write(to: folder.appending(path: "CLAUDE.md"))
        await fixture.workspace.projectDiscovery.refresh()
        #expect(fixture.workspace.projectDiscovery.folder(for: ShellRenderFixture.projectID)?.skills.map(\.id) == ["repo-skill"])

        try expectDrawn(
            ProjectsView(workspace: fixture.workspace, initialSelection: ShellRenderFixture.projectID)
                .frame(width: shellWindowSize.width, height: shellWindowSize.height))
    }
}
