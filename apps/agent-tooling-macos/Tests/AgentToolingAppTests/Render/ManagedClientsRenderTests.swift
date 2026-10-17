import AgentToolingCore
import SwiftUI
import Testing

@testable import AgentToolingApp

/// The fixes to how apps read on the sidebar, Apps and Settings are covered at
/// the session level elsewhere; what these add is proof the screens still lay
/// out with the new wiring — a verdict detail on every row, and a Settings pane
/// scoped to the apps this Mac manages.
@Suite("Managed clients render")
@MainActor
struct ManagedClientsRenderTests {
    /// A version-less but answering client is the state F1 introduced: found,
    /// version unknown. The sidebar and Apps must still draw it, not fail.
    @Test func theSidebarAndAppsDrawAVersionUnknownClient() async throws {
        let fixture = try await ShellRenderFixture(
            deviceObserver: VersionUnknownObserver())
        defer { fixture.remove() }
        await fixture.workspace.device.refresh()
        // The verdict the row draws is the new attention-with-explanation state.
        let verdict = fixture.workspace.device.verdict(for: .claude)
        #expect(verdict.state == .attention)
        #expect(verdict.text == "Found, version unknown")
        #expect(!verdict.detail.isEmpty)

        try expectDrawn(
            renderShell(.syncCenter, fixture: fixture)
                .environment(\.operationReceiptReader, StubOperationReceiptReader(receipts: [])))
    }

    private struct VersionUnknownObserver: DeviceObserving {
        func observe(homeRoot: URL) async throws -> [TargetObservation] {
            [
                ShellRenderFixture.observation(.claudeCode, installed: true, commandAvailable: true),
                ShellRenderFixture.observation(.codexCLI, installed: false, commandAvailable: false),
            ]
        }
    }
}
