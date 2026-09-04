import AgentToolingCore
import Foundation
import Testing

@testable import AgentToolingMCP

/// A workspace deliberately stuffed with the things that must not come back
/// out: a live token in an endpoint, home directories in configuration paths
/// and bundle names, and a project root.
private func compromisingSnapshot() -> WorkspaceSnapshot {
    let clients = [ClientState(client: .claude, state: .healthy, detail: "Installed", isInstalled: true)]
    return WorkspaceSnapshot(
        skills: [
            Skill(
                id: "release-summary",
                name: "release-summary",
                displayName: "Release summary",
                summary: "Summarize a release branch before tagging.",
                bundle: "/Users/testperson/Library/Application Support/Agent Tooling/library/release-summary",
                scope: "This Mac",
                owned: true,
                triggers: ["release", "tag"],
                negativeTrigger: "",
                files: ["SKILL.md"],
                clients: clients,
                validationCount: 2,
                projectRoot: "/Users/testperson/Projects/secret-product"
            )
        ],
        mcpServers: [
            MCPServer(
                id: "weather",
                name: "Weather",
                summary: "Forecast lookups",
                endpoint: "https://weather.example.com/mcp?api_key=sk-live-SUPERSECRET",
                transport: .http,
                authentication: "API key",
                scope: "This Mac",
                clients: clients,
                repairCommand: "/Users/testperson/.local/bin/weather-mcp --repair",
                secretNames: ["WEATHER_API_KEY"]
            ),
            MCPServer(
                id: "local-notes",
                name: "Local notes",
                summary: "Notes over stdio",
                endpoint: "/Users/testperson/.local/bin/notes-mcp --token sk-live-ANOTHERSECRET",
                transport: .stdio,
                authentication: "None",
                scope: "This Mac",
                clients: clients,
                secretNames: ["NOTES_TOKEN"]
            ),
        ],
        plugins: [
            Plugin(
                id: "developer-workflows",
                name: "Developer workflows",
                summary: "Shared workflows",
                source: "/Users/testperson/ws/agent-tooling",
                scope: "This Mac",
                revision: "abc1234",
                skills: ["release-summary"],
                profiles: [],
                clients: clients,
                installed: true
            )
        ],
        operationReceipts: [
            OperationReceipt(
                planID: UUID(),
                kind: .configureMCP,
                title: "Add weather",
                state: .healthy,
                targetSurfaces: [.claudeCode],
                results: [
                    OperationStepResult(
                        stepID: UUID(),
                        status: .succeeded,
                        output: "Wrote /Users/testperson/.claude/settings.json",
                        startedAt: .now,
                        finishedAt: .now
                    )
                ],
                verificationSummary: "Verified against /Users/testperson/.claude/settings.json"
            )
        ],
        targetObservations: [
            TargetObservation(
                surface: .claudeCode,
                installed: true,
                commandAvailable: true,
                version: "2.0.1",
                configurationPaths: ["/Users/testperson/.claude/settings.json", "/Users/testperson/.claude.json"],
                discoveredSkills: ["release-summary"],
                discoveredPlugins: ["developer-workflows"],
                discoveredMCPServers: ["weather"],
                capabilities: TargetCapabilities(
                    supportsPluginInstall: true,
                    supportsProjectScope: true,
                    supportsLocalMarketplace: true,
                    supportsMCPAuthentication: true,
                    supportsConnectorDiscovery: true,
                    requiresNewSession: false,
                    requiresRestart: false,
                    supportsMachineReadableOutput: true
                ),
                notes: ["Read /Users/testperson/.claude/settings.json"]
            )
        ]
    )
}

private let forbiddenSubstrings = [
    "sk-live-SUPERSECRET",
    "sk-live-ANOTHERSECRET",
    "/Users/testperson",
    "secret-product",
    ".local/bin",
    "settings.json",
]

@Suite("Read-only disclosure")
struct ReadOnlyDisclosureTests {
    private func assertNothingSensitive(_ payload: [String: JSONValue], tool: String) {
        for value in JSONValue.object(payload).allStrings {
            for forbidden in forbiddenSubstrings {
                #expect(!value.contains(forbidden), "\(tool) leaked '\(forbidden)' in: \(value)")
            }
        }
    }

    @Test func searchResultsCarryNoSecretValueAndNoHomeDirectory() throws {
        let harness = try MCPTestHarness(snapshot: compromisingSnapshot())
        try harness.initialize()

        let payload = try harness.callTool("search_inventory")
        let results = try #require(payload["results"]?.arrayValue)
        #expect(results.count == 4)
        assertNothingSensitive(payload, tool: "search_inventory")
    }

