import Foundation
import SwiftUI
import Testing

@testable import AgentToolingApp
@testable import AgentToolingCore

/// App settings draw the effective native settings.
@Suite("Apps · Settings renders")
@MainActor
struct AppSettingsSectionRenderTests {
    @Test func theShellDrawsAppSettings() async throws {
        let fixture = try await ShellRenderFixture()
        defer { fixture.remove() }
        await fixture.workspace.settings.refresh()

        try expectDrawn(renderShell(.appSettings, fixture: fixture))
    }
}
