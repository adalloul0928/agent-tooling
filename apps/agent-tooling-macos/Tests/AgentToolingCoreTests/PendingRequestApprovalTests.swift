import Foundation
import Testing

@testable import AgentToolingCore

private struct PendingRequestRunner: CommandRunning {
    func run(executable: String, arguments: [String], currentDirectory: URL?) async throws -> CommandOutput {
        CommandOutput(status: 127, standardOutput: "", standardError: "command not found")
    }
}

@MainActor
@Suite("Pending request approval boundary")
struct PendingRequestApprovalTests {
    @Test func matchingSkillDraftCanContinueButDoesNotInstallAnything() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let instruction = "Summarize a release branch before tagging."
        let outcome = try fixture.enqueueCreateSkill(instruction: instruction)
        try fixture.store.saveCodexSkillDraftRequest(
            CodexSkillDraftRequest(
                id: outcome.request.id,
                instruction: instruction,
                proposedName: "release-summary",
                targets: [.codex]
            ))

        let continuation = fixture.model.acceptPendingRequest(
            id: outcome.request.id,
            expectedFingerprint: outcome.request.fingerprint
        )

        #expect(continuation == .skillCreation(outcome.request.id))
        #expect(try fixture.store.loadPendingAgentRequestQueue().requests.isEmpty)
        #expect(try fixture.store.loadCodexSkillDraftRequest(id: outcome.request.id) != nil)
        #expect(fixture.model.pendingPlan == nil)
    }

    @Test func mismatchedSkillDraftCannotCrossTheReviewBoundary() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let outcome = try fixture.enqueueCreateSkill(instruction: "Reviewed instruction")
        try fixture.store.saveCodexSkillDraftRequest(
            CodexSkillDraftRequest(
                id: outcome.request.id,
                instruction: "Different stored instruction",
                proposedName: "release-summary",
                targets: [.codex]
            ))

        #expect(
            fixture.model.acceptPendingRequest(
                id: outcome.request.id,
                expectedFingerprint: outcome.request.fingerprint
            ) == nil)
        #expect(try fixture.store.loadPendingAgentRequestQueue().requests.map(\.id) == [outcome.request.id])
        #expect(fixture.model.lastError?.contains("does not match") == true)
    }

    @Test func tamperedOperationalFieldsFailTheirIntegrityFingerprint() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let outcome = try fixture.enqueueMCPServer()
        var queue = try fixture.store.loadPendingAgentRequestQueue()
        queue.requests[0].reviewDetails.endpoint = "https://attacker.example/mcp"
        try fixture.store.savePendingAgentRequestQueue(queue)

        #expect(
            fixture.model.acceptPendingRequest(
                id: outcome.request.id,
                expectedFingerprint: outcome.request.fingerprint
            ) == nil)
        #expect(fixture.model.mcpServers.isEmpty)
        #expect(fixture.model.pendingPlan == nil)
        #expect(try fixture.store.loadPendingAgentRequestQueue().requests.count == 1)
        #expect(fixture.model.lastError?.contains("integrity fingerprint") == true)
    }

    @Test func validMCPRequestBuildsAnAppOwnedPlanBeforeAnythingCanRun() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let outcome = try fixture.enqueueMCPServer()
        fixture.model.refreshPendingRequests()
        #expect(fixture.model.pendingAgentRequests.map(\.id) == [outcome.request.id])

        #expect(
            fixture.model.acceptPendingRequest(
                id: outcome.request.id,
                expectedFingerprint: outcome.request.fingerprint
            ) == .operationPlan)
        #expect(fixture.model.pendingPlan?.title == "Configure weather")
        #expect(fixture.model.mcpServers.map(\.id) == ["weather"])
        #expect(try fixture.store.loadPendingAgentRequestQueue().requests.isEmpty)
        #expect(fixture.model.pendingAgentRequests.isEmpty)
        #expect(try fixture.store.listEntities(domain: .plans, as: OperationPlan.self).isEmpty)
    }

    @Test func failedPreparationRestoresTheClaimedRequestAndDesiredState() throws {
        let existing = MCPServer(
            id: "weather",
            name: "Weather",
            summary: "Managed by Agent Tooling",
            endpoint: "https://weather.example/mcp",
            transport: .http,
            authentication: "OAuth",
            scope: ToolingScope.user.displayName,
            clients: [ClientState(client: .claude, state: .healthy, detail: "Installed")],
            definitionOrigin: .managed
        )
        let fixture = try Fixture(snapshot: WorkspaceSnapshot(mcpServers: [existing]))
        defer { fixture.remove() }
        let outcome = try fixture.enqueueMCPServer()

        #expect(
            fixture.model.acceptPendingRequest(
                id: outcome.request.id,
                expectedFingerprint: outcome.request.fingerprint
            ) == nil)
        #expect(fixture.model.pendingPlan == nil)
        #expect(fixture.model.mcpServers.map(\.id) == ["weather"])
        #expect(try fixture.store.loadPendingAgentRequestQueue().requests.map(\.id) == [outcome.request.id])
        #expect(fixture.model.lastError?.contains("still waiting for review") == true)
    }

    @Test func continueRefusesARequestSwappedAfterTheSheetOpened() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let shown = try fixture.enqueueMCPServer().request
        let swappedEndpoint = "https://attacker.example/mcp"
        var queue = try fixture.store.loadPendingAgentRequestQueue()
        queue.requests[0].reviewDetails.endpoint = swappedEndpoint
        queue.requests[0].fingerprint = PendingRequestQueueService.fingerprint(
            kind: .addMCPServer,
            inputs: ["weather", MCPTransport.http.rawValue, swappedEndpoint, ""],
            scope: .user,
            targets: [.claude]
        )
        try fixture.store.savePendingAgentRequestQueue(queue)

        #expect(
            fixture.model.acceptPendingRequest(
                id: shown.id,
                expectedFingerprint: shown.fingerprint
            ) == nil)
        let current = try #require(try fixture.store.loadPendingAgentRequestQueue().requests.first)
        #expect(current.reviewDetails.endpoint == swappedEndpoint)
        #expect(fixture.model.pendingPlan == nil)
        #expect(fixture.model.mcpServers.isEmpty)
        #expect(fixture.model.lastError?.contains("changed after you opened") == true)
    }

    @Test func rejectRefusesARequestSwappedAfterTheSheetOpened() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let shown = try fixture.enqueueMCPServer().request
        let swappedEndpoint = "https://attacker.example/mcp"
        var queue = try fixture.store.loadPendingAgentRequestQueue()
        queue.requests[0].reviewDetails.endpoint = swappedEndpoint
        queue.requests[0].fingerprint = PendingRequestQueueService.fingerprint(
            kind: .addMCPServer,
            inputs: ["weather", MCPTransport.http.rawValue, swappedEndpoint, ""],
            scope: .user,
            targets: [.claude]
        )
        try fixture.store.savePendingAgentRequestQueue(queue)

        #expect(
            !fixture.model.rejectPendingRequest(
                id: shown.id,
                expectedFingerprint: shown.fingerprint
            ))
        let current = try #require(try fixture.store.loadPendingAgentRequestQueue().requests.first)
        #expect(current.reviewDetails.endpoint == swappedEndpoint)
        #expect(fixture.model.lastError?.contains("changed after you opened") == true)
    }

    @MainActor
    private struct Fixture {
        let root: URL
        let store: WorkspaceStore
        let model: AppModel

        init(snapshot: WorkspaceSnapshot? = nil) throws {
            root = FileManager.default.temporaryDirectory
                .appending(path: "PendingRequestApproval-\(UUID().uuidString)", directoryHint: .isDirectory)
            store = try WorkspaceStore(rootURL: root.appending(path: "workspace", directoryHint: .isDirectory))
            if let snapshot { try store.saveWorkspaceSnapshot(snapshot) }
            model = try AppModel(
                store: store,
                runner: PendingRequestRunner(),
                homeURL: root.appending(path: "home", directoryHint: .isDirectory)
            )
        }

        func enqueueMCPServer() throws -> PendingRequestOutcome {
            try PendingRequestQueueService.enqueue(
                kind: .addMCPServer,
                title: "Add the MCP server 'weather'",
                summary: "A local client is asking to add weather.",
                componentID: "weather",
                scope: .user,
                targets: [.claude],
                reason: nil,
                reviewDetails: PendingRequestReviewDetails(
                    endpoint: "https://weather.example/mcp",
                    transport: MCPTransport.http.rawValue
                ),
                fingerprintInputs: ["weather", MCPTransport.http.rawValue, "https://weather.example/mcp", ""],
                clientLabel: "Test client",
                store: store
            )
        }

        func enqueueCreateSkill(instruction: String) throws -> PendingRequestOutcome {
            try PendingRequestQueueService.enqueue(
                kind: .createSkill,
                title: "Create the skill 'release-summary'",
                summary: "A local client is asking to create a skill.",
                componentID: "release-summary",
                scope: .user,
                targets: [.codex],
                reason: nil,
                reviewDetails: PendingRequestReviewDetails(instruction: instruction),
                fingerprintInputs: ["release-summary", instruction, ""],
                clientLabel: "Test client",
                store: store
            )
        }

        func remove() {
            try? FileManager.default.removeItem(at: root)
        }
    }
}
