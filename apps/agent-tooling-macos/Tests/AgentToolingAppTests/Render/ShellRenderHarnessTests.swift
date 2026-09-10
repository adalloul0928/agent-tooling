import AppKit
import Foundation
import SwiftUI
import Testing

@testable import AgentToolingApp
@testable import AgentToolingCore

/// The harness itself, and the one screen that stands in front of another.
@Suite("Shell render harness")
@MainActor
struct ShellRenderHarnessTests {
    /// Proves the blank-frame check every other test relies on can fail.
    ///
    /// Every section test would pass on an app that opened to nothing if the
    /// check could not tell a drawn screen from an empty one, so the check is
    /// held to an empty screen here.
    @Test func theBlankFrameCheckWouldCatchAScreenThatDrewNothing() throws {
        let empty = try rasterize(Color(nsColor: .windowBackgroundColor))
        #expect(distinctColours(in: empty) <= 4)
    }

    /// Getting started stands in front of the library, and only the library,
    /// while a writable workspace has items and nothing assigned.
    @Test func firstRunDrawsBeforeAnythingIsAssigned() async throws {
        let fixture = try await ShellRenderFixture()
        defer { fixture.remove() }
        // The wizard's primary action is enabled from the first frame, and a
        // bare `NSHostingView` with no window does not finish compositing an
        // enabled `.glassProminent` control before this reads it back; see
        // `rasterizeWarmed` in `Fixture+Onboarding.swift`.
        try expectDrawnWarmed(
            OnboardingWizard(workspace: fixture.workspace) {}
                .environment(AppNavigationState()))
    }

    /// The fixture is the app's own wiring, so what a screen is handed here is
    /// what a screen is handed on a Mac.
    @Test func theFixtureOpensARealWorkspaceWithSomethingInIt() async throws {
        let fixture = try await ShellRenderFixture()
        defer { fixture.remove() }
        let library = try #require(fixture.workspace.library.state?.library)
        // A plugin, a standalone skill and a server are rows; the plugin's own
        // skill is folded into it, and presets and projects are their own lists.
        #expect(library.rows.count == 3)
        #expect(library.nestedToolCount == 1)
        #expect(library.presets.count == 1)
        #expect(library.projects.count == 1)
    }

    /// The sidebar's verdicts come from the scripted scan, never from whatever
    /// happens to be installed on the machine running the tests.
    @Test func theDeviceScanIsScriptedRatherThanReal() async throws {
        let fixture = try await ShellRenderFixture()
        defer { fixture.remove() }
        #expect(fixture.workspace.device.verdict(for: .claude).state == .pending)

        await fixture.workspace.device.refresh()

        #expect(fixture.workspace.device.verdict(for: .claude).state == .healthy)
        #expect(fixture.workspace.device.verdict(for: .codex) == ClientVerdict(state: .attention, text: "Not found"))
    }
}
