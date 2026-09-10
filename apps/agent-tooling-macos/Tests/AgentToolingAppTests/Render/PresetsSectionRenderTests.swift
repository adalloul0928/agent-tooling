import Foundation
import SwiftUI
import Testing

@testable import AgentToolingApp
@testable import AgentToolingCore

/// Presets draw the shelves this workspace holds.
@Suite("Library · Presets renders")
@MainActor
struct PresetsSectionRenderTests {
    @Test func theShellDrawsPresets() async throws {
        let fixture = try await ShellRenderFixture()
        defer { fixture.remove() }
        await fixture.workspace.presets?.refresh()

        try expectDrawn(renderShell(.presets, fixture: fixture))
    }
}
