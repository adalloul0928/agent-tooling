import AgentToolingCore
import AgentToolingTestSupport
import Foundation
import Testing

@testable import AgentToolingApp

/// D39: the sidebar's Apps badge and Home's "need attention" line count the
/// connections that need the person (signed out, failing, waiting for
/// approval), never a status the check could not read, which is every one
/// Codex lists.
@Suite("Connections that need you", .timeLimit(.minutes(5)))
@MainActor
struct WorkspaceHealthNeedsYouTests {
    /// Juniper's check: Sentry needs a sign-in in Claude Code; Codex lists
    /// its two connections with no status it reports.
    private static let juniper = [
        "claude mcp list": """
        plugin:github:github: https://api.githubcopilot.com/mcp/ (HTTP) - ✔ Connected
        plugin:sentry:sentry: https://mcp.sentry.dev/mcp (HTTP) - ! Needs authentication
        context7: https://mcp.context7.com/mcp (HTTP) - ✔ Connected
        """,
        "codex mcp list --json":
            #"[{"name":"playwright","enabled":true,"transport":{"type":"stdio","command":"npx"}},{"name":"linear","enabled":true,"transport":{"type":"streamable_http","url":"https://mcp.linear.app/mcp"}}]"#,
    ]

    @Test func codexsUnreadStatusesAreNotCounted() async throws {
        let fixture = try await ShellRenderFixture()
        defer { fixture.remove() }
        let health = try await FinishSetupHealthCheck.checked(fixture: fixture, managing: [.codex, .claude], answers: Self.juniper)

        #expect(health.entries.count == 5)
        #expect(health.needsYouCount == 1)
        // The old count took Codex's two unread rows as two more problems.
        #expect(health.attentionCount == 3)
    }

    @Test func failingAndPendingConnectionsNeedYouToo() {
        #expect(ConnectionHealthStatus.needsAuthentication.needsYou)
        #expect(ConnectionHealthStatus.failed(detail: "timed out").needsYou)
        #expect(ConnectionHealthStatus.pendingApproval.needsYou)
        #expect(!ConnectionHealthStatus.unknown(rawText: "?").needsYou)
        #expect(!ConnectionHealthStatus.connected.needsYou)
        #expect(!ConnectionHealthStatus.disabled.needsYou)
        #expect(!ConnectionHealthStatus.notConfigured.needsYou)
    }

    /// Before any check there is nothing to count, so Apps carries no badge
    /// from its connections (P01: no Apps badge after setup).
    @Test func theAppsBadgeCountsUnreachableAppsAndConnectionsThatNeedYou() async throws {
        let fixture = try await ShellRenderFixture()
        defer { fixture.remove() }
        #expect(
            SidebarView.appsBadge(device: fixture.workspace.device, health: fixture.workspace.health)
                == fixture.workspace.device.attentionCount)

        let health = try await FinishSetupHealthCheck.checked(fixture: fixture, managing: [.codex, .claude], answers: Self.juniper)

        #expect(SidebarView.appsBadge(device: fixture.workspace.device, health: health) == fixture.workspace.device.attentionCount + 1)
    }

    /// The sign-in row's predicate and the badge agree: a check that leaves
    /// only Codex's unread rows signs every connection in.
    @Test func theSignInRowAndTheBadgeReadTheSameCheck() async throws {
        let fixture = try await ShellRenderFixture()
        defer { fixture.remove() }
        var answers = Self.juniper
        answers["claude mcp list"] = "plugin:sentry:sentry: https://mcp.sentry.dev/mcp (HTTP) - ✔ Connected"
        let health = try await FinishSetupHealthCheck.checked(fixture: fixture, managing: [.codex, .claude], answers: answers)
        var facts = FinishSetupFacts(record: FinishSetupFixture.record(.juniper))
        facts.signInCandidates = [FinishSetupFixture.sentry]
        facts.connectionCheck = FinishSetupFacts.connectionCheck(health, naming: facts)

        #expect(health.needsYouCount == 0)
        #expect(FinishSetupChecklist.satisfied(facts).contains(.signInConnections))
        #expect(facts.connectionCheck?.connected.map(\.name) == ["Sentry"])
        #expect(FinishSetupChecklist.summary(for: .signInConnections, facts: facts, now: FinishSetupFixture.doneAt) == "Sentry signed in")
    }
}
