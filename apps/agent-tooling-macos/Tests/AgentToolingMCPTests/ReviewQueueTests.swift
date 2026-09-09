import AgentToolingCore
import Foundation
import Testing

@testable import AgentToolingMCP

@Suite("Review queue")
struct ReviewQueueTests {
    private func addServerArguments(
        name: String = "weather",
        endpoint: String = "https://weather.example.com/mcp"
    ) -> [String: JSONValue] {
        [
            "name": .string(name),
            "transport": .string("http"),
            "endpoint": .string(endpoint),
            "scope": .string("user"),
            "targets": .array([.string("claude-code")]),
        ]
    }

    @Test func aQueuedRequestReturnsPendingReviewAndCreatesExactlyOneRow() throws {
        let harness = try MCPTestHarness()
        try harness.initialize()

        let payload = try harness.callTool("request_add_mcp_server", arguments: addServerArguments())

        #expect(payload["state"]?.stringValue == "pending-review")
        let reviewURL = try #require(payload["reviewURL"]?.stringValue)
        #expect(reviewURL.hasPrefix("agent-tooling://requests/"))
        #expect(payload["collapsedIntoExistingRequest"]?.boolValue == false)

        let rows = try harness.pendingRequests()
        #expect(rows.count == 1)
        #expect(rows[0].kind == .addMCPServer)
        #expect(rows[0].componentID == "weather")
        #expect(reviewURL == rows[0].reviewURL)

        // The link must be one the app already routes, not a shape invented here.
        let url = try #require(URL(string: reviewURL))
        #expect(ExternalAppRoute(url: url) == .pendingRequest(rows[0].id))
    }

    @Test func nothingIsAppliedAndNoPlanIsBuilt() throws {
        let harness = try MCPTestHarness()
        try harness.initialize()

        _ = try harness.callTool("request_add_mcp_server", arguments: addServerArguments())

        // The workspace the app reads must be untouched: no connection added,
        // and above all nothing that happened for a person to discover after.
        let snapshot = try #require(try harness.store.snapshot())
        #expect(snapshot.document.artifacts.isEmpty)
        #expect(try harness.store.operationReceipts().isEmpty)
    }

    @Test func duplicateRequestsCollapseIntoTheExistingRow() throws {
        let harness = try MCPTestHarness()
        try harness.initialize()

        let first = try harness.callTool("request_add_mcp_server", arguments: addServerArguments())
        let second = try harness.callTool("request_add_mcp_server", arguments: addServerArguments())
        let third = try harness.callTool("request_add_mcp_server", arguments: addServerArguments())

        let rows = try harness.pendingRequests()
        #expect(rows.count == 1)
        #expect(second["collapsedIntoExistingRequest"]?.boolValue == true)
        #expect(third["timesRequested"]?.numberValue == 3)
        #expect(first["reviewURL"] == third["reviewURL"])
    }

    @Test func aDifferentRequestDoesNotCollapse() throws {
        let harness = try MCPTestHarness()
        try harness.initialize()

        _ = try harness.callTool("request_add_mcp_server", arguments: addServerArguments())
        _ = try harness.callTool("request_add_mcp_server", arguments: addServerArguments(name: "calendar"))

        let rows = try harness.pendingRequests()
        #expect(rows.count == 2)
    }

    @Test func repeatsFromADifferentClientStillCollapse() throws {
        let harness = try MCPTestHarness()
        try harness.initialize(clientName: "Claude Code")
        _ = try harness.callTool("request_add_mcp_server", arguments: addServerArguments())
        try harness.initialize(clientName: "Codex")
        _ = try harness.callTool("request_add_mcp_server", arguments: addServerArguments())

        let rows = try harness.pendingRequests()
        #expect(rows.count == 1)
        // Both labels are recorded for display, and neither changed the outcome.
        #expect(rows[0].requestedByLabels.count == 2)
        #expect(rows[0].repeatCount == 2)
    }

