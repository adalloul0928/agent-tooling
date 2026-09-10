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
        // A package with a saved assignment but no native presence anywhere:
        // the shape the plan warns must never be drawn as "installed".
        try await fixture.addRequestedPackage()

        try expectDrawn(renderShell(.plugins, fixture: fixture))
    }

    /// A palette result that names one plugin row leaves its identifier on
    /// `AppNavigationState` for the screen to reveal on arrival and clear —
    /// `navigation.openItem(_:in:)` — splitting into the master-detail layout
    /// rather than staying on the plain list.
    @Test func theShellDrawsAPluginOpenedFromThePalette() async throws {
        let fixture = try await ShellRenderFixture()
        defer { fixture.remove() }

        let navigation = AppNavigationState()
        navigation.openItem(ShellRenderFixture.plugin.rawValue.uuidString.lowercased(), in: .plugins)

        try expectDrawn(
            AppShellView(workspace: fixture.workspace, initialSection: .plugins, navigation: navigation)
                .frame(width: shellWindowSize.width, height: shellWindowSize.height))
    }
}
