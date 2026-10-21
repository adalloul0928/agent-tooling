import Foundation
import Testing

@testable import AgentToolingCore

/// Taking Agent Tooling's own connection out of an app (D10): the command each
/// app's own tool runs, the operation it runs in, and the receipt it leaves,
/// which ends the proof an earlier set-up gave, so a registration somebody
/// makes under the name afterwards is theirs.
@Suite("Deployment operations · taking a connection out")
struct WorkspaceDeploymentOperationsConnectionRemovalTests {
    private static let helper = "/Applications/Agent Tooling.app/Contents/Helpers/agent-tooling-mcp"

    @Test(arguments: ClientKind.allCases)
    func eachAppRemovesItByNameWithItsOwnTool(client: ClientKind) throws {
        let tool = URL(filePath: "/opt/tools").appending(path: MCPClientCommand.executable(for: client))
        let plan = try Self.removal(surface: client.defaultSurface, tool: tool)

        #expect(plan.isRemoval)
        #expect(plan.preArguments == nil)
        #expect(plan.arguments == MCPClientCommand.removeArguments(serverID: "agent-tooling", client: client, scope: .user))
        #expect(plan.arguments == AgentToolingConnection.previewRemovalArguments(client: client))
        #expect(plan.executableURL == tool)
        if client == .kiro {
            #expect(plan.arguments == ["mcp", "remove", "--name", "agent-tooling", "--scope", "global"], "Kiro CLI removes by name too")
        }
    }

