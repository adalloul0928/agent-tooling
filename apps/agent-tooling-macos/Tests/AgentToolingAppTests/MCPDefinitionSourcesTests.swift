import Testing

@testable import AgentToolingApp
@testable import AgentToolingCore

/// The Connections detail says where each app gets a server by one name.
@Suite("MCP definition sources")
@MainActor
struct MCPDefinitionSourcesTests {
    @Test func eachAppListsEveryPlaceItGetsTheServer() {
        var claude = ShellRenderFixture.observation(.claudeCode, installed: true, commandAvailable: true)
        claude.mcpMetadata = [
            "builder-mcp": .init(
                transport: "stdio", authentication: "", source: "WootAICapabilities-all@aim",
                additionalSources: ["AtlasAICapabilities-all@aim", "Claude Code configuration"])
        ]
        var codex = ShellRenderFixture.observation(.codexCLI, installed: true, commandAvailable: true)
        codex.mcpMetadata = ["builder-mcp": .init(transport: "stdio", authentication: "", source: "Codex native MCP inventory")]
        let kiro = ShellRenderFixture.observation(.kiroCLI, installed: true, commandAvailable: true)

        let found = MCPDefinitionSources.found(named: "builder-mcp", in: [kiro, codex, claude])
        #expect(found.map(\.client) == [.claude, .codex], "an app without it is not listed")
        #expect(found.first?.sources.count == 3)
        #expect(MCPDefinitionSources.found(named: nil, in: [claude]).isEmpty, "no declared name, no guess")
        #expect(MCPDefinitionSources.label("WootAICapabilities-all@aim") == "WootAICapabilities All · Aim")
        #expect(MCPDefinitionSources.label("Claude Code configuration") == "Claude Code configuration")
    }
}
