import Foundation
import SwiftUI
import Testing

@testable import AgentToolingApp
@testable import AgentToolingCore

/// The library draws the workspace it was given.
@Suite("Library · Skills renders")
@MainActor
struct SkillsSectionRenderTests {
    @Test func theShellDrawsSkills() async throws {
        let fixture = try await ShellRenderFixture()
        defer { fixture.remove() }
        let preferences = try ShellRenderFixture.preferences()
        defer { preferences.remove() }
        let service = StubSkillContentService()

        try expectDrawn(
            renderShell(.skills, fixture: fixture)
                .environment(\.skillContentService, service)
                .defaultAppStorage(preferences.defaults))

        // Drawing the list reads no stored content and reaches no repository.
        // A screen that opened a content store or ran `git` to show a row would
        // do it on somebody's Mac too, before they asked for anything.
        #expect(service.readCount == 0)
        #expect(service.fetchCount == 0)
        #expect(service.writeCount == 0)
    }

    /// A library nothing has been assigned in still opens onto getting started,
    /// and it is still only this section that it stands in front of.
    @Test func theShellDrawsOnboardingBeforeAnythingIsAssigned() async throws {
        let fixture = try await ShellRenderFixture()
        defer { fixture.remove() }
        let preferences = try ShellRenderFixture.preferences(onboardingSkipped: false)
        defer { preferences.remove() }

        try expectDrawn(
            renderShell(.skills, fixture: fixture)
                .environment(\.skillContentService, StubSkillContentService())
                .defaultAppStorage(preferences.defaults))
        try expectDrawn(
            renderShell(.plugins, fixture: fixture)
                .defaultAppStorage(preferences.defaults))
    }

    /// One saved assignment is enough to put the gate away, and the screen
    /// behind it draws the row that was assigned.
    @Test func theScreenDrawsOnceSomethingIsAssigned() async throws {
        let fixture = try await ShellRenderFixture()
        defer { fixture.remove() }
        let preferences = try ShellRenderFixture.preferences(onboardingSkipped: false)
        defer { preferences.remove() }
        await fixture.assignStandaloneSkill()

        let assigned = try #require(
            fixture.workspace.library.state?.library.rows.first { $0.artifactID == ShellRenderFixture.skill })
        #expect(!assigned.requestedAssignments.isEmpty)

        try expectDrawn(
            renderShell(.skills, fixture: fixture)
                .environment(\.skillContentService, StubSkillContentService())
                .defaultAppStorage(preferences.defaults))
    }

    /// A device check speaks in the name a skill declared, never its display
    /// name, so the row and the observation only meet if both carry it. This
    /// is `declaredName` doing that job: `WorkspaceLibraryReadModelRow` carries
    /// it straight from the artifact now, rather than a screen re-reading the
    /// document to recover it.
    @Test func theJoinLightsAClientMarkFromADeclaredName() async throws {
        var observation = ShellRenderFixture.observation(.claudeCode, installed: true, commandAvailable: true)
        observation.skillMetadata = [
            "standalone-skill": .init(
                path: "/Users/example/.claude/skills/standalone-skill", source: "Claude Code skill")
        ]
        let fixture = try await ShellRenderFixture(deviceObserver: StubDeviceObserver(observations: [observation]))
        defer { fixture.remove() }
        let preferences = try ShellRenderFixture.preferences()
        defer { preferences.remove() }
        await fixture.workspace.device.refresh()

        let index = SkillInventoryIndex(
            library: fixture.workspace.library.state?.library,
            snapshot: fixture.workspace.library.state?.snapshot,
            observations: fixture.workspace.device.observations,
            ownershipJSON: "{}")
        #expect(index.observedClients[ShellRenderFixture.skill] == [.claude])

        try expectDrawn(
            renderShell(.skills, fixture: fixture)
                .environment(\.skillContentService, StubSkillContentService())
                .defaultAppStorage(preferences.defaults))
    }
}
