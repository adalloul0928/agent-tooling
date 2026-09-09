import Foundation
import Testing
@testable import AgentToolingCore

@MainActor
struct WorkspaceMCPMigrationParityTests {
    @Test(arguments: [ClientKind.claude, .codex, .gemini],
          [ToolingScope.user, .project, .localProject, .workspace])
    func checkpointMigrationMatchesTheActualAppModelPlan(client: ClientKind, scope: ToolingScope) async throws {
        for transport in [MCPTransport.http, .stdio] {
            let root = FileManager.default.temporaryDirectory.appending(path: "mcp-migration-parity-\(UUID())")
            defer { try? FileManager.default.removeItem(at: root) }
            let store = try WorkspaceStore(rootURL: root.appending(path: "legacy"))
            let home = root.appending(path: "home")
            let projectRoot = root.appending(path: "project")
            try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: projectRoot, withIntermediateDirectories: true)
            let surface: TargetSurface = switch client {
            case .claude: .claudeCode
            case .codex: .codexCLI
            case .gemini: .geminiCLI
            }
            let endpoint = transport == .http ? "https://mcp.example.com/v1" : "mcp-runner --label 'two words'"
            let server = MCPServer(id: "original-server-id", name: "Different display label", summary: "Fixture",
                endpoint: endpoint, transport: transport, authentication: "None", scope: scope.displayName,
                projectRoot: scope == .user ? nil : projectRoot.path,
                clients: [.init(client: client, state: .healthy, detail: "Configured")], definitionOrigin: .managed)
            let observation = TargetObservation(surface: surface, installed: true, commandAvailable: true,
                version: "fixture-1", capabilities: .init(supportsPluginInstall: false,
                    supportsProjectScope: true, supportsLocalMarketplace: false, supportsMCPAuthentication: false,
                    supportsConnectorDiscovery: false, requiresNewSession: false, requiresRestart: false,
                    supportsMachineReadableOutput: false))
            let snapshot = WorkspaceSnapshot(mcpServers: [server], targetObservations: [observation],
                activeProfileID: "", preferences: .init(enabledClients: [client]))
            try store.saveWorkspaceSnapshot(snapshot)
            let model = try AppModel(store: store, runner: NoCommandRunner(), homeURL: home)
            model.planMCPConfiguration(server: server, targets: [client])
            let oldPlan = try #require(model.pendingPlan)

            let checkpoint = try await WorkspaceLegacyCheckpoint.capture(databaseURL: store.databaseURL)
            let context = WorkspaceMigrationContext(workspaceID: WorkspaceObjectID(), deviceID: WorkspaceObjectID(),
                revision: .init(writerID: WorkspaceObjectID()))
            let key = LegacyReferenceKey(domain: .mcpServer, identifier: server.id)
            let identities = try WorkspaceMigrationIdentity.mapping(keys: [key], workspaceID: context.workspaceID)
            let artifactID = ArtifactID(try #require(identities.first?.objectID.rawValue))
            let logicalProjectID = scope == .project || scope == .localProject ? ArtifactID() : nil
            let definition = PortableMCPDefinitionRecord(artifactID: artifactID,
                connection: transport == .http ? .remoteHTTPS(url: endpoint) : .deviceBound(transport: .stdio))
            let binding = DeviceMCPDefinitionBinding(artifactID: artifactID,
                destination: transport == .stdio ? .stdio(executable: "mcp-runner", arguments: ["--label", "two words"]) : nil,
                workspaceRootPath: scope == .workspace ? projectRoot.path : nil)
            let assignment = AssignmentContribution(artifactID: artifactID,
                destination: .init(surface: surface, scope: scope, logicalProjectID: logicalProjectID,
                    deviceIDs: [context.deviceID]), reason: .manual)
            var decisions = WorkspaceMigrationDecisions()
            decisions.artifacts = [.init(legacy: key, artifact: .init(
                identity: .init(id: artifactID, kind: .mcpServer, displayName: server.name), authority: .centralPersonal))]
            decisions.managedMCP = [.init(legacyServerID: server.id, definition: definition, deviceBinding: binding,
                assignments: [assignment], project: logicalProjectID.map {
                    .init(project: .init(id: $0, name: "Project"), rootPath: projectRoot.path)
                })]
            let preparation = try WorkspaceMigrationPreparation.build(attemptID: WorkspaceObjectID(),
                checkpoint: checkpoint, legacyDatabaseURL: store.databaseURL, context: context,
                decisions: decisions, sourceDirectories: [:])
            let document = preparation.record.document
            var device = preparation.record.device
            let capability = TargetCapabilityEvidence(surface: surface, installedClientVersion: "fixture-1",
                adapterContractVersion: 1, component: .mcpServer, transport: transport.rawValue,
                scopes: [scope], support: .supported)
            device.capabilityEvidence = [capability]
            let target = ResolvedAssignmentTarget(selector: .init(destination: assignment.destination),
                physicalDestinationID: WorkspaceObjectID(), installedClientVersion: "fixture-1", adapterContractVersion: 1,
                componentContexts: [.init(component: .mcpServer, transport: transport.rawValue)])
            let resolved = WorkspaceAssignmentResolver.resolve(artifacts: document.artifacts,
                contributions: document.assignments, currentDeviceID: device.deviceID, targets: [target],
                capabilityEvidence: device.capabilityEvidence, portableMCPDefinitions: document.mcpDefinitions ?? [],
                deviceMCPBindings: device.mcpBindings ?? [])
            #expect(resolved.issues.isEmpty)
            let requirement = try #require(resolved.requirements.first)
            func newPlan() throws -> WorkspaceManagedMCPCommandPlan {
                try WorkspaceManagedMCPCommandPlanning.plan(document: document, device: device,
                    requirement: requirement, resolvedTargets: [target], target: target, capability: capability,
                    nativeServerIdentifier: server.id,
                    executableURL: URL(fileURLWithPath: "/usr/local/bin/\(MCPClientCommand.executable(for: client))"))
            }
            if client == .codex && scope != .user {
                #expect(oldPlan.steps.filter { $0.kind == .command }.isEmpty)
                #expect(oldPlan.steps.contains { $0.kind == .manual })
                #expect(throws: WorkspaceManagedMCPCommandPlanningError.unsupportedScope(scope, client)) {
                    _ = try newPlan()
                }
            } else {
                let old = try #require(oldPlan.steps.first { $0.kind == .command })
                let new = try newPlan()
                #expect(new.arguments == old.arguments)
                #expect(new.executable == old.executable)
                #expect(new.workingDirectoryPath == old.currentDirectoryPath)
                #expect(old.projectRootPath == new.workingDirectoryPath)
                #expect(new.nativeServerIdentifier == server.id)
            }
            #expect(preparation.record.manifest.content.isEmpty)
            #expect(!FileManager.default.fileExists(atPath: home.appending(path: ".claude").path))
            #expect(!FileManager.default.fileExists(atPath: home.appending(path: ".codex").path))
        }
    }

    private struct NoCommandRunner: CommandRunning {
        func run(executable: String, arguments: [String], currentDirectory: URL?) async throws -> CommandOutput {
            Issue.record("Planning must not execute a native process.")
            throw WorkspaceMigrationError.invalidPreparation
        }
    }
}
