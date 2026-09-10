import Foundation
import Testing

@testable import AgentToolingApp
@testable import AgentToolingCore

/// What `ProjectsSectionRenderTests` needs beyond the shared fixture: the
/// fixture's project with something actually assigned to it, and a folder
/// binding on this device, so the render test exercises the detail pane's
/// "In this project" card and its location text rather than only the
/// no-folder, nothing-assigned empty state.
extension ShellRenderFixture {
    /// Assigns the fixture's standalone skill to Project A on this device, and
    /// binds Project A to a folder on this device — both through the
    /// workspace's own public commands.
    func assignSkillToFixtureProject() async throws {
        await workspace.library.reviewAssignments(
            artifactIDs: [Self.skill],
            destinations: [
                .init(
                    surface: .claudeCode, scope: .project, logicalProjectID: Self.projectID,
                    deviceIDs: [store.deviceID])
            ])
        await workspace.library.applyReviewedAssignments()

        guard let head = try await workspace.service.snapshot()?.document.revision.id else {
            Issue.record("Fixture workspace has no revision to bind the project folder onto.")
            return
        }
        // Captured into a local first: the mutation closure is `@Sendable`, so
        // it cannot reach across to a main-actor-isolated static property.
        let projectID = Self.projectID
        _ = try await workspace.service.commitDeviceChange(expectedRevisionID: head) { device in
            device.projectRoots =
                (device.projectRoots ?? []) + [
                    .init(projectID: projectID, rootPath: "/tmp/agent-tooling-render-fixture/project-a")
                ]
        }
        await workspace.library.refresh()
    }
}
