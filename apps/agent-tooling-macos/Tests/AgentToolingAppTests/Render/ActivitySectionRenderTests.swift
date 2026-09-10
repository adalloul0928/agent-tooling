import Foundation
import SwiftUI
import Testing

@testable import AgentToolingApp
@testable import AgentToolingCore

/// Activity draws while its journal is still arriving, and once it has real
/// receipts, drift and a selected item to show.
@Suite("Activity renders")
@MainActor
struct ActivitySectionRenderTests {
    @Test func theShellDrawsActivity() async throws {
        let fixture = try await ShellRenderFixture()
        defer { fixture.remove() }

        try expectDrawn(renderShell(.activity, fixture: fixture))
    }

    /// The session itself is created by the section rather than handed down
    /// from the fixture's workspace, so this exercises it directly: real
    /// receipts and a real journal entry, read back through the same store the
    /// section would use, with drift stubbed so nothing here hashes a real
    /// path on disk.
    @Test func theScreenDrawsReceiptsDriftAndASelectedItem() async throws {
        let fixture = try await ShellRenderFixture()
        defer { fixture.remove() }
        let receipt = try fixture.seedActivity()

        let session = WorkspaceActivitySession(store: fixture.store)
        let drift = InstalledPackageDrift(
            destinationPath: "/tmp/example-drift/skills/example",
            packageName: "example",
            state: .modifiedSinceReview,
            reviewedFingerprint: "abc123",
            reviewedAt: .now)
        await session.refresh(driftReader: StubInstallDriftReader(reports: [drift]))

        #expect(session.receipts.map(\.id) == [receipt.id])
        #expect(session.activities.count == 1)
        #expect(session.drift == [drift])
        #expect(session.operationReceipt(for: session.activities.first?.operationReceiptID)?.id == receipt.id)

        try expectDrawn(
            ActivityView(session: session)
                .environment(AppNavigationState()))
    }

    /// An empty session — no receipts, no journal, no drift — still has to
    /// draw something: its empty state, not a blank pane.
    @Test func theEmptyScreenStillDraws() async throws {
        let fixture = try await ShellRenderFixture()
        defer { fixture.remove() }
        let session = WorkspaceActivitySession(store: fixture.store)

        try expectDrawn(
            ActivityView(session: session)
                .environment(AppNavigationState()))
    }
}
