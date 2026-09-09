import Foundation
import Testing

@testable import AgentToolingCore

private struct DiscoveredSkillInstallRunner: CommandRunning {
    func run(executable: String, arguments: [String], currentDirectory: URL?) async throws -> CommandOutput {
        CommandOutput(status: 0, standardOutput: arguments == ["--version"] ? "fixture 1.0" : "", standardError: "")
    }
}

@MainActor
struct DiscoveredSkillRepositoryInstallTests {
    @Test func successfulCrossClientInstallRetainsSourceTrackingAfterScanAndReload() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let model = try await fixture.model()
        #expect(await model.linkSkillRepository(skillID: "review", repositoryURL: "https://github.com/example/skills"))
        let original = try #require(model.skills.first { $0.id == "review" }?.repositoryBinding)

        model.planDiscoveredSkillInstall("review", client: .codex)
        let plan = try #require(model.pendingPlan)
        let staged = try #require(plan.steps.first { $0.kind == .copyDirectory }?.sourcePath)
        #expect(plan.summary.contains("same GitHub repository"))
        #expect(staged.hasPrefix(model.store.libraryURL.path + "/.discovered-install-"))
        #expect(!FileManager.default.fileExists(atPath: fixture.destination.path))
        #expect(model.skills.first { $0.id == "review" }?.repositoryBinding == original)
        #expect(await model.executePendingPlan(try OperationPlanApproval.review(plan)))
        let receipt = try #require(model.operationReceipts.first { $0.planID == plan.id })
        #expect(receipt.results.allSatisfy { $0.status == .succeeded }, "\(receipt.results)")
        try #require(FileManager.default.fileExists(atPath: fixture.destination.path))
        #expect(!FileManager.default.fileExists(atPath: staged))

        let installed = try #require(model.skills.first { $0.id == "review" })
        let binding = try #require(installed.repositoryBinding)
        #expect(!installed.owned)
        #expect(binding.repositoryURL == original.repositoryURL)
        #expect(binding.installedFingerprints[fixture.source.path] == original.installedFingerprints[fixture.source.path])
        #expect(binding.installedFingerprints[fixture.destination.path] == original.installedFingerprints[fixture.source.path])
        #expect(binding.installedFingerprints.count == 2)
        #expect(try DirectoryFingerprint.sha256(of: fixture.destination) == binding.installedFingerprints[fixture.destination.path])
        #expect(installed.clients.contains { $0.client == .codex && $0.reportsLocalPresence })
        let restored = try AppModel(store: model.store, runner: DiscoveredSkillInstallRunner(), homeURL: fixture.home)
        #expect(restored.skills.first { $0.id == "review" }?.repositoryBinding == binding)
    }

    @Test func discardingCrossClientInstallDoesNotAddUninstalledBaseline() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let model = try await fixture.model()
        #expect(await model.linkSkillRepository(skillID: "review", repositoryURL: "https://github.com/example/skills"))
        let binding = try #require(model.skills.first { $0.id == "review" }?.repositoryBinding)
        model.planDiscoveredSkillInstall("review", client: .codex)
        #expect(model.pendingPlan != nil)
        let staging = try #require(model.pendingDiscoveredSkillInstall?.stagingURL)
        model.discardPendingPlan()
        #expect(model.skills.first { $0.id == "review" }?.repositoryBinding == binding)
        #expect(!FileManager.default.fileExists(atPath: fixture.destination.path))
        #expect(!FileManager.default.fileExists(atPath: staging.path))
        #expect(model.pendingDiscoveredSkillInstall == nil)
    }

    @Test func changedLinkedSourceCannotBeCopiedWithItsOldBaseline() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let model = try await fixture.model()
        #expect(await model.linkSkillRepository(skillID: "review", repositoryURL: "https://github.com/example/skills"))
        let binding = try #require(model.skills.first { $0.id == "review" }?.repositoryBinding)
        try "Local edit".write(to: fixture.source.appending(path: "notes.md"), atomically: true, encoding: .utf8)
        model.planDiscoveredSkillInstall("review", client: .codex)
        #expect(model.pendingPlan == nil)
        #expect(model.lastError == SkillRepositoryError.changedInstallation.localizedDescription)
        #expect(model.skills.first { $0.id == "review" }?.repositoryBinding == binding)
        #expect(!FileManager.default.fileExists(atPath: fixture.destination.path))
    }

    @Test func failedCopyAndUnrelatedReceiptCannotExtendSourceBaseline() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let model = try await fixture.model()
        #expect(await model.linkSkillRepository(skillID: "review", repositoryURL: "https://github.com/example/skills"))
        let binding = try #require(model.skills.first { $0.id == "review" }?.repositoryBinding)
        model.planDiscoveredSkillInstall("review", client: .codex)
        let plan = try #require(model.pendingPlan)
        let copy = try #require(plan.steps.first { $0.kind == .copyDirectory })
        for (planID, status) in [(UUID(), OperationStepStatus.succeeded), (plan.id, .failed)] {
            let receipt = OperationReceipt(
                planID: planID, kind: plan.kind, title: plan.title, state: .attention, targetSurfaces: plan.targetSurfaces,
                results: [.init(stepID: copy.id, status: status, output: "Fixture", startedAt: .now, finishedAt: .now)],
                verificationSummary: "Fixture")
            model.completeDiscoveredSkillInstall(plan: plan, receipt: receipt)
            #expect(model.skills.first { $0.id == "review" }?.repositoryBinding == binding)
        }
    }

    private struct Fixture {
        let root: URL
        let home: URL
        let source: URL
        let destination: URL

        init() throws {
            root = FileManager.default.temporaryDirectory.appending(path: "discovered-skill-install-\(UUID().uuidString)")
                .resolvingSymlinksInPath()
            home = root.appending(path: "home")
            source = home.appending(path: ".claude/skills/review")
            destination = home.appending(path: ".agents/skills/review")
            try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
            try "---\nname: review\ndescription: Review a document\n---\n# Instructions\n"
                .write(to: source.appending(path: "SKILL.md"), atomically: true, encoding: .utf8)
        }

        func remove() { try? FileManager.default.removeItem(at: root) }

        @MainActor func model() async throws -> AppModel {
            let model = try AppModel(
                store: WorkspaceStore(rootURL: root.appending(path: "workspace")), runner: DiscoveredSkillInstallRunner(), homeURL: home)
            await model.runDoctor()
            return model
        }
    }
}
