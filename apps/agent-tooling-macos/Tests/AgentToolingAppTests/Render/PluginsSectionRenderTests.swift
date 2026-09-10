import Foundation
import SwiftUI
import Testing

@testable import AgentToolingApp
@testable import AgentToolingCore

/// The plugins tab draws inside the Library family.
@Suite("Library · Plugins renders")
@MainActor
struct PluginsSectionRenderTests {
    @Test func theShellDrawsPlugins() async throws {
        let fixture = try await ShellRenderFixture()
        defer { fixture.remove() }

        try expectDrawn(renderShell(.plugins, fixture: fixture))
    }
}
