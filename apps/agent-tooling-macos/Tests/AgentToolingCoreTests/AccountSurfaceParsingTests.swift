import Foundation
import Testing

@testable import AgentToolingCore

/// Every shape a client prints about its hosted account is pinned to a fixed
/// string here, so an unfamiliar update shows up as a failing test rather than
/// as a wrong answer on somebody's screen.
@Suite("Accounts · reading what the clients print")
struct AccountSurfaceParsingTests {
    // MARK: claude auth status --json

    @Test func aClaudeAISignInKeepsItsAccountFacts() throws {
        let text = """
            {"loggedIn":true,"authMethod":"claude.ai","apiProvider":"firstParty","email":"me@example.com",\
            "orgId":"org-123","orgName":"Example","subscriptionType":"max","configDirectory":"/Users/me/.claude"}
            """
        let signIn = try #require(ClaudeAccountParsing.signIn(fromAuthStatus: text))
        #expect(signIn.method == .subscription)
        #expect(signIn.method.reachesAccount)
        #expect(signIn.email == "me@example.com")
        #expect(signIn.organizationID == "org-123")
        #expect(signIn.organizationName == "Example")
        #expect(signIn.plan == "max")
        #expect(signIn.configDirectory == "/Users/me/.claude")
        #expect(signIn.summary(for: .claude) == "claude.ai · Max · Example")
    }

    /// What Claude Code 2.1.300 printed on a Mac that runs it on Bedrock.
    @Test func aBedrockSignInIsAThirdPartyProvider() throws {
        let text = """
            {
              "loggedIn": true,
              "authMethod": "third_party",
              "apiProvider": "bedrock",
              "analyticsDisabled": true,
              "projectsDirectory": "/Users/me/.claude/projects",
              "configDirectory": "/Users/me/.claude"
            }
            """
        let signIn = try #require(ClaudeAccountParsing.signIn(fromAuthStatus: text))
        #expect(signIn.method == .thirdParty)
        #expect(signIn.provider == "bedrock")
        #expect(signIn.email == nil)
        #expect(signIn.summary(for: .claude) == "Amazon Bedrock")
        #expect(!signIn.method.reachesAccount)
    }

    @Test(arguments: [
        ("api_key", AccountSignIn.Method.apiKey),
        ("oauth_token", .token),
        ("api_key_helper", .keyHelper),
        ("none", .signedOut),
        ("a_method_not_yet_seen", .unknown),
    ])
    func everyDocumentedMethodHasAReading(method: String, expected: AccountSignIn.Method) throws {
        let signIn = try #require(ClaudeAccountParsing.signIn(fromAuthStatus: #"{"loggedIn":true,"authMethod":"\#(method)"}"#))
        #expect(signIn.method == expected)
        #expect(!signIn.method.reachesAccount)
    }

    @Test func signedOutAndUnreadableAnswersAreKeptApart() {
        #expect(ClaudeAccountParsing.signIn(fromAuthStatus: #"{"loggedIn":false,"authMethod":"none"}"#)?.method == .signedOut)
        #expect(ClaudeAccountParsing.signIn(fromAuthStatus: "Not logged in") == nil)
        #expect(ClaudeAccountParsing.signIn(fromAuthStatus: "") == nil)
    }

