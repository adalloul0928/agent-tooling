import Foundation
import Testing

@testable import AgentToolingCore

private struct SilentRunner: CommandRunning {
    func run(executable: String, arguments: [String], currentDirectory: URL?) async throws -> CommandOutput {
        CommandOutput(status: 127, standardOutput: "", standardError: "command not found")
    }
}

@MainActor
struct ProjectsAppModelTests {

    @Test func addingAProjectPinsItAndItSurvivesARestart() async throws {
        let fixture = try Fixture()
        let project = try fixture.makeProject(named: "chosen", files: ["CLAUDE.md": "# chosen"])

        let model = try fixture.makeModel()
        await model.addProject(at: project)

        #expect(model.projects.map(\.path) == [ProjectPath.canonical(project)])
        #expect(model.projects.first?.origins == [.pinned])

        let restarted = try fixture.makeModel()
        await restarted.discoverProjects()
        #expect(restarted.projects.map(\.path) == [ProjectPath.canonical(project)])
        #expect(restarted.projects.first?.isPinned == true)
    }

    @Test func forgettingAPinnedOnlyProjectRemovesItFromTheList() async throws {
        let fixture = try Fixture()
        let project = try fixture.makeProject(named: "temporary", files: ["CLAUDE.md": "#"])
        let model = try fixture.makeModel()
        await model.addProject(at: project)
        #expect(!model.projects.isEmpty)

        model.forgetProject(ProjectPath.canonical(project))
        #expect(model.projects.isEmpty)

        let restarted = try fixture.makeModel()
        await restarted.discoverProjects()
        #expect(restarted.projects.isEmpty)
    }

    @Test func unpinningKeepsAProjectClaudeCodeHasRunIn() async throws {
        let fixture = try Fixture()
        let project = try fixture.makeProject(named: "worked-in", files: ["CLAUDE.md": "#"])
        try fixture.recordSessionIndexEntry(for: project)

        let model = try fixture.makeModel()
        await model.discoverProjects()
        #expect(model.projects.map(\.path) == [ProjectPath.canonical(project)])
        #expect(model.projects.first?.isPinned == false)

        model.setProjectPinned(ProjectPath.canonical(project), pinned: true)
        #expect(model.projects.first?.isPinned == true)

        model.forgetProject(ProjectPath.canonical(project))
        #expect(model.projects.map(\.path) == [ProjectPath.canonical(project)])
        #expect(model.projects.first?.isPinned == false)
    }

    @Test func scanningAFolderListsTheProjectsInsideIt() async throws {
        let fixture = try Fixture()
        _ = try fixture.makeProject(named: "one", files: ["CLAUDE.md": "#"])
        _ = try fixture.makeProject(named: "two", files: [".mcp.json": #"{"mcpServers": {}}"#])
        try FileManager.default.createDirectory(
            at: fixture.workspace.appending(path: "notes", directoryHint: .isDirectory), withIntermediateDirectories: true)

        let model = try fixture.makeModel()
        await model.addProjectScanRoot(at: fixture.workspace)

        #expect(model.projects.map(\.name).sorted() == ["one", "two"])
        #expect(model.projectScanRoots == [ProjectPath.canonical(fixture.workspace)])

        await model.removeProjectScanRoot(ProjectPath.canonical(fixture.workspace))
        #expect(model.projects.isEmpty)
        #expect(model.projectScanRoots.isEmpty)
    }

    @Test func applyingTheIgnorePlanRecordsAnActivityAndClearsTheWarning() async throws {
        let fixture = try Fixture()
        let project = try fixture.makeProject(
            named: "leaky",
            files: [".claude/settings.json": "{}", ".claude/settings.local.json": "{}"]
        )

        let model = try fixture.makeModel()
        await model.addProject(at: project)
        let discovered = try #require(model.projects.first)
        #expect(discovered.configurationHealth == .attention)

        let plan = try #require(model.projectIgnorePlan(for: discovered))
        #expect(model.applyProjectIgnorePlan(plan))

        #expect(model.projects.first?.configurationHealth == .healthy)
        #expect(model.projects.first?.unlistedMachineLocalPatterns.isEmpty == true)
        #expect(model.activities.first?.affectedPaths == [plan.gitignorePath])
        #expect(model.lastError == nil)

        // A second attempt with the same plan is refused rather than
        // duplicating the lines.
        #expect(!model.applyProjectIgnorePlan(plan))
    }

    // MARK: - Fixture

    private struct Fixture {
        let root: URL
        let home: URL
        let workspace: URL

        init() throws {
            root = FileManager.default.temporaryDirectory
                .appending(path: "agent-tooling-projects-model-\(UUID().uuidString)", directoryHint: .isDirectory)
            home = root.appending(path: "home", directoryHint: .isDirectory)
            workspace = root.appending(path: "ws", directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        }

        @MainActor
        func makeModel() throws -> AppModel {
            let store = try WorkspaceStore(rootURL: root.appending(path: "workspace", directoryHint: .isDirectory))
            return try AppModel(store: store, runner: SilentRunner(), homeURL: home)
        }

        func makeProject(named name: String, files: [String: String]) throws -> URL {
            let project = workspace.appending(path: name, directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
            for (relativePath, contents) in files {
                let url = project.appending(path: relativePath)
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try Data(contents.utf8).write(to: url, options: .atomic)
            }
            return project
        }

        func recordSessionIndexEntry(for project: URL) throws {
            let encoded = ProjectPath.canonical(project)
                .replacingOccurrences(of: "/", with: "-")
                .replacingOccurrences(of: ".", with: "-")
            try FileManager.default.createDirectory(
                at: home.appending(path: ".claude/projects", directoryHint: .isDirectory)
                    .appending(path: encoded, directoryHint: .isDirectory),
                withIntermediateDirectories: true)
        }
    }
}
