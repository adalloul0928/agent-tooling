import Foundation
import Testing

@testable import AgentToolingCore

@Suite("Stacked plans")
struct StackedPlanBuilderTests {
    private func server(
        id: String,
        transport: MCPTransport = .http,
        endpoint: String = "https://mcp.example.com/mcp",
        scope: ToolingScope = .user,
        projectRoot: String? = nil
    ) -> MCPServer {
        MCPServer(
            id: id,
            name: id,
            summary: "Managed by Agent Tooling",
            endpoint: endpoint,
            transport: transport,
            authentication: "OAuth",
            scope: scope.displayName,
            projectRoot: projectRoot,
            clients: [ClientState(client: .claude, state: .pending, detail: "Desired")],
            definitionOrigin: .managed
        )
    }

    @Test("Emits one plan for several servers across several apps")
    func emitsOnePlanForTheWholeStack() throws {
        let plan = try StackedPlanBuilder.mcpConfigurationPlan(
            servers: [server(id: "linear"), server(id: "context7", transport: .stdio, endpoint: "npx -y context7")],
            targets: [.claude, .gemini],
            availableClients: [.claude, .gemini]
        )

        #expect(plan.kind == .configureMCP)
        #expect(plan.title == "Configure 2 MCP servers")
        #expect(plan.steps.filter { $0.kind == .command }.count == 4)
        #expect(plan.steps.last?.kind == .scan)
        #expect(plan.targetSurfaces == [.claudeCode, .geminiCLI])
        let claudeStep = try #require(plan.steps.first { $0.title.contains("context7") && $0.title.contains("Claude") })
        #expect(
            claudeStep.arguments == ["mcp", "add", "--transport", "stdio", "--scope", "user", "context7", "--", "npx", "-y", "context7"])
    }

    @Test("Every composed command passes the engine's own allowlist")
    func composedCommandsPassTheAllowlist() throws {
        let plan = try StackedPlanBuilder.mcpConfigurationPlan(
            servers: [server(id: "linear"), server(id: "context7", transport: .stdio, endpoint: "npx -y context7")],
            targets: [.claude, .codex, .gemini],
            availableClients: [.claude, .codex, .gemini]
        )
        let policy = OperationCommandPolicy(
            libraryURL: URL(fileURLWithPath: "/tmp/library", isDirectory: true),
            gitBackupRoot: URL(fileURLWithPath: "/tmp/backup", isDirectory: true)
        )

        for step in plan.steps where step.kind == .command {
            let executable = try #require(step.executable)
            #expect(throws: Never.self) { try policy.validate(executable: executable, arguments: step.arguments) }
        }
    }

    @Test("Replaces a step with manual guidance when a client is missing or unsupported")
    func explainsUnavailableTargets() throws {
        let plan = try StackedPlanBuilder.mcpConfigurationPlan(
            servers: [server(id: "linear", scope: .project, projectRoot: "/Users/example/project")],
            targets: [.claude, .codex],
            availableClients: [.claude]
        )

        let codexStep = try #require(plan.steps.first { $0.title.contains("Codex") })
        #expect(codexStep.kind == .manual)
        #expect(codexStep.requiresUserAction)
        let claudeStep = try #require(plan.steps.first { $0.title.contains("Claude Code") })
        #expect(claudeStep.currentDirectoryPath == "/Users/example/project")
        #expect(claudeStep.arguments.contains("project"))
    }

    @Test("Refuses selections it cannot describe in one plan")
    func refusesUnbuildableSelections() {
        #expect(throws: StackedPlanError.emptySelection) {
            _ = try StackedPlanBuilder.mcpConfigurationPlan(servers: [], targets: [.claude], availableClients: [.claude])
        }
        #expect(throws: StackedPlanError.noTargets) {
            _ = try StackedPlanBuilder.mcpConfigurationPlan(servers: [server(id: "linear")], targets: [], availableClients: [.claude])
        }
        #expect(throws: StackedPlanError.self) {
            _ = try StackedPlanBuilder.mcpConfigurationPlan(
                servers: [server(id: "linear"), server(id: "files", scope: .project, projectRoot: "/tmp")],
                targets: [.claude],
                availableClients: [.claude]
            )
        }
        #expect(throws: StackedPlanError.missingProjectRoot("files")) {
            _ = try StackedPlanBuilder.mcpConfigurationPlan(
                servers: [server(id: "files", scope: .project)],
                targets: [.claude],
                availableClients: [.claude]
            )
        }
    }

    @Test("Removes several plugins through one reviewed plan, or refuses without a verified route")
    func buildsPluginRemovalStack() throws {
        let plugin = Plugin(
            id: "release-tools",
            name: "Release Tools",
            summary: "",
            source: "example-market",
            scope: "This Mac",
            revision: "a1b2c3d",
            skills: [],
            profiles: [],
            clients: [ClientState(client: .claude, state: .healthy, detail: "Installed", isInstalled: true)],
            installed: true
        )
        let package = MarketplacePackage(
            id: "claude:release-tools",
            name: "Release Tools",
            publisher: "example",
            summary: "",
            sourceName: "Claude marketplace",
            components: [.plugin],
            supportedClients: [.claude],
            location: "https://example.com/catalog",
            nativeInstalls: [
                NativeInstall(
                    client: .claude,
                    executable: "claude",
                    arguments: ["plugin", "install", "release-tools@example", "--scope", "user"],
                    removalArguments: ["plugin", "uninstall", "release-tools@example", "--scope", "user"],
                    detail: "Installs through the Claude plugin manager."
                )
            ]
        )

        let plan = try StackedPlanBuilder.pluginRemovalPlan(plugins: [plugin], client: .claude, packages: [package])
        #expect(plan.steps.count == 2)
        #expect(plan.steps.first?.arguments == ["plugin", "uninstall", "release-tools@example", "--scope", "user"])

        #expect(throws: StackedPlanError.noRemovalRoute("Release Tools", .codex)) {
            _ = try StackedPlanBuilder.pluginRemovalPlan(plugins: [plugin], client: .codex, packages: [package])
        }
    }
}
