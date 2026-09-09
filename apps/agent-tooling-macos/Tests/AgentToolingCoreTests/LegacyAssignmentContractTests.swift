import Foundation
import Testing

@testable import AgentToolingCore

/// Freeze the old resolver's observable behavior before the portable model's
/// migration preview compares it with explicit assignment contributions.
@MainActor
struct LegacyAssignmentContractTests {
    @Test func nearestExplicitBindingsReplaceAncestorsIncludingExplicitEmpty() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let inherited = [binding(.claude, enabled: true)]
        fixture.model.profiles = [
            profile("ancestor", bindings: inherited),
            profile("middle", parent: "ancestor"),
            profile("child", parent: "middle"),
        ]
        fixture.model.activeProfileID = "child"
        #expect(fixture.model.onboardingTargetBindings == inherited)

        fixture.model.profiles[2].targetBindings = []
        #expect(fixture.model.onboardingTargetBindings == [])

        let replacement = [binding(.codex, enabled: false)]
        fixture.model.profiles[2].targetBindings = replacement
        #expect(fixture.model.onboardingTargetBindings == replacement,
            "The child replaces the whole binding set, rather than merging clients")

        fixture.model.profiles[2].targetBindings = nil
        fixture.model.profiles[0].targetBindings = nil
        #expect(fixture.model.onboardingTargetBindings == nil,
            "An all-nil chain preserves the legacy installation fallback")
    }

    @Test func persistedEnabledStatesRemainDistinctAndOnlyTrueDeploys() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let saved = profile("setup", bindings: [
            binding(.claude, enabled: true),
            binding(.codex, enabled: false),
            binding(.gemini, enabled: nil),
        ], requiredSkills: ["sample"])
        let data = try AgentToolingCoding.encoder().encode(saved)
        let restored = try AgentToolingCoding.decoder().decode(ToolingProfile.self, from: data)
        #expect(restored.targetBindings == saved.targetBindings)
        fixture.model.profiles = [restored]
        fixture.model.activeProfileID = restored.id
        fixture.model.skills = [sampleSkill()]
        #expect(fixture.model.onboardingSyncTargets(for: sampleSkill()) == [.claude])

        for bindings: [OnboardingTargetBinding]? in [nil, []] {
            let original = profile("empty", bindings: bindings)
            let encoded = try AgentToolingCoding.encoder().encode(original)
            let decoded = try AgentToolingCoding.decoder().decode(ToolingProfile.self, from: encoded)
            #expect(decoded.targetBindings == bindings)
        }
    }

    @Test func fallbackPlansUnlistedOwnedSkillWithoutChangingItsUserScope() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let project = fixture.root.appending(path: "project")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        var draft = SkillDraft()
        draft.name = "sample"
        draft.purpose = "Review documents before publication."
        draft.triggers = ["Review this document"]
        draft.negativeTrigger = "Do not use for unrelated tasks."
        draft.selectedTargets = [.codex]
        draft.syncClients = false
        let created = try fixture.model.library.createSkill(from: draft)
        fixture.model.skills = [created.skill]
        fixture.model.profiles = [profile("project", scope: .project, projectRoot: project.path)]
        fixture.model.activeProfileID = "project"
        #expect(fixture.model.effectiveProfile(for: "project")?.requiredSkills.isEmpty == true)

        await fixture.model.runSync()

        let plan = try #require(fixture.model.pendingPlan)
        let copies = plan.steps.filter { $0.kind == .copyDirectory }
        let destination = fixture.home.appending(path: ".agents/skills/sample")
        #expect(copies.count == 1)
        let plannedDestination = try #require(copies.first?.destinationPath)
        #expect(URL(fileURLWithPath: plannedDestination).standardizedFileURL.path == destination.standardizedFileURL.path)
        #expect(plan.scope == .user)
        #expect(!FileManager.default.fileExists(atPath: destination.path),
            "The legacy preview must not perform an installation")
        #expect(!FileManager.default.fileExists(atPath: project.appending(path: ".agents/skills/sample").path))
    }

    @Test func explicitPluginChildRequirementNeverCreatesStandaloneAssignment() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        fixture.model.skills = [sampleSkill()]
        fixture.model.plugins = [Plugin(
            id: "bundle@catalog", name: "Bundle", summary: "A native package.", source: "catalog",
            scope: "This Mac", revision: "1", skills: ["sample"], profiles: [],
            clients: [.init(client: .claude, state: .healthy, detail: "Found", isInstalled: true)], installed: true
        )]
        fixture.model.profiles = [profile("setup", bindings: [binding(.claude, enabled: true)], requiredSkills: ["sample"])]
        fixture.model.activeProfileID = "setup"
        #expect(fixture.model.effectiveProfile(for: "setup")?.requiredSkills == ["sample"])
        #expect(fixture.model.onboardingSyncTargets(for: sampleSkill()) == [],
            "Native plugin membership overrides an explicit child binding")
    }

    private func binding(_ client: ClientKind, enabled: Bool?) -> OnboardingTargetBinding {
        .init(item: .init(kind: .skill, identifier: "sample"), client: client, enabled: enabled)
    }

    private func profile(
        _ id: String, parent: String? = nil, scope: ToolingScope = .user, projectRoot: String? = nil,
        bindings: [OnboardingTargetBinding]? = nil, requiredSkills: [String] = []
    ) -> ToolingProfile {
        .init(id: id, name: id, summary: "Legacy fixture", inheritedFrom: parent, scope: scope,
            projectRoot: projectRoot, checks: [], enabledPlugins: [], requiredMCPs: [],
            requiredSkills: requiredSkills, targetBindings: bindings)
    }

    private func sampleSkill() -> Skill {
        .init(id: "sample", name: "sample", displayName: "Sample", summary: "A useful skill.",
            bundle: "Existing", scope: "This Mac", owned: false, triggers: [], negativeTrigger: "",
            files: ["SKILL.md"], clients: [.init(client: .claude, state: .healthy, detail: "Found", isInstalled: true)],
            validationCount: 0)
    }

    @MainActor private struct Fixture {
        let root: URL
        let home: URL
        let model: AppModel

        init() throws {
            root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
                .appending(path: "legacy-assignment-\(UUID().uuidString)")
            home = root.appending(path: "home")
            try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
            let store = try WorkspaceStore(rootURL: root.appending(path: "store"))
            model = try AppModel(store: store, runner: NoCommands(), homeURL: home)
        }

        func remove() { try? FileManager.default.removeItem(at: root) }
    }

    private struct NoCommands: CommandRunning {
        func run(executable: String, arguments: [String], currentDirectory: URL?) async throws -> CommandOutput {
            Issue.record("Assignment previews must not launch commands")
            return CommandOutput(status: 1, standardOutput: "", standardError: "Unexpected command")
        }
    }
}
