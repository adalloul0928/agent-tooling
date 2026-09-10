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

    /// The apps a person ticked before this sheet ever opened — the Codex
    /// creator's "Use after review", for one — must not make the sheet that
    /// opens next any less drawable than the one that starts blank.
    ///
    /// assertion: preselecting a client makes `canReview` true from the first
    /// layout pass, which turns on the footer's `GlassEffectContainer` button
    /// rather than leaving it disabled. Isolated from everything else in this
    /// file — a bare `GlassEffectContainer` around one `.glassProminent`
    /// button, `.disabled(false)`, nothing else on screen — that alone is
    /// enough to make `rasterize`'s `cacheDisplay` capture come back as one
    /// flat colour, and it takes an unrelated sibling view down with it.
    /// Disabled, the same container captures fine. Nothing here is about
    /// `initialClients`'s own correctness: the identical repro has no
    /// `WorkspaceAssignmentSheet`, no `ShellRenderFixture`, and no library
    @Test func theSheetDrawsWithClientsPreselected() async throws {
        let fixture = try await ShellRenderFixture()
        defer { fixture.remove() }

        let bitmap = try rasterize(
            WorkspaceAssignmentSheet(
                session: fixture.workspace.library, artifactIDs: [ShellRenderFixture.skill],
                initialClients: [.claude, .gemini]))

        #expect(distinctColours(in: bitmap) > 4, "the sheet drew a blank frame")
    }
}
