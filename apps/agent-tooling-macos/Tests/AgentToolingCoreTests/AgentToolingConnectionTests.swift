import AgentToolingTestSupport
import Foundation
import Testing

@testable import AgentToolingCore

/// Where each app stands with Agent Tooling's own connection, read from what
/// this Mac observed and the app's own configuration files, and the receipt
/// that proves an earlier registration was Agent Tooling's.
@Suite("Agent Tooling connection")
struct AgentToolingConnectionTests {
    static let helper = "/Applications/Agent Tooling.app/Contents/Helpers/agent-tooling-mcp"

    @Test func anAppThatAnsweredWithNoRegistrationIsReadyAndOneWithNoVersionWaits() {
        let states = AgentToolingConnection.states(
            observations: [
                Self.observation(.codexCLI, version: "codex-cli 0.164.0"),
                Self.observation(.claudeCode, version: nil),
                Self.observation(.geminiCLI, installed: false),
            ], helperPath: Self.helper)

        #expect(states[.codex] == .notConnected)
        #expect(states[.claude] == .waitsForVersion)
        #expect(states[.gemini] == .notFound)
        #expect(states[.kiro] == .notChecked)
    }

    /// A registration under the connection's name is read from the app's own
    /// file: this copy's helper is already connected; any other command is
    /// another copy, Agent Tooling's own only when a receipt proves it.
    @Test func aRegistrationIsAlreadyConnectedOrAnotherCopy() throws {
        let home = try FixtureHome("connection-states")
        defer { home.remove() }
        let elsewhere = "/Users/example/Downloads/Agent Tooling.app/Contents/Helpers/agent-tooling-mcp"
        try home.plant(".claude.json", #"{"mcpServers":{"agent-tooling":{"type":"stdio","command":"\#(Self.helper)","args":[]}}}"#)
        try home.plant(".gemini/settings.json", #"{"mcpServers":{"agent-tooling":{"command":"\#(elsewhere)"}}}"#)
        let observations = [
            Self.observation(.claudeCode, registered: true, files: [home.appending(".claude.json").path(percentEncoded: false)]),
            Self.observation(.geminiCLI, registered: true, files: [home.appending(".gemini/settings.json").path(percentEncoded: false)]),
        ]

        let unproven = AgentToolingConnection.states(observations: observations, helperPath: Self.helper)
        let proven = AgentToolingConnection.states(
            observations: observations, helperPath: Self.helper, provenSurfaces: [.claudeCode, .geminiCLI])

        #expect(unproven[.claude] == .alreadyConnected(provenOurs: false))
        #expect(unproven[.gemini] == .connectedToAnotherCopy(path: elsewhere, provenOurs: false))
        #expect(proven[.claude] == .alreadyConnected(provenOurs: true), "Agent Tooling set this one up, so it may take it out")
        #expect(proven[.gemini] == .connectedToAnotherCopy(path: elsewhere, provenOurs: true))
    }

    /// Codex's TOML file as a JSON writer leaves it, slashes escaped, still
    /// names the same command; a literal string and a trailing comment read
    /// as written.
    @Test func codexsConfigurationNamesTheSameCommandHoweverItIsQuoted() throws {
        let home = try FixtureHome("connection-toml")
        defer { home.remove() }
        let escaped = Self.helper.replacingOccurrences(of: "/", with: #"\/"#)
        try home.plant(
            ".codex/config.toml",
            """
            [mcp_servers.agent-tooling]
            command = "\(escaped)"
            args = []

            [mcp_servers.literal]
            command = '/opt/tools/serve here'

            [mcp_servers.commented]
            command = "/opt/tools/serve" # started by hand
            """)
        let file = home.appending(".codex/config.toml").path(percentEncoded: false)
        let observation = Self.observation(.codexCLI, registered: true, files: [file])
        let servers = SetupAuditor.userScopeServers(configurationPaths: [file])

        #expect(observation.userScopeMCPRegistration(ofServer: "agent-tooling")?.command == Self.helper)
        #expect(servers["literal"]?.command == "/opt/tools/serve here")
        #expect(servers["commented"]?.command == "/opt/tools/serve")
        #expect(
            AgentToolingConnection.states(observations: [observation], helperPath: Self.helper)[.codex]
                == .alreadyConnected(provenOurs: false))
    }

    /// A registration counts only where the app holds it for the person. One
    /// only a project's settings name (Claude Code's `projects` in
    /// `~/.claude.json`) and one the last check found only in a plugin are
    /// some other server: the app reads as not connected yet, as the planner
    /// plans it.
    @Test func aProjectsOrAPluginsServerOfTheSameNameIsNoRegistration() throws {
        let home = try FixtureHome("connection-scope")
        defer { home.remove() }
        try home.plant(
            ".claude.json",
            #"{"projects":{"/Users/example/work":{"mcpServers":{"agent-tooling":{"command":"/Users/example/old/agent-tooling-mcp"}}}}}"#)
        try home.plant(".codex/config.toml", "[mcp_servers.agent-tooling]\ncommand = \"/Users/example/old/agent-tooling-mcp\"\n")
        let claude = home.appending(".claude.json").path(percentEncoded: false)
        var plugin = Self.observation(.codexCLI, files: [home.appending(".codex/config.toml").path(percentEncoded: false)])
        plugin.discoveredMCPServers = ["agent-tooling"]
        plugin.mcpMetadata = ["agent-tooling": .init(transport: "stdio", authentication: "Not inferred", source: "agent-tooling@market")]

        let states = AgentToolingConnection.states(
            observations: [Self.observation(.claudeCode, registered: true, files: [claude]), plugin], helperPath: Self.helper,
            provenSurfaces: [.claudeCode, .codexCLI])

        #expect(states[.claude] == .notConnected)
        #expect(states[.codex] == .notConnected)
        #expect(SetupAuditor.userScopeServers(configurationPaths: [claude]).isEmpty)
    }

    /// An entry under the name that is an address, not a command, is not this
    /// copy's helper: another copy, with no path to name.
    @Test func aRegistrationThatIsAnAddressIsAnotherCopy() throws {
        let home = try FixtureHome("connection-address")
        defer { home.remove() }
        try home.plant(".gemini/settings.json", #"{"mcpServers":{"agent-tooling":{"httpUrl":"https://example.com/mcp"}}}"#)
        let observation = Self.observation(
            .geminiCLI, registered: true, files: [home.appending(".gemini/settings.json").path(percentEncoded: false)])

        #expect(observation.userScopeMCPRegistration(ofServer: "agent-tooling") == .init(command: nil))
        #expect(
            AgentToolingConnection.states(observations: [observation], helperPath: Self.helper)[.gemini]
                == .connectedToAnotherCopy(path: "", provenOurs: false))
    }

    /// What an app's own files say about a server: on unless they switch it
    /// off, read from JSON and from TOML alike; a TOML table nested under a
    /// server (its environment) is no server of its own.
    @Test func aRegistrationSaysWhetherItIsOn() throws {
        let home = try FixtureHome("connection-enabled")
        defer { home.remove() }
        try home.plant(".kiro/settings/mcp.json", #"{"mcpServers":{"off":{"command":"serve","disabled":true},"on":{"command":"serve"}}}"#)
        try home.plant(
            ".codex/config.toml",
            "[mcp_servers.quiet]\ncommand = \"serve\"\nenabled = false\n\n[mcp_servers.quiet.env]\nLOG_LEVEL = \"debug\"\n")
        let servers = SetupAuditor.userScopeServers(configurationPaths: [
            home.appending(".kiro/settings/mcp.json").path(percentEncoded: false),
            home.appending(".codex/config.toml").path(percentEncoded: false),
        ])

        #expect(servers["off"] == .init(command: "serve", isEnabled: false))
        #expect(servers["on"] == .init(command: "serve", isEnabled: true))
        #expect(servers["quiet"] == .init(command: "serve", isEnabled: false))
        #expect(Set(servers.keys) == ["off", "on", "quiet"])
    }

    /// This Mac's apps are the ones its own contributions name: another
    /// Mac's are not, and nothing is named before the library holds the
    /// connection.
    @Test func thisMacsAppsAreItsOwnContributions() throws {
        let thisMac = WorkspaceObjectID()
        let otherMac = WorkspaceObjectID()
        let connection = ArtifactID()
        var document = PortableWorkspaceDocument(
            workspaceID: WorkspaceObjectID(), revision: .init(writerID: thisMac),
            artifacts: [
                ArtifactRecord(
                    identity: .init(id: connection, kind: .mcpServer, displayName: "Agent Tooling"), authority: .centralPersonal,
                    declaredName: "agent-tooling")
            ],
            assignments: [
                .init(artifactID: connection, destination: .init(surface: .codexCLI, scope: .user, deviceIDs: [thisMac]), reason: .manual),
                .init(
                    artifactID: connection, destination: .init(surface: .geminiCLI, scope: .user, deviceIDs: [otherMac]), reason: .manual),
            ])
        #expect(AgentToolingConnection.apps(on: thisMac, in: document).isEmpty, "no definition yet: not the library's own")

        document.mcpDefinitions = [.init(artifactID: connection, connection: .deviceBound(transport: .stdio))]
        #expect(AgentToolingConnection.apps(on: thisMac, in: document) == [.codex])
        #expect(AgentToolingConnection.apps(on: otherMac, in: document) == [.gemini])
    }

    @Test func oneSpellingOfACommandMatchesAnother() {
        #expect(AgentToolingConnection.sameCommand(Self.helper, "/Applications/./Agent Tooling.app/Contents/Helpers/agent-tooling-mcp"))
        #expect(AgentToolingConnection.sameCommand("npx", "npx"))
        #expect(!AgentToolingConnection.sameCommand(Self.helper, "/Applications/Agent Tooling.app/Contents/Helpers/agent-tooling"))
    }

    @Test func changedArgumentsAreNotTheAppsOwnRegistrationDespiteAnEarlierReceipt() throws {
        let home = try FixtureHome("connection-changed-args")
        defer { home.remove() }
        try home.plant(".claude.json", #"{"mcpServers":{"agent-tooling":{"command":"\#(Self.helper)","args":["--help"]}}}"#)
        let observation = Self.observation(
            .claudeCode, registered: true, files: [home.appending(".claude.json").path(percentEncoded: false)])
        #expect(
            AgentToolingConnection.states(observations: [observation], helperPath: Self.helper, provenSurfaces: [.claudeCode])[.claude]
                == .connectedToAnotherCopy(path: Self.helper, provenOurs: false))
    }

    @Test func registrationArgumentsAreReadOrLeftUnknown() throws {
        let home = try FixtureHome("connection-args")
        defer { home.remove() }
        try home.plant(
            ".claude.json",
            #"{"mcpServers":{"json":{"command":"serve","args":["--mode","local"]},"invalid":{"command":"serve","args":true}}}"#)
        try home.plant(
            ".codex/config.toml",
            """
            [mcp_servers.toml]
            command = "serve"
            args = ["--mode", "local#label"] # comment
            [mcp_servers.missing]
            command = "serve"
            [mcp_servers.quoted]
            "command" = "serve"
            "args" = ["--help"]
            [mcp_servers.literal]
            'command' = "serve"
            'args' = ["--version"]
            [mcp_servers.multiline]
            command = "serve"
            args = [
              "--help"
            ]
            """)
        let servers = SetupAuditor.userScopeServers(configurationPaths: [
            home.appending(".claude.json").path(percentEncoded: false), home.appending(".codex/config.toml").path(percentEncoded: false),
        ])
        #expect(servers["json"]?.arguments == ["--mode", "local"])
        #expect(servers["toml"]?.arguments == ["--mode", "local#label"])
        #expect(servers["missing"]?.arguments == [])
        #expect(servers["quoted"] == .init(command: "serve", arguments: ["--help"]))
        #expect(servers["literal"] == .init(command: "serve", arguments: ["--version"]))
        #expect(servers["invalid"]?.arguments == nil)
        #expect(servers["multiline"]?.arguments == nil)
    }

    @Test(arguments: [
        #"""
        args = [
          """
        args = []
        """
        ]
        """#,
        #"""
        args = [
          '''
        [mcp_servers.agent-tooling]
        args = []
        '''
        ]
        """#,
        "[mcp_servers.agent-tooling.args]\ncustom = \"value\"",
        "[[mcp_servers.agent-tooling.args]]\ncustom = \"value\"",
        "args.custom = \"value\"",
        "args = true\nargs = []",
    ])
    func unsupportedArgumentsCannotBecomeAnAbsentOrEmptyList(arguments: String) throws {
        let home = try FixtureHome("connection-unsupported-args")
        defer { home.remove() }
        try home.plant(
            ".codex/config.toml",
            "[mcp_servers.agent-tooling]\ncommand = \"\(Self.helper)\"\n\(arguments)\n"
                + "[mcp_servers.normal]\ncommand = \"serve\"\nargs = []\n")
        let file = home.appending(".codex/config.toml").path(percentEncoded: false)
        let servers = SetupAuditor.userScopeServers(configurationPaths: [file])
        let registration = try #require(servers["agent-tooling"])
        #expect(registration.arguments == nil)
        #expect(servers["normal"] == .init(command: "serve", arguments: []))
        let observation = Self.observation(.codexCLI, registered: true, files: [file])
        #expect(
            AgentToolingConnection.states(observations: [observation], helperPath: Self.helper, provenSurfaces: [.codexCLI])[.codex]
                == .connectedToAnotherCopy(path: Self.helper, provenOurs: false))
    }

    @Test func multilineValuesCannotInventRegistrationKeysOrHeaders() throws {
        let home = try FixtureHome("connection-multiline-values")
        defer { home.remove() }
        try home.plant(
            ".codex/config.toml",
            #"""
            notes = """
            [mcp_servers.invented]
            command = "serve"
            args = []
            """
            [mcp_servers.real]
            command = "serve"
            args = ["--mode", "local#label"] # an actual comment
            description = '''
            args = []
            '''
            [mcp_servers.missing]
            command = "serve"
            # args = ["ignored"]
            [mcp_servers.quoted]
            'command' = "serve"
            "args" = []
            """#)
        let servers = SetupAuditor.userScopeServers(configurationPaths: [home.appending(".codex/config.toml").path(percentEncoded: false)])
        #expect(servers["invented"] == nil)
        #expect(servers["real"] == .init(command: "serve", arguments: ["--mode", "local#label"]))
        #expect(servers["missing"] == .init(command: "serve", arguments: []))
        #expect(servers["quoted"] == .init(command: "serve", arguments: []))
    }

    /// Only a step that set this connection up and succeeded proves it: not a
    /// failed one, not another connection's, not an install of something
    /// else.
    @Test func aSucceededReceiptStepIsTheProof() {
        func receipt(
            _ kind: OperationKind, _ surface: TargetSurface, _ title: String, _ status: OperationStepStatus
        ) -> OperationReceipt {
            OperationReceipt(
                planID: UUID(), kind: kind, title: "Set up 1 connection in \(surface.displayName)", state: .healthy,
                targetSurfaces: [surface], results: [], verificationSummary: "",
                itemOutcomes: [.init(id: UUID(), title: title, status: status, reason: "Completed.")])
        }

        let proven = AgentToolingConnection.provenSurfaces(in: [
            receipt(.configureMCP, .claudeCode, "Set up agent-tooling", .succeeded),
            receipt(.configureMCP, .codexCLI, "Set up agent-tooling", .failed),
            receipt(.configureMCP, .geminiCLI, "Set up agent-tooling-beta", .succeeded),
            receipt(.installPlugin, .kiroCLI, "Set up agent-tooling", .succeeded),
        ])

        #expect(proven == [.claudeCode])
    }

    /// The proof reads the step titles the reviewed plan writes, so a change
    /// to how a connection step is named is caught here.
    @Test func theProofReadsTheTitleTheReviewedPlanWrites() throws {
        let plans = WorkspaceDeploymentOperations.operations(
            managedConnections: [Self.commandPlan(surface: .claudeCode)])
        let step = try #require(plans.first?.steps.first)
        let receipt = OperationReceipt(
            planID: try #require(plans.first?.id), kind: try #require(plans.first?.kind), title: plans[0].title, state: .healthy,
            targetSurfaces: plans[0].targetSurfaces, results: [], verificationSummary: "",
            itemOutcomes: [.init(id: step.id, title: step.title, status: .succeeded, reason: "Completed.")])

        #expect(AgentToolingConnection.provenSurfaces(in: [receipt]) == [.claudeCode])
    }

    @Test func itsToolsAreNamedInAPersonsWords() {
        #expect(AgentToolingConnection.lookUpTools.count == 9)
        #expect(AgentToolingConnection.askTools.count == 5)
        let words = (AgentToolingConnection.lookUpTools + AgentToolingConnection.askTools).map(\.words)
        #expect(words.allSatisfy { !$0.contains("'") && !$0.contains("_") })
        #expect(AgentToolingConnection.askTools.allSatisfy { $0.words.hasPrefix("Ask to ") && $0.name.hasPrefix("request_") })
    }

    // MARK: - Observations

    private static func observation(
        _ surface: TargetSurface, installed: Bool = true, version: String? = "1.0.0", registered: Bool = false,
        files: [String] = []
    ) -> TargetObservation {
        TargetObservation(
            surface: surface, installed: installed, version: version, configurationPaths: files,
            discoveredMCPServers: registered ? ["agent-tooling"] : [],
            mcpMetadata: registered
                ? [
                    "agent-tooling": .init(
                        transport: "stdio", authentication: "Not inferred", source: "\(surface.displayName) configuration")
                ]
                : [:],
            capabilities: .init(
                supportsPluginInstall: false, supportsProjectScope: false, supportsLocalMarketplace: false,
                supportsMCPAuthentication: false, supportsConnectorDiscovery: false, requiresNewSession: false,
                requiresRestart: false, supportsMachineReadableOutput: false))
    }

    private static func commandPlan(surface: TargetSurface) -> WorkspaceManagedMCPCommandPlan {
        WorkspaceManagedMCPCommandPlan(
            artifactID: ArtifactID(), physicalDestinationID: WorkspaceObjectID(), surface: surface, scope: .user,
            nativeServerIdentifier: "agent-tooling", executableURL: URL(filePath: "/usr/local/bin/claude"),
            executable: "/usr/local/bin/claude",
            arguments: AgentToolingConnection.previewArguments(client: .claude, helperPath: helper), workingDirectoryPath: nil)
    }
}
