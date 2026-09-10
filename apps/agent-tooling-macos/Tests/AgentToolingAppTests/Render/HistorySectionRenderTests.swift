import Foundation
import SwiftUI
import Testing

@testable import AgentToolingApp
@testable import AgentToolingCore

/// History draws this workspace's restore points, in the same panel and card
/// language as its Activity sibling tab.
@Suite("Activity · History renders")
@MainActor
struct HistorySectionRenderTests {
    @Test func theShellDrawsHistory() async throws {
        let fixture = try await ShellRenderFixture()
        defer { fixture.remove() }
        await fixture.workspace.history.refresh()

        try expectDrawn(renderShell(.history, fixture: fixture))
    }

    /// Selecting the current point draws the "this is where you are" card
    /// rather than a change list, since there is nothing to go back to yet.
    @Test func selectingTheCurrentPointDrawsWhereYouAreCard() async throws {
        let fixture = try await ShellRenderFixture()
        defer { fixture.remove() }
        await fixture.workspace.history.refresh()
        let current = try #require(fixture.workspace.history.points.first(where: { $0.isCurrent }))
        fixture.workspace.history.select(current.revisionID)

        try expectDrawn(renderShell(.history, fixture: fixture))
    }
}
