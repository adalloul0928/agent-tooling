import AgentToolingTestSupport
import Foundation
import Testing

@testable import AgentToolingCore

/// A Codex app server played from a script: it answers each allowed method
/// with a canned result, can chatter between replies the way the real one
/// does, and records every line it was sent.
actor ScriptedAppServer: CodexAppServerTransport {
    private(set) var sent: [JSONValue] = []
    private(set) var isClosed = false
    private var queue: [Data] = []
    private let answers: [String: JSONValue]
    private let errors: [String: String]
    private let silent: Set<String>
    private let raw: [String: String]
    private let chatter: Bool

    init(
        answers: [String: JSONValue] = [:], errors: [String: String] = [:], silent: Set<String> = [],
        raw: [String: String] = [:], chatter: Bool = false
    ) {
        self.answers = answers
        self.errors = errors
        self.silent = silent
        self.raw = raw
        self.chatter = chatter
    }

    var sentMethods: [String] { sent.compactMap { $0["method"]?.stringValue } }

    func send(_ line: Data) async throws {
        guard !isClosed else { throw CodexAppServerError.stopped("closed") }
        let message = try AgentToolingCoding.decoder().decode(JSONValue.self, from: line)
        sent.append(message)
        guard case .number(let id)? = message["id"], let method = message["method"]?.stringValue,
            !silent.contains(method)
        else { return }
        if chatter {
            queue.append(Data(#"{"method":"remoteControl/status/changed","params":{"status":"disabled"}}"#.utf8))
            queue.append(Data(#"{"id":99,"method":"item/tool/requestUserInput","params":{}}"#.utf8))
            queue.append(Data("not json at all".utf8))
            queue.append(Data(#"{"id":12345,"result":{}}"#.utf8))
        }
        if let line = raw[method] {
            queue.append(Data(line.replacingOccurrences(of: "{ID}", with: String(Int(id))).utf8))
        } else if let message = errors[method] {
            queue.append(
                try AgentToolingCoding.encoder().encode(
                    JSONValue.object([
                        "id": .number(id), "error": .object(["code": .number(-32_600), "message": .string(message)]),
                    ])))
        } else {
            queue.append(
                try AgentToolingCoding.encoder().encode(
                    JSONValue.object([
                        "id": .number(id), "result": answers[method] ?? .object([:]),
                    ])))
        }
    }

    func receive() async throws -> Data? {
        while queue.isEmpty {
            if isClosed { return nil }
            try await Task.sleep(for: .milliseconds(2))
        }
        return queue.removeFirst()
    }

    func diagnostics() async -> String { "scripted" }

    func close() async { isClosed = true }

    func stop() { isClosed = true }
}

@Suite("Accounts · the Codex app server, read only")
struct CodexAppServerSessionTests {
    /// Every method that changes something is refused before a byte is
    /// written, so the account view cannot edit a configuration, install a
    /// plugin, or start a model turn even by mistake.
    @Test(arguments: [
        "config/value/write", "config/batchWrite", "plugin/install", "plugin/uninstall", "plugin/list",
        "turn/start", "thread/start", "mcpServer/tool/call", "skills/config/write", "account/login/start",
    ])
    func aMethodThatChangesThingsIsNeverSent(method: String) async throws {
        let server = ScriptedAppServer()
        let session = CodexAppServerSession(transport: server)
        await #expect(throws: CodexAppServerError.notAllowed(method)) {
            _ = try await session.request(method)
        }
        #expect(await server.sent.isEmpty)
    }

    @Test func onlyTheHandshakeNotificationIsSent() async throws {
        let server = ScriptedAppServer()
        let session = CodexAppServerSession(transport: server)
        await #expect(throws: CodexAppServerError.notAllowed("exit")) { try await session.notify("exit") }
        try await session.notify("initialized")
        #expect(await server.sentMethods == ["initialized"])
    }

    @Test func theHandshakeIntroducesTheClientAndThenSaysItIsReady() async throws {
        let server = ScriptedAppServer(answers: ["initialize": .object(["userAgent": .string("agent_tooling/0.162.1")])])
        let session = CodexAppServerSession(transport: server)
        let hello = try await session.initialize(clientName: "agent_tooling", clientTitle: "Agent Tooling", version: "3")
        #expect(hello["userAgent"]?.stringValue == "agent_tooling/0.162.1")
        let sent = await server.sent
        #expect(sent.count == 2)
        #expect(sent[0]["method"]?.stringValue == "initialize")
        #expect(sent[0]["params"]?["clientInfo"]?["name"]?.stringValue == "agent_tooling")
        #expect(sent[1]["method"]?.stringValue == "initialized")
        #expect(sent[1]["id"] == nil, "a notification carries no id")
    }

    /// The real server writes notifications, asks the client things, and the
    /// odd line that is not JSON, between replies. Only the matching id is
    /// the answer.
    @Test func everythingButTheMatchingReplyIsPassedOver() async throws {
        let server = ScriptedAppServer(answers: ["account/read": .object(["requiresOpenaiAuth": .bool(true)])], chatter: true)
        let session = CodexAppServerSession(transport: server)
        let result = try await session.request("account/read")
        #expect(result["requiresOpenaiAuth"]?.boolValue == true)
        let second = try await session.request("config/read")
        #expect(second == .object([:]))
    }

    @Test func aServerErrorIsReportedAndRedacted() async throws {
        let server = ScriptedAppServer(errors: ["app/list": "Bearer sk-abcdefghijklmnopqrstuvwxyz was refused"])
        let session = CodexAppServerSession(transport: server)
        do {
            _ = try await session.request("app/list")
            Issue.record("expected an error")
        } catch let error as CodexAppServerError {
            guard case .serverError(let method, let message) = error else {
                Issue.record("wrong error \(error)")
                return
            }
            #expect(method == "app/list")
            #expect(!message.contains("sk-abcdefghij"))
        }
    }

    @Test func aReplyWithoutAResultIsMalformed() async throws {
        let server = ScriptedAppServer(raw: ["app/installed": #"{"id":{ID}}"#])
        let session = CodexAppServerSession(transport: server)
        await #expect(throws: CodexAppServerError.malformedResponse("app/installed")) {
            _ = try await session.request("app/installed")
        }
    }

    @Test func aServerThatStopsIsReported() async throws {
        let server = ScriptedAppServer(silent: ["account/read"])
        let session = CodexAppServerSession(transport: server, requestTimeout: .seconds(5))
        Task {
            try await Task.sleep(for: .milliseconds(20))
            await server.stop()
        }
        await #expect(throws: CodexAppServerError.stopped("scripted")) {
            _ = try await session.request("account/read")
        }
    }

    /// A server that never answers is cut off at the deadline and closed, so
    /// a slow Codex cannot hold the screen.
    @Test func aSilentServerTimesOutAndIsClosed() async throws {
        let server = ScriptedAppServer(silent: ["app/list"])
        let session = CodexAppServerSession(transport: server, requestTimeout: .milliseconds(50))
        await #expect(throws: CodexAppServerError.timedOut("app/list")) {
            _ = try await session.request("app/list")
        }
        #expect(await server.isClosed)
        await #expect(throws: CodexAppServerError.stopped("")) { _ = try await session.request("account/read") }
    }
}

// MARK: - The Codex reader

@Suite("Accounts · reading the ChatGPT account through Codex")
struct CodexAccountReaderTests {
    static let home = URL(filePath: "/Users/example", directoryHint: .isDirectory)

    static func reader(_ server: ScriptedAppServer, locate: URL? = URL(filePath: "/opt/homebrew/bin/codex")) -> CodexAccountReader {
        CodexAccountReader(
            homeURL: home, locate: { _, _ in locate },
            makeSession: { _, _ in CodexAppServerSession(transport: server) })
    }

    static func answers(account: String, config: String? = nil, apps: String? = nil, installed: String? = nil) throws -> [String: JSONValue]
    {
        var answers: [String: JSONValue] = [
            "initialize": try AccountSurfaceParsingTests.json(#"{"userAgent":"agent_tooling/0.162.1 (Mac OS 26.7.1; arm64)"}"#),
            "account/read": try AccountSurfaceParsingTests.json(account),
            "config/read": try AccountSurfaceParsingTests.json(
                config ?? """
                    {"config":{},"layers":[{"name":{"type":"user","file":"/Users/example/.codex/config.toml"},"config":{}}]}
                    """),
        ]
        if let apps { answers["app/list"] = try AccountSurfaceParsingTests.json(apps) }
        if let installed { answers["app/installed"] = try AccountSurfaceParsingTests.json(installed) }
        return answers
    }

    @Test func aChatGPTAccountsAppsAreListedWithTheirState() async throws {
        let server = ScriptedAppServer(
            answers: try Self.answers(
                account: #"{"account":{"type":"chatgpt","email":"me@example.com","planType":"plus"},"requiresOpenaiAuth":true}"#,
                config: """
                    {"config":{"apps":{"slack":{"enabled":false}}},
                     "layers":[{"name":{"type":"user","file":"/Users/example/.codex/config.toml"},
                                "config":{"apps":{"slack":{"enabled":false}}}}]}
                    """,
                apps: """
                    {"data":[
                      {"id":"github","name":"GitHub","description":"Code.","isAccessible":true,"isEnabled":true,
                       "installUrl":"https://chatgpt.com/apps/github/github"},
                      {"id":"slack","name":"Slack","isAccessible":true,"isEnabled":false},
                      {"id":"drive","name":"Google Drive","isAccessible":true,"isEnabled":true},
                      {"id":"linear","name":"Linear","isAccessible":true,"isEnabled":true},
                      {"id":"figma","name":"Figma","isAccessible":false,"isEnabled":true},
                      {"id":"notion","name":"Notion","isAccessible":false,"isEnabled":true}
                    ],"nextCursor":null}
                    """,
                installed: """
                    {"apps":[{"id":"github","enabled":true,"callable":true},
                             {"id":"slack","enabled":false,"callable":false},
                             {"id":"drive","enabled":false,"callable":false},
                             {"id":"linear","enabled":true,"callable":false}]}
                    """))
        let observation = await Self.reader(server).read(contents: true, now: Date(timeIntervalSince1970: 1_000))
        #expect(observation.unavailableReason == nil)
        #expect(observation.clientVersion == "0.162.1")
        #expect(observation.signIn?.method == .subscription)
        #expect(observation.contentsRead)
        let apps = observation.items(.app)
        #expect(apps.map(\.name) == ["GitHub", "Google Drive", "Linear", "Slack"])
        #expect(apps.first { $0.key == "github" }?.state.tone == .ready)
        #expect(apps.first { $0.key == "slack" }?.state.tone == .off)
        #expect(apps.first { $0.key == "slack" }?.detail?.contains("config.toml") == true)
        #expect(apps.first { $0.key == "linear" }?.state.tone == .attention)
        #expect(observation.directoryCount == 2, "apps not on the account are counted, not listed")
        #expect(observation.fileValues == [.init(.app, subject: "slack"): .off])
        // Drive is off at runtime while config.toml says nothing: a policy did
        // it, and editing the file would not change that.
        #expect(observation.constrained[.init(.app, subject: "drive")] != nil)
        #expect(observation.constrained[.init(.app, subject: "slack")] == nil)
        #expect(await server.sentMethods == ["initialize", "initialized", "account/read", "config/read", "app/list", "app/installed"])
        #expect(await server.isClosed, "the server is stopped once read")
    }

    /// Codex on a third-party provider lists no ChatGPT apps, so the reader
    /// does not ask it to.
    @Test func noAppsAreAskedForWithoutAChatGPTSignIn() async throws {
        let server = ScriptedAppServer(
            answers: try Self.answers(
                account: #"{"account":{"type":"amazonBedrock"},"requiresOpenaiAuth":false}"#))
        let observation = await Self.reader(server).read(contents: true)
        #expect(observation.signIn?.method == .thirdParty)
        #expect(observation.items.isEmpty)
        #expect(observation.notes.contains { $0.contains("ChatGPT apps reach Codex only when it signs in with ChatGPT") })
        #expect(await !server.sentMethods.contains("app/list"))
    }

    @Test func aLightReadAsksOnlyHowCodexSignsIn() async throws {
        let server = ScriptedAppServer(
            answers: try Self.answers(
                account: #"{"account":{"type":"chatgpt","email":"me@example.com"},"requiresOpenaiAuth":true}"#))
        let observation = await Self.reader(server).read(contents: false)
        #expect(!observation.contentsRead)
        #expect(observation.signIn?.method == .subscription)
        #expect(await server.sentMethods == ["initialize", "initialized", "account/read", "config/read"])
    }

    @Test func aConfigurationFolderThisAppDoesNotEditBlocksWrites() async throws {
        let server = ScriptedAppServer(
            answers: try Self.answers(
                account: #"{"account":{"type":"chatgpt"},"requiresOpenaiAuth":true}"#,
                config: #"{"config":{},"layers":[{"name":{"type":"user","file":"/Volumes/other/codex/config.toml"},"config":{}}]}"#))
        let observation = await Self.reader(server).read(contents: false)
        #expect(observation.writeBlocker?.contains("/Volumes/other/codex/config.toml") == true)
    }

    @Test func aMissingCodexIsReportedRatherThanRead() async {
        let observation = await Self.reader(ScriptedAppServer(), locate: nil).read(contents: true)
        #expect(observation.unavailableReason?.contains("not found") == true)
        #expect(!observation.contentsRead)
    }

    @Test func aServerThatRefusesTheHandshakeIsUnavailable() async {
        let server = ScriptedAppServer(errors: ["initialize": "unsupported client"])
        let observation = await Self.reader(server).read(contents: true)
        #expect(observation.unavailableReason?.contains("unsupported client") == true)
        #expect(observation.signIn == nil)
    }
}

// MARK: - The Claude reader

/// The scripted runner for these suites is the shared `ScriptedCommandRunner`
/// (answers by exact argument list, records calls, unscripted calls return
/// status 1).

@Suite("Accounts · reading the claude.ai account through Claude Code")
struct ClaudeAccountReaderTests {
    struct Home {
        let root: URL
        let home: URL
        let managed: URL

        init() throws {
            root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
                .appending(path: "claude-account-\(UUID())", directoryHint: .isDirectory)
            home = root.appending(path: "home", directoryHint: .isDirectory)
            managed = root.appending(path: "managed-settings.json")
            try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        }

        func write(_ relative: String, _ text: String) throws {
            try AccountSurfaceParsingTests.write(home.appending(path: relative), text)
        }

        func remove() { try? FileManager.default.removeItem(at: root) }

        func authStatus(_ method: String = "claude.ai", configDirectory: String? = nil) -> String {
            let directory = configDirectory ?? home.appending(path: ".claude").path(percentEncoded: false)
            return """
                {"loggedIn":true,"authMethod":"\(method)","email":"me@example.com","orgId":"org-1",\
                "orgName":"Example","subscriptionType":"max","configDirectory":"\(directory)"}
                """
        }
    }

    static let pluginList = """
        [{"id":"personal@agent-tooling","installPath":"/x","enabled":true},
         {"id":"design@synced","installPath":"/p/design","enabled":true,"version":"2.0.0","mcpServers":{"figma":{}}},
         {"id":"notes@synced","installPath":"/p/notes","enabled":false}]
        """

    static let mcpList = """
        Checking MCP server health…

        personal-server: npx personal - ✔ Connected
        claude.ai Google Calendar: https://gcal.example.com/mcp - ! Needs authentication
        claude.ai Drive: https://drive.example.com/mcp - ✔ Connected
        """

    func reader(_ home: Home, runner: ScriptedCommandRunner, located: Bool = true) -> ClaudeAccountReader {
        ClaudeAccountReader(
            runner: runner, homeURL: home.home,
            locate: { _, _ in located ? URL(filePath: "/opt/homebrew/bin/claude") : nil },
            managedSettingsURL: home.managed)
    }

    @Test func theAccountsConnectorsPluginsAndSkillsAreRead() async throws {
        let home = try Home()
        defer { home.remove() }
        try home.write(
            ".claude/settings.json",
            """
            {"deniedMcpServers":[{"serverName":"claude.ai Gmail"}],"enabledPlugins":{"notes@synced":false}}
            """)
        try home.write(".claude/skills/synced/pdf/SKILL.md", "---\nname: pdf\ndescription: Fill PDF forms.\n---\n")
        try home.write(".claude/skills/review/SKILL.md", "---\nname: review\ndescription: Local, not the account's.\n---\n")
        try Data(#"{"deniedMcpServers":[{"serverName":"claude.ai Slack"}]}"#.utf8).write(to: home.managed)
        let runner = ScriptedCommandRunner(standardOutput: [
            ["--version"]: "2.1.300 (Claude Code)",
            ClaudeAccountCommands.authStatus: home.authStatus(),
            ClaudeAccountCommands.pluginList: Self.pluginList,
            ["mcp", "list"]: Self.mcpList,
        ])

        let observation = await reader(home, runner: runner).read(contents: true)
        #expect(observation.clientVersion == "2.1.300")
        #expect(observation.signIn?.method == .subscription)
        #expect(observation.writeBlocker == nil)
        #expect(observation.contentsRead)

        let connectors = observation.items(.connector)
        #expect(connectors.map(\.name) == ["Drive", "Gmail", "Google Calendar", "Slack"])
        #expect(connectors.first { $0.key == "Google Calendar" }?.state.tone == .attention)
        #expect(connectors.first { $0.key == "Gmail" }?.state.tone == .off, "a denied connector is shown, as off")
        #expect(connectors.first { $0.key == "Slack" }?.detail?.contains("organization") == true)
        #expect(!connectors.contains { $0.key == "personal-server" }, "a local server is not the account's")

        #expect(observation.items(.plugin).map(\.key) == ["design", "notes"])
        #expect(observation.items(.plugin).first { $0.key == "design" }?.facts.contains { $0.contains("figma") } == true)
        #expect(observation.items(.skill).map(\.key) == ["pdf"], "only ~/.claude/skills/synced is the account's")

        #expect(
            observation.fileValues == [
                .init(.connector, subject: "Gmail"): .off, .init(.plugin, subject: "notes"): .off,
            ])
        #expect(observation.switches[.init(.connector, subject: "Slack")] == .off)
        #expect(observation.switches[.init(.plugin, subject: "design")] == .on)
        #expect(observation.constrained[.init(.connector, subject: "Slack")] != nil)
        #expect(observation.constrained[.init(.connector, subject: "Gmail")] == nil)
    }

    /// A light read is for Checkup: how Claude Code signs in and what its
    /// switches say, without health-checking every server.
    @Test func aLightReadDoesNotListOrHealthCheck() async throws {
        let home = try Home()
        defer { home.remove() }
        try home.write(".claude/settings.json", #"{"syncClaudeAiSkills":false}"#)
        let runner = ScriptedCommandRunner(standardOutput: [
            ["--version"]: "2.1.300", ClaudeAccountCommands.authStatus: home.authStatus(),
        ])
        let observation = await reader(home, runner: runner).read(contents: false)
        #expect(!observation.contentsRead)
        #expect(observation.items.isEmpty)
        #expect(observation.switches[.init(.skillSync)] == .off)
        #expect(!(await runner.calls).contains(["mcp", "list"]))
        #expect(!(await runner.calls).contains(ClaudeAccountCommands.pluginList))
    }

    @Test func aSignInThatIsNotTheSubscriptionIsSaid() async throws {
        let home = try Home()
        defer { home.remove() }
        let runner = ScriptedCommandRunner(standardOutput: [
            ClaudeAccountCommands.authStatus: #"{"loggedIn":true,"authMethod":"third_party","apiProvider":"bedrock"}"#,
            ClaudeAccountCommands.pluginList: "[]", ["mcp", "list"]: "",
        ])
        let observation = await reader(home, runner: runner).read(contents: true, shellOverrides: [.claudeBedrock, .codexHome])
        #expect(observation.signIn?.method == .thirdParty)
        #expect(observation.notes.contains { $0.contains("only when it signs in with your claude.ai subscription") })
        #expect(observation.shellOverrides == [.claudeBedrock], "only this provider's overrides")
    }

    @Test func aConfigurationFolderElsewhereBlocksWrites() async throws {
        let home = try Home()
        defer { home.remove() }
        let runner = ScriptedCommandRunner(standardOutput: [
            ClaudeAccountCommands.authStatus: home.authStatus(configDirectory: "/Volumes/work/.claude")
        ])
        let observation = await reader(home, runner: runner).read(contents: false)
        #expect(observation.writeBlocker?.contains("/Volumes/work/.claude") == true)
    }

    @Test func aMissingClaudeCodeIsReportedRatherThanRead() async throws {
        let home = try Home()
        defer { home.remove() }
        let observation = await reader(home, runner: ScriptedCommandRunner(standardOutput: [:]), located: false).read(contents: true)
        #expect(observation.unavailableReason?.contains("not found") == true)
    }
}
