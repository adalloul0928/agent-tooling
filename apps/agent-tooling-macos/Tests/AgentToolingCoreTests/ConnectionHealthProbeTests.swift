import Foundation
import Testing

@testable import AgentToolingCore

/// The probe runs each client's list command and parses it, but never runs a
/// real client: the runner and the locator are both scripted here.
@Suite("Connection health probe")
struct ConnectionHealthProbeTests {
    /// A runner that answers by the tool name at the end of the executable
    /// path, so a test scripts one client's output without a real process.
    private struct ScriptedRunner: CommandRunning {
        var answers: [String: CommandOutput]

        func run(executable: String, arguments: [String], currentDirectory: URL?) async throws -> CommandOutput {
            let name = URL(fileURLWithPath: executable).lastPathComponent
            return answers[name] ?? CommandOutput(status: 127, standardOutput: "", standardError: "not found")
        }
    }

    private let home = URL(fileURLWithPath: "/tmp/connection-health-probe-home", isDirectory: true)

    /// Records what a scripted flow was asked to run, safely across tasks, and
    /// lets a waiter block until a given number of calls have landed so a test
    /// need not sleep and hope a detached recording Task has run.
    private actor Recorder {
        private(set) var calls: [(String, [String])] = []
        private var waiters: [(count: Int, continuation: CheckedContinuation<Void, Never>)] = []

        func record(_ executable: String, _ arguments: [String]) {
            calls.append((executable, arguments))
            let reached = waiters.filter { calls.count >= $0.count }
            waiters.removeAll { calls.count >= $0.count }
            for waiter in reached { waiter.continuation.resume() }
        }

        /// Suspends until at least `count` calls have been recorded, resuming
        /// immediately if that many already have.
        func waitUntilCount(_ count: Int) async {
            if calls.count >= count { return }
            await withCheckedContinuation { continuation in
                waiters.append((count, continuation))
            }
        }
    }

    /// A located tool whose listing parses into entries.
    @Test func aListedClientParsesItsConnections() async throws {
        let runner = ScriptedRunner(answers: [
            "claude": CommandOutput(
                status: 0,
                standardOutput: "foo: npx foo - ✔ Connected\nbar: https://bar.example/sse - ! Needs authentication",
                standardError: "")
        ])
        let probe = ConnectionHealthProbe(
            runner: runner, homeURL: home,
            locate: { client, _ in
                client == .claude ? URL(fileURLWithPath: "/opt/homebrew/bin/claude") : nil
            })

        let result = await probe.probe(.claude)
        #expect(result.unavailableReason == nil)
        #expect(result.entries.count == 2)
        #expect(result.entries.contains { $0.name == "bar" && $0.status == .needsAuthentication })
    }

    /// A client whose tool is not located is reported unavailable and no
    /// command is ever run for it.
    @Test func anUnlocatedClientIsUnavailable() async {
        let probe = ConnectionHealthProbe(
            runner: ScriptedRunner(answers: [:]), homeURL: home, locate: { _, _ in nil })

        let result = await probe.probe(.claude)
        #expect(result.entries.isEmpty)
        #expect(result.unavailableReason != nil)
    }

    /// A nonzero exit carries its redacted error as the reason rather than
    /// pretending the client has no connections.
    @Test func aFailedCommandCarriesItsReason() async {
        let runner = ScriptedRunner(answers: [
            "claude": CommandOutput(status: 1, standardOutput: "", standardError: "not logged in")
        ])
        let probe = ConnectionHealthProbe(
            runner: runner, homeURL: home,
            locate: { _, _ in URL(fileURLWithPath: "/opt/homebrew/bin/claude") })

        let result = await probe.probe(.claude)
        #expect(result.entries.isEmpty)
        #expect(result.unavailableReason?.contains("not logged in") == true)
    }

    /// Gemini has no listing this app reads, so it is unavailable with a reason
    /// rather than run.
    @Test func aClientWithNoListingIsUnavailable() async {
        let probe = ConnectionHealthProbe(
            runner: ScriptedRunner(answers: [:]), homeURL: home,
            locate: { _, _ in URL(fileURLWithPath: "/opt/homebrew/bin/gemini") })

        let result = await probe.probe(.gemini)
        #expect(result.entries.isEmpty)
        #expect(result.unavailableReason != nil)
    }

    /// The sign-in is the exact reviewed shape, run on a terminal, with the
    /// authorization URL the tool prints handed straight to the opener. The
    /// scripted flow stands in for the pseudo-terminal so no process spawns.
    @Test func loginRunsExactlyTheReviewedShapeAndOpensTheURL() async throws {
        let recorder = Recorder()
        let opened = Recorder()
        let login = ConnectionHealthLoginRunner(
            homeURL: home,
            locate: { _, _ in URL(fileURLWithPath: "/opt/homebrew/bin/claude") },
            run: { executable, arguments, onAuthorizationURL in
                await recorder.record(executable, arguments)
                if let url = URL(string: "https://mcp.linear.app/oauth/authorize?state=abc") { onAuthorizationURL(url) }
                return .completed(
                    transcript:
                        "Visit this URL to authorize:\n  https://mcp.linear.app/oauth/authorize?state=abc\r\nWaiting for authorization…\r\nAuthentication successful. Connected to linear."
                )
            })

        let result = await login.logIn(client: .claude, serverID: "linear") { url in
            Task { await opened.record(url.absoluteString, []) }
        }
        #expect(result.succeeded)
        #expect(result.message.contains("Authentication successful"))
        let calls = await recorder.calls
        try #require(calls.count == 1)
        #expect(calls[0].0 == "/opt/homebrew/bin/claude")
        #expect(calls[0].1 == ["mcp", "login", "linear", "--no-browser"])
        #expect(login.commandText(client: .claude, serverID: "linear") == "claude mcp login linear --no-browser")
        await opened.waitUntilCount(1)
        #expect(await opened.calls.map(\.0) == ["https://mcp.linear.app/oauth/authorize?state=abc"])
    }

