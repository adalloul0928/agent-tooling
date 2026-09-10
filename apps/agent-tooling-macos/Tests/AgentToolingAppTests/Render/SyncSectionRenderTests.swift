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

    /// A freshly connected encrypted folder shows the one-time recovery
    /// phrase, its password-manager caption, and the connected card together
    /// — the state a person actually sees right after connecting.
    @Test func theShellDrawsSyncJustAfterConnectingAnEncryptedFolder() async throws {
        let fixture = try await ShellRenderFixture()
        defer { fixture.remove() }
        guard let sync = fixture.workspace.sync, sync.supportsEncryptedFolder else {
            Issue.record("This fixture always prepares a folder key store.")
            return
        }
        let folder = fixture.root.appending(path: "shared-folder", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        await sync.connectFolder(folder, phrase: "")

        try expectDrawn(renderShell(.sync, fixture: fixture))
    }
}
