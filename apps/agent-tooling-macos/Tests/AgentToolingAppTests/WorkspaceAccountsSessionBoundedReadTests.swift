import AgentToolingCore
import Foundation
import Testing

@testable import AgentToolingApp
@testable import AgentToolingCore

/// `replan` reads each client's settings file to rehearse the edits applying
/// would make. The read must be bounded the way every other read of these
/// files is, so a pathological settings file cannot be loaded whole into
/// memory on a hot path (every save, apply, and tab visit, per provider).
@Suite("Accounts · the plan read is bounded")
@MainActor
struct WorkspaceAccountsSessionBoundedReadTests {
    /// Answers ChatGPT with a fixed observation that reaches the account and
    /// sets no app switches, so the file on disk is the only thing that can
    /// change what `replan` makes of the choice.
    final class FixedChatGPTReader: AccountSurfaceReading, @unchecked Sendable {
        func read(_ providers: [AccountProvider], depth: AccountSurfaceProbe.Depth, now: Date) async -> [AccountObservation] {
            providers.map { provider in
                guard provider == .chatGPT else {
                    return AccountObservation(provider: provider, observedAt: now, unavailableReason: "Not read in tests.")
                }
                return AccountObservation(
                    provider: .chatGPT, observedAt: now,
                    signIn: .init(method: .subscription, email: "me@example.com", plan: "plus"),
                    contentsRead: depth == .contents)
            }
        }
    }

    /// A config.toml that defines `apps.github.enabled` as a dotted key the
    /// line editor cannot rewrite, padded past the configuration byte cap.
    /// Read whole, the planner sees the obstacle and holds the choice; read
    /// bounded, the oversize file is ignored and the choice becomes a change.
    @Test func anOversizeConfigFileIsNotReadWholeWhenPlanning() async throws {
        let fixture = try await ShellRenderFixture(
            deviceObserver: StubDeviceObserver(observations: [
                ShellRenderFixture.observation(.codexCLI, installed: true, commandAvailable: true, version: "0.162.1"),
            ]),
            accountReader: FixedChatGPTReader())
        defer { fixture.remove() }
        let session = fixture.workspace.accounts

        let config = fixture.home.appending(path: ".codex/config.toml")
        try FileManager.default.createDirectory(
            at: config.deletingLastPathComponent(), withIntermediateDirectories: true)
        // The dotted key is the obstacle; the comment lines pad the file past
        // the cap without adding any TOML the scanner reacts to.
        let fillerLine = "# " + String(repeating: "x", count: 120) + "\n"
        let fillerLines = (BoundedFileAccess.maximumConfigurationBytes / fillerLine.utf8.count) + 16
        let text = "apps.github.enabled = false\n" + String(repeating: fillerLine, count: fillerLines)
        #expect(text.utf8.count > BoundedFileAccess.maximumConfigurationBytes)
        try Data(text.utf8).write(to: config)

        await session.read()
        #expect(await session.setChoice(.init(.app, subject: "github"), to: .off))
        let plan = try #require(session.plan(.chatGPT))
        #expect(
            plan.changes.map(\.key) == [.init(.app, subject: "github")],
            "an oversize file is ignored, so the choice is a change rather than held on an obstacle only a whole read would see")
        #expect(plan.held.isEmpty)
    }
}
