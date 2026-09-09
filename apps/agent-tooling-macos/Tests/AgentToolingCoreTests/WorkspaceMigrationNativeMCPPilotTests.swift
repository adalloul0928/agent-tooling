import Foundation
import Testing

@testable import AgentToolingCore

struct WorkspaceMigrationNativeMCPPilotTests {
    @Test func intakeAndCandidateKeepNativePluginMCPAndSkillAsOnePortablePackage() async throws {
        let fixture = try WorkspaceMigrationServiceTests.Fixture()
        var retainedForPilot = false
        defer { if !retainedForPilot { fixture.remove() } }
        let snapshot = fixture.nativeSnapshotWithMCP()
        try fixture.legacy.saveWorkspaceSnapshot(snapshot)
        let checkpoint = try await WorkspaceLegacyCheckpoint.capture(databaseURL: fixture.legacy.databaseURL)
        let intake = try WorkspaceMigrationIntake.review(checkpoint: checkpoint, workspaceID: fixture.context.workspaceID)
        #expect(intake.issues.isEmpty)
        let choice = try #require(intake.choices.first { $0.legacy == .init(domain: .plugin, identifier: "browser") })
        guard case let .nativePackage(routes, children) = choice.strategy else {
            Issue.record("Expected native package choice")
            return
        }
        #expect(routes == [.init(client: .codex, externalPluginID: "browser")])
        #expect(children.count == 2)
        #expect(children.contains { $0.legacy == .init(domain: .skill, identifier: "browse") })
        #expect(children.contains { $0.legacy == .init(domain: .mcpServer, identifier: "browser-mcp") })
        let placements = try intake.nativePlacements(workspaceID: fixture.context.workspaceID)
        let request = WorkspaceMigrationCandidatePreparationRequest(
            attemptID: WorkspaceObjectID(), checkpoint: checkpoint, legacyDatabaseURL: fixture.legacy.databaseURL,
            context: fixture.context, choices: intake.choices, nativePluginPlacements: placements)
        let preview = try await WorkspaceMigrationCandidatePreparationService().preview(request)
        let preparation = try #require(preview.preparation)
        #expect(preparation.record.document.artifacts.filter { $0.authority == .nativeOwned }.count == 3)
        #expect(preparation.record.document.artifacts.filter { $0.authority == .centralPersonal }.isEmpty)
        #expect(preparation.record.document.mcpDefinitions?.isEmpty == true)
        #expect(preparation.record.manifest.content.isEmpty)
        #expect(preparation.record.document.artifacts.contains { $0.identity.kind == .skill && $0.identity.parentPackageID != nil })
        #expect(preparation.record.document.artifacts.contains { $0.identity.kind == .mcpServer && $0.identity.parentPackageID != nil })
        let mcp = try #require(preparation.record.document.artifacts.first { $0.identity.kind == .mcpServer })
        #expect(preparation.record.document.configurationState?.configurations.first?.requiredMCPs
            == [.init(legacy: .init(domain: .mcpServer, identifier: "browser-mcp"), resolution: .artifact(mcp.identity.id))])
        #expect(preparation.record.document.assignments.count == 1)
        #expect(preparation.record.document.assignments.first?.artifactID == preparation.record.document.artifacts.first { $0.identity.kind == .nativePlugin }?.identity.id)
        retainedForPilot = try exportFixtureIfRequested(fixture: fixture)
    }

    @Test @MainActor func nativeCatalogAliasesAndCachedListingsSurviveCandidateInitializationAndReopen() async throws {
        let fixture = try WorkspaceMigrationServiceTests.Fixture()
        var retainedForPilot = false
        defer { if !retainedForPilot { fixture.remove() } }
        var snapshot = fixture.nativeSnapshotWithMCP()
        var claude = snapshot.targetObservations[0]
        claude.surface = .claudeCode
        snapshot.targetObservations.append(claude)
        let catalog = MarketplaceService()
        snapshot.marketplacePackages = catalog.packagesFromCodexCatalogJSON("""
        {"installed":[{"pluginId":"browser","name":"Browser"},{"pluginId":"stale","name":"Old catalog listing"}],
         "available":[{"pluginId":"available","name":"Available only"}]}
        """) + catalog.packagesFromClaudeCatalogJSON("""
        [{"name":"browser","installed":true}]
        """)
        try #require(snapshot.marketplacePackages.count == 4)
        try fixture.legacy.saveWorkspaceSnapshot(snapshot)
        // Settings is reached after startup refresh. Offline or excluded
        // clients must not erase the catalog evidence before intake sees it.
        let model = try AppModel(store: fixture.legacy, runner: UnavailableNativeCatalogPilotRunner(),
            homeURL: fixture.root.appending(path: "home"), marketplaceProviders: [])
        await model.bootstrap()
        try #require(model.marketplacePackages.sorted { $0.id < $1.id }
            == snapshot.marketplacePackages.sorted { $0.id < $1.id })
        let beforeNative = try Data(contentsOf: fixture.nativeSentinel)
        let beforeLegacy = try AgentToolingCoding.encoder().encode(
            try #require(try fixture.legacy.loadWorkspaceSnapshot()))
        let checkpoint = try await WorkspaceLegacyCheckpoint.capture(databaseURL: fixture.legacy.databaseURL)
        let intake = try WorkspaceMigrationIntake.review(checkpoint: checkpoint, workspaceID: fixture.context.workspaceID)
        try #require(intake.issues.isEmpty)
        let preview = try await WorkspaceMigrationCandidatePreparationService().preview(.init(
            attemptID: WorkspaceObjectID(), checkpoint: checkpoint, legacyDatabaseURL: fixture.legacy.databaseURL,
            context: fixture.context, choices: intake.choices,
            nativePluginPlacements: try intake.nativePlacements(workspaceID: fixture.context.workspaceID)))
        let preparation = try #require(preview.preparation)
        #expect(preparation.record.manifest.content.isEmpty)
        #expect(preparation.record.manifest.sourceCaptures.isEmpty)
        #expect(preparation.record.manifest.deploymentNames.isEmpty)
        let service = try fixture.service()
        _ = try await service.stage(preparation)
        _ = try await service.initialize(attemptID: preparation.record.manifest.attemptID,
            inputDigest: try preparation.record.inputDigest)
        let stored = try #require(try fixture.revisionStore().snapshot())
        let root = try #require(stored.document.artifacts.first { $0.identity.kind == .nativePlugin })
        #expect(stored.document.artifacts.count == 3)
        #expect(stored.document.artifacts.allSatisfy { $0.authority == .nativeOwned })
        #expect(stored.document.artifacts.filter { $0.identity.parentPackageID == root.identity.id }.count == 2)
        #expect(Set(root.nativeRoutes) == [.init(client: .codex, externalPluginID: "browser"),
                                          .init(client: .claude, externalPluginID: "browser")])
        #expect(Set(root.identity.aliases.filter { $0.namespace == "legacy.marketplacePackage" }.map(\.value))
            == ["codex:browser", "claude:browser"])
        #expect(stored.document.assignments.count == 1)
        #expect(stored.document.assignments.first?.artifactID == root.identity.id)
        #expect(stored.document.mcpDefinitions?.isEmpty == true)
        #expect(stored.device.applicationState?.marketplacePackages.sorted { $0.id < $1.id }
            == snapshot.marketplacePackages.sorted { $0.id < $1.id })
        #expect(try Data(contentsOf: fixture.nativeSentinel) == beforeNative)
        #expect(try AgentToolingCoding.encoder().encode(
            try #require(try fixture.legacy.loadWorkspaceSnapshot())) == beforeLegacy)
        retainedForPilot = try exportFixtureIfRequested(fixture: fixture,
            environmentKey: "WORKSPACE_MIGRATION_NATIVE_CATALOG_FIXTURE")
    }

    private func exportFixtureIfRequested(
        fixture: WorkspaceMigrationServiceTests.Fixture,
        environmentKey: String = "WORKSPACE_MIGRATION_NATIVE_MCP_FIXTURE"
    ) throws -> Bool {
        guard let path = ProcessInfo.processInfo.environment[environmentKey], !path.isEmpty else { return false }
        let output = URL(fileURLWithPath: path)
        let home = fixture.root.appending(path: "home")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: false)
        let payload = ["workspace": fixture.legacy.rootURL.path, "home": home.path]
        let data = try JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: output, options: [.withoutOverwriting])
        return true
    }
}

