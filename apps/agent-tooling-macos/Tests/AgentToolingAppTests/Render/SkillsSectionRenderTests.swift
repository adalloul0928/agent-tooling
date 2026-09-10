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
}
