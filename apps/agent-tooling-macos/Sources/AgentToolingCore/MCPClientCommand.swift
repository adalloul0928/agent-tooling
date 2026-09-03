import Foundation

/// The one place that knows how each client spells an MCP command.
///
/// These argument shapes are matched exactly by `OperationCommandPolicy`, so a
/// change here that the policy does not recognise turns into a refused step
/// rather than a wrong command. They were previously written out in three
/// places — the app's own configuration plan, the multi-server stack builder,
/// and the registry's install routes — which meant a client changing its CLI
/// needed three edits to stay consistent, and any one of them drifting would
/// only surface when a plan was executed.
enum MCPClientCommand {
    static func executable(for client: ClientKind) -> String {
        switch client {
        case .claude: "claude"
        case .codex: "codex"
        case .gemini: "gemini"
        }
    }

    /// The scope word a client expects. Gemini has no separate local scope, so
    /// a local request is spelled as project there rather than silently
    /// widening to user.
    static func scopeArgument(for scope: ToolingScope, client: ClientKind) -> String {
        let requested: String =
            switch scope {
            case .project, .workspace: "project"
            case .localProject: "local"
            default: "user"
            }
        if client == .gemini, requested == "local" { return "project" }
        return requested
    }

    /// Bridges a stored display name back to a scope. Records hold the display
    /// string rather than the enum, so this keeps that translation in one place
    /// too.
    static func scope(fromDisplayName displayName: String) -> ToolingScope {
        ToolingScope.allCases.first { $0.displayName == displayName } ?? .user
    }

    static func addArguments(
        serverID: String,
        transport: MCPTransport,
        destination: ValidatedMCPDestination,
        client: ClientKind,
        scope: ToolingScope
    ) -> [String] {
        let scopeWord = scopeArgument(for: scope, client: client)
        switch (client, transport) {
        case (.claude, .http):
            return ["mcp", "add", "--transport", "http", "--scope", scopeWord, serverID, destination.endpoint]
        case (.claude, .stdio):
            return ["mcp", "add", "--transport", "stdio", "--scope", scopeWord, serverID, "--"] + destination.command
        // Codex's MCP command exposes no scope flag. A non-user scope is
        // refused before it reaches here rather than being written into the
        // global configuration under a scope the CLI cannot honour.
        case (.codex, .http):
            return ["mcp", "add", serverID, "--url", destination.endpoint]
        case (.codex, .stdio):
            return ["mcp", "add", serverID, "--"] + destination.command
        case (.gemini, .http):
            return ["mcp", "add", "--scope", scopeWord, "--transport", "http", serverID, destination.endpoint]
        case (.gemini, .stdio):
            return ["mcp", "add", "--scope", scopeWord, "--transport", "stdio", serverID, "--"] + destination.command
        }
    }

    static func removeArguments(serverID: String, client: ClientKind, scope: ToolingScope) -> [String] {
        let scopeWord = scopeArgument(for: scope, client: client)
        switch client {
        case .claude: return ["mcp", "remove", "--scope", scopeWord, serverID]
        case .codex: return ["mcp", "remove", serverID]
        case .gemini: return ["mcp", "remove", "--scope", scopeWord, serverID]
        }
    }

    /// True when the client can honour the requested scope. Codex is the only
    /// client without a scope selector today.
    static func supportsScope(_ scope: ToolingScope, client: ClientKind) -> Bool {
        guard client == .codex else { return true }
        return scopeArgument(for: scope, client: client) == "user"
    }
}
