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
        #expect(ConnectionSource("Claude Code configuration").source == "Claude")
    }
}