    @Test func componentDetailReturnsSecretNamesButNeverSecretValues() throws {
        let harness = try MCPTestHarness(snapshot: compromisingSnapshot())
        try harness.initialize()

        let http = try harness.callTool("get_component", arguments: ["kind": .string("mcp-server"), "id": .string("weather")])
        // The reference name is useful. The value behind it is not offered by
        // any tool on this server.
        #expect(http["secretReferenceNames"]?.arrayValue?.first?.stringValue == "WEATHER_API_KEY")
        // An http endpoint collapses to scheme and host, so the query-string
        // token has nothing to ride out on.
        #expect(http["endpointSummary"]?.stringValue == "https://weather.example.com")
        assertNothingSensitive(http, tool: "get_component(http)")

        let stdio = try harness.callTool("get_component", arguments: ["kind": .string("mcp-server"), "id": .string("local-notes")])
        // A stdio endpoint collapses to the executable's base name.
        #expect(stdio["endpointSummary"]?.stringValue == "notes-mcp")
        assertNothingSensitive(stdio, tool: "get_component(stdio)")

        let skill = try harness.callTool("get_component", arguments: ["kind": .string("skill"), "id": .string("release-summary")])
        #expect(skill["isProjectScoped"]?.boolValue == true)
        assertNothingSensitive(skill, tool: "get_component(skill)")

        let plugin = try harness.callTool("get_component", arguments: ["kind": .string("plugin"), "id": .string("developer-workflows")])
        assertNothingSensitive(plugin, tool: "get_component(plugin)")
    }

    @Test func clientStatusOmitsConfigurationPathsAndCountsThemInstead() throws {
        let harness = try MCPTestHarness(snapshot: compromisingSnapshot())
        try harness.initialize()

        let payload = try harness.callTool("get_client_status")
        let clients = try #require(payload["clients"]?.arrayValue)
        let claude = try #require(clients.first?.objectValue)
        #expect(claude["configurationFileCount"]?.numberValue == 2)
        #expect(claude["version"]?.stringValue == "2.0.1")
        // The tool reports what the app observed; it starts no scan and runs no
        // client command.
        #expect(payload["isLiveScan"]?.boolValue == false)
        assertNothingSensitive(payload, tool: "get_client_status")
    }

    @Test func receiptOutputIsStrippedOfPaths() throws {
        let harness = try MCPTestHarness(snapshot: compromisingSnapshot())
        try harness.initialize()

        let list = try harness.callTool("list_receipts")
        assertNothingSensitive(list, tool: "list_receipts")

        let receipts = try #require(list["receipts"]?.arrayValue)
        let id = try #require(receipts.first?.objectValue?["id"]?.stringValue)
        let detail = try harness.callTool("get_receipt", arguments: ["receiptID": .string(id)])
        assertNothingSensitive(detail, tool: "get_receipt")
        #expect(JSONValue.object(detail).allStrings.contains { $0.contains(ResponseRedaction.withheldPathPlaceholder) })
    }

    @Test func everyReadOnlyToolSurvivesAnEmptyWorkspace() throws {
        let harness = try MCPTestHarness()
        try harness.initialize()

        for tool in ToolCatalog.readOnlyTools where tool.name != "get_receipt" && tool.name != "get_request_status" {
            var arguments: [String: JSONValue] = [:]
            if tool.name == "get_component" {
                arguments = ["kind": .string("skill"), "id": .string("nothing")]
            }
            if tool.name == "open_review_screen" { arguments = ["screen": .string("overview")] }
            let response = harness.rawCallTool(tool.name, arguments: arguments)
            #expect(response?["error"] == nil, "\(tool.name) failed on an empty workspace.")
        }
    }

    @Test func openReviewScreenOnlyEmitsLinksTheAppAccepts() throws {
        let harness = try MCPTestHarness()
        try harness.initialize()

        for section in ExternalAppSection.allCases {
            let payload = try harness.callTool("open_review_screen", arguments: ["screen": .string(section.rawValue)])
            let raw = try #require(payload["url"]?.stringValue)
            let url = try #require(URL(string: raw))
            #expect(ExternalAppRoute(url: url) == .section(section))
        }

        let id = UUID()
        let request = try harness.callTool(
            "open_review_screen",
            arguments: ["screen": .string("request"), "requestID": .string(id.uuidString)]
        )
        let rawRequestURL = try #require(request["url"]?.stringValue)
        let url = try #require(URL(string: rawRequestURL))
        #expect(ExternalAppRoute(url: url) == .pendingRequest(id))

        // A request link without an identifier is a mistake, not a link to the
        // whole queue.
        #expect(harness.rawCallTool("open_review_screen", arguments: ["screen": .string("request")])?["error"] != nil)
    }

    @Test func redactionRecognizesPathsSecretsAndLeavesOrdinaryTextAlone() {
        #expect(ResponseRedaction.containsFileSystemPath("/Users/someone/notes"))
        #expect(ResponseRedaction.containsFileSystemPath("~/Library/Preferences"))
        #expect(!ResponseRedaction.containsFileSystemPath("developer-workflows"))
        // A slash in prose is not a path, and over-redacting descriptions would
        // make the read tools useless.
        #expect(ResponseRedaction.redactedText("Applies to skills and/or plugins") == "Applies to skills and/or plugins")
        #expect(ResponseRedaction.redactedText("Wrote /Users/x/f").hasSuffix(ResponseRedaction.withheldPathPlaceholder))
        // A path with a space in it is withheld whole, not just its first token.
        #expect(!ResponseRedaction.redactedText("at /Users/x/My Folder/file").contains("Folder"))
        #expect(ResponseRedaction.redactedText("Authorization: Bearer abc123") == ResponseRedaction.withheldSecretPlaceholder)
        #expect(ResponseRedaction.locationFreeSummary("/Users/x/bin/tool") == nil)
        #expect(ResponseRedaction.executableName(from: "/Users/x/bin/tool --flag") == "tool")
    }
}
