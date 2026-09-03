import Foundation
import Testing

@testable import AgentToolingCore

private func managedServer(endpoint: String, transport: MCPTransport) -> MCPServer {
    MCPServer(
        id: "fixture",
        name: "Fixture",
        summary: "Managed by Agent Tooling",
        endpoint: endpoint,
        transport: transport,
        authentication: "None",
        scope: "This Mac",
        clients: [],
        definitionOrigin: .managed
    )
}

private struct TemporaryTree {
    let root: URL

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appending(path: "mcp-policy-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    func makeExecutable(named name: String) throws -> URL {
        let url = root.appending(path: name, directoryHint: .notDirectory)
        try Data("#!/bin/echo\n".utf8).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path(percentEncoded: false))
        return url
    }

    func remove() {
        try? FileManager.default.removeItem(at: root)
    }
}

struct MCPTestConnectionPolicyTests {
    // MARK: What is refused before anything runs

    @Test func aDiscoveredDefinitionIsNeverGuessedIntoACommand() {
        let observed = MCPServer(
            id: "observed",
            name: "Observed",
            summary: "Discovered from ~/.claude.json.",
            endpoint: "~/.claude.json",
            transport: .stdio,
            authentication: "Not inferred",
            scope: "This Mac",
            clients: [],
            definitionOrigin: .observed
        )

        #expect(throws: MCPLiveTestError.self) { try MCPTestConnectionPolicy.resolve(server: observed) }
    }

