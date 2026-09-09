import Foundation
import Testing

@testable import AgentToolingCore

private actor RepositoryFixtureRunner: CommandRunning {
    let repository: URL
    private(set) var gitCalls: [[String]] = []

    init(repository: URL) { self.repository = repository }

    func run(executable: String, arguments: [String], currentDirectory: URL?) async throws -> CommandOutput {
        guard executable == "/usr/bin/env" else {
            return CommandOutput(status: 0, standardOutput: arguments == ["--version"] ? "fixture 1.0" : "", standardError: "")
        }
        gitCalls.append(arguments)
        // Transport injection belongs only to this local fixture. Production accepts HTTPS GitHub only.
        let fixtureArguments = arguments.map { argument in
            switch argument {
            case "https://github.com/example/skills": repository.path
            case "GIT_ALLOW_PROTOCOL=https": "GIT_ALLOW_PROTOCOL=file"
            case "protocol.file.allow=never": "protocol.file.allow=always"
            default: argument
            }
        }
        return try await ProcessCommandRunner().run(executable: executable, arguments: fixtureArguments, currentDirectory: currentDirectory)
    }
}

@MainActor
struct SkillRepositoryTests {
    @Test func linkPersistsTrackingWithoutRewritingInstalledCopiesAndSurvivesRediscovery() async throws {
        let fixture = try await Fixture()
        defer { fixture.remove() }
        let (model, _) = try await fixture.model()
        for index in model.targetObservations.indices {
            if var metadata = model.targetObservations[index].skillMetadata["review"] {
                metadata.path += "/"
                model.targetObservations[index].skillMetadata["review"] = metadata
            }
        }
        let before = try Data(contentsOf: fixture.installed.appending(path: "SKILL.md"))
        #expect(
            await model.linkSkillRepository(
                skillID: "review", repositoryURL: "https://github.com/example/skills", subdirectory: "skills/review"))
        let binding = try #require(model.skills.first { $0.id == "review" }?.repositoryBinding)
        #expect(binding.installedRevision == nil)
        #expect(binding.installedFingerprints.count == 1)
        #expect(model.skills.first { $0.id == "review" }?.owned == false)
        #expect(try Data(contentsOf: fixture.installed.appending(path: "SKILL.md")) == before)
        #expect(model.pendingPlan == nil)
        await model.runDoctor()
        #expect(model.skills.first { $0.id == "review" }?.repositoryBinding == binding)
        let restored = try AppModel(
            store: model.store, runner: RepositoryFixtureRunner(repository: fixture.repository), homeURL: fixture.home)
        #expect(restored.skills.first { $0.id == "review" }?.repositoryBinding == binding)
        #expect(restored.unlinkSkillRepository(skillID: "review"))
        #expect(try Data(contentsOf: fixture.installed.appending(path: "SKILL.md")) == before)
    }

    @Test func checkThenReviewUpdatesOriginalPathAndPreservesDisabledSettings() async throws {
        let fixture = try await Fixture()
        defer { fixture.remove() }
        let codexSkill = fixture.home.appending(path: ".agents/skills/review")
        try FileManager.default.createDirectory(at: codexSkill.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: fixture.installed, to: codexSkill)
        let codexSettings = fixture.home.appending(path: ".codex/config.toml")
        try FileManager.default.createDirectory(at: codexSettings.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes]
        let quotedSkillPath = String(decoding: try encoder.encode(codexSkill.appending(path: "SKILL.md").path), as: UTF8.self)
        try "[[skills.config]]\npath = \(quotedSkillPath)\nenabled = false\n".write(to: codexSettings, atomically: true, encoding: .utf8)
        let beforeCodexSettings = try Data(contentsOf: codexSettings)
        let (model, fixtureRunner) = try await fixture.model()
        #expect(
            await model.linkSkillRepository(
                skillID: "review", repositoryURL: "https://github.com/example/skills", subdirectory: "skills/review"))
        #expect(await model.checkSkillRepositoryUpdate(skillID: "review"))
        #expect(model.skillRepositoryUpdateAvailability("review").isUpToDate)
        let oldRevision = try #require(model.skills.first { $0.id == "review" }?.repositoryBinding?.installedRevision)
        try fixture.write("---\nname: review\ndescription: Updated review\n---\n# New instructions\n", path: "skills/review/SKILL.md")
        try await fixture.commit()
        #expect(await model.checkSkillRepositoryUpdate(skillID: "review"))
        #expect(model.skillRepositoryUpdateAvailability("review").hasUpdate)
        #expect(await model.planSkillRepositoryUpdate(skillID: "review"))
        let plan = try #require(model.pendingPlan)
        let copy = try #require(plan.steps.first { $0.kind == .copyDirectory })
        #expect(
            Set(plan.steps.filter { $0.kind == .copyDirectory }.compactMap(\.destinationPath)) == [fixture.installed.path, codexSkill.path])
        #expect(copy.destinationFingerprint != nil)
        #expect(copy.sourcePath?.contains(".repository-update-") == true)
        let beforeSettings = try Data(contentsOf: fixture.settings)
        #expect(model.isSkillEnabled("review", client: .claude) == false)
        #expect(model.isSkillEnabled("review", client: .codex) == false)
        #expect(await model.executePendingPlan(try OperationPlanApproval.review(plan)))
        #expect(try Data(contentsOf: fixture.settings) == beforeSettings)
        #expect(model.isSkillEnabled("review", client: .claude) == false)
        #expect(model.isSkillEnabled("review", client: .codex) == false)
        #expect(try Data(contentsOf: codexSettings) == beforeCodexSettings)
        #expect(try String(contentsOf: codexSkill.appending(path: "SKILL.md"), encoding: .utf8).contains("Updated review"))
        #expect(try String(contentsOf: fixture.installed.appending(path: "SKILL.md"), encoding: .utf8).contains("Updated review"))
        #expect(model.skills.first { $0.id == "review" }?.owned == false)
        #expect(model.skills.first { $0.id == "review" }?.repositoryBinding?.installedRevision != oldRevision)
        #expect(model.operationReceipts.first?.results.filter { $0.status == .failed }.isEmpty == true)
        let calls = await fixtureRunner.gitCalls
        #expect(
            calls.allSatisfy { $0.contains("-i") && $0.contains("core.hooksPath=/dev/null") && $0.contains("GIT_CONFIG_GLOBAL=/dev/null") })
        #expect(!calls.contains { $0.contains("pull") || $0.contains("submodule") })
    }

    @Test func refusesLocalEditsAndSourceNameMismatchBeforeCreatingPlan() async throws {
        let fixture = try await Fixture()
        defer { fixture.remove() }
        let (model, _) = try await fixture.model()
        #expect(
            await model.linkSkillRepository(
                skillID: "review", repositoryURL: "https://github.com/example/skills", subdirectory: "skills/review"))
        try "Local changes".write(to: fixture.installed.appending(path: "notes.md"), atomically: true, encoding: .utf8)
        #expect(await model.planSkillRepositoryUpdate(skillID: "review") == false)
        #expect(model.lastError?.contains("changed") == true)
        #expect(model.pendingPlan == nil)
        try FileManager.default.removeItem(at: fixture.installed.appending(path: "notes.md"))
        try fixture.write("---\nname: different\ndescription: Wrong skill\n---\n", path: "skills/review/SKILL.md")
        try await fixture.commit()
        #expect(await model.planSkillRepositoryUpdate(skillID: "review") == false)
        #expect(model.lastError == SkillRepositoryError.nameMismatch.localizedDescription)
    }

    @Test func sharedPhysicalInstallationCopiesOnceAndNamesEveryAffectedClient() async throws {
        let fixture = try await Fixture()
        defer { fixture.remove() }
        let (model, _) = try await fixture.model()
        let metadata = ObservedSkillMetadata(path: fixture.installed.path, source: "Standalone")
        model.targetObservations = [
            TargetObservation(
                surface: .claudeCode, installed: true, commandAvailable: true, discoveredSkills: ["review"],
                skillMetadata: ["review": metadata], capabilities: ClaudeCodeAdapter().capabilities),
            TargetObservation(
                surface: .codexCLI, installed: true, commandAvailable: true, discoveredSkills: ["review"],
                skillMetadata: ["review": metadata], capabilities: CodexAdapter().capabilities),
        ]
        model.skills = InventoryCompiler.compile(observations: model.targetObservations, homeURL: fixture.home).skills
        #expect(
            await model.linkSkillRepository(
                skillID: "review", repositoryURL: "https://github.com/example/skills", subdirectory: "skills/review"))
        #expect(await model.planSkillRepositoryUpdate(skillID: "review"))
        let plan = try #require(model.pendingPlan)
        let copies = plan.steps.filter { $0.kind == .copyDirectory }
        #expect(copies.count == 1)
        #expect(Set(plan.targetSurfaces) == [.claudeCode, .codexCLI])
        #expect(copies.first?.title.contains(ClientKind.claude.rawValue) == true)
        #expect(copies.first?.title.contains(ClientKind.codex.rawValue) == true)
        model.discardPendingPlan()
    }

    @Test func isolatedFetchPreservesBinaryAssetsAndIgnoresCheckoutConversions() async throws {
        let fixture = try await Fixture()
        defer { fixture.remove() }
        try fixture.write("*.md text eol=crlf\n*.bin filter=unsafe\n", path: "skills/review/.gitattributes")
        let binary = Data([0, 255, 128, 10, 13, 65])
        try binary.write(to: fixture.repository.appending(path: "skills/review/asset.bin"))
        try await fixture.commit()
        let service = SkillRepositoryService(
            cacheURL: fixture.root.appending(path: "cache"), runner: RepositoryFixtureRunner(repository: fixture.repository))
        let binding = try SkillRepositoryBinding(repositoryURL: "https://github.com/example/skills", subdirectory: "skills/review")
        let checkout = try await service.fetch(binding)
        defer { service.discard(checkout) }
        #expect(try Data(contentsOf: checkout.skillURL.appending(path: "asset.bin")) == binary)
        let markdown = try Data(contentsOf: checkout.skillURL.appending(path: "SKILL.md"))
        #expect(!markdown.contains(13))
        #expect(!FileManager.default.fileExists(atPath: checkout.skillURL.appending(path: ".git").path))
    }

    @Test func missingInstallationKeepsSourceBindingAndOriginalBaseline() async throws {
        let fixture = try await Fixture()
        defer { fixture.remove() }
        let (model, _) = try await fixture.model()
        #expect(
            await model.linkSkillRepository(
                skillID: "review", repositoryURL: "https://github.com/example/skills", subdirectory: "skills/review"))
        #expect(await model.checkSkillRepositoryUpdate(skillID: "review"))
        let binding = try #require(model.skills.first { $0.id == "review" }?.repositoryBinding)
        #expect(model.skillRepositoryUpdateAvailability("review").isUpToDate)
        try FileManager.default.removeItem(at: fixture.installed)
        await model.runDoctor()
        let missing = try #require(model.skills.first { $0.id == "review" })
        #expect(missing.repositoryBinding == binding)
        #expect(missing.clients.allSatisfy { !$0.reportsLocalPresence })
        if case .sourceMissing = model.skillRepositoryUpdateAvailability("review") {
        } else {
            Issue.record("A missing installation used a cached up-to-date verdict")
        }
        try FileManager.default.copyItem(at: fixture.repository.appending(path: "skills/review"), to: fixture.installed)
        try "New local change".write(to: fixture.installed.appending(path: "notes.md"), atomically: true, encoding: .utf8)
        await model.runDoctor()
        #expect(model.skills.first { $0.id == "review" }?.repositoryBinding == binding)
        #expect(await model.checkSkillRepositoryUpdate(skillID: "review") == false)
        #expect(model.lastError == SkillRepositoryError.changedInstallation.localizedDescription)
    }

    @Test func rejectsUnsafeSourcesAndTrees() throws {
        for url in [
            "git@github.com:owner/repo", "https://github.com/owner/repo/tree/main", "https://user@github.com/owner/repo",
            "https://github.com/owner/repo?token=value", "https://example.com/owner/repo", "file:///tmp/repo",
        ] {
            #expect(throws: SkillRepositoryError.invalidRepository) { try SkillRepositoryBinding(repositoryURL: url) }
        }
        for path in ["../review", "/review", ".git", "skills/../review", "skills//review"] {
            #expect(throws: SkillRepositoryError.invalidPath) {
                try SkillRepositoryBinding(repositoryURL: "https://github.com/example/skills", subdirectory: path)
            }
        }
        for listing in [
            "120000 blob abc 3\tskills/review/link\0", "160000 commit abc -\tskills/review/submodule\0",
            "100644 blob abc 1\tskills/review/../escape\0", "100644 blob abc 1\tskills/review/A\0" + "100644 blob abc 1\tskills/review/a\0",
        ] {
            #expect(throws: SkillRepositoryError.unsafeTree) {
                try SkillRepositoryService.validateListing(listing, subdirectory: "skills/review")
            }
        }
    }

    private struct Fixture {
        let root: URL
        let repository: URL
        let home: URL
        let installed: URL
        var settings: URL { home.appending(path: ".claude/settings.json") }

        init() async throws {
            root = FileManager.default.temporaryDirectory.appending(path: "skill-repository-test-\(UUID().uuidString)")
                .resolvingSymlinksInPath()
            repository = root.appending(path: "upstream")
            home = root.appending(path: "home")
            installed = home.appending(path: ".claude/skills/review")
            try FileManager.default.createDirectory(at: repository, withIntermediateDirectories: true)
            try await git(["init", "--initial-branch=main"])
            try write("---\nname: review\ndescription: Review a document\n---\n# Instructions\n", path: "skills/review/SKILL.md")
            try await commit()
            try FileManager.default.createDirectory(at: installed.deletingLastPathComponent(), withIntermediateDirectories: true)
            try FileManager.default.copyItem(at: repository.appending(path: "skills/review"), to: installed)
            try "{\"skillOverrides\":{\"review\":\"off\"}}".write(to: settings, atomically: true, encoding: .utf8)
        }

        func write(_ text: String, path: String) throws {
            let file = repository.appending(path: path)
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try text.write(to: file, atomically: true, encoding: .utf8)
        }

        func commit() async throws {
            try await git(["add", "."])
            try await git(["commit", "-m", "Fixture revision"])
        }
        func remove() { try? FileManager.default.removeItem(at: root) }
        func git(_ arguments: [String]) async throws {
            let result = try await ProcessCommandRunner().run(
                executable: "/usr/bin/git",
                arguments: [
                    "-c", "core.hooksPath=/dev/null", "-c", "commit.gpgsign=false", "-c", "user.name=Fixture", "-c",
                    "user.email=fixture@example.com",
                ] + arguments, currentDirectory: repository)
            #expect(result.status == 0)
        }
        @MainActor func model() async throws -> (AppModel, RepositoryFixtureRunner) {
            let runner = RepositoryFixtureRunner(repository: repository)
            let model = try AppModel(store: WorkspaceStore(rootURL: root.appending(path: "workspace")), runner: runner, homeURL: home)
            await model.runDoctor()
            return (model, runner)
        }
    }
}
