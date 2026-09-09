import Foundation
import Testing

@testable import AgentToolingCore

@MainActor
struct ClientSelectionTests {
    @Test func oldPreferencesDefaultToAllAndEmptySelectionSurvivesRestart() throws {
        let old = try JSONDecoder().decode(WorkspacePreferences.self, from: Data("{}".utf8))
        #expect(old.enabledClients == Set(ClientKind.allCases))
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let model = try fixture.model()
        for client in ClientKind.allCases { #expect(model.setClientEnabled(client, enabled: false)) }
        let restarted = try fixture.model()
        #expect(restarted.enabledClients.isEmpty)
        #expect(restarted.availableTargetSurfaces.isEmpty)
        #expect(restarted.visibleAccountSurfaces.isEmpty)
        #expect(restarted.setClientEnabled(.gemini, enabled: true))
        #expect(try fixture.model().enabledClients == [.gemini])
    }

    @Test func hiddenInventoryIsRetainedAndReappears() throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let model = try fixture.model()
        model.skills = [
            skill("gemini-only", clients: [.gemini]), skill("shared", clients: [.gemini, .codex]), skill("local", clients: [], owned: true),
        ]
        #expect(model.setClientEnabled(.gemini, enabled: false))
        #expect(Set(model.visibleSkills.map(\.id)) == ["shared", "local"])
        #expect(model.visibleSkills.flatMap(\.clients).allSatisfy { $0.client != .gemini })
        #expect(model.skills.count == 3)
        #expect(!model.visibleAccountSurfaces.contains { $0.surface.client == .gemini })
        #expect(!model.visibleSources.contains { $0.kind == .geminiExtensionGallery })
        let restarted = try fixture.model()
        #expect(restarted.skills.count == 3)
        #expect(restarted.setClientEnabled(.gemini, enabled: true))
        #expect(restarted.visibleSkills.count == 3)
    }

    @Test func missingLinkedSkillStaysVisibleOnlyForItsRecordedEnabledClientAcrossRestart() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let source = fixture.home.appending(path: ".claude/skills/linked-review")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try "---\nname: linked-review\ndescription: Review local changes.\n---\nReview the change.\n"
            .write(to: source.appending(path: "SKILL.md"), atomically: true, encoding: .utf8)
        let model = try fixture.model()
        #expect(await model.runDoctor())
        let index = try #require(model.skills.firstIndex { $0.id == "linked-review" })
        let binding = try SkillRepositoryBinding(
            repositoryURL: "https://github.com/example/skills",
            installedFingerprints: [source.path: try DirectoryFingerprint.sha256(of: source)])
        model.skills[index].repositoryBinding = binding
        try FileManager.default.removeItem(at: source)
        #expect(await model.runDoctor())
        let missing = try #require(model.visibleSkills.first { $0.id == "linked-review" })
        #expect(missing.repositoryBinding == binding)
        #expect(!missing.owned && missing.clients.allSatisfy { !$0.reportsLocalPresence })

