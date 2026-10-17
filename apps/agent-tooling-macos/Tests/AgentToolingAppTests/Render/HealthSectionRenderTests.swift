import Foundation
import SwiftUI
import Testing

@testable import AgentToolingApp
@testable import AgentToolingCore

/// The Health screen draws its connections, or its empty states, at a real
/// window size. A screen that throws never gets here; one that lays out to
/// nothing rasterizes flat.
@Suite("Apps · Health renders")
@MainActor
struct HealthSectionRenderTests {
    /// A scripted runner keyed by tool name, so the render never runs a real
    /// client.
    private struct FixtureRunner: CommandRunning {
        let output: String
        func run(executable: String, arguments: [String], currentDirectory: URL?) async throws -> CommandOutput {
            CommandOutput(status: 0, standardOutput: output, standardError: "")
        }
    }

    private func session(
        fixture: ShellRenderFixture, listing: String
    ) async -> WorkspaceHealthSession {
        // Manage only Claude so the fixture report comes from one client.
        for client in ClientKind.allCases {
            await fixture.workspace.device.setEnabled(client, client == .claude)
        }
        let session = WorkspaceHealthSession(
            device: fixture.workspace.device,
            homeRoot: fixture.home,
            runner: FixtureRunner(output: listing),
            locate: { client, _ in
                URL(fileURLWithPath: "/opt/homebrew/bin/\(ClientExecutableLocator.executableName(for: client))")
            },
            openURL: { _ in })
        await session.check()
        return session
    }

    private func render(_ session: WorkspaceHealthSession, device: WorkspaceDeviceSession) -> some View {
        HealthView(session: session, device: device)
            .environment(\.workspaceSelection, AppSection.health)
            .environment(\.workspaceNavigate, { _ in })
            .frame(width: shellWindowSize.width, height: shellWindowSize.height)
    }

    /// A report with a needs-auth remote, a connected local, a plugin server
    /// and a claude.ai connector draws every row shape and its action.
    @Test func theScreenDrawsAFixtureReport() async throws {
        let fixture = try await ShellRenderFixture()
        defer { fixture.remove() }
        let listing =
            "linear: https://mcp.linear.app/sse - ! Needs authentication\n"
            + "local: npx -y @scope/local - ✔ Connected\n"
            + "plugin:devtools:inspector: npx inspector - ✘ Failed to connect — connection refused\n"
            + "Gmail: claude.ai connector - ✘ Failed to connect — is Anthropic-hosted and doesn't support local OAuth"
        let session = await self.session(fixture: fixture, listing: listing)
        #expect(session.entries.count == 4)

        try expectDrawn(render(session, device: fixture.workspace.device))
    }

    /// Before any check, the screen draws its "nothing checked yet" state.
    @Test func theScreenDrawsTheUncheckedEmptyState() async throws {
        let fixture = try await ShellRenderFixture()
        defer { fixture.remove() }
        let session = WorkspaceHealthSession(
            device: fixture.workspace.device, homeRoot: fixture.home,
            runner: FixtureRunner(output: ""), locate: { _, _ in nil }, openURL: { _ in })

        try expectDrawn(render(session, device: fixture.workspace.device))
    }

    /// A client whose tool could not run draws its per-client note rather than
    /// looking like it has no connections.
    @Test func theScreenDrawsAPerClientNote() async throws {
        let fixture = try await ShellRenderFixture()
        defer { fixture.remove() }
        for client in ClientKind.allCases {
            await fixture.workspace.device.setEnabled(client, client == .claude)
        }
        let session = WorkspaceHealthSession(
            device: fixture.workspace.device, homeRoot: fixture.home,
            runner: FixtureRunner(output: ""), locate: { _, _ in nil }, openURL: { _ in })
        await session.check()
        #expect(session.results.first?.unavailableReason != nil)

        try expectDrawn(render(session, device: fixture.workspace.device))
    }
}