    /// What the tool printed reaches the row without its colour codes, cursor
    /// moves, hyperlink escapes or its paste prompt: just the sentence.
    @Test func terminalEscapesAreStrippedFromTheResult() async {
        let raw =
            "\u{1B}[?25l\u{1B}[1G\u{1B}[0JOr paste the redirect URL here: \u{1B}[33G\r\n"
            + "\u{1B}[0m\u{1B}[31mCouldn't complete authentication for \"sentry\": Authentication timeout\u{1B}[39m\u{1B}[0m\r\n"
            + "\u{1B}[?25h"
        #expect(
            ConnectionHealthLoginRunner.plainLines(raw) == [
                "Or paste the redirect URL here:",
                "Couldn't complete authentication for \"sentry\": Authentication timeout",
            ])
        let login = ConnectionHealthLoginRunner(
            homeURL: home,
            locate: { _, _ in URL(fileURLWithPath: "/opt/homebrew/bin/claude") },
            run: { _, _, _ in .failed(status: 1, transcript: raw) })
        let result = await login.logIn(client: .claude, serverID: "sentry") { _ in }
        #expect(result.message == "Couldn't complete authentication for \"sentry\": Authentication timeout")
    }

    /// A sign-in nobody finishes is stopped and said so, in words rather than
    /// a status code.
    @Test func aTimedOutLoginSaysSo() async {
        let login = ConnectionHealthLoginRunner(
            homeURL: home,
            locate: { _, _ in URL(fileURLWithPath: "/opt/homebrew/bin/codex") },
            run: { _, _, _ in .timedOut(transcript: "Waiting for authorization…") })

        let result = await login.logIn(client: .codex, serverID: "notion") { _ in }
        #expect(!result.succeeded)
        #expect(result.message.contains("not finished in the browser"))
    }

    /// A server name the policy refuses never reaches the terminal.
    @Test func anUnsafeServerNameNeverRuns() async {
        let recorder = Recorder()
        let login = ConnectionHealthLoginRunner(
            homeURL: home,
            locate: { _, _ in URL(fileURLWithPath: "/opt/homebrew/bin/claude") },
            run: { executable, arguments, _ in
                await recorder.record(executable, arguments)
                return .completed(transcript: "")
            })

        let result = await login.logIn(client: .claude, serverID: "bad name; rm -rf") { _ in }
        #expect(!result.succeeded)
        #expect(await recorder.calls.isEmpty)
    }

    /// Kiro has no login, so the runner refuses to run anything.
    @Test func aClientWithoutALoginRefuses() async {
        let login = ConnectionHealthLoginRunner(
            homeURL: home,
            locate: { _, _ in URL(fileURLWithPath: "/opt/homebrew/bin/kiro-cli") },
            run: { _, _, _ in .completed(transcript: "") })

        let result = await login.logIn(client: .kiro, serverID: "fetch") { _ in }
        #expect(!result.succeeded)
        #expect(login.canLogIn(client: .kiro) == false)
        #expect(login.canLogIn(client: .claude))
    }
}

/// The authorization URL is fished out of raw terminal output, which carries
/// OSC 8 hyperlink escapes that double the URL and bell characters around it.
@Suite("Interactive login URL detection")
struct InteractiveLoginURLDetectionTests {
    @Test func findsTheURLInsideAnOSC8Hyperlink() {
        let raw =
            "Visit this URL to authorize:\n  \u{1B}]8;;https://mcp.sentry.dev/oauth/authorize?a=1&b=2\u{07}https://mcp.sentry.dev/oauth/authorize?a=1&b=2\u{1B}]8;;\u{07}\r\n\nWaiting for authorization… (^C to cancel)"
        #expect(
            InteractiveLoginProcess.firstHTTPSURL(in: raw)?.absoluteString
                == "https://mcp.sentry.dev/oauth/authorize?a=1&b=2")
    }

    /// Two lines arriving in one read must not run together: the line ending
    /// ends the URL.
    @Test func aLineEndingEndsTheURL() {
        #expect(
            InteractiveLoginProcess.firstHTTPSURL(in: "visit https://a.example/authorize?x=1\r\nagain https://b.example/")?.absoluteString
                == "https://a.example/authorize?x=1")
    }

    @Test func plainURLsAndNonURLsBehave() {
        #expect(InteractiveLoginProcess.firstHTTPSURL(in: "open https://example.com/x. now")?.absoluteString == "https://example.com/x")
        #expect(InteractiveLoginProcess.firstHTTPSURL(in: "http://insecure.example/only") == nil)
        #expect(InteractiveLoginProcess.firstHTTPSURL(in: "Starting authentication…") == nil)
    }
}
