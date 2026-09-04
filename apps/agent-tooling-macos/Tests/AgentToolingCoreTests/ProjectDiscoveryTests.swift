import Foundation
import Testing

@testable import AgentToolingCore

struct ProjectDiscoveryTests {

    // MARK: - Session index

    @Test func sessionIndexFindsProjectsAndIgnoresNonDirectories() throws {
        let root = try temporaryDirectory()
        let home = root.appending(path: "home", directoryHint: .isDirectory)
        let index = home.appending(path: ".claude/projects", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: index, withIntermediateDirectories: true)

        let alpha = try makeProject(named: "alpha", under: root, files: ["CLAUDE.md": "# alpha"])
        // A folder whose own name contains a dot exercises the lossy `.` to `-`
        // substitution Claude Code applies when it names an index entry.
        let dotted = try makeProject(named: "beta.app", under: root, files: ["AGENTS.md": "# beta"])
        let ignoredByFileEntry = try makeProject(named: "gamma", under: root, files: ["CLAUDE.md": "# gamma"])
        let missing = root.appending(path: "work/deleted-project", directoryHint: .isDirectory)

        try makeIndexDirectory(for: alpha, in: index)
        try makeIndexDirectory(for: dotted, in: index)
        try makeIndexDirectory(for: missing, in: index)
        // A regular file in the index is not a project, even though its name
        // decodes to a folder that really exists.
        try Data("not an index entry".utf8).write(to: index.appending(path: encodedName(for: ignoredByFileEntry)))

        let roots = ProjectDiscovery.sessionIndexRoots(homeURL: home).map(ProjectPath.canonical)

        #expect(roots.contains(ProjectPath.canonical(alpha)))
        #expect(roots.contains(ProjectPath.canonical(dotted)))
        #expect(!roots.contains(ProjectPath.canonical(ignoredByFileEntry)))
        #expect(!roots.contains(ProjectPath.canonical(missing)))
    }

    @Test func sessionIndexPrefersTheLongestRealPathComponent() throws {
        let root = try temporaryDirectory()
        let home = root.appending(path: "home", directoryHint: .isDirectory)
        let index = home.appending(path: ".claude/projects", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: index, withIntermediateDirectories: true)

        // `pumpd` and `pumpd-app` are siblings; a naive split on "-" would
        // resolve the second entry to the first folder.
        _ = try makeProject(named: "pumpd", under: root, files: ["CLAUDE.md": "#"])
        let longer = try makeProject(named: "pumpd-app", under: root, files: ["CLAUDE.md": "#"])
        try makeIndexDirectory(for: longer, in: index)

        let roots = ProjectDiscovery.sessionIndexRoots(homeURL: home).map(ProjectPath.canonical)
        #expect(roots == [ProjectPath.canonical(longer)])
    }

    @Test func sessionIndexNeverListsTheHomeFolderItself() throws {
        let root = try temporaryDirectory()
        let home = root.appending(path: "home", directoryHint: .isDirectory)
        let index = home.appending(path: ".claude/projects", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: index, withIntermediateDirectories: true)
        // The user-scope installation lives here; it is not a project.
        try write("---\nname: global\n---\n", to: home.appending(path: ".claude/skills/global/SKILL.md"))
        try makeIndexDirectory(for: home, in: index)

        #expect(ProjectDiscovery.sessionIndexRoots(homeURL: home).isEmpty)
        #expect(!ProjectDiscovery.isEligibleProjectRoot(home, homeURL: home))
        #expect(!ProjectDiscovery.isEligibleProjectRoot(root, homeURL: home))
        #expect(!ProjectDiscovery.isEligibleProjectRoot(URL(fileURLWithPath: "/"), homeURL: home))
        #expect(ProjectDiscovery.isEligibleProjectRoot(home.appending(path: "work"), homeURL: home))
    }

    @Test func aProjectWithOnlyLocalSettingsStillDescribesItself() throws {
        let root = try temporaryDirectory()
        let project = root.appending(path: "work/quiet", directoryHint: .isDirectory)
        try write("{}", to: project.appending(path: ".claude/settings.local.json"))

        let inspected = try #require(ProjectDiscovery.inspect(root: project, origins: []))
        #expect(!inspected.isPlain)
        #expect(inspected.badges == ["1 machine-local file"])
    }

    @Test func sessionIndexIsEmptyWhenClaudeHasNeverRun() throws {
        let root = try temporaryDirectory()
        #expect(ProjectDiscovery.sessionIndexRoots(homeURL: root).isEmpty)
    }

    // MARK: - Inspection

