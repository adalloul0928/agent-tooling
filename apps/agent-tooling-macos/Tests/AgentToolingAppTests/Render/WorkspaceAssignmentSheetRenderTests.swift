import Foundation
import SwiftUI
import Testing

@testable import AgentToolingApp
@testable import AgentToolingCore

/// The one sheet Skills, Plugins, Presets and MCP servers all open to choose
/// where an item is used.
@Suite("Workspace assignment sheet renders")
@MainActor
struct WorkspaceAssignmentSheetRenderTests {
    @Test func theSheetDrawsWithNothingPreselected() async throws {
        let fixture = try await ShellRenderFixture()
        defer { fixture.remove() }

        try expectDrawn(
            WorkspaceAssignmentSheet(session: fixture.workspace.library, artifactIDs: [ShellRenderFixture.skill]))
    }

    /// Preselection enables the footer's glass button on the first layout.
    /// An enabled GlassEffectContainer can make cacheDisplay return a flat
    /// frame, including sibling views; its disabled form captures correctly.
    /// This guards rendering with initial selections, not selection logic.
    @Test func theSheetDrawsWithClientsPreselected() async throws {
        let fixture = try await ShellRenderFixture()
        defer { fixture.remove() }

        let bitmap = try rasterize(
            WorkspaceAssignmentSheet(
                session: fixture.workspace.library, artifactIDs: [ShellRenderFixture.skill],
                initialClients: [.claude, .gemini]))

        #expect(distinctColours(in: bitmap) > 4, "the sheet drew a blank frame")
    }

    /// Opening straight into a project scope, on a project with no folder on
    /// this Mac, draws the picker and the inline "installing waits" note rather
    /// than a blank frame. The fixture's project has no folder binding, so this
    /// is the note path, not the folder-present one.
    @Test func theSheetDrawsInProjectScopeForAFolderlessProject() async throws {
        let fixture = try await ShellRenderFixture()
        defer { fixture.remove() }

        try expectDrawn(
            WorkspaceAssignmentSheet(
                session: fixture.workspace.library, artifactIDs: [ShellRenderFixture.skill],
                initialProjectID: ShellRenderFixture.projectID))
    }
}
