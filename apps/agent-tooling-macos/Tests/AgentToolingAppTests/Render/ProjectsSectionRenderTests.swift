import Foundation
import SwiftUI
import Testing

@testable import AgentToolingApp
@testable import AgentToolingCore

/// Projects draw the logical projects this workspace holds.
@Suite("Projects renders")
@MainActor
struct ProjectsSectionRenderTests {
    @Test func theShellDrawsProjects() async throws {
        let fixture = try await ShellRenderFixture()
        defer { fixture.remove() }

        try expectDrawn(renderShell(.projects, fixture: fixture))
    }

    /// A project with something assigned to it and a folder on this device
    /// draws a populated row and clause rather than the "no folder yet" and
    /// "0 tools assigned" defaults every other project in the fixture has.
    @Test func theShellDrawsAProjectWithAssignedTools() async throws {
        let fixture = try await ShellRenderFixture()
        defer { fixture.remove() }
        try await fixture.assignSkillToFixtureProject()

        try expectDrawn(renderShell(.projects, fixture: fixture))
    }

    /// Nothing in the shell deep-links into one project today, so this
    /// exercises `ProjectDetailView` directly through the same
    /// `initialSelection` seam a future route could reuse — the tabs, the
    /// "In this project" / "Inherited from this Mac" cards, and the location
    /// text over a real device folder binding.
    @Test func theProjectDetailPaneDraws() async throws {
        let fixture = try await ShellRenderFixture()
        defer { fixture.remove() }
        try await fixture.assignSkillToFixtureProject()

        try expectDrawn(
            ProjectsView(workspace: fixture.workspace, initialSelection: ShellRenderFixture.projectID)
                .frame(width: shellWindowSize.width, height: shellWindowSize.height))
    }
}
