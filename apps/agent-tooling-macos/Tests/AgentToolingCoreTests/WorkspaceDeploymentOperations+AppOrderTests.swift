import AgentToolingTestSupport
import Foundation
import Testing

@testable import AgentToolingCore

/// One apply's operations run in the app order (Codex, Claude Code, Gemini
/// CLI, Kiro CLI), and in each app what is copied first, then what the app
/// installs itself, then its connections; inside an operation the steps follow
/// the order the review lists them in, and every step maps back to the
/// reviewed step it carries out.
@Suite("Workspace deployment operations · app order")
struct WorkspaceDeploymentOperationsAppOrderTests {
    @Test func operationsRunInTheAppOrderAndKnowTheirReviewedSteps() throws {
        let copyCodex = Self.staged("release-notes", client: .codex)
        let copyClaude = Self.staged("release-notes", client: .claude)
        let copyClaudeSecond = Self.staged("changelog", client: .claude)
        let plugin = WorkspaceNativePluginCommandPlan(
            artifactID: ArtifactID(), physicalDestinationID: WorkspaceObjectID(), surface: .claudeCode, scope: .user,
            externalPluginID: "supabase@claude-plugins-official", executableURL: URL(fileURLWithPath: "/usr/local/bin/claude"),
            executable: "claude", arguments: ["plugin", "install", "supabase@claude-plugins-official", "--scope", "user"])
        let connectionClaude = Self.connection(.claudeCode)
        let connectionCodex = Self.connection(.codexCLI)
        let order = [
            copyCodex.installKey, Self.key(connectionCodex), copyClaudeSecond.installKey, copyClaude.installKey,
            .init(artifactID: plugin.artifactID, physicalDestinationID: plugin.physicalDestinationID), Self.key(connectionClaude),
        ].compactMap(\.self)

        let run = WorkspaceDeploymentOperations.run(
            staged: [copyClaude, copyCodex, copyClaudeSecond], nativePlugins: [plugin],
            managedConnections: [connectionClaude, connectionCodex], order: order)

        #expect(
            run.operations.map(\.title) == [
                "Install 1 tool in Codex", "Set up 1 connection in Codex", "Install 2 tools in Claude Code",
                "Install 1 package in Claude Code", "Set up 1 connection in Claude Code",
            ])
        // Every step, in the order the operations run them, maps back to the
        // reviewed step it carries out, which is the order the review listed.
        #expect(run.operations.flatMap(\.steps).map { run.installKeys[$0.id] } == order)
    }

    @Test func withoutAReviewOrderStepsFollowTheirNames() {
        let second = Self.staged("zeta", client: .codex)
        let first = Self.staged("alpha", client: .codex)
        let run = WorkspaceDeploymentOperations.run(staged: [second, first])
        #expect(run.operations.flatMap(\.steps).map(\.title) == ["Install alpha", "Install zeta"])
    }

    private static func staged(_ name: String, client: ClientKind) -> StagedDeployment {
        StagedDeployment(
            artifactID: ArtifactID(), deploymentName: name, stagingPath: "/tmp/staging/\(name)", fingerprint: "fingerprint",
            destinationPath: "/tmp/\(client.rawValue)/\(name)", client: client, scope: .user,
            physicalDestinationID: WorkspaceObjectID())
    }

    private static func connection(_ surface: TargetSurface) -> WorkspaceManagedMCPCommandPlan {
        WorkspaceManagedMCPCommandPlan(
            artifactID: ArtifactID(), physicalDestinationID: WorkspaceObjectID(), surface: surface, scope: .user,
            nativeServerIdentifier: AgentToolingConnection.declaredName,
            executableURL: URL(fileURLWithPath: "/usr/local/bin/\(surface == .codexCLI ? "codex" : "claude")"),
            executable: surface == .codexCLI ? "codex" : "claude", arguments: ["mcp", "add"], workingDirectoryPath: nil)
    }

    private static func key(_ plan: WorkspaceManagedMCPCommandPlan) -> WorkspaceDeploymentInstallKey {
        .init(artifactID: plan.artifactID, physicalDestinationID: plan.physicalDestinationID)
    }
}
