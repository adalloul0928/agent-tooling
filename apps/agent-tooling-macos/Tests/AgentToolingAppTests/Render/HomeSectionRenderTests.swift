import Foundation
import SwiftUI
import Testing

@testable import AgentToolingApp
@testable import AgentToolingCore

/// Home draws the shell it composes onto.
@Suite("Home renders")
@MainActor
struct HomeSectionRenderTests {
    @Test func theShellDrawsHome() async throws {
        let fixture = try await ShellRenderFixture()
        defer { fixture.remove() }

        try expectDrawn(renderShell(.overview, fixture: fixture))
    }
}
