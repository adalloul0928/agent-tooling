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
    /// Read whole, the planner would hold the choice on that obstacle. Read
    /// bounded, the file is refused for its size before it is loaded, and the
    /// choice is held with that reason: not planned against an empty file,
    /// which the engine would only refuse when the plan was applied.
    @Test func anOversizeConfigFileIsNotReadWholeWhenPlanning() async throws {
        let fixture = try await ShellRenderFixture(
            deviceObserver: StubDeviceObserver(observations: [
                ShellRenderFixture.observation(.codexCLI, installed: true, commandAvailable: true, version: "0.162.1")
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
        #expect(plan.changes.isEmpty, "nothing is planned against a file that could not be read")
        #expect(plan.held.map(\.key) == [.init(.app, subject: "github")])
        #expect(
            plan.held.first?.reason
                == ConfigurationFileTooLargeError(
                    path: ".codex/config.toml", maximumBytes: BoundedFileAccess.maximumConfigurationBytes
                ).errorDescription,
            "held for the file's size, not for an obstacle only a whole read would see")
        #expect(session.operationPlan(.chatGPT) == nil)
    }
}
