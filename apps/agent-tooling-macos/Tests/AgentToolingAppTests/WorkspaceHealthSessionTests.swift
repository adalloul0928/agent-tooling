import Foundation
import Testing

@testable import AgentToolingApp
@testable import AgentToolingCore

/// The Health session reads each managed client's connections and runs the one
/// reviewed re-authentication a row offers. Everything it reaches for outside
/// the app — the runner, the tool locator, the URL opener — is scripted here,
/// so no real client is ever touched.
@Suite("Workspace health session")
@MainActor
struct WorkspaceHealthSessionTests {
    /// Answers by tool name; records every command it was asked to run, so a
    /// test can assert exactly `claude mcp login <name>` ran.
    final class ScriptedRunner: CommandRunning, @unchecked Sendable {
        private let lock = NSLock()
        private(set) var calls: [(executable: String, arguments: [String])] = []
        private let answers: [String: CommandOutput]

        init(answers: [String: CommandOutput]) { self.answers = answers }

        func run(executable: String, arguments: [String], currentDirectory: URL?) async throws -> CommandOutput {
            lock.withLock { calls.append((executable, arguments)) }
            let key = "\(URL(fileURLWithPath: executable).lastPathComponent) \(arguments.joined(separator: " "))"
            let name = URL(fileURLWithPath: executable).lastPathComponent
            return answers[key] ?? answers[name]
                ?? CommandOutput(status: 0, standardOutput: "", standardError: "")
        }
    }

    /// A scripted stand-in for the pseudo-terminal sign-in: records the argv it
    /// was given, hands back a fixed authorization URL, and answers per server
    /// name, so no process ever spawns and no browser opens.
    final class ScriptedLogin: @unchecked Sendable {
        private let lock = NSLock()
        private(set) var calls: [(executable: String, arguments: [String])] = []
        private let outcomes: [String: InteractiveLoginOutcome]

        init(outcomes: [String: InteractiveLoginOutcome]) { self.outcomes = outcomes }

        var run: InteractiveLoginRun {
            { [self] executable, arguments, onAuthorizationURL in
                lock.withLock { calls.append((executable, arguments)) }
                let server = arguments.count > 2 ? arguments[2] : ""
                if let url = URL(string: "https://\(server).example/oauth/authorize") { onAuthorizationURL(url) }
                return outcomes[server] ?? .completed(transcript: "Authentication successful.")
            }
        }
    }

    /// A session over one managed client, with a scripted runner, a scripted
    /// sign-in, and a locator that pretends every client's tool is present.
    private func makeSession(
        fixture: ShellRenderFixture,
        runner: ScriptedRunner,
        login: ScriptedLogin = ScriptedLogin(outcomes: [:]),
        managing: Set<ClientKind> = [.claude],
        openURL: @escaping @Sendable (URL) -> Void = { _ in }
    ) async -> WorkspaceHealthSession {
        for client in ClientKind.allCases {
            await fixture.workspace.device.setEnabled(client, managing.contains(client))
        }
        return WorkspaceHealthSession(
            device: fixture.workspace.device,
            homeRoot: fixture.home,
            runner: runner,
            locate: { client, _ in URL(fileURLWithPath: "/opt/homebrew/bin/\(ClientExecutableLocator.executableName(for: client))") },
            loginRun: login.run,
            openURL: openURL)
    }

    /// A check reads the managed client and files its connections.
    @Test func aCheckListsTheManagedClientsConnections() async throws {
        let fixture = try await ShellRenderFixture()
        defer { fixture.remove() }
        let runner = ScriptedRunner(answers: [
            "claude mcp list": CommandOutput(
                status: 0,
                standardOutput: "linear: https://mcp.linear.app/sse - ! Needs authentication\nlocal: npx local - ✔ Connected",
                standardError: "")
        ])
        let session = await makeSession(fixture: fixture, runner: runner)

        await session.check()

        #expect(session.lastCheckedAt != nil)
        #expect(session.entries.count == 2)
        #expect(session.attentionCount == 1)
        #expect(session.reauthenticatableEntries.map(\.name) == ["linear"])
    }