    @Test func theQueueBoundHoldsAndRefusesRatherThanEvicting() throws {
        let harness = try MCPTestHarness()
        try harness.initialize(clientName: "Queue fixture")

        for index in 0..<PendingAgentRequestQueue.maximumPendingRequests {
            _ = try PendingRequestQueueService.enqueue(
                kind: .addMCPServer,
                title: "Add server-\(index)",
                summary: "Queue bound fixture",
                componentID: "server-\(index)",
                scope: .user,
                targets: [.claude],
                reason: nil,
                reviewDetails: PendingRequestReviewDetails(
                    endpoint: "https://weather.example.com/mcp",
                    transport: MCPTransport.http.rawValue
                ),
                fingerprintInputs: ["server-\(index)", MCPTransport.http.rawValue, "https://weather.example.com/mcp", ""],
                clientLabel: "Display-only fixture",
                store: harness.store
            )
        }
        let filled = try harness.pendingRequests()
        #expect(filled.count == PendingAgentRequestQueue.maximumPendingRequests)
        let firstRowID = try #require(filled.first?.id)

        try harness.initialize(clientName: "Queue overflow fixture")
        let overflow = try #require(harness.rawCallTool("request_add_mcp_server", arguments: addServerArguments(name: "one-too-many")))
        guard case .object(let result)? = overflow["result"] else {
            Issue.record("The overflow call produced no result.")
            return
        }
        #expect(result["isError"]?.boolValue == true)

        let rows = try harness.pendingRequests()
        #expect(rows.count == PendingAgentRequestQueue.maximumPendingRequests)
        // Refusing rather than evicting matters: evicting the oldest row would
        // let a caller flush a request a person had not read yet.
        #expect(rows.first?.id == firstRowID)
        #expect(!rows.contains { $0.componentID == "one-too-many" })
    }

