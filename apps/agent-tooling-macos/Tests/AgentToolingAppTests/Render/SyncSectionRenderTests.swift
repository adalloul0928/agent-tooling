import Foundation
import SwiftUI
import Testing

@testable import AgentToolingApp
@testable import AgentToolingCore

/// Sync draws this Mac's transport between Macs.
@Suite("Settings · Sync renders")
@MainActor
struct SyncSectionRenderTests {
    @Test func theShellDrawsSync() async throws {
        let fixture = try await ShellRenderFixture()
        defer { fixture.remove() }
        fixture.workspace.sync?.load()

        try expectDrawn(renderShell(.sync, fixture: fixture))
    }
}
