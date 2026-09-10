import Foundation
import SwiftUI
import Testing

@testable import AgentToolingApp
@testable import AgentToolingCore

/// General draws appearance and what is still missing.
@Suite("Settings · General renders")
@MainActor
struct SettingsSectionRenderTests {
    @Test func theShellDrawsSettings() async throws {
        let fixture = try await ShellRenderFixture()
        defer { fixture.remove() }

        try expectDrawn(renderShell(.settings, fixture: fixture))
    }
}
