import AgentToolingCore
import Foundation
import SwiftUI
import Testing

@testable import AgentToolingApp

private func server(origin: MCPDefinitionOrigin, endpoint: String, transport: MCPTransport) -> MCPServer {
    MCPServer(
        id: "fixture",
        name: "Fixture",
        summary: origin == .managed ? "Managed by Agent Tooling" : "Discovered in local agent configuration.",
        endpoint: endpoint,
        transport: transport,
        authentication: "None",
        scope: "This Mac",
        clients: [ClientState(client: .claude, state: .healthy, detail: "Configured", isInstalled: true)],
        definitionOrigin: origin
    )
}

@Suite("MCP capabilities pane")
@MainActor
struct MCPCapabilitiesPaneRenderTests {
    /// Renders the detail-pane entry point so a missing environment object or a
    /// broken layout fails here rather than in front of a person.
    private func render(_ server: MCPServer, capabilities: MCPCapabilityModel = MCPCapabilityModel()) -> CGSize? {
        let renderer = ImageRenderer(
            content: MCPServerCapabilitiesPane(server: server)
                .environment(capabilities)
                .frame(width: 640)
        )
        return renderer.nsImage?.size
    }

    @Test func aManagedHTTPServerRendersTheConsoleBeforeAnythingConnects() {
        let size = render(server(origin: .managed, endpoint: "https://mcp.example.com/rpc", transport: .http))

        #expect(size?.width ?? 0 > 0)
        #expect(size?.height ?? 0 > 0)
    }

    @Test func aDiscoveredServerRendersTheUnavailableExplanation() {
        let size = render(server(origin: .observed, endpoint: "~/.claude.json", transport: .stdio))

        #expect(size?.width ?? 0 > 0)
    }

    @Test func recordedCapabilitiesRenderTheirSwitchesAndSummary() throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "mcp-pane-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let capabilities = MCPCapabilityModel()
        capabilities.activate(workspaceRoot: root)
        capabilities.observe(toolNames: ["alpha", "beta", "gamma", "delta"], serverID: "fixture")
        capabilities.setEnabled(false, tool: "delta", serverID: "fixture")

        #expect(capabilities.summary(for: "fixture") == "3/4 enabled")
        #expect(capabilities.isEnabled(tool: "delta", serverID: "fixture") == false)
        #expect(capabilities.lastError == nil)

        let size = render(
            server(origin: .managed, endpoint: "https://mcp.example.com/rpc", transport: .http),
            capabilities: capabilities
        )
        #expect(size?.height ?? 0 > 0)

        // A second model over the same workspace sees the same recorded intent.
        let reopened = MCPCapabilityModel()
        reopened.activate(workspaceRoot: root)
        #expect(reopened.summary(for: "fixture") == "3/4 enabled")
    }

    @Test func theRunFormForADestructiveToolRendersItsWarningAndResult() {
        let destructive = MCPToolDescriptor(
            name: "delete_project",
            summary: "Removes a project and everything in it.",
            inputSchema: .object([
                "type": .string("object"),
                "required": .array([.string("projectId")]),
                "properties": .object([
                    "projectId": .object(["type": .string("string"), "description": .string("The project to remove.")]),
                    "force": .object(["type": .string("boolean")]),
                    "mode": .object(["type": .string("string"), "enum": .array([.string("soft"), .string("hard")])]),
                ]),
            ]),
            annotations: MCPToolAnnotations(destructiveHint: true)
        )
        #expect(destructive.requiresRunConfirmation)

        let renderer = ImageRenderer(
            content: MCPToolRunPanel(
                tool: destructive,
                serverName: "Fixture",
                isRunning: false,
                needsConfirmation: true,
                outcome: MCPToolCallOutcome(
                    toolName: "delete_project",
                    isError: false,
                    text: "Removed project PRJ-12.",
                    structuredText: "{\"removed\":1}",
                    latencyMilliseconds: 87
                ),
                failure: nil,
                onRun: { _, _ in }
            )
            .frame(width: 640)
        )

        #expect(renderer.nsImage?.size.height ?? 0 > 0)
    }
}