    @Test func oneSessionCannotConsumeTheWholeQueueOrResetItsQuotaWithDisplayLabels() throws {
        let harness = try MCPTestHarness()

        for index in 0..<ToolingMCPService.maximumReviewRequestsPerSession {
            try harness.initialize(clientName: "Self-reported identity \(index)")
            _ = try harness.callTool("request_add_mcp_server", arguments: addServerArguments(name: "noisy-\(index)"))
        }
        try harness.initialize(clientName: "One more invented identity")
        let overflow = try #require(
            harness.rawCallTool("request_add_mcp_server", arguments: addServerArguments(name: "noisy-overflow")))
        guard case .object(let result)? = overflow["result"] else {
            Issue.record("The session-quota response produced no result.")
            return
        }
        #expect(result["isError"]?.boolValue == true)
        #expect(try harness.pendingRequests().count == ToolingMCPService.maximumReviewRequestsPerSession)
    }

    @Test func aCreateSkillRequestAlsoWritesTheDraftTheAppRouteResolves() throws {
        let harness = try MCPTestHarness()
        try harness.initialize()

        let payload = try harness.callTool(
            "request_create_skill",
            arguments: [
                "instruction": .string("Summarize a release branch before tagging."),
                "proposedName": .string("release-summary"),
                "scope": .string("user"),
                "targets": .array([.string("codex"), .string("claude-code")]),
            ]
        )

        let rows = try harness.pendingRequests()
        #expect(rows.count == 1)
        #expect(payload["state"]?.stringValue == "pending-review")

        let draft = try harness.store.requestDraft(rows[0].id, as: CodexSkillDraftRequest.self)
        let resolved = try #require(draft)
        #expect(resolved.proposedName == "release-summary")
        #expect(resolved.targets == [.claude, .codex])
    }

    @Test func aCollapsedCreateSkillRequestRepairsItsMissingDraftPayload() throws {
        let harness = try MCPTestHarness()
        try harness.initialize()
        let arguments: [String: JSONValue] = [
            "instruction": .string("Summarize a release branch before tagging."),
            "proposedName": .string("release-summary"),
            "scope": .string("user"),
            "targets": .array([.string("codex")]),
        ]

        _ = try harness.callTool("request_create_skill", arguments: arguments)
        let request = try #require(harness.pendingRequests().first)
        try harness.store.deleteRequestDraft(request.id)

        let repeated = try harness.callTool("request_create_skill", arguments: arguments)

        #expect(repeated["collapsedIntoExistingRequest"]?.boolValue == true)
        #expect(try harness.pendingRequests().count == 1)
        #expect(try harness.store.requestDraft(request.id, as: CodexSkillDraftRequest.self)?
            .proposedName == "release-summary")
    }

    @Test func aRequestWithAnInlineSecretIsRefused() throws {
        let harness = try MCPTestHarness()
        try harness.initialize()

        let response = try #require(
            harness.rawCallTool(
                "request_add_mcp_server",
                arguments: [
                    "name": .string("leaky"),
                    "transport": .string("stdio"),
                    "endpoint": .string("weather-mcp --api-key sk-live-abcdef123456"),
                    "scope": .string("user"),
                    "targets": .array([.string("claude-code")]),
                ]
            ))
        guard case .object(let result)? = response["result"] else {
            Issue.record("Expected a tool result.")
            return
        }
        #expect(result["isError"]?.boolValue == true)
        let queued = try harness.pendingRequests()
        #expect(queued.isEmpty)
        #expect(!JSONValue.object(result).allStrings.contains { $0.contains("sk-live-abcdef123456") })
    }

    @Test func aProjectScopedRequestNeedsAnAbsoluteRootAndNeverReturnsIt() throws {
        let harness = try MCPTestHarness()
        try harness.initialize()

        let relative = try #require(
            harness.rawCallTool(
                "request_install_skill",
                arguments: [
                    "skillID": .string("release-summary"),
                    "scope": .string("project"),
                    "projectRoot": .string("relative/path"),
                    "targets": .array([.string("codex")]),
                ]
            ))
        #expect(relative["error"] != nil)

        let payload = try harness.callTool(
            "request_install_skill",
            arguments: [
                "skillID": .string("release-summary"),
                "scope": .string("project"),
                "projectRoot": .string("/Users/someone/Projects/pumpd"),
                "targets": .array([.string("codex")]),
            ]
        )
        let rows = try harness.pendingRequests()
        // Standardized the same way `agent-tooling request create-skill --project`
        // standardizes it, trailing separator included, so the app sees one shape.
        #expect(rows[0].reviewDetails.projectRoot == "/Users/someone/Projects/pumpd/")
        // The reviewer sees the root in the app. The caller never gets it back.
        #expect(!JSONValue.object(payload).allStrings.contains { $0.contains("pumpd") })
    }

    @Test func requestToolsAcceptOneComponentAndRefuseAnythingUndeclared() throws {
        let harness = try MCPTestHarness()
        try harness.initialize()

        // No bulk variant exists, and an array smuggled into the single-component
        // argument is refused rather than partly honored.
        var bulk = addServerArguments()
        bulk["name"] = .array([.string("weather"), .string("calendar")])
        let bulkResponse = try #require(harness.rawCallTool("request_add_mcp_server", arguments: bulk))
        #expect(bulkResponse["error"] != nil)

        var extra = addServerArguments()
        extra["workspace"] = .string("/tmp/elsewhere")
        let extraResponse = try #require(harness.rawCallTool("request_add_mcp_server", arguments: extra))
        #expect(extraResponse["error"] != nil)

        var homeOverride = addServerArguments()
        homeOverride["home"] = .string("/tmp/elsewhere")
        let homeResponse = try #require(harness.rawCallTool("request_add_mcp_server", arguments: homeOverride))
        #expect(homeResponse["error"] != nil)

        let queued = try harness.pendingRequests()
        #expect(queued.isEmpty)
    }

    @Test func aPendingRequestIsListedAndNeverReportsAnApproval() throws {
        let harness = try MCPTestHarness()
        try harness.initialize()
        _ = try harness.callTool("request_add_mcp_server", arguments: addServerArguments())

        let listed = try harness.callTool("list_pending_requests")
        let rows = try #require(listed["requests"]?.arrayValue)
        #expect(rows.count == 1)
        #expect(rows[0].objectValue?["state"]?.stringValue == "pending-review")

        let queuedRows = try harness.pendingRequests()
        let id = try #require(queuedRows.first?.id)
        let status = try harness.callTool("get_request_status", arguments: ["requestID": .string(id.uuidString)])
        let request = try #require(status["request"]?.objectValue)
        #expect(request["state"]?.stringValue == "pending-review")

        // No state a caller can reach ever reads as approved.
        let everyString = JSONValue.object(status).allStrings + JSONValue.object(listed).allStrings
        #expect(!everyString.contains { $0.lowercased().contains("approved") })
    }
}
