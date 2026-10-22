import Foundation
import Testing

@testable import AgentToolingApp
@testable import AgentToolingCore

/// An assignment to an app this Mac has not checked yet — one skipped during
/// the first read — is held back by name, and the rest of the plan still
/// forms. It used to take the whole plan down with it.
@Suite("Deployment · an app not checked yet") @MainActor
struct WorkspaceDeploymentSessionNotCheckedTests {
    @Test func anAssignmentToAnAppNotCheckedYetIsHeldBackByName() async throws {
        let fixture = try await ShellRenderFixture()
        defer { fixture.remove() }
        // The fixture's device record holds no observation at all, so Codex
        // has not been checked on this Mac.
        #expect(try fixture.store.snapshot()?.device.observations.isEmpty == true)
        await fixture.assignStandaloneSkill(to: .codexCLI)

        await fixture.workspace.deployment.prepare()

        #expect(fixture.workspace.deployment.errorMessage == nil)
        let plan = try #require(fixture.workspace.deployment.plan)
        let held = plan.exclusions.filter { $0.artifactID == ShellRenderFixture.skill }
        #expect(held.map(\.reason) == [.noDestination])
        #expect(held.map(\.detail) == ["Codex has not been checked on this Mac yet. Check your apps again."])
        #expect(plan.items.isEmpty)
    }
}