    @Test func projectWithoutOverridesReportsPlain() throws {
        let root = try temporaryDirectory()
        let plain = root.appending(path: "work/plain", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(
            at: plain.appending(path: ".git", directoryHint: .isDirectory), withIntermediateDirectories: true)

        let project = try #require(ProjectDiscovery.inspect(root: plain, origins: [.sessionIndex]))

        #expect(project.isPlain)
        #expect(project.badges.isEmpty)
        #expect(project.configurationHealth == nil)
        #expect(project.files.isEmpty)
        #expect(project.skills.isEmpty)
        #expect(project.mcpServers.isEmpty)
        #expect(project.plugins.isEmpty)
    }

    @Test func inspectionReadsSkillsServersPluginsAndInstructions() throws {
        let root = try temporaryDirectory()
        let project = root.appending(path: "work/configured", directoryHint: .isDirectory)
        try write("# instructions", to: project.appending(path: "CLAUDE.md"))
        try write(#"{"mcpServers": {"sentry": {"url": "https://example.test/mcp"}}}"#, to: project.appending(path: ".mcp.json"))
        try write(
            #"{"enabledPlugins": {"developer-workflows@local": true}}"#,
            to: project.appending(path: ".claude/settings.json"))
        try write("---\nname: review\n---\n", to: project.appending(path: ".claude/skills/review/SKILL.md"))
        try write("---\nname: portable\n---\n", to: project.appending(path: ".agents/skills/portable/SKILL.md"))
        // A folder without SKILL.md is not a skill package.
        try FileManager.default.createDirectory(
            at: project.appending(path: ".claude/skills/not-a-skill", directoryHint: .isDirectory),
            withIntermediateDirectories: true)

        let inspected = try #require(ProjectDiscovery.inspect(root: project, origins: [.pinned]))

        #expect(!inspected.isPlain)
        #expect(inspected.isPinned)
        #expect(inspected.skills.map(\.id).sorted() == ["portable", "review"])
        #expect(inspected.mcpServers.map(\.id) == ["sentry"])
        #expect(inspected.plugins.map(\.id) == ["developer-workflows@local"])
        #expect(inspected.instructionFileTitles == ["CLAUDE.md"])
        #expect(inspected.badges.contains("1 MCP server"))
        #expect(inspected.badges.contains("2 skills"))
        #expect(inspected.badges.contains("CLAUDE.md"))
    }

    @Test func inspectionSeparatesCommittedFromMachineLocalFiles() throws {
        let root = try temporaryDirectory()
        let project = root.appending(path: "work/split", directoryHint: .isDirectory)
        try write(#"{"permissions": {}}"#, to: project.appending(path: ".claude/settings.json"))
        try write(#"{"permissions": {}}"#, to: project.appending(path: ".claude/settings.local.json"))
        // An unknown `*.local.*` file is machine-local by convention.
        try write("model = \"x\"\n", to: project.appending(path: ".codex/config.local.toml"))

        let inspected = try #require(ProjectDiscovery.inspect(root: project, origins: [.sessionIndex]))

        #expect(inspected.committedFiles.map(\.descriptor.relativePath) == [".claude/settings.json"])
        #expect(
            inspected.machineLocalFiles.map(\.descriptor.relativePath).sorted() == [
                ".claude/settings.local.json", ".codex/config.local.toml",
            ])
        #expect(inspected.configurationHealth == .attention)
    }

    @Test func inspectionReadsTheCheckedOutBranch() throws {
        let root = try temporaryDirectory()
        let project = root.appending(path: "work/branchy", directoryHint: .isDirectory)
        try write("# notes", to: project.appending(path: "CLAUDE.md"))
        try write("ref: refs/heads/feature/projects-section\n", to: project.appending(path: ".git/HEAD"))

        let inspected = try #require(ProjectDiscovery.inspect(root: project, origins: []))
        #expect(inspected.gitBranch == "feature/projects-section")
        #expect(!inspected.isDetachedHead)
    }

    @Test func inspectionReportsADetachedHeadAsAShortCommit() throws {
        let root = try temporaryDirectory()
        let project = root.appending(path: "work/detached", directoryHint: .isDirectory)
        try write("# notes", to: project.appending(path: "CLAUDE.md"))
        try write(String(repeating: "a1b2c3d4", count: 5) + "\n", to: project.appending(path: ".git/HEAD"))

        let inspected = try #require(ProjectDiscovery.inspect(root: project, origins: []))
        #expect(inspected.gitBranch == "a1b2c3d")
        #expect(inspected.isDetachedHead)
    }

    @Test func inspectionFollowsAWorktreeGitPointerFile() throws {
        let root = try temporaryDirectory()
        let gitDirectory = root.appending(path: "repo/.git/worktrees/feature", directoryHint: .isDirectory)
        try write("ref: refs/heads/side-branch\n", to: gitDirectory.appending(path: "HEAD"))
        let project = root.appending(path: "work/worktree", directoryHint: .isDirectory)
        try write("# notes", to: project.appending(path: "CLAUDE.md"))
        try write("gitdir: \(gitDirectory.path(percentEncoded: false))\n", to: project.appending(path: ".git"))

        let inspected = try #require(ProjectDiscovery.inspect(root: project, origins: []))
        #expect(inspected.gitBranch == "side-branch")
    }

    @Test func scanningAFolderFindsOnlyProjectLookingChildren() throws {
        let root = try temporaryDirectory()
        let workspace = root.appending(path: "ws", directoryHint: .isDirectory)
        let repository = workspace.appending(path: "repo", directoryHint: .isDirectory)
        try write("ref: refs/heads/main\n", to: repository.appending(path: ".git/HEAD"))
        let configured = workspace.appending(path: "configured", directoryHint: .isDirectory)
        try write("# notes", to: configured.appending(path: "CLAUDE.md"))
        try FileManager.default.createDirectory(
            at: workspace.appending(path: "notes", directoryHint: .isDirectory), withIntermediateDirectories: true)

        let found = ProjectDiscovery.scannedRoots(under: workspace).map(\.lastPathComponent).sorted()
        #expect(found == ["configured", "repo"])
    }

    // MARK: - Inherited versus overridden

    @Test func overlayMarksInheritedOverriddenAndProjectOnlyComponents() throws {
        let root = try temporaryDirectory()
        let project = root.appending(path: "work/overlay", directoryHint: .isDirectory)
        try write("---\nname: review\n---\n", to: project.appending(path: ".claude/skills/review/SKILL.md"))
        try write("---\nname: only-here\n---\n", to: project.appending(path: ".claude/skills/only-here/SKILL.md"))

        let inspected = try #require(ProjectDiscovery.inspect(root: project, origins: []))
        let rows = ProjectOverlay.rows(
            kind: .skill,
            inherited: [
                ProjectInheritedComponent(id: "review", name: "Review", detail: "Managed on this Mac", clients: [.claude]),
                ProjectInheritedComponent(id: "elsewhere", name: "Elsewhere", detail: "Managed on this Mac", clients: [.codex]),
            ],
            local: inspected.skills
        )

        let origins = Dictionary(uniqueKeysWithValues: rows.map { ($0.id, $0.origin) })
        #expect(origins["review"] == .overridden)
        #expect(origins["only-here"] == .projectOnly)
        #expect(origins["elsewhere"] == .inherited)
        // Overridden first, then project-only, then inherited.
        #expect(rows.map(\.id) == ["review", "only-here", "elsewhere"])
        #expect(rows.first?.sourceRelativePath == ".claude/skills/review")
    }

    @Test func overlayReportsEverythingInheritedForAPlainProject() throws {
        let rows = ProjectOverlay.rows(
            kind: .mcpServer,
            inherited: [ProjectInheritedComponent(id: "sentry", name: "Sentry", detail: "HTTP · This Mac")],
            local: []
        )
        #expect(rows.map(\.origin) == [.inherited])
    }

    @Test func overlayIgnoresRecordsOfAnotherKind() throws {
        let record = ProjectComponentRecord(
            id: "sentry",
            name: "Sentry",
            kind: .mcpServer,
            client: .claude,
            sharing: .committed,
            sourceRelativePath: ".mcp.json",
            sourcePath: "/tmp/.mcp.json"
        )
        let rows = ProjectOverlay.rows(kind: .skill, inherited: [], local: [record])
        #expect(rows.isEmpty)
    }

    // MARK: - Machine-local hygiene

    @Test func gitignorePlanWritesTheExpectedLineAndIsIdempotent() throws {
        let root = try temporaryDirectory()
        let project = root.appending(path: "work/hygiene", directoryHint: .isDirectory)
        try write(#"{"permissions": {}}"#, to: project.appending(path: ".claude/settings.local.json"))
        try write("node_modules\n", to: project.appending(path: ".gitignore"))

        let inspected = try #require(ProjectDiscovery.inspect(root: project, origins: []))
        #expect(inspected.unlistedMachineLocalPatterns == ["/.claude/settings.local.json"])

        let plan = try ProjectGitignore.plan(for: inspected)
        #expect(plan.missingPatterns == ["/.claude/settings.local.json"])
        #expect(plan.appendedText == "\n\(ProjectGitignore.header)\n/.claude/settings.local.json\n")

        #expect(try ProjectGitignore.apply(plan))

        let contents = try String(contentsOf: project.appending(path: ".gitignore"), encoding: .utf8)
        #expect(contents == "node_modules\n\n\(ProjectGitignore.header)\n/.claude/settings.local.json\n")

        // Applying the same plan again is a no-op, and a freshly computed plan
        // has nothing left to do.
        #expect(try ProjectGitignore.apply(plan) == false)
        let reinspected = try #require(ProjectDiscovery.inspect(root: project, origins: []))
        #expect(reinspected.unlistedMachineLocalPatterns.isEmpty)
        #expect(reinspected.configurationHealth == .healthy)
        #expect(try ProjectGitignore.plan(for: reinspected).isSatisfied)
        #expect(try String(contentsOf: project.appending(path: ".gitignore"), encoding: .utf8) == contents)
    }

    @Test func gitignorePlanCreatesTheFileWhenItIsMissing() throws {
        let root = try temporaryDirectory()
        let project = root.appending(path: "work/fresh", directoryHint: .isDirectory)
        try write(#"{}"#, to: project.appending(path: ".claude/settings.local.json"))

        let inspected = try #require(ProjectDiscovery.inspect(root: project, origins: []))
        let plan = try ProjectGitignore.plan(for: inspected)
        #expect(plan.appendedText == "\(ProjectGitignore.header)\n/.claude/settings.local.json\n")
        #expect(try ProjectGitignore.apply(plan))

        let contents = try String(contentsOf: project.appending(path: ".gitignore"), encoding: .utf8)
        #expect(contents == "\(ProjectGitignore.header)\n/.claude/settings.local.json\n")
    }

    @Test func gitignoreRecognisesEquivalentExistingRules() throws {
        #expect(ProjectGitignore.lists("/.claude/settings.local.json", in: ".claude/settings.local.json\n"))
        #expect(ProjectGitignore.lists("/.claude/settings.local.json", in: "/.claude/settings.local.json\n"))
        #expect(ProjectGitignore.lists("/.claude/settings.local.json", in: "**/.claude/settings.local.json\n"))
        // A directory rule covers everything beneath it.
        #expect(ProjectGitignore.lists("/.claude/settings.local.json", in: ".claude/\n"))
        // A comment mentioning the path does not count as a rule.
        #expect(!ProjectGitignore.lists("/.claude/settings.local.json", in: "# .claude/settings.local.json\n"))
        #expect(!ProjectGitignore.lists("/.claude/settings.local.json", in: "node_modules\n"))
    }

    @Test func gitignoreRefusesAPlanForAFolderThatIsGone() throws {
        let project = DiscoveredProject(path: "/nonexistent/agent-tooling-project", name: "gone")
        #expect(throws: ProjectIgnoreError.self) {
            _ = try ProjectGitignore.plan(for: project)
        }
    }

    @Test func gitignoreReadFailureIsNotTreatedAsAnEmptyFile() throws {
        let root = try temporaryDirectory()
        let project = root.appending(path: "work/unreadable-ignore", directoryHint: .isDirectory)
        try write(#"{}"#, to: project.appending(path: ".claude/settings.local.json"))
        try Data([0xFF, 0xFE]).write(to: project.appending(path: ".gitignore"), options: .atomic)
        let inspected = try #require(ProjectDiscovery.inspect(root: project, origins: []))

        #expect(throws: BoundedFileAccessError.self) {
            _ = try ProjectGitignore.plan(for: inspected)
        }
    }

    @Test func gitignoreRefusesToApplyAPlanWithNothingToDo() throws {
        let plan = ProjectIgnorePlan(
            projectPath: "/tmp", gitignorePath: "/tmp/.gitignore", missingPatterns: [], appendedText: "")
        #expect(throws: ProjectIgnoreError.self) {
            _ = try ProjectGitignore.apply(plan)
        }
    }

    // MARK: - Helpers

    private func temporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "agent-tooling-projects-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.resolvingSymlinksInPath().standardizedFileURL
    }

    private func makeProject(named name: String, under root: URL, files: [String: String]) throws -> URL {
        let project = root.appending(path: "work", directoryHint: .isDirectory)
            .appending(path: name, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        for (relativePath, contents) in files {
            try write(contents, to: project.appending(path: relativePath))
        }
        return project.standardizedFileURL
    }

    /// Reproduces Claude Code's own naming: the absolute path with every `/`
    /// and `.` replaced by `-`.
    private func encodedName(for url: URL) -> String {
        url.path(percentEncoded: false)
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ".", with: "-")
    }

    private func makeIndexDirectory(for project: URL, in index: URL) throws {
        try FileManager.default.createDirectory(
            at: index.appending(path: encodedName(for: project), directoryHint: .isDirectory),
            withIntermediateDirectories: true)
    }

    private func write(_ contents: String, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(contents.utf8).write(to: url, options: .atomic)
    }
}
