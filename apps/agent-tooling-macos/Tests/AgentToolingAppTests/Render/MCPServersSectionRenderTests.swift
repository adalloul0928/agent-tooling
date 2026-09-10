import Foundation
import SwiftUI
import Testing

@testable import AgentToolingApp
@testable import AgentToolingCore

/// The connections tab draws inside the Library family.
@Suite("Library · Connections renders")
@MainActor
struct MCPServersSectionRenderTests {
    @Test func theShellDrawsMCPServers() async throws {
        let fixture = try await ShellRenderFixture()
        defer { fixture.remove() }

        try expectDrawn(renderShell(.mcpServers, fixture: fixture))
    }
}
