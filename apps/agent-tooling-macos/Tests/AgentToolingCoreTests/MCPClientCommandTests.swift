import Foundation
import Testing

@testable import AgentToolingCore

/// Every client MCP command in the app comes from one builder, and the
/// operation engine accepts a fixed set of argument shapes. These tests tie the
/// two together: a shape the builder can emit that the policy would refuse is a
/// step that fails at execution instead of at review.
struct MCPClientCommandTests {
    private let policy = OperationCommandPolicy(
        libraryURL: URL(fileURLWithPath: "/tmp/agent-tooling-policy-fixture/library", isDirectory: true),
        gitBackupRoot: URL(fileURLWithPath: "/tmp/agent-tooling-policy-fixture/exports/git-backup", isDirectory: true)
    )

    @Test func everyAddCommandTheBuilderCanEmitPassesTheCommandPolicy() throws {
        let http = ValidatedMCPDestination(endpoint: "https://mcp.example.com/sse", command: [])
        let stdio = ValidatedMCPDestination(endpoint: "", command: ["npx", "-y", "@example/server@1.2.3"])

        for client in ClientKind.allCases {
            for scope in ToolingScope.allCases {
                guard MCPClientCommand.supportsScope(scope, client: client) else { continue }
                for (transport, destination) in [(MCPTransport.http, http), (MCPTransport.stdio, stdio)] {
                    let arguments = MCPClientCommand.addArguments(
                        serverID: "example-server",
                        transport: transport,
                        destination: destination,
                        client: client,
                        scope: scope
                    )
                    #expect(throws: Never.self) {
                        try policy.validate(executable: MCPClientCommand.executable(for: client), arguments: arguments)
                    }
                }
            }
        }
    }

    @Test func everyRemoveCommandTheBuilderCanEmitPassesTheCommandPolicy() throws {
        for client in ClientKind.allCases {
            for scope in ToolingScope.allCases {
                guard MCPClientCommand.supportsScope(scope, client: client) else { continue }
                let arguments = MCPClientCommand.removeArguments(serverID: "example-server", client: client, scope: scope)
                #expect(throws: Never.self) {
                    try policy.validate(executable: MCPClientCommand.executable(for: client), arguments: arguments)
                }
            }
        }
    }

    /// Gemini has no separate local scope. A local request must become project
    /// there, never silently widen to user.
    @Test func aLocalScopeBecomesProjectForGeminiAndStaysLocalForClaude() {
        #expect(MCPClientCommand.scopeArgument(for: .localProject, client: .gemini) == "project")
        #expect(MCPClientCommand.scopeArgument(for: .localProject, client: .claude) == "local")
        #expect(MCPClientCommand.scopeArgument(for: .project, client: .gemini) == "project")
    }

    /// Codex exposes no scope flag, so anything but user scope has to be
    /// refused rather than written into its global configuration.
    @Test func codexAcceptsOnlyUserScope() {
        #expect(MCPClientCommand.supportsScope(.user, client: .codex))
        #expect(!MCPClientCommand.supportsScope(.project, client: .codex))
        #expect(!MCPClientCommand.supportsScope(.localProject, client: .codex))
        #expect(MCPClientCommand.supportsScope(.project, client: .claude))
    }

    /// Records store a scope's display name rather than the enum, so the round
    /// trip has to survive that translation.
    @Test func aScopeSurvivesTheRoundTripThroughItsDisplayName() {
        for scope in ToolingScope.allCases {
            #expect(MCPClientCommand.scope(fromDisplayName: scope.displayName) == scope)
        }
        #expect(MCPClientCommand.scope(fromDisplayName: "not a scope") == .user)
    }
}
