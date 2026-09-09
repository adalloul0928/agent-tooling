import Foundation
import Testing

@testable import AgentToolingCore

@MainActor
struct LegacyConfigurationResolutionTests {
    @Test func resolvesInheritanceCollectionsAndChecksUsingLegacyOrdering() throws {
        let root = profile(
            "root", checks: [check("root"), check("same")], plugins: ["root-plugin", "shared-plugin"],
            mcps: ["root-mcp"], skills: ["root-skill"], collections: ["first"]
        )
        let child = profile(
            "child", parent: "root", checks: [check("same"), check("child")], plugins: ["child-plugin", "shared-plugin"],
            mcps: ["child-mcp"], skills: ["child-skill"], collections: ["second", "first"]
        )
        let snapshot = WorkspaceSnapshot(
            profiles: [root, child],
            collections: [
                collection("first", [.init(kind: .skill, identifier: "shelf-skill"), .init(kind: .plugin, identifier: "shared-plugin")]),
                collection("second", [.init(kind: .mcpServer, identifier: "shelf-mcp"), .init(kind: .skill, identifier: "shelf-skill")]),
            ]
        )

        let result = try LegacyConfigurationResolver.resolve(snapshot, configuration: .personal("child"))

        #expect(result.contributingConfigurationIDs == ["root", "child"])
        #expect(result.enabledPlugins == ["child-plugin", "root-plugin", "shared-plugin"])
        #expect(result.requiredMCPs == ["child-mcp", "root-mcp", "shelf-mcp"])
        #expect(result.requiredSkills == ["child-skill", "root-skill", "shelf-skill"])
        #expect(result.includedCollections == ["first", "second"])
        #expect(result.checks.map(\.id) == ["root", "same", "child"])
    }

    @Test func retainsDuplicateChecksWrittenInOneLegacyConfigurationBatch() throws {
        let result = try LegacyConfigurationResolver.resolve(
            WorkspaceSnapshot(profiles: [profile("one", checks: [check("same"), check("same")])]), configurationID: "one"
        )
        #expect(result.checks.map(\.id) == ["same", "same"])
    }

