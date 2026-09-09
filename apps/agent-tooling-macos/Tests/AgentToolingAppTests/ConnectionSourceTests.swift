import AgentToolingCore
import Testing

@testable import AgentToolingApp

struct ConnectionSourceTests {
    @Test func separatesPluginAndMarketplaceWithoutMisreadingURLs() {
        let source = ConnectionSource("developer-workflows@agent-tooling")
        #expect(source.source == "Plugin")
        #expect(source.plugin == "developer-workflows")
        #expect(source.marketplace == "agent-tooling")
        #expect(ConnectionSource.title(source.plugin!) == "Developer Workflows")
        #expect(ConnectionSource("https://user@example.com/mcp").plugin == nil)
        #expect(ConnectionSource("/tmp/plugin@work").plugin == nil)
        #expect(ConnectionSource("Codex native MCP inventory").source == "Codex")
        #expect(ConnectionSource("Claude Code configuration").source == "Claude Code")
    }

    @Test func catalogPrefixesPreserveSeparatePluginAndMarketplaceNames() {
        for identifier in ["cyrus-workflows@agent-tooling", "codex:cyrus-workflows@agent-tooling", "claude:cyrus-workflows@agent-tooling"] {
            let source = ConnectionSource(identifier)
            #expect(source.pluginTitle == "Cyrus Workflows")
            #expect(source.marketplaceTitle == "Agent Tooling")
        }
        #expect(ConnectionSource.title("openai-curated-remote") == "OpenAI Curated Remote")
        #expect(ConnectionSource.title("github-mcp") == "GitHub MCP")
        for value in [
            "Personal", "https://user@example.com/mcp", "/tmp/plugin@marketplace", "codex:claude:plugin@marketplace",
            "plugin@marketplace@other",
        ] {
            #expect(ConnectionSource(value).plugin == nil)
            #expect(ConnectionSource(value).marketplace == nil)
        }
    }

    @Test func displayNamesOnlyLoseTheirOwnCatalogSuffix() {
        let identifier = "cyrus-workflows@agent-tooling"
        #expect(ConnectionSource.pluginName(identifier, identifier: identifier) == "Cyrus Workflows")
        #expect(ConnectionSource.pluginName("Cyrus Workflows@Agent Tooling", identifier: identifier) == "Cyrus Workflows")
        #expect(ConnectionSource.pluginName("Cyrus", identifier: identifier) == "Cyrus")
        #expect(
            ConnectionSource.pluginName("Cyrus Workflows@Another Marketplace", identifier: identifier)
                == "Cyrus Workflows@Another Marketplace")
        #expect(ConnectionSource.pluginName("Team@example.com", identifier: "unqualified") == "Team@example.com")
    }

    @Test func managedDefinitionsAreNotMisidentifiedAsPluginOrClientSources() {
        let managed = MCPServer(
            id: "docs", name: "Docs", summary: "My docs", endpoint: "docs@company", transport: .stdio,
            authentication: "None", scope: "This Mac", clients: [], definitionOrigin: .managed)
        let origin = ConnectionSource(server: managed)
        #expect(origin.source == "Local library")
        #expect(origin.plugin == nil)
        #expect(origin.marketplace == nil)
        #expect(ConnectionSource("Codex CLI configuration").source == "Codex")
        #expect(ConnectionSource("https://example.com/mcp").source == "Not recorded")
    }
}
