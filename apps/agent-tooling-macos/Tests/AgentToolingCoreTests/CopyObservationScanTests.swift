import Foundation
import Testing

@testable import AgentToolingCore

/// What a device check records so copies can be told apart later: who put a
/// loose folder there, what each folder holds, and every place a client gets
/// one server name from.
struct CopyObservationScanTests {
    private struct ScriptedRunner: CommandRunning {
        let pluginList: String

        func run(executable: String, arguments: [String], currentDirectory: URL?) async throws -> CommandOutput {
            if arguments == ["--version"] { return CommandOutput(status: 0, standardOutput: "1.0.0", standardError: "") }
            if arguments == ["plugin", "list", "--json"] {
                return CommandOutput(status: 0, standardOutput: pluginList, standardError: "")
            }
            return CommandOutput(status: 127, standardOutput: "", standardError: "not found")
        }
    }

    @Test func aServerFromTheConfigurationAndTwoPluginsKeepsEverySource() async throws {
        let home = try temporaryHome()
        defer { try? FileManager.default.removeItem(at: home) }
        try #"{"mcpServers":{"builder":{"command":"builder-mcp"}}}"#
            .write(to: home.appending(path: ".claude.json"), atomically: true, encoding: .utf8)
        let plugins = #"""
            [
              {"id": "Example-all@example", "installPath": "cache", "mcpServers": {"builder": {"command": "builder-mcp", "args": ["--a"]}}},
              {"id": "Additional-all@example", "installPath": "cache", "mcpServers": {"builder": {"command": "builder-mcp", "args": ["--b"]}}}
            ]
            """#

        let observation = await ClaudeCodeAdapter().scan(homeURL: home, runner: ScriptedRunner(pluginList: plugins))

        let builder = try #require(observation.mcpMetadata["builder"])
        #expect(Set(builder.allSources) == ["Example-all@example", "Additional-all@example", "Claude Code configuration"])
        try WorkspaceSnapshotValidator.validate(observation)
    }

    @Test func standaloneKiroSkillsHaveContentDigestsWithoutAnExternalManager() async throws {
        let home = try temporaryHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let skills = home.appending(path: ".kiro/skills", directoryHint: .isDirectory)
        for name in ["build", "mine"] {
            let folder = skills.appending(path: name, directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try "---\nname: \(name)\ndescription: d\n---\n".write(to: folder.appending(path: "SKILL.md"), atomically: true, encoding: .utf8)
        }

        let observation = await KiroCLIAdapter().scan(homeURL: home, runner: ScriptedRunner(pluginList: "[]"))

        let build = try #require(observation.skillMetadata["build"])
        #expect(build.externalManager == nil)
        #expect(build.definitionDigest?.count == 64)
        #expect(observation.skillMetadata["mine"]?.externalManager == nil, "a folder nothing claims stays loose")
        try WorkspaceSnapshotValidator.validate(observation)
    }

    private func temporaryHome() throws -> URL {
        let url = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
            .appending(path: "CopyObservationScanTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
