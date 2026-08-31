import Foundation
import Testing

@testable import AgentToolingCore

struct AgentPluginMCPModelsTests {
    @Test func loadsValidServersAndSkipsOneInvalidEntry() throws {
        let data = Data(
            """
            {
              "$schema": "https://agent-plugins.org/schemas/1.0.0/mcp.schema.json",
              "mcpServers": {
                "local": {"type":"stdio","command":"./bin/server","args":["--data","${PLUGIN_DATA}/db"]},
                "remote": {"type":"streamable-http","url":"https://example.com/mcp","headers":{"X-Tenant":"public"}},
                "unsafe": {"type":"stdio","command":"sh -c echo unsafe"}
              }
            }
            """.utf8)

        let result = try AgentPluginMCPConfigurationLoader.load(data)

        #expect(result.servers.keys.sorted() == ["local", "remote"])
        #expect(result.issues.count == 1)
        #expect(result.issues.first?.serverName == "unsafe")
    }

    @Test func rejectsInvalidTopLevelAndPortableCredentials() throws {
        let extraField = Data(
            """
            {"$schema":"https://agent-plugins.org/schemas/1.0.0/mcp.schema.json","mcpServers":{},"extra":true}
            """.utf8)
        #expect(throws: AgentPluginMCPValidationError.self) {
            _ = try AgentPluginMCPConfigurationLoader.load(extraField)
        }

        let credential = Data(
            """
            {
              "$schema":"https://agent-plugins.org/schemas/1.0.0/mcp.schema.json",
              "mcpServers":{"remote":{"type":"streamable-http","url":"https://example.com/mcp","headers":{"Authorization":"Bearer secret"}}}
            }
            """.utf8)
        let result = try AgentPluginMCPConfigurationLoader.load(credential)
        #expect(result.servers.isEmpty)
        #expect(result.issues.first?.message.contains("credentials") == true)
    }

    @Test func allowsOnlyHttpsOrLoopbackHTTP() throws {
        let data = Data(
            """
            {
              "$schema":"https://agent-plugins.org/schemas/1.0.0/mcp.schema.json",
              "mcpServers":{
                "local":{"type":"streamable-http","url":"http://127.0.0.1:8787/mcp"},
                "public":{"type":"streamable-http","url":"http://example.com/mcp"}
              }
            }
            """.utf8)
        let result = try AgentPluginMCPConfigurationLoader.load(data)
        #expect(result.servers.keys.sorted() == ["local"])
        #expect(result.issues.first?.serverName == "public")
    }
}
