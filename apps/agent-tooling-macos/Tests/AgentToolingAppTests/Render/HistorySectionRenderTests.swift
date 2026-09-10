import Foundation
import SwiftUI
import Testing

@testable import AgentToolingApp
@testable import AgentToolingCore

/// History draws this workspace's restore points.
@Suite("Activity · History renders")
@MainActor
struct HistorySectionRenderTests {
    @Test func theShellDrawsHistory() async throws {
        let fixture = try await ShellRenderFixture()
        defer { fixture.remove() }
        await fixture.workspace.history.refresh()

        try expectDrawn(renderShell(.history, fixture: fixture))
    }
}
