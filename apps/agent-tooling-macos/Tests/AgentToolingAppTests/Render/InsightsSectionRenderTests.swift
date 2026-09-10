import Foundation
import SwiftUI
import Testing

@testable import AgentToolingApp
@testable import AgentToolingCore

/// Insights draws while its scan is still arriving.
@Suite("Insights renders")
@MainActor
struct InsightsSectionRenderTests {
    @Test func theShellDrawsInsights() async throws {
        let fixture = try await ShellRenderFixture()
        defer { fixture.remove() }

        try expectDrawn(renderShell(.insights, fixture: fixture))
    }
}
