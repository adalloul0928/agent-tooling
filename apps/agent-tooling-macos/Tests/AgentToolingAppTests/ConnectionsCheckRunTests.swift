import AgentToolingCore
import AgentToolingTestSupport
import Foundation
import Testing

@testable import AgentToolingApp

/// Exercises connection checks and sign-ins with scripted runners. Verifies
/// single execution, explicit confirmation and failure output for plugin-scoped
/// and plain server names admitted by OperationCommandPolicy.
@Suite("Connections check run", .serialized, .timeLimit(.minutes(5)))
@MainActor
struct ConnectionsCheckRunTests {
    /// Sentry, which its plugin brought into Claude Code, needs a sign-in;
    /// Codex lists one connection with no status it reports.
    private static let needsSentry = [
        "claude mcp list": "plugin:sentry:sentry: https://mcp.sentry.dev/mcp (HTTP) - ! Needs authentication",
        "codex mcp list --json":
            #"[{"name":"playwright","enabled":true,"transport":{"type":"stdio","command":"npx"}}]"#,
    ]

    @Test func checkRunsTheListsOnceThenShowsTheCommandTheCheckFound() async throws {
        let fixture = try await ShellRenderFixture()
        defer { fixture.remove() }
        let lists = ScriptedLists(Self.needsSentry)
        let health = try await Self.health(fixture, lists: lists, logins: Logins())
        // Before any check, setup knew Sentry by the name its plugin gives
        // it, as Home's card draws it.
        let hint = FinishSetupFacts.Connection(name: "Sentry", serverID: "plugin:sentry:sentry", client: .claude)
        let run = ConnectionsCheckRun(health: health, hints: [hint])
        #expect(run.phase == .confirm)
        #expect(run.signIns.map(\.command) == ["claude mcp login plugin:sentry:sentry --no-browser"])

        await run.check()

        // The lists the confirmation names, in the order the check runs them.
        #expect(lists.calls == ConnectionsCheckFlow.listCommands(for: fixture.workspace.device.managedClients))
        #expect(lists.calls == ["codex mcp list --json", "claude mcp list"])
        #expect(run.phase == .signIn)
        #expect(run.signIns.map(\.command) == ["claude mcp login plugin:sentry:sentry --no-browser"])
        #expect(run.who == "Sentry in Claude Code")
        // Check again does nothing once it has run.
        await run.check()
        #expect(lists.calls.count == 2)
    }

    @Test func aPlainReturnAtTheSignInShowsTheHintAndRunsNothing() async throws {
        let fixture = try await ShellRenderFixture()
        defer { fixture.remove() }
        let logins = Logins()
        let health = try await Self.health(fixture, lists: ScriptedLists(Self.needsSentry), logins: logins)
        let run = ConnectionsCheckRun(health: health, hints: [])
        await run.check()

        run.plainReturn()

        #expect(run.showsHint)
        #expect(run.phase == .signIn)
        #expect(logins.calls.isEmpty)
    }

