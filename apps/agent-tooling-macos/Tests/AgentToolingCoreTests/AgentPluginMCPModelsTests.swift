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

    @Test func rootAwareLoadingSkipsOnlyEscapingPluginRelativeServers() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "mcp-root-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root.appending(path: "bin"), withIntermediateDirectories: true)
        try Data().write(to: root.appending(path: "bin/server"))
        try FileManager.default.createSymbolicLink(at: root.appending(path: "bin/inside-link"), withDestinationURL: root.appending(path: "bin/server"))
        let outside = root.deletingLastPathComponent().appending(path: "mcp-outside-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: outside) }
        try Data().write(to: outside)
        try FileManager.default.createSymbolicLink(at: root.appending(path: "bin/escape"), withDestinationURL: outside)
        let data = Data("""
        {"$schema":"https://agent-plugins.org/schemas/1.0.0/mcp.schema.json","mcpServers":{
        "bare":{"type":"stdio","command":"node"},
        "inside":{"type":"stdio","command":"./bin/server","cwd":"${PLUGIN_ROOT}"},
        "insideLink":{"type":"stdio","command":"./bin/inside-link"},
        "escape":{"type":"stdio","command":"./bin/escape"},
        "cwdEscape":{"type":"stdio","command":"node","cwd":"./bin/escape"}}}
        """.utf8)

        let result = try AgentPluginMCPConfigurationLoader.load(data, packageRoot: root)

        #expect(result.servers.keys.sorted() == ["bare", "inside", "insideLink"])
        #expect(result.issues.map(\.serverName).sorted() == ["cwdEscape", "escape"])
    }
}
