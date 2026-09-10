import Foundation
import SwiftUI
import Testing

@testable import AgentToolingApp
@testable import AgentToolingCore

/// The library draws the workspace it was given.
@Suite("Library · Skills renders")
@MainActor
struct SkillsSectionRenderTests {
    @Test func theShellDrawsSkills() async throws {
        let fixture = try await ShellRenderFixture()
        defer { fixture.remove() }

        try expectDrawn(renderShell(.skills, fixture: fixture))
    }
}