        let restarted = try fixture.model()
        #expect(restarted.visibleSkills.first { $0.id == "linked-review" }?.repositoryBinding == binding)
        #expect(restarted.setClientEnabled(.claude, enabled: false))
        #expect(restarted.enabledClients.contains(.codex), "An unrelated enabled client must not reveal this missing skill")
        #expect(!restarted.visibleSkills.contains { $0.id == "linked-review" })
        #expect(await restarted.runDoctor())
        let hidden = try fixture.model()
        #expect(hidden.skills.first { $0.id == "linked-review" }?.repositoryBinding == binding)
        #expect(!hidden.visibleSkills.contains { $0.id == "linked-review" })
        #expect(hidden.setClientEnabled(.claude, enabled: true))
        #expect(hidden.visibleSkills.contains { $0.id == "linked-review" })
        #expect(!FileManager.default.fileExists(atPath: source.path), "Visibility never restores or installs the source")
    }

    @Test func disabledClientCannotBeTargetedAndSelectionCannotChangeDuringReview() throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let model = try fixture.model()
        #expect(model.setClientEnabled(.gemini, enabled: false))
        model.planMCPRemoval(serverID: "missing", client: .gemini)
        #expect(model.pendingPlan == nil)
        #expect(model.lastError?.contains("unchecked") == true)
        let hiddenCommand = OperationPlan(
            kind: .configureMCP, title: "Undeclared target", summary: "",
            steps: [
                OperationStep(kind: .command, title: "Run", detail: "", executable: "gemini", arguments: ["mcp", "list"])
            ])
        #expect(!model.reviewComposedPlan(hiddenCommand))
        let hiddenFile = OperationPlan(
            kind: .installSkill, title: "Hidden destination", summary: "",
            steps: [
                OperationStep(
                    kind: .writeFile, title: "Write", detail: "",
                    destinationPath: fixture.home.appending(path: ".gemini/skills/test/SKILL.md").path, contents: "test")
            ])
        #expect(!model.reviewComposedPlan(hiddenFile))
        let review = OperationPlan(
            kind: .scan, title: "Review", summary: "", steps: [OperationStep(kind: .manual, title: "Inspect", detail: "")])
        #expect(model.reviewComposedPlan(review))
        #expect(!model.setClientEnabled(.codex, enabled: false))
        #expect(model.enabledClients.contains(.codex))
    }

    @Test func scannersAndMarketplaceNeverInvokeUncheckedClients() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let runner = RecordingRunner()
        let model = try fixture.model(runner: runner)
        #expect(model.setClientEnabled(.gemini, enabled: false))
        #expect(model.setClientEnabled(.claude, enabled: false))
        _ = await model.runDoctor()
        await model.refreshMarketplace()
        let commands = await runner.commands
        #expect(!commands.isEmpty)
        #expect(commands.allSatisfy { $0 == "codex" })
        #expect(model.visibleTargetObservations.allSatisfy { $0.surface.client == .codex })
        #expect(model.setClientEnabled(.codex, enabled: false))
        let before = commands.count
        _ = await model.runDoctor()
        await model.refreshMarketplace()
        #expect(await runner.commands.count == before)
    }

    @Test func projectInspectionExcludesUncheckedConfiguration() throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let project = fixture.root.appending(path: "project")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        for file in ["GEMINI.md", "CLAUDE.md", "AGENTS.md"] { try Data("# Instructions".utf8).write(to: project.appending(path: file)) }
        let result = try #require(ProjectDiscovery.inspect(root: project, origins: [.pinned], clients: [.codex]))
        #expect(result.files.map(\.descriptor.relativePath) == ["AGENTS.md"])
    }

    private func skill(_ id: String, clients: [ClientKind], owned: Bool = false) -> Skill {
        Skill(
            id: id, name: id, displayName: id, summary: "", bundle: id, scope: "This Mac", owned: owned,
            triggers: [], negativeTrigger: "", files: [],
            clients: clients.map { ClientState(client: $0, state: .healthy, detail: "Installed", isInstalled: true) }, validationCount: 0)
    }
    private struct Fixture {
        let root = FileManager.default.temporaryDirectory.appending(path: "client-selection-\(UUID())")
        var home: URL { root.appending(path: "home") }
        init() throws { try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true) }
        func cleanUp() { try? FileManager.default.removeItem(at: root) }
        @MainActor func model(runner: any CommandRunning = RecordingRunner()) throws -> AppModel {
            try AppModel(store: WorkspaceStore(rootURL: root.appending(path: "store")), runner: runner, homeURL: home)
        }
    }
    private actor RecordingRunner: CommandRunning {
        var commands: [String] = []
        func run(executable: String, arguments: [String], currentDirectory: URL?) async throws -> CommandOutput {
            commands.append(executable)
            return CommandOutput(status: 127, standardOutput: "", standardError: "command not found")
        }
    }
}
