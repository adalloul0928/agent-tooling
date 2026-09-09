import Foundation
import Testing

@testable import AgentToolingCore

private struct MCPRuntimeRunnerStub: CommandRunning {
    var versionResult: CommandOutput
    var listResult: CommandOutput

    func run(executable: String, arguments: [String], currentDirectory: URL?) async throws -> CommandOutput {
        #expect(executable == "thv")
        if arguments == ["version", "--format", "json"] { return versionResult }
        #expect(arguments == ["list", "--all", "--format", "json"])
        return listResult
    }
}

struct MCPRuntimeTests {
    @Test func directRuntimeIsAlwaysAvailableWithoutOwningServerLifecycle() async throws {
        let provider = DirectMCPRuntimeProvider()

        let status = await provider.status()

        #expect(status.isAvailable)
        #expect(status.capabilities == [.directConfiguration])
        #expect(try await provider.servers().isEmpty)
    }

    @Test func toolHiveDiscoveryDegradesCleanlyAndMapsReadOnlyWorkloads() async throws {
        let unavailable = ToolHiveMCPRuntimeProvider(
            runner: MCPRuntimeRunnerStub(
                versionResult: CommandOutput(status: 127, standardOutput: "", standardError: "command not found"),
                listResult: CommandOutput(status: 1, standardOutput: "", standardError: "unused")
            ))
        #expect(await unavailable.status().isAvailable == false)
        #expect(try await unavailable.servers().isEmpty)

        let workloadJSON = #"""
            [{
              "name": "filesystem",
              "package": "ghcr.io/example/filesystem:1.0.0",
              "url": "http://127.0.0.1:3000",
              "transport_type": "stdio",
              "status": "running",
              "group": "local",
              "remote": false
            }]
            """#
        let available = ToolHiveMCPRuntimeProvider(
            runner: MCPRuntimeRunnerStub(
                versionResult: CommandOutput(status: 0,
                    standardOutput: #"{"version":"0.34.0","commit":"abc","build_date":"fixture","go_version":"go1.25","platform":"darwin/arm64"}"#,
                    standardError: ""),
                listResult: CommandOutput(status: 0, standardOutput: workloadJSON, standardError: "")
            ))

        let servers = try await available.servers()

        #expect(servers.count == 1)
        #expect(servers.first?.name == "filesystem")
        #expect(servers.first?.status == "running")
        #expect(servers.first?.transport == "stdio")
    }
}