    /// Each offered sign-in runs once, in turn, and the confirmation ends
    /// with nothing left once the check after them finds both signed in.
    @Test func signInRunsEachOfferedSignInOnceInTurn() async throws {
        let fixture = try await ShellRenderFixture()
        defer { fixture.remove() }
        var answers = Self.needsSentry
        answers["claude mcp list"] = """
            plugin:sentry:sentry: https://mcp.sentry.dev/mcp (HTTP) - ! Needs authentication
            notion: https://mcp.notion.com/mcp - ! Needs authentication
            """
        let lists = ScriptedLists(answers)
        let logins = Logins()
        logins.afterEach = { calls in
            // Both signed in once the second sign-in has run.
            guard calls == 2 else { return }
            lists.answer(
                "claude mcp list",
                """
                plugin:sentry:sentry: https://mcp.sentry.dev/mcp (HTTP) - ✔ Connected
                notion: https://mcp.notion.com/mcp - ✔ Connected
                """)
        }
        let health = try await Self.health(fixture, lists: lists, logins: logins)
        let run = ConnectionsCheckRun(health: health, hints: [])
        await run.check()
        #expect(run.signIns.count == 2)

        await run.signIn()

        #expect(
            logins.calls.map { $0.joined(separator: " ") } == [
                "mcp login plugin:sentry:sentry --no-browser", "mcp login notion --no-browser",
            ])
        #expect(run.phase == .finished)
        #expect(run.message == nil)
        #expect(run.signInElsewhere == nil)
    }

    @Test func aSignInThatDidNotFinishSaysWhatItPrinted() async throws {
        let fixture = try await ShellRenderFixture()
        defer { fixture.remove() }
        let logins = Logins()
        logins.outcome = .failed(status: 1, transcript: "The browser sign-in was cancelled.")
        let health = try await Self.health(fixture, lists: ScriptedLists(Self.needsSentry), logins: logins)
        let run = ConnectionsCheckRun(health: health, hints: [])
        await run.check()

        await run.signIn()

        #expect(logins.calls.count == 1)
        #expect(run.message == "The browser sign-in was cancelled.")
        // Still offered, so the sign-in stays up to try again.
        #expect(run.phase == .signIn)
    }

    /// A check whose only connection needing a sign-in is a claude.ai
    /// connector, which signs in on claude.ai: the confirmation ends with
    /// a statement, naming it and where Agent Tooling shows how.
    @Test func aCheckWithASignInOnlyItsAppCanRunSaysSo() async throws {
        let fixture = try await ShellRenderFixture()
        defer { fixture.remove() }
        var answers = Self.needsSentry
        answers["claude mcp list"] = "Gmail: claude.ai connector - ! Needs authentication"
        let health = try await Self.health(fixture, lists: ScriptedLists(answers), logins: Logins())
        let run = ConnectionsCheckRun(health: health, hints: [])

        await run.check()

        #expect(run.phase == .finished)
        #expect(run.signInElsewhere == "Gmail in Claude Code needs you to sign in from its app. Apps › Health shows how.")
    }

    /// Opened after a check that already offered a sign-in, the confirmation
    /// starts at the sign-in.
    @Test func itOpensAtTheSignInWhenTheLastCheckOfferedOne() async throws {
        let fixture = try await ShellRenderFixture()
        defer { fixture.remove() }
        let health = try await Self.health(fixture, lists: ScriptedLists(Self.needsSentry), logins: Logins())
        await health.check()

        #expect(ConnectionsCheckRun(health: health, hints: []).phase == .signIn)
    }

    // MARK: - Helpers

    private static func health(
        _ fixture: ShellRenderFixture, lists: ScriptedLists, logins: Logins
    ) async throws -> WorkspaceHealthSession {
        for client in ClientKind.allCases {
            await fixture.workspace.device.setEnabled(client, [.codex, .claude].contains(client))
        }
        return WorkspaceHealthSession(
            device: fixture.workspace.device, homeRoot: fixture.home, runner: lists,
            locate: { client, _ in URL(filePath: "/opt/homebrew/bin/\(ClientExecutableLocator.executableName(for: client))") },
            loginRun: { executable, arguments, open in try await logins.run(executable, arguments, open) }, openURL: { _ in })
    }
}

/// Each app's list command answered from a script that can change, with
/// every call kept in order.
private final class ScriptedLists: CommandRunning, @unchecked Sendable {
    private let lock = NSLock()
    private var answers: [String: String]
    private var made: [String] = []

    init(_ answers: [String: String]) {
        self.answers = answers
    }

    var calls: [String] { lock.withLock { made } }

    func answer(_ command: String, _ output: String) {
        lock.withLock { answers[command] = output }
    }

    func run(executable: String, arguments: [String], currentDirectory: URL?) async throws -> CommandOutput {
        let key = ([URL(filePath: executable).lastPathComponent] + arguments).joined(separator: " ")
        return lock.withLock {
            made.append(key)
            return CommandOutput(status: 0, standardOutput: answers[key] ?? "", standardError: "")
        }
    }
}

/// A sign-in that runs nothing: it keeps each one's arguments in order and
/// answers with `outcome`.
private final class Logins: @unchecked Sendable {
    private let lock = NSLock()
    private var made: [[String]] = []
    var outcome = InteractiveLoginOutcome.completed(transcript: "Signed in.")
    /// Called after each sign-in with how many have run.
    var afterEach: @Sendable (Int) -> Void = { _ in }

    var calls: [[String]] { lock.withLock { made } }

    func run(_ executable: String, _ arguments: [String], _ open: @escaping @Sendable (URL) -> Void) async throws
        -> InteractiveLoginOutcome
    {
        let count = lock.withLock {
            made.append(arguments)
            return made.count
        }
        afterEach(count)
        return lock.withLock { outcome }
    }
}
