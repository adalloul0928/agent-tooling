import Foundation
import Testing

@testable import AgentToolingCore

/// The commands that add Agent Tooling's own connection to each app, with the
/// helper's path and the space in it, are ones the executor's allowlist runs:
/// at the place the locator found each app's tool, as a reviewed plan carries
/// it. So is the remove a replacement runs first (D30). S11 shows these
/// commands and S12 runs them, so a refusal here would be a review that
/// cannot install what it lists.
@Suite("Operation command policy · Agent Tooling's own connection")
struct OperationCommandPolicyAgentToolingConnectionTests {
    static let helpers = [
        "/Applications/Agent Tooling.app/Contents/Helpers/agent-tooling-mcp",
        "/Users/example/Applications/Agent Tooling.app/Contents/Helpers/agent-tooling-mcp",
    ]

    @Test(arguments: ClientKind.allCases)
    func eachAppsAddAndRemoveRunAtTheLocatedTool(client: ClientKind) throws {
        let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
            .appending(path: "connection-policy-\(UUID())", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        let home = root.appending(path: "home", directoryHint: .isDirectory)
        let tool = home.appending(path: ".local/bin").appending(path: ClientExecutableLocator.executableName(for: client))
        try FileManager.default.createDirectory(at: tool.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("#!/bin/sh\n".utf8).write(to: tool)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: tool.path)
        let policy = OperationCommandPolicy(
            libraryURL: root.appending(path: "library", directoryHint: .isDirectory),
            gitBackupRoot: root.appending(path: "backup", directoryHint: .isDirectory), homeURL: home)
        let located = try #require(ClientExecutableLocator.locate(client, homeURL: home)).path

        for helper in Self.helpers {
            let add = AgentToolingConnection.previewArguments(client: client, helperPath: helper)
            #expect(add.contains(helper), "the path is one argument, its space and all")
            #expect(throws: Never.self, "\(client) \(add.joined(separator: " "))") {
                try policy.validate(executable: located, arguments: add)
            }
        }
        let remove = MCPClientCommand.removeArguments(serverID: AgentToolingConnection.declaredName, client: client, scope: .user)
        #expect(throws: Never.self, "\(client) \(remove.joined(separator: " "))") {
            try policy.validate(executable: located, arguments: remove)
        }
    }
}
