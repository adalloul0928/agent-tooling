import Foundation
import SwiftUI
import Testing

@testable import AgentToolingApp
@testable import AgentToolingCore

/// Discover draws while its catalogs are still arriving.
@Suite("Discover renders")
@MainActor
struct DiscoverSectionRenderTests {
    @Test func theShellDrawsDiscover() async throws {
        let fixture = try await ShellRenderFixture()
        defer { fixture.remove() }

        try expectDrawn(renderShell(.marketplace, fixture: fixture))
    }
}
