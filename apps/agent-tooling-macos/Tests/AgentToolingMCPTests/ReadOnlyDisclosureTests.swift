import Foundation
import Testing

@testable import AgentToolingCore
@testable import AgentToolingMCP

/// A workspace deliberately stuffed with the things that must not come back
/// out: secret-looking text in the names people choose, home directories in the
/// paths this Mac observed, and a project root in a receipt.
///
/// The versioned library carries no endpoint, no file path and no project root
/// at all — there is nowhere in it to put one. That is a stronger guarantee than
/// redaction and is asserted as such. What still needs redacting is what people
/// type and what this device observed, and those are what this exercises.
private func compromisingArtifacts() -> [ArtifactRecord] {
    [
        .init(identity: .init(id: ArtifactID(), kind: .skill,
                              displayName: "Release summary /Users/testperson/Projects/secret-product"),
              authority: .centralPersonal, declaredName: "release-summary",
              contentDigest: .init(value: String(repeating: "a", count: 64))),
        .init(identity: .init(id: ArtifactID(), kind: .mcpServer,
                              displayName: "Weather sk-live-SUPERSECRET"),
              authority: .trackedOnly, declaredName: "weather"),
        .init(identity: .init(id: ArtifactID(), kind: .nativePlugin,
                              displayName: "Developer workflows"),
              authority: .trackedOnly, declaredName: "developer-workflows"),
    ]
}

private func compromisingObservations() -> [TargetObservation] {
    [
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
}

private func compromisingReceipts() -> [OperationReceipt] {
    [
        OperationReceipt(
            planID: UUID(), kind: .installSkill, title: "Installed a skill",
            state: .healthy, targetSurfaces: [.claudeCode],
            results: [.init(stepID: UUID(), status: .succeeded,
                            output: "Copied into /Users/testperson/.claude/skills/release-summary",
                            startedAt: Date(timeIntervalSince1970: 1_700_000_000),
                            finishedAt: Date(timeIntervalSince1970: 1_700_000_001))],
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            verificationSummary: "Verified against /Users/testperson/.claude/settings.json")
    ]
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
        let harness = try MCPTestHarness(artifacts: compromisingArtifacts())
        try harness.initialize()

        let payload = try harness.callTool("search_inventory")
        #expect(payload["results"]?.arrayValue?.count == 3)
        // The names are what people type, so they are what still needs
        // redacting on the way out.
        assertNothingSensitive(payload, tool: "search_inventory")
    }

    @Test func theLibraryHasNowhereToPutAnEndpointOrAPath() throws {
        let harness = try MCPTestHarness(artifacts: compromisingArtifacts())
        try harness.initialize()

        let server = try harness.callTool("get_component", arguments: [
            "kind": .string("mcp-server"), "id": .string(harness.identifier(of: "weather")),
        ])

        // Stronger than redaction: an address lives in this Mac's own client
        // files, and the library has no field for one. There is nothing to
        // strip because there is nothing to carry.
        #expect(server["endpointSummary"]?.stringValue?.isEmpty != false)
        let skill = try harness.callTool("get_component", arguments: [
            "kind": .string("skill"), "id": .string(harness.identifier(of: "release-summary")),
        ])
        #expect(skill["isProjectScoped"]?.boolValue == false)
        assertNothingSensitive(server, tool: "get_component(mcp-server)")
        assertNothingSensitive(skill, tool: "get_component(skill)")
    }

    @Test func aNameSomebodyTypedIsRedactedOnTheWayOut() throws {
        let harness = try MCPTestHarness(artifacts: compromisingArtifacts())
        try harness.initialize()

        let plugin = try harness.callTool("get_component", arguments: [
            "kind": .string("plugin"), "id": .string(harness.identifier(of: "developer-workflows")),
        ])
        assertNothingSensitive(plugin, tool: "get_component(plugin)")
    }

    @Test func clientStatusOmitsConfigurationPathsAndCountsThemInstead() throws {
        let harness = try MCPTestHarness(observations: compromisingObservations())
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
        let harness = try MCPTestHarness(receipts: compromisingReceipts())
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
            if tool.name == "get_effective_settings" { arguments = ["client": .string("claude-code")] }
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