    @Test func shellsAndPrivilegeWrappersAreRefusedSoTheShownLineIsTheProgramThatRuns() throws {
        let tree = try TemporaryTree()
        defer { tree.remove() }

        for wrapper in ["sh", "bash", "zsh", "env", "sudo", "xargs", "osascript", "nohup", "ssh", "arch"] {
            let server = managedServer(endpoint: "/bin/\(wrapper) -c 'node server.js'", transport: .stdio)
            #expect(
                throws: MCPLiveTestError.executableNotPermitted(wrapper),
                "\(wrapper) must be refused"
            ) {
                try MCPTestConnectionPolicy.resolve(server: server, homeURL: tree.root)
            }
        }
    }

    @Test func aSymlinkIntoAShellIsRefusedAfterResolutionNotBeforeIt() throws {
        let tree = try TemporaryTree()
        defer { tree.remove() }
        let disguised = tree.root.appending(path: "mcp-server", directoryHint: .notDirectory)
        try FileManager.default.createSymbolicLink(at: disguised, withDestinationURL: URL(fileURLWithPath: "/bin/sh"))
        let server = managedServer(endpoint: disguised.path(percentEncoded: false), transport: .stdio)

        #expect(throws: MCPLiveTestError.executableNotPermitted("sh")) {
            try MCPTestConnectionPolicy.resolve(server: server, homeURL: tree.root)
        }
    }

    @Test func aMissingProgramFailsRatherThanFallingBackToAShell() throws {
        let tree = try TemporaryTree()
        defer { tree.remove() }
        let server = managedServer(
            endpoint: tree.root.appending(path: "not-installed").path(percentEncoded: false),
            transport: .stdio
        )

        #expect(throws: MCPLiveTestError.self) { try MCPTestConnectionPolicy.resolve(server: server, homeURL: tree.root) }
    }

    @Test func anInlineSecretInTheCommandNeverReachesTheTestConnection() throws {
        let tree = try TemporaryTree()
        defer { tree.remove() }
        let executable = try tree.makeExecutable(named: "mcp-fixture")
        let server = managedServer(
            endpoint: "\(executable.path(percentEncoded: false)) --api-key sk-EXAMPLE-NOT-A-REAL-KEY",
            transport: .stdio
        )

        #expect(throws: MCPDefinitionValidationError.inlineSecret) {
            try MCPTestConnectionPolicy.resolve(server: server, homeURL: tree.root)
        }
    }

    // MARK: What is allowed

    @Test func aNamedProgramResolvesToTheExactFileThatWillRun() throws {
        let tree = try TemporaryTree()
        defer { tree.remove() }
        let executable = try tree.makeExecutable(named: "mcp-fixture")
        let server = managedServer(endpoint: "\(executable.path(percentEncoded: false)) --stdio", transport: .stdio)

        let target = try MCPTestConnectionPolicy.resolve(server: server, homeURL: tree.root)

        guard case .stdio(let resolved, let arguments) = target else {
            Issue.record("Expected a stdio target")
            return
        }
        #expect(resolved.lastPathComponent == "mcp-fixture")
        #expect(arguments == ["--stdio"])
        #expect(target.isProcessLaunch)
        #expect(target.displayCommand.hasSuffix("mcp-fixture --stdio"))
    }

    @Test func plaintextHTTPIsAllowedOnlyToThisMac() throws {
        let secure = managedServer(endpoint: "https://mcp.example.com/rpc", transport: .http)
        let loopback = managedServer(endpoint: "http://127.0.0.1:8931/mcp", transport: .http)
        let remotePlaintext = managedServer(endpoint: "http://mcp.example.com/rpc", transport: .http)

        let secureTarget = try MCPTestConnectionPolicy.resolve(server: secure)
        let loopbackTarget = try MCPTestConnectionPolicy.resolve(server: loopback)

        #expect(secureTarget == .http(url: URL(string: "https://mcp.example.com/rpc") ?? URL(fileURLWithPath: "/")))
        #expect(loopbackTarget == .http(url: URL(string: "http://127.0.0.1:8931/mcp") ?? URL(fileURLWithPath: "/")))
        #expect(secureTarget.isProcessLaunch == false)
        #expect(secureTarget.displayCommand == "POST https://mcp.example.com/rpc")
        #expect(throws: MCPLiveTestError.self) { try MCPTestConnectionPolicy.resolve(server: remotePlaintext) }
    }

    @Test func loopbackDetectionCoversTheNamesAMCPServerActuallyUses() {
        for host in ["localhost", "127.0.0.1", "::1", "[::1]", "api.localhost"] {
            #expect(MCPTestConnectionPolicy.isLoopbackHost(host), "\(host) is this Mac")
        }
        for host in ["example.com", "127.0.0.1.example.com", "localhost.example.com"] {
            #expect(!MCPTestConnectionPolicy.isLoopbackHost(host), "\(host) is not this Mac")
        }
    }

    // MARK: The environment handed to a tested server

    @Test func theChildEnvironmentIsBuiltFromNothingSoNoExportedSecretRidesAlong() {
        let environment = MCPTestConnectionPolicy.childEnvironment(
            homeURL: URL(fileURLWithPath: "/Users/example"),
            temporaryDirectory: URL(fileURLWithPath: "/tmp/example")
        )

        #expect(Set(environment.keys) == ["PATH", "HOME", "TMPDIR", "LANG", "USER", "LOGNAME", "MCP_TEST_CONNECTION"])
        #expect(environment["HOME"] == "/Users/example")
        #expect(environment["PATH"]?.contains("/Users/example/.local/bin") == true)
        // Whatever the app itself was launched with must not be visible here.
        for key in ProcessInfo.processInfo.environment.keys where !environment.keys.contains(key) {
            #expect(environment[key] == nil)
        }
    }

    @Test func theConsentSummaryNamesWhatIsAboutToHappen() throws {
        let tree = try TemporaryTree()
        defer { tree.remove() }
        let executable = try tree.makeExecutable(named: "mcp-fixture")
        let stdio = try MCPTestConnectionPolicy.resolveStdio(
            [executable.path(percentEncoded: false)],
            homeURL: tree.root
        )
        let http = try MCPTestConnectionPolicy.resolveHTTP("https://mcp.example.com/rpc")

        #expect(MCPTestConnectionPolicy.consentSummary(for: stdio, serverName: "Fixture").contains("start this program"))
        #expect(MCPTestConnectionPolicy.consentSummary(for: http, serverName: "Fixture").contains("mcp.example.com"))
    }
}
