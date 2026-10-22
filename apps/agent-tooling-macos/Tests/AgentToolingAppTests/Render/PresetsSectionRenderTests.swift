import Foundation
import SwiftUI
import Testing

@testable import AgentToolingApp
@testable import AgentToolingCore

/// Presets draw the shelves this workspace holds.
@Suite("Library · Presets renders")
@MainActor
struct PresetsSectionRenderTests {
    @Test func theShellDrawsPresets() async throws {
        let fixture = try await ShellRenderFixture()
        defer { fixture.remove() }
        await fixture.workspace.presets?.refresh()

        try expectDrawn(renderShell(.presets, fixture: fixture))
    }

    /// Selecting a preset that is not followed shows its items and the
    /// "Follow this preset…" action, never a blank detail pane.
    @Test func theDetailPaneDrawsAnUnfollowedPreset() async throws {
        let fixture = try await ShellRenderFixture()
        defer { fixture.remove() }
        guard let presets = fixture.workspace.presets else {
            Issue.record("This fixture always links a preset store.")
            return
        }
        await presets.refresh()

        try expectDrawn(
            PresetsView(
                session: presets, library: fixture.workspace.library, export: fixture.workspace.export,
                initialSelection: ShellRenderFixture.presetID))
    }

    /// Following a preset that has changes to catch up with draws the
    /// destinations, the pending-change summary, and the catch-up action.
    @Test func theDetailPaneDrawsAFollowedPresetWithChanges() async throws {
        let fixture = try await ShellRenderFixture()
        defer { fixture.remove() }
        guard let presets = fixture.workspace.presets else {
            Issue.record("This fixture always links a preset store.")
            return
        }
        await presets.link(
            ShellRenderFixture.presetID,
            destinations: [
                .init(surface: .claudeCode, scope: .user, logicalProjectID: nil, deviceIDs: [fixture.workspace.library.deviceID])
            ])

        try expectDrawn(
            PresetsView(
                session: presets, library: fixture.workspace.library, export: fixture.workspace.export,
                initialSelection: ShellRenderFixture.presetID))
    }
}
