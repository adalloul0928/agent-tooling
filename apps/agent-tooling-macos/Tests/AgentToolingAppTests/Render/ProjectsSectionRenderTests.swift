import Foundation
import SwiftUI
import Testing

@testable import AgentToolingApp
@testable import AgentToolingCore

/// Projects draw the logical projects this workspace holds.
@Suite("Projects renders")
@MainActor
struct ProjectsSectionRenderTests {
    @Test func theShellDrawsProjects() async throws {
        let fixture = try await ShellRenderFixture()
        defer { fixture.remove() }

        try expectDrawn(renderShell(.projects, fixture: fixture))
    }
}