    /// Re-authenticating a needs-auth entry runs exactly `claude mcp login
    /// <name>`, then a fresh list.
    @Test func reauthenticateRunsExactlyTheLoginThenAList() async throws {
        let fixture = try await ShellRenderFixture()
        defer { fixture.remove() }
        let runner = ScriptedRunner(answers: [
            "claude mcp list": CommandOutput(
                status: 0,
                standardOutput: "linear: https://mcp.linear.app/sse - ! Needs authentication",
                standardError: ""),
        ])
        let login = ScriptedLogin(outcomes: [:])
        final class Sink: @unchecked Sendable {
            private let lock = NSLock()
            private(set) var urls: [URL] = []
            func add(_ url: URL) { lock.withLock { urls.append(url) } }
        }
        let sink = Sink()
        let session = await makeSession(fixture: fixture, runner: runner, login: login, openURL: { sink.add($0) })
        await session.check()
        let entry = try #require(session.entries.first { $0.name == "linear" })

        await session.reauthenticate(entry)

        // The login is exactly the reviewed shape, on the terminal path, and the
        // URL the tool printed was opened; a re-check follows the sign-in.
        #expect(login.calls.map { "\($0.executable) \($0.arguments.joined(separator: " "))" }
            == ["/opt/homebrew/bin/claude mcp login linear --no-browser"])
        #expect(sink.urls.map(\.absoluteString) == ["https://linear.example/oauth/authorize"])
        #expect(runner.calls.filter { $0.arguments == ["mcp", "list"] }.count == 2)
        #expect(session.actionState[entry.id] == .finished(message: "Authentication successful."))
    }

    /// Re-authenticating them all runs the logins one after another and reports
    /// a tally; none run in parallel.
    @Test func reauthenticateAllRunsEligibleEntriesSequentially() async throws {
        let fixture = try await ShellRenderFixture()
        defer { fixture.remove() }
        let runner = ScriptedRunner(answers: [
            "claude mcp list": CommandOutput(
                status: 0,
                standardOutput:
                    "one: https://one.example/sse - ! Needs authentication\n"
                    + "two: https://two.example/sse - ✘ Failed to connect — token expired\n"
                    + "local: npx local - ✔ Connected",
                standardError: ""),
        ])
        let login = ScriptedLogin(outcomes: [:])
        let session = await makeSession(fixture: fixture, runner: runner, login: login)
        await session.check()
        #expect(session.reauthenticatableEntries.count == 2)

        await session.reauthenticateAll()

        #expect(login.calls.map { $0.arguments[2] } == ["one", "two"])
        #expect(session.errorMessage == nil)
    }

    /// A login that fails surfaces its redacted stderr on that row and leaves
    /// the bulk tally honest.
    @Test func aFailedLoginSurfacesItsRedactedError() async throws {
        let fixture = try await ShellRenderFixture()
        defer { fixture.remove() }
        let runner = ScriptedRunner(answers: [
            "claude mcp list": CommandOutput(
                status: 0,
                standardOutput: "linear: https://mcp.linear.app/sse - ! Needs authentication",
                standardError: ""),
        ])
        // The transcript arrives already redacted from Core's terminal reader;
        // the session must keep it that way and show it on the row.
        let login = ScriptedLogin(outcomes: [
            "linear": .failed(
                status: 1,
                transcript: SensitiveValueRedactor.redact("authorization failed with token sk-secretsecretsecret123"))
        ])
        let session = await makeSession(fixture: fixture, runner: runner, login: login)
        await session.check()
        let entry = try #require(session.entries.first { $0.name == "linear" })

        await session.reauthenticate(entry)

        let state = try #require(session.actionState[entry.id])
        guard case .failed(let message) = state else {
            Issue.record("expected a failed row, got \(state)")
            return
        }
        #expect(!message.contains("sk-secretsecretsecret123"))
        #expect(message.contains("[redacted]"))
    }

    /// A hosted connector opens the connectors page rather than running a
    /// login. The URL sink records the one page it was asked to open.
    @Test func openingConnectorsUsesTheOneURL() async throws {
        let fixture = try await ShellRenderFixture()
        defer { fixture.remove() }
        final class Sink: @unchecked Sendable {
            private let lock = NSLock()
            private(set) var urls: [URL] = []
            func add(_ url: URL) { lock.withLock { urls.append(url) } }
        }
        let sink = Sink()
        let session = await makeSession(
            fixture: fixture, runner: ScriptedRunner(answers: [:]),
            openURL: { sink.add($0) })

        session.openConnectorsPage()

        #expect(sink.urls == [ConnectionHealthAction.claudeAIConnectorsURL].compactMap { $0 })
    }
}
