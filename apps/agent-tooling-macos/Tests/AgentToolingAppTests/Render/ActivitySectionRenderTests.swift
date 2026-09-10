import Foundation
import SwiftUI
import Testing

@testable import AgentToolingApp
@testable import AgentToolingCore

/// Activity draws while its journal is still arriving.
@Suite("Activity renders")
@MainActor
struct ActivitySectionRenderTests {
    @Test func theShellDrawsActivity() async throws {
        let fixture = try await ShellRenderFixture()
        defer { fixture.remove() }

        try expectDrawn(renderShell(.activity, fixture: fixture))
    }
}
