import Foundation
import SwiftUI
import Testing

@testable import AgentToolingApp
@testable import AgentToolingCore

/// Apps draws what this Mac would change.
@Suite("Apps · Clients renders")
@MainActor
struct ClientsSectionRenderTests {
    @Test func theShellDrawsClients() async throws {
        let fixture = try await ShellRenderFixture()
        defer { fixture.remove() }

        try expectDrawn(renderShell(.syncCenter, fixture: fixture))
    }
}