private struct UnavailableNativeCatalogPilotRunner: CommandRunning {
    func run(executable: String, arguments: [String], currentDirectory: URL?) async throws -> CommandOutput {
        .init(status: 127, standardOutput: "", standardError: "Not installed in disposable home")
    }
}

private extension WorkspaceMigrationServiceTests.Fixture {
    func nativeSnapshotWithMCP() -> WorkspaceSnapshot {
        var snapshot = nativeSnapshot()
        snapshot.mcpServers = [MCPServer(id: "browser-mcp", name: "Browser MCP", summary: "Native", endpoint: "browser",
            transport: .stdio, authentication: "none", scope: "This Mac", clients: [])]
        snapshot.targetObservations[0].mcpMetadata = ["browser-mcp": .init(transport: "stdio", authentication: "none", source: "Native")]
        snapshot.targetObservations[0].pluginMetadata["browser"]?.mcpServerIDs = ["browser-mcp"]
        snapshot.targetObservations[0].discoveredMCPServers = ["browser-mcp"]
        let nativeRoot = nativeSentinel.deletingLastPathComponent()
        snapshot.targetObservations[0].pluginMetadata["browser"]?.source = nativeRoot.path
        snapshot.targetObservations[0].skillMetadata["browse"]?.path = nativeRoot.appending(path: "skills/browse").path
        snapshot.profiles[0].requiredMCPs = ["browser-mcp"]
        snapshot.profiles[0].targetBindings = [.init(item: .init(kind: .plugin, identifier: "browser"),
            client: .codex, enabled: true)]
        snapshot.preferences.enabledClients = [.codex]
        snapshot.preferences.automaticallyCheckHealth = false
        return snapshot
    }
}