    @Test func aRemovalIsRefusedAnywhereButThePersonsOwnScopeWithTheAppsOwnTool() {
        let claude = URL(filePath: "/opt/tools/claude")
        #expect(throws: WorkspaceManagedMCPCommandPlanningError.invalidCLIURL) {
            try Self.removal(surface: .claudeCode, tool: URL(filePath: "/opt/tools/codex"))
        }
        #expect(throws: WorkspaceManagedMCPCommandPlanningError.unsupportedScope(.project, .claude)) {
            try Self.removal(surface: .claudeCode, tool: claude, scope: .project)
        }
        #expect(throws: WorkspaceManagedMCPCommandPlanningError.invalidNativeServerIdentifier) {
            try Self.removal(surface: .claudeCode, tool: claude, name: "agent tooling; rm -rf ~")
        }
    }

    /// The removal runs in an operation of its own, after the app's adds: one
    /// step per connection, titled as its receipt keeps it.
    @Test func aRemovalRunsLastInItsAppAsItsOwnOperation() throws {
        let add = WorkspaceManagedMCPCommandPlan(
            artifactID: ArtifactID(), physicalDestinationID: WorkspaceObjectID(), surface: .claudeCode, scope: .user,
            nativeServerIdentifier: "sentry", executableURL: URL(filePath: "/opt/tools/claude"), executable: "claude",
            arguments: ["mcp", "add", "--transport", "http", "--scope", "user", "sentry", "https://mcp.sentry.dev/mcp"],
            workingDirectoryPath: nil)
        let removal = try Self.removal(surface: .claudeCode, tool: URL(filePath: "/opt/tools/claude"))

        let run = WorkspaceDeploymentOperations.run(staged: [], managedConnections: [removal, add])

        #expect(run.operations.map(\.title) == ["Set up 1 connection in Claude Code", "Remove 1 connection from Claude Code"])
        let operation = try #require(run.operations.last)
        #expect(operation.kind == .configureMCP)
        #expect(operation.targetSurfaces == [.claudeCode])
        let step = try #require(operation.steps.first)
        #expect(operation.steps.count == 1)
        #expect(step.title == "Remove agent-tooling")
        #expect(step.executable == "/opt/tools/claude")
        #expect(step.arguments == ["mcp", "remove", "--scope", "user", "agent-tooling"])
        #expect(step.stopsOnFailure == nil, "a failed removal stops nothing else")
        #expect(
            run.installKeys[step.id]
                == .init(artifactID: removal.artifactID, physicalDestinationID: removal.physicalDestinationID))
    }

    // MARK: - The proof

    @Test func aLaterRemovalEndsTheProofAndALaterSetUpGivesItAgain() {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let setUp = Self.receipt(.claudeCode, "Set up agent-tooling", at: start)
        let removed = Self.receipt(.claudeCode, "Remove agent-tooling", at: start.addingTimeInterval(60))
        let again = Self.receipt(.claudeCode, "Set up agent-tooling", at: start.addingTimeInterval(120))
        let codex = Self.receipt(.codexCLI, "Set up agent-tooling", at: start)

        // Whatever order they come in: the store lists the newest first.
        for receipts in [[removed, setUp, codex], [setUp, removed, codex]] {
            #expect(WorkspaceDeploymentOperations.provenConnections(in: receipts) == [.codexCLI: ["agent-tooling"]])
            #expect(AgentToolingConnection.provenSurfaces(in: receipts) == [.codexCLI])
        }
        #expect(AgentToolingConnection.provenSurfaces(in: [again, removed, setUp]) == [.claudeCode])
        // A removal before the set-up ends nothing.
        #expect(
            AgentToolingConnection.provenSurfaces(in: [
                Self.receipt(.claudeCode, "Set up agent-tooling", at: start.addingTimeInterval(60)),
                Self.receipt(.claudeCode, "Remove agent-tooling", at: start),
            ]) == [.claudeCode])
    }

    /// The removal a replacement runs before its add, and a removal that
    /// failed, end nothing; nor does taking out another connection.
    @Test func onlyASucceededRemovalForGoodOfThatConnectionEndsTheProof() {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let setUp = Self.receipt(.claudeCode, "Set up agent-tooling", at: start)
        for later in [
            Self.receipt(.claudeCode, "Remove the old agent-tooling", at: start.addingTimeInterval(60)),
            Self.receipt(.claudeCode, "Remove agent-tooling", status: .failed, at: start.addingTimeInterval(60)),
            Self.receipt(.claudeCode, "Remove sentry", at: start.addingTimeInterval(60)),
            Self.receipt(.geminiCLI, "Remove agent-tooling", at: start.addingTimeInterval(60)),
        ] {
            #expect(AgentToolingConnection.provenSurfaces(in: [later, setUp]) == [.claudeCode], "\(later.itemOutcomes)")
        }
    }

    /// The proof reads the titles the reviewed plan writes: a receipt of the
    /// removal operation, step for step, ends it.
    @Test func theProofReadsTheRemovalTitleTheReviewedPlanWrites() throws {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let setUp = Self.receipt(.claudeCode, "Set up agent-tooling", at: start)
        let run = WorkspaceDeploymentOperations.run(
            staged: [], managedConnections: [try Self.removal(surface: .claudeCode, tool: URL(filePath: "/opt/tools/claude"))])
        let operation = try #require(run.operations.first)
        let removed = OperationReceipt(
            planID: operation.id, kind: operation.kind, title: operation.title, state: .healthy,
            targetSurfaces: operation.targetSurfaces, results: [], createdAt: start.addingTimeInterval(60), verificationSummary: "",
            itemOutcomes: operation.steps.map { .init(id: $0.id, title: $0.title, status: .succeeded, reason: "Completed.") })

        #expect(AgentToolingConnection.provenSurfaces(in: [removed, setUp]).isEmpty)
    }

    // MARK: - Building one

    private static func removal(
        surface: TargetSurface, tool: URL, scope: ToolingScope = .user, name: String = AgentToolingConnection.declaredName
    ) throws -> WorkspaceManagedMCPCommandPlan {
        try WorkspaceManagedMCPCommandPlanning.removal(
            artifactID: ArtifactID(), physicalDestinationID: WorkspaceObjectID(), surface: surface, scope: scope,
            nativeServerIdentifier: name, executableURL: tool)
    }

    private static func receipt(
        _ surface: TargetSurface, _ title: String, status: OperationStepStatus = .succeeded, at date: Date
    ) -> OperationReceipt {
        OperationReceipt(
            planID: UUID(), kind: .configureMCP, title: "A connection in \(surface.displayName)", state: .healthy,
            targetSurfaces: [surface], results: [], createdAt: date, verificationSummary: "",
            itemOutcomes: [.init(id: UUID(), title: title, status: status, reason: "Completed.")])
    }
}
