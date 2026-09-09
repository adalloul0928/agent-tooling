import Foundation
import Testing

@testable import AgentToolingCore

private struct PluginUpdateTestRunner: CommandRunning {
    func run(executable: String, arguments: [String], currentDirectory: URL?) async throws -> CommandOutput {
        Issue.record("Preparing a plugin update must not execute a client command.")
        return CommandOutput(status: 127, standardOutput: "", standardError: "No commands expected")
    }
}

@MainActor
struct PluginUpdateTests {
    @Test func claudeUpdateUsesTheObservedNativeIdentifierAndKeepsBundledSkillsNative() throws {
        let model = try model()
        let plugin = plugin(id: "code-review@claude-plugins-official", client: .claude)
        model.plugins = [plugin]
        model.targetObservations = [observation(plugin: plugin, client: .claude, scope: "User")]

        let route = try #require(model.pluginUpdateRoute(pluginID: plugin.id, client: .claude))
        #expect(route.canUpdateHere)
        model.planPluginUpdate(pluginID: plugin.id, client: .claude)

        let plan = try #require(model.pendingPlan)
        let command = try #require(plan.steps.first { $0.kind == .command })
        #expect(command.executable == "claude")
        #expect(command.arguments == ["plugin", "update", plugin.id, "--scope", "user"])
        #expect(plan.scope == .user)
        #expect(plan.targetSurfaces == [.claudeCode])
        #expect(plan.requiresConfirmation)
        #expect(plan.steps.contains { $0.kind == .scan })
        #expect(plan.steps.contains { $0.kind == .manual && $0.title.contains("fresh Claude Code session") })
        #expect(!plan.steps.contains { $0.kind == .copyDirectory })
        #expect(model.plugins == [plugin])
        #expect(model.skills.isEmpty)
        #expect(model.pendingSkillAdoption == nil)

        let policy = OperationCommandPolicy(libraryURL: model.store.libraryURL, gitBackupRoot: model.store.rootURL.appending(path: "backup"))
        try policy.validate(executable: try #require(command.executable), arguments: command.arguments)
    }

    @Test(arguments: ["Project", "Local", "Managed", "This Mac", ""])
    func claudeUpdateNeverGuessesUserScope(observedScope: String) throws {
        let model = try model()
        let plugin = plugin(id: "review@marketplace", client: .claude)
        model.plugins = [plugin]
        model.targetObservations = [observation(plugin: plugin, client: .claude, scope: observedScope)]

        #expect(model.pluginUpdateRoute(pluginID: plugin.id, client: .claude)?.canUpdateHere == false)
        model.planPluginUpdate(pluginID: plugin.id, client: .claude)

        let plan = try #require(model.pendingPlan)
        #expect(plan.steps.allSatisfy { $0.kind == .manual && $0.requiresUserAction })
        #expect(!plan.requiresConfirmation)
        #expect(!plan.steps.contains { $0.executable != nil || $0.destinationPath != nil })
    }

    @Test func conflictingScopesOrMissingCommandKeepClaudeUpdatesInTheClient() throws {
        let model = try model()
        let plugin = plugin(id: "review@marketplace", client: .claude)
        model.plugins = [plugin]
        var secondObservation = observation(plugin: plugin, client: .claude, scope: "Project")
        secondObservation.surface = .claudeDesktop
        model.targetObservations = [observation(plugin: plugin, client: .claude, scope: "User"), secondObservation]
        #expect(model.pluginUpdateRoute(pluginID: plugin.id, client: .claude)?.canUpdateHere == false)

        var unavailable = observation(plugin: plugin, client: .claude, scope: "User")
        unavailable.commandAvailable = false
        model.targetObservations = [unavailable]
        #expect(model.pluginUpdateRoute(pluginID: plugin.id, client: .claude)?.canUpdateHere == false)
    }

    @Test func codexGuidanceNeverReinstallsOrCopiesAnOfficialPlugin() throws {
        let model = try model()
        let plugin = plugin(id: "documents@openai-bundled", client: .codex)
        model.plugins = [plugin]
        model.targetObservations = [observation(plugin: plugin, client: .codex, scope: "User")]
        model.marketplacePackages = [
            MarketplacePackage(
                id: "codex:\(plugin.id)", name: plugin.name, publisher: "OpenAI", summary: plugin.summary,
                sourceName: "OpenAI", components: [.plugin, .skill], supportedClients: [.codex],
                location: plugin.source, isInstalled: true,
                nativeInstalls: [.init(client: .codex, executable: "codex", arguments: ["plugin", "add", plugin.id], detail: "Install")]
            )
        ]

        let route = try #require(model.pluginUpdateRoute(pluginID: plugin.id, client: .codex))
        #expect(route.actionTitle == "Update in Codex…")
        #expect(!route.canUpdateHere)
        model.planPluginUpdate(pluginID: plugin.id, client: .codex)

        let plan = try #require(model.pendingPlan)
        #expect(plan.steps.allSatisfy { $0.kind == .manual })
        #expect(plan.steps.allSatisfy { $0.arguments.isEmpty && $0.sourcePath == nil && $0.destinationPath == nil })
        #expect(model.plugins == [plugin])
        #expect(model.skills.isEmpty)
        #expect(model.pendingSkillAdoption == nil)
    }

    @Test func unknownOrAbsentPluginsCannotReceiveAnUpdatePlan() throws {
        let model = try model()
        let plugin = plugin(id: "review@marketplace", client: .claude)
        model.plugins = [plugin]
        model.targetObservations = [observation(plugin: plugin, client: .claude, scope: "User")]
        #expect(model.pluginUpdateRoute(pluginID: "another@marketplace", client: .claude) == nil)
        #expect(model.pluginUpdateRoute(pluginID: plugin.id, client: .codex) == nil)
        model.planPluginUpdate(pluginID: "another@marketplace", client: .claude)
        #expect(model.pendingPlan == nil)
        #expect(model.lastError?.contains("no longer reported as installed") == true)
    }

    @Test func updateCannotReplaceAnExistingReview() throws {
        let model = try model()
        let plugin = plugin(id: "review@marketplace", client: .claude)
        model.plugins = [plugin]
        model.targetObservations = [observation(plugin: plugin, client: .claude, scope: "User")]
        model.planPluginUpdate(pluginID: plugin.id, client: .claude)
        let originalPlanID = try #require(model.pendingPlan?.id)
        model.planPluginUpdate(pluginID: plugin.id, client: .claude)
        #expect(model.pendingPlan?.id == originalPlanID)
        #expect(model.lastError?.contains("Finish or discard") == true)
    }

    @Test func updateCommandAllowlistDoesNotAcceptScopeChangesOrMarketplaceCommandConsent() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        let policy = OperationCommandPolicy(libraryURL: root, gitBackupRoot: root.appending(path: "backup"))
        try policy.validate(executable: "claude", arguments: ["plugin", "update", "review@marketplace", "--scope", "user"])
        for arguments in [
            ["plugin", "update", "review@marketplace", "--scope", "project"],
            ["plugin", "update", "review@marketplace", "--scope", "managed"],
            ["plugin", "update", "review@marketplace", "--scope", "user", "--yes"],
            ["plugin", "update", "--all", "--scope", "user"],
            ["plugin", "update", "review;other", "--scope", "user"],
            ["plugin", "marketplace", "update"],
        ] {
            #expect(throws: OperationEngineError.self) { try policy.validate(executable: "claude", arguments: arguments) }
        }
        #expect(throws: OperationEngineError.self) {
            try policy.validate(executable: "codex", arguments: ["plugin", "update", "documents@openai-bundled"])
        }
    }

    private func model() throws -> AppModel {
        let root = FileManager.default.temporaryDirectory.appending(path: "plugin-update-tests-\(UUID().uuidString)")
        return try AppModel(
            store: WorkspaceStore(rootURL: root.appending(path: "workspace")), runner: PluginUpdateTestRunner(),
            homeURL: root.appending(path: "home"), marketplaceProviders: []
        )
    }

    private func plugin(id: String, client: ClientKind) -> Plugin {
        Plugin(
            id: id, name: "Review", summary: "A native plugin.", source: "https://github.com/example/plugins",
            scope: "This Mac", revision: "1.0.0", skills: ["review:child"], profiles: [],
            clients: [.init(client: client, state: .healthy, detail: "Found", isInstalled: true)], installed: true
        )
    }

    private func observation(plugin: Plugin, client: ClientKind, scope: String) -> TargetObservation {
        TargetObservation(
            surface: client == .claude ? .claudeCode : .codexCLI, installed: true, commandAvailable: true,
            discoveredPlugins: [plugin.id],
            pluginMetadata: [plugin.id: .init(name: plugin.name, source: plugin.source, scope: scope, enabled: true, skillIDs: plugin.skills)],
            capabilities: .init(
                supportsPluginInstall: true, supportsProjectScope: true, supportsLocalMarketplace: true,
                supportsMCPAuthentication: true, supportsConnectorDiscovery: false, requiresNewSession: true,
                requiresRestart: false, supportsMachineReadableOutput: true
            )
        )
    }
}