    /// An API key sign-in does not let a key's own email stand in for the
    /// subscription's.
    @Test func anAPIKeySignInKeepsNoAccountIdentity() throws {
        let signIn = try #require(ClaudeAccountParsing.signIn(fromAuthStatus: """
            {"loggedIn":true,"authMethod":"api_key","apiKeySource":"ANTHROPIC_API_KEY","email":"other@example.com"}
            """))
        #expect(signIn.method == .apiKey)
        #expect(signIn.provider == "ANTHROPIC_API_KEY")
        #expect(signIn.email == nil)
    }

    @Test func theVersionIsTheFirstNumericToken() {
        #expect(ClaudeAccountParsing.version(fromVersionOutput: "2.1.300.1248 (ASBX Claude Code, channel head)\n") == "2.1.300.1248")
        #expect(ClaudeAccountParsing.version(fromVersionOutput: "claude 2.1.300") == "2.1.300")
        #expect(ClaudeAccountParsing.version(fromVersionOutput: "unknown") == nil)
    }

    // MARK: claude plugin list --json

    @Test func onlyTheAccountsPluginsAreRead() {
        let text = """
            [
              {"id":"personal@agent-tooling","version":"1","scope":"user","enabled":true,"installPath":"/x"},
              {"id":"design@synced","version":"2.0.0","scope":"synced","enabled":true,
               "installPath":"/Users/me/.claude/plugins/synced/design",
               "mcpServers":{"figma":{"type":"http","url":"https://example.com/mcp"}}},
              {"id":"notes@synced","version":"unknown","scope":"synced","enabled":false,
               "installPath":"/Users/me/.claude/plugins/synced/notes"},
              {"id":"personal@synced","version":"unknown","scope":"synced","enabled":true,"installPath":"",
               "notes":["A plugin named personal from agent-tooling loads instead."]},
              {"id":"broken@synced","version":"unknown","scope":"synced","enabled":false,"installPath":"",
               "errors":["Download failed: 403"]}
            ]
            """
        let plugins = ClaudeAccountParsing.syncedPlugins(fromPluginList: text)
        #expect(plugins.map(\.name) == ["broken", "design", "notes", "personal"])
        #expect(plugins[1].version == "2.0.0")
        #expect(plugins[1].enabled && plugins[1].isInstalled)
        #expect(plugins[1].mcpServers == ["figma"])
        #expect(plugins[2].version == nil, "\"unknown\" is not a version")
        #expect(!plugins[2].enabled)
        #expect(!plugins[3].isInstalled)
        #expect(plugins[3].notes.first?.contains("loads instead") == true)
        #expect(plugins[0].errors == ["Download failed: 403"])
    }

    /// A shadowed row and the loaded row for one name describe one plugin.
    @Test func aPluginListedTwiceIsDescribedOnce() {
        let text = """
            [{"id":"design@synced","installPath":"","enabled":true,"notes":["Shadowed earlier."]},
             {"id":"design@synced","installPath":"/p","enabled":true,"version":"3"}]
            """
        let plugins = ClaudeAccountParsing.syncedPlugins(fromPluginList: text)
        #expect(plugins.count == 1)
        #expect(plugins[0].isInstalled && plugins[0].version == "3")
        #expect(plugins[0].notes == ["Shadowed earlier."])
    }

    @Test func aPluginListThatIsNotJSONListsNothing() {
        #expect(ClaudeAccountParsing.syncedPlugins(fromPluginList: "No plugins installed.").isEmpty)
    }

    // MARK: settings.json

    @Test func theAccountSwitchesInASettingsFileAreRead() {
        let text = """
            {
              "syncClaudeAiSkills": false,
              "syncClaudeAiPlugins": true,
              "disableClaudeAiConnectors": true,
              "deniedMcpServers": [
                {"serverName": "claude.ai Gmail"}, {"serverName": "filesystem"},
                {"serverUrl": "https://example.com/*"}, {"serverName": "claude.ai Google Calendar"}
              ],
              "enabledPlugins": {"notes@synced": false, "design@synced": true, "personal@agent-tooling": true}
            }
            """
        let settings = ClaudeAccountParsing.settings(fromJSON: text)
        #expect(settings.skillSyncOff)
        #expect(!settings.pluginSyncOff, "true is the same as unset")
        #expect(settings.connectorsOff)
        #expect(settings.deniedConnectors == ["Gmail", "Google Calendar"])
        #expect(settings.syncedPluginFlags == ["notes": false, "design": true])
    }

    @Test func aFileThatIsNotJSONSaysNothing() {
        #expect(ClaudeAccountParsing.settings(fromJSON: "{ not json").isEmpty)
        #expect(ClaudeAccountParsing.settings(fromJSON: "").isEmpty)
    }

    // MARK: ~/.claude/skills/synced

    @Test func syncedSkillsAreNamedByTheirFrontmatter() throws {
        let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
            .appending(path: "synced-skills-\(UUID())", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        try Self.write(root.appending(path: "pdf/SKILL.md"), "---\nname: pdf\ndescription: Read and fill PDF forms.\n---\n\nBody\n")
        try Self.write(root.appending(path: "weekly/SKILL.md"), "No frontmatter here.\n")
        try Self.write(root.appending(path: "notes/README.md"), "Not a skill.\n")
        try Self.write(root.appending(path: ".hidden/SKILL.md"), "---\nname: hidden\ndescription: x\n---\n")

        let skills = ClaudeAccountParsing.syncedSkills(in: root)
        #expect(skills.map(\.folder) == ["pdf", "weekly"])
        #expect(skills[0].name == "pdf")
        #expect(skills[0].summary == "Read and fill PDF forms.")
        #expect(skills[1].name == "weekly", "an unreadable definition is named by its folder")
        #expect(skills[1].summary == nil)
    }

    @Test func aMissingSyncedFolderHoldsNoSkills() {
        let missing = FileManager.default.temporaryDirectory.appending(path: "absent-\(UUID())", directoryHint: .isDirectory)
        #expect(ClaudeAccountParsing.syncedSkills(in: missing).isEmpty)
    }

    // MARK: claude mcp list

    /// Verified against Claude Code 2.1.300: a fetched connector is listed as
    /// `claude.ai <display name>: <url> - <status>`, and that whole name is
    /// what a deniedMcpServers serverName entry matches.
    @Test func aClaudeAIConnectorKeepsItsWholeNameAndShowsItsOwn() {
        let entries = ConnectionHealthReport.parse(client: .claude, text: """
            Checking MCP server health…

            claude.ai Gmail: https://gmail.mcp.example.com/mcp - ✔ Connected
            claude.ai Google Calendar: https://gcal.mcp.example.com/mcp - ! Needs authentication
            claude.ai Linear (2): https://mcp.linear.app/mcp - - Not configured
            local: npx foo - ✘ Connection error
            """)
        #expect(entries.map(\.name) == ["claude.ai Gmail", "claude.ai Google Calendar", "claude.ai Linear (2)", "local"])
        #expect(entries.map(\.displayName) == ["Gmail", "Google Calendar", "Linear (2)", "local"])
        #expect(entries.prefix(3).allSatisfy { $0.isClaudeAIConnector })
        #expect(entries[0].status == .connected)
        #expect(entries[1].status == .needsAuthentication)
        #expect(entries[2].status == .notConfigured)
        #expect(entries[2].summary == "https://mcp.linear.app/mcp", "the status's own dash is not part of the address")
        #expect(entries[3].status == .failed(detail: ""))
        #expect(!entries[3].isClaudeAIConnector)
    }

    /// The exception for spaces is the documented prefix and nothing else; a
    /// sentence before a colon is still not a server.
    @Test func onlyTheConnectorPrefixAllowsSpacesInAName() {
        let entries = ConnectionHealthReport.parse(client: .claude, text: """
            Some note about servers: see /mcp - for details
            claude.ai : nothing - ✔ Connected
            """)
        // The sentence is skipped. A server literally named "claude.ai" is a
        // plain server, not a connector: the prefix needs a name after it.
        #expect(entries.map(\.name) == ["claude.ai"])
        #expect(entries.first?.isClaudeAIConnector == false)
        #expect(ConnectionHealthReport.isClaudeAIConnectorName("claude.ai Slack"))
        #expect(!ConnectionHealthReport.isClaudeAIConnectorName("claude.ai "))
        #expect(!ConnectionHealthReport.isClaudeAIConnectorName("slack"))
    }

    // MARK: The login shell

    @Test func theShellProbeReadsOnlyMarkedNames() {
        let output = """
            Welcome back
            agent-tooling-shell-override:ANTHROPIC_API_KEY
            agent-tooling-shell-override:CODEX_HOME
            agent-tooling-shell-override:NOT_ONE_WE_KNOW
            ANTHROPIC_API_KEY=would-never-be-printed
            """
        #expect(AccountShellEnvironmentProbe.parse(output) == [.anthropicAPIKey, .codexHome])
    }

    /// The real script, run by zsh without any profile, against a known
    /// environment: it names what is set and prints no value.
    @Test func theShellScriptNamesVariablesAndNeverPrintsAValue() throws {
        let home = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
            .appending(path: "shell-probe-\(UUID())", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        let secret = "value-that-must-not-print-\(UUID().uuidString)"
        func run(_ environment: [String: String]) throws -> String {
            let process = Process()
            process.executableURL = URL(filePath: "/bin/zsh")
            process.arguments = ["-f", "-c", AccountShellEnvironmentProbe.script]
            process.environment = ["HOME": home.path, "PATH": "/usr/bin:/bin"].merging(environment) { $1 }
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = Pipe()
            try process.run()
            process.waitUntilExit()
            #expect(process.terminationStatus == 0)
            return String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        }

        let reported = try run([
            "ANTHROPIC_API_KEY": secret, "CLAUDE_CONFIG_DIR": "/tmp/elsewhere", "ENABLE_CLAUDEAI_MCP_SERVERS": "false",
        ])
        #expect(!reported.contains(secret))
        #expect(!reported.contains("/tmp/elsewhere"))
        #expect(AccountShellEnvironmentProbe.parse(reported) == [.anthropicAPIKey, .claudeConnectorsOff, .claudeConfigDirectory])

        // An empty value is not set, and connectors switched on is no override.
        let quiet = try run(["ANTHROPIC_API_KEY": "", "ENABLE_CLAUDEAI_MCP_SERVERS": "true"])
        #expect(AccountShellEnvironmentProbe.parse(quiet).isEmpty)
    }

    @Test func everyOverrideNamesItsProviderAndWhatItDoes() {
        for override in AccountShellOverride.allCases {
            #expect(!override.consequence.isEmpty)
            #expect(AccountShellEnvironmentProbe.script.contains(override.variable))
        }
        #expect(AccountShellOverride.codexHome.provider == .chatGPT)
        #expect(AccountShellOverride.anthropicAPIKey.replacesSubscription)
        #expect(!AccountShellOverride.claudeConfigDirectory.replacesSubscription)
    }

    // MARK: Codex app-server

    @Test func theCodexVersionComesFromTheUserAgent() throws {
        let hello = try Self.json(#"{"userAgent":"agent_tooling/0.162.1 (Mac OS 26.7.1; arm64) unknown (agent_tooling; 1)"}"#)
        #expect(CodexAccountParsing.version(fromInitialize: hello) == "0.162.1")
        #expect(CodexAccountParsing.version(fromInitialize: try Self.json("{}")) == nil)
    }

    @Test func aChatGPTAccountReadingKeepsItsPlan() throws {
        let signIn = try #require(CodexAccountParsing.signIn(fromAccountRead: try Self.json("""
            {"account":{"type":"chatgpt","email":"me@example.com","planType":"pro"},"requiresOpenaiAuth":true}
            """)))
        #expect(signIn.method == .subscription)
        #expect(signIn.email == "me@example.com")
        #expect(signIn.plan == "pro")
        #expect(signIn.summary(for: .chatGPT) == "ChatGPT · Pro")
    }

    /// The answer Codex 0.162.1 gave on a Mac that runs it on Bedrock.
    @Test func everyOtherCodexSignInIsNotTheAccount() throws {
        let bedrock = try Self.json(#"{"account":{"type":"amazonBedrock","usesCodexManagedCredentials":false},"requiresOpenaiAuth":false,"workspaceRouting":null}"#)
        #expect(CodexAccountParsing.signIn(fromAccountRead: bedrock)?.method == .thirdParty)
        #expect(CodexAccountParsing.signIn(fromAccountRead: bedrock)?.summary(for: .chatGPT) == "Amazon Bedrock")
        #expect(CodexAccountParsing.signIn(fromAccountRead: try Self.json(#"{"account":{"type":"apiKey"},"requiresOpenaiAuth":true}"#))?.method == .apiKey)
        #expect(CodexAccountParsing.signIn(fromAccountRead: try Self.json(#"{"account":null,"requiresOpenaiAuth":true}"#))?.method == .signedOut)
        #expect(CodexAccountParsing.signIn(fromAccountRead: try Self.json(#"{"account":null,"requiresOpenaiAuth":false}"#))?.method == .thirdParty)
        #expect(CodexAccountParsing.signIn(fromAccountRead: .string("nonsense")) == nil)
    }

    @Test func theAppListKeepsAccessAndLocalStateApart() throws {
        let page = try #require(CodexAccountParsing.appList(try Self.json("""
            {"data":[
              {"id":"github","name":"GitHub","description":"Repositories and pull requests.",
               "installUrl":"https://chatgpt.com/apps/github/github","isAccessible":true,"isEnabled":false},
              {"id":"demo-app","name":"Demo App","installUrl":"http://insecure.example.com","isAccessible":false,"isEnabled":true},
              {"name":"No id"}
            ],"nextCursor":"page-2"}
            """)))
        #expect(page.apps.map(\.id) == ["github", "demo-app"])
        #expect(page.apps[0].isAccessible && !page.apps[0].isEnabled)
        #expect(page.apps[0].installURL?.absoluteString == "https://chatgpt.com/apps/github/github")
        #expect(page.apps[1].installURL == nil, "only an https page is opened")
        #expect(page.nextCursor == "page-2")
        #expect(CodexAccountParsing.appList(try Self.json("{}")) == nil)
    }

    @Test func theInstalledSnapshotSaysWhatIsCallable() throws {
        let installed = CodexAccountParsing.installedApps(try Self.json("""
            {"apps":[{"id":"demo-app","runtimeName":"Demo App","enabled":true,"callable":true},
                     {"id":"github","runtimeName":null,"enabled":false,"callable":false}]}
            """))
        #expect(installed["demo-app"]?.callable == true)
        #expect(installed["github"]?.enabled == false)
    }

    /// The example from the Codex app-server documentation.
    @Test func theAppSwitchesInAConfigurationAreRead() throws {
        let switches = CodexAccountParsing.switches(fromConfig: try Self.json("""
            {"features":{"apps":true},
             "apps":{
               "_default":{"enabled":true,"destructive_enabled":true,"open_world_enabled":true,
                           "approvals_reviewer":"user","default_tools_approval_mode":"auto"},
               "google_drive":{"enabled":true,"destructive_enabled":false,"approvals_reviewer":"auto_review",
                               "default_tools_approval_mode":"prompt",
                               "tools":{"files/delete":{"enabled":false,"approval_mode":"approve"}}},
               "bad id":{"enabled":false},
               "github":{"default_tools_approval_mode":"never-heard-of-it"}
             }}
            """))
        #expect(switches[.init(.apps)] == .on)
        #expect(switches[.init(.destructiveTools)] == .on)
        #expect(switches[.init(.openWorldTools)] == .on)
        #expect(switches[.init(.approvalMode)] == .auto)
        #expect(switches[.init(.app, subject: "google_drive")] == .on)
        #expect(switches[.init(.destructiveTools, subject: "google_drive")] == .off)
        #expect(switches[.init(.approvalMode, subject: "google_drive")] == .prompt)
        #expect(switches[.init(.app, subject: "bad id")] == nil, "an id that cannot be a table name is not a switch")
        #expect(switches[.init(.approvalMode, subject: "github")] == nil)
        #expect(switches.count == 7)
        #expect(CodexAccountParsing.switches(fromConfig: nil).isEmpty)
    }

    @Test func theUserLayerIsTheOneThisAppEdits() throws {
        let reading = CodexAccountParsing.configReading(try Self.json("""
            {"config":{"features":{"apps":false}},
             "layers":[{"name":{"type":"sessionFlags"},"config":{}},
                       {"name":{"type":"user","file":"/Users/me/.codex/config.toml","profile":null},
                        "config":{"apps":{"github":{"enabled":false}}}},
                       {"name":{"type":"system","file":"/etc/codex/config.toml"},"config":{}}]}
            """))
        #expect(reading.userFile == "/Users/me/.codex/config.toml")
        #expect(CodexAccountParsing.switches(fromConfig: reading.user) == [.init(.app, subject: "github"): .off])
        #expect(CodexAccountParsing.switches(fromConfig: reading.effective) == [.init(.apps): .off])
    }

    // MARK: Helpers

    static func json(_ text: String) throws -> JSONValue {
        try AgentToolingCoding.decoder().decode(JSONValue.self, from: Data(text.utf8))
    }

    static func write(_ url: URL, _ text: String) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }
}