    @Test func preservesNilEmptyAndOptionalBindingFlagsAtNearestExplicitLevel() throws {
        let inherited = [binding(.claude, enabled: true)]
        var child = profile("child", parent: "root")
        let snapshot = WorkspaceSnapshot(profiles: [profile("root", bindings: inherited), child])
        #expect(try LegacyConfigurationResolver.resolve(snapshot, configurationID: "child").targetBindings == inherited)

        child.targetBindings = []
        #expect(try LegacyConfigurationResolver.resolve(
            WorkspaceSnapshot(profiles: [profile("root", bindings: inherited), child]), configurationID: "child"
        ).targetBindings == [])

        child.targetBindings = [binding(.claude, enabled: nil), binding(.codex, enabled: false), binding(.gemini, enabled: true)]
        let resolved = try LegacyConfigurationResolver.resolve(
            WorkspaceSnapshot(profiles: [profile("root", bindings: inherited), child]), configurationID: "child"
        )
        #expect(resolved.targetBindings?.map(\.enabled) == [nil, false, true])
        #expect(try LegacyConfigurationResolver.resolve(WorkspaceSnapshot(profiles: [profile("only")]), configurationID: "only").targetBindings == nil)
    }

    @Test func policyProfilesRequireQualifiedIdentityAndRejectConflictingRules() throws {
        let personal = profile("shared", plugins: ["personal-plugin"])
        let policyProfile = profile("shared", plugins: ["policy-plugin"])
        let policy = ManagedPolicy(
            id: "company", name: "Company", sourcePath: "/policy.json", requiredPluginIDs: [], requiredMCPIDs: [],
            blockedPluginIDs: [], profiles: [policyProfile]
        )
        let snapshot = WorkspaceSnapshot(profiles: [personal], managedPolicies: [policy])

        #expect(throws: LegacyConfigurationResolutionError.ambiguousConfigurationID("shared", [.personal("shared"), .policy(policyID: "company", profileID: "shared")])) {
            _ = try LegacyConfigurationResolver.resolve(snapshot, configurationID: "shared")
        }
        #expect(try LegacyConfigurationResolver.resolve(snapshot, configuration: .personal("shared")).enabledPlugins == ["personal-plugin"])
        #expect(try LegacyConfigurationResolver.resolve(
            snapshot, configuration: .policy(policyID: "company", profileID: "shared")
        ).enabledPlugins == ["policy-plugin"])

        let conflicting = ManagedPolicy(
            id: "conflict", name: "Conflict", sourcePath: "/conflict.json", requiredPluginIDs: ["plugin"],
            blockedPluginIDs: ["plugin"], profiles: [profile("managed")]
        )
        #expect(throws: LegacyConfigurationResolutionError.conflictingPolicyPluginRule(policyID: "conflict", pluginID: "plugin")) {
            _ = try LegacyConfigurationResolver.resolve(
                WorkspaceSnapshot(managedPolicies: [conflicting]), configuration: .policy(policyID: "conflict", profileID: "managed")
            )
        }
    }

    @Test func reportsMissingParentsCyclesAndDuplicateExplicitIdentities() throws {
        #expect(throws: LegacyConfigurationResolutionError.missingParent(child: .personal("child"), parentID: "missing")) {
            _ = try LegacyConfigurationResolver.resolve(
                WorkspaceSnapshot(profiles: [profile("child", parent: "missing")]), configurationID: "child"
            )
        }
        #expect(throws: LegacyConfigurationResolutionError.inheritanceCycle([.personal("one"), .personal("two"), .personal("one")])) {
            _ = try LegacyConfigurationResolver.resolve(
                WorkspaceSnapshot(profiles: [profile("one", parent: "two"), profile("two", parent: "one")]), configurationID: "one"
            )
        }
        #expect(throws: LegacyConfigurationResolutionError.ambiguousConfiguration(.personal("duplicate"))) {
            _ = try LegacyConfigurationResolver.resolve(
                WorkspaceSnapshot(profiles: [profile("duplicate"), profile("duplicate")]), configuration: .personal("duplicate")
            )
        }
    }

    @Test func matchesLivePersonalResolutionForVisibilityAndBindings() throws {
        let bindings = [binding(.codex, enabled: true), binding(.claude, enabled: nil)]
        let parent = profile(
            "parent", checks: [check("parent")], plugins: ["unknown-plugin", "hidden-plugin"],
            mcps: ["unknown-mcp", "hidden-mcp"], skills: ["unknown-skill", "hidden-skill", "owned-skill"],
            collections: ["shelf"], bindings: bindings
        )
        let child = profile(
            "child", parent: "parent", checks: [check("parent"), check("child")], plugins: ["native-plugin"],
            mcps: ["observed-mcp"], skills: ["unknown-skill"]
        )
        let snapshot = WorkspaceSnapshot(
            skills: [
                skill("hidden-skill", owned: false, clients: [.init(client: .claude, state: .healthy, detail: "Found")]),
                skill("owned-skill", owned: true, clients: []),
            ],
            mcpServers: [
                mcp("hidden-mcp", clients: [.init(client: .claude, state: .healthy, detail: "Found")]),
                mcp("observed-mcp", clients: [.init(client: .codex, state: .healthy, detail: "Found")]),
            ],
            plugins: [
                plugin("hidden-plugin", clients: [.init(client: .claude, state: .healthy, detail: "Found")]),
                plugin("native-plugin", clients: [.init(client: .codex, state: .healthy, detail: "Found")]),
            ],
            profiles: [parent, child],
            activeProfileID: "child",
            preferences: .init(enabledClients: [.codex]),
            collections: [collection("shelf", [
                .init(kind: .skill, identifier: "owned-skill"),
                .init(kind: .plugin, identifier: "native-plugin"),
                .init(kind: .mcpServer, identifier: "observed-mcp"),
            ])]
        )
        let fixture = try Fixture(snapshot: snapshot)
        defer { fixture.remove() }

        let actual = try #require(fixture.model.effectiveProfile(for: "child"))
        let oracle = try LegacyConfigurationResolver.resolve(snapshot, configuration: .personal("child"))

        #expect(oracle.requiredSkills == actual.requiredSkills)
        #expect(oracle.enabledPlugins == actual.enabledPlugins)
        #expect(oracle.requiredMCPs == actual.requiredMCPs)
        #expect(oracle.includedCollections == actual.includedCollections)
        #expect(oracle.checks == actual.checks)
        #expect(oracle.targetBindings == fixture.model.onboardingTargetBindings)
        #expect(oracle.requiredSkills == ["owned-skill", "unknown-skill"])
        #expect(oracle.enabledPlugins == ["native-plugin", "unknown-plugin"])
        #expect(oracle.requiredMCPs == ["observed-mcp", "unknown-mcp"])
    }

    @Test func matchesRepositoryLinkedSkillVisibilityWithoutALocalClientRow() throws {
        let fingerprint = String(repeating: "a", count: 64)
        let linked = try SkillRepositoryBinding(
            repositoryURL: "https://github.com/example/linked-skill",
            installedFingerprints: ["/private/tmp/home/.agents/skills/linked": fingerprint]
        )
        for (enabledClients, expectedVisible) in [
            (Set([ClientKind.codex]), true),
            (Set([ClientKind.claude]), false),
        ] {
            var repositorySkill = skill("linked", owned: false, clients: [])
            repositorySkill.repositoryBinding = linked
            let snapshot = WorkspaceSnapshot(
                skills: [repositorySkill],
                profiles: [profile("configuration", skills: ["linked"])],
                activeProfileID: "configuration",
                preferences: .init(enabledClients: enabledClients)
            )
            let fixture = try Fixture(snapshot: snapshot)
            defer { fixture.remove() }

            let actual = try #require(fixture.model.effectiveProfile(for: "configuration"))
            let oracle = try LegacyConfigurationResolver.resolve(snapshot, configurationID: "configuration")
            #expect(oracle.requiredSkills == actual.requiredSkills)
            #expect(oracle.requiredSkills.contains("linked") == expectedVisible)
            #expect(fixture.model.visibleSkills.contains { $0.id == "linked" } == expectedVisible)
        }
    }

    private func profile(
        _ id: String,
        parent: String? = nil,
        checks: [ProfileCheck] = [],
        plugins: [String] = [],
        mcps: [String] = [],
        skills: [String] = [],
        collections: [String] = [],
        bindings: [OnboardingTargetBinding]? = nil
    ) -> ToolingProfile {
        .init(id: id, name: id, summary: "", inheritedFrom: parent, checks: checks, enabledPlugins: plugins,
            requiredMCPs: mcps, requiredSkills: skills, includedCollections: collections, targetBindings: bindings)
    }

    private func check(_ id: String) -> ProfileCheck {
        .init(id: id, name: id, detail: "", state: .healthy)
    }

    private func collection(_ id: String, _ items: [ToolingItemReference]) -> ToolingCollection {
        .init(id: id, name: id, items: items, createdAt: Date(timeIntervalSince1970: 0))
    }

    private func binding(_ client: ClientKind, enabled: Bool?) -> OnboardingTargetBinding {
        .init(item: .init(kind: .skill, identifier: "skill"), client: client, enabled: enabled)
    }

    private func skill(_ id: String, owned: Bool, clients: [ClientState]) -> Skill {
        .init(id: id, name: id, displayName: id, summary: "", bundle: "standalone", scope: "This Mac", owned: owned, triggers: [],
            negativeTrigger: "", files: [], clients: clients, validationCount: 0)
    }

    private func mcp(_ id: String, clients: [ClientState]) -> MCPServer {
        .init(id: id, name: id, summary: "", endpoint: "node", transport: .stdio, authentication: "", scope: "This Mac", clients: clients)
    }

    private func plugin(_ id: String, clients: [ClientState]) -> Plugin {
        .init(id: id, name: id, summary: "", source: "", scope: "", revision: "", skills: [], profiles: [], clients: clients, installed: true)
    }

    @MainActor private struct Fixture {
        let root: URL
        let model: AppModel

        init(snapshot: WorkspaceSnapshot) throws {
            root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
                .appending(path: "legacy-resolution-\(UUID().uuidString)")
            let store = try WorkspaceStore(rootURL: root.appending(path: "store"))
            try store.saveWorkspaceSnapshot(snapshot)
            model = try AppModel(store: store, runner: NoCommands(), homeURL: root.appending(path: "home"))
        }

        func remove() { try? FileManager.default.removeItem(at: root) }
    }

    private struct NoCommands: CommandRunning {
        func run(executable: String, arguments: [String], currentDirectory: URL?) async throws -> CommandOutput {
            Issue.record("Legacy resolution must not launch commands")
            return CommandOutput(status: 1, standardOutput: "", standardError: "Unexpected command")
        }
    }
}
