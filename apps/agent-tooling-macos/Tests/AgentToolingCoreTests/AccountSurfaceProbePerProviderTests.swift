import AgentToolingTestSupport
import Foundation
import Testing

@testable import AgentToolingCore

/// The sign-in read one provider at a time, so setup can start each app's
/// read on its own and drop one when that app is skipped. The login shell is
/// asked once and its answer handed to each read; with no provider at all,
/// nothing runs, not even the shell.
@Suite("Account probe · per provider")
struct AccountSurfaceProbePerProviderTests {
    private static let shellAnswer =
        "agent-tooling-shell-override:ANTHROPIC_API_KEY\nagent-tooling-shell-override:CODEX_HOME\n"

    @Test func withNoProviderNothingRuns() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }

        let observations = await fixture.probe.read([], depth: .signInOnly)

        #expect(observations.isEmpty)
        #expect(await fixture.shell.launches.isEmpty, "no login shell starts for an answer nothing would use")
        #expect(await fixture.claudeRunner.launches.isEmpty)
    }

    @Test func theLoginShellIsAskedOnceForItsOverrides() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }

        let overrides = await fixture.probe.readShellOverrides()

        #expect(overrides == [.anthropicAPIKey, .codexHome])
        let launches = await fixture.shell.launches
        #expect(launches == [CommandLaunch(executable: "/bin/zsh", arguments: AccountShellEnvironmentProbe.arguments)])
    }

    @Test func oneProvidersReadStartsNoShellAndKeepsOnlyItsOwnOverrides() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }

        let claude = await fixture.probe.read(.claude, depth: .signInOnly, shellOverrides: [.anthropicAPIKey, .codexHome])

        #expect(claude.provider == .claude)
        #expect(claude.shellOverrides == [.anthropicAPIKey])
        #expect(claude.clientVersion == "2.1.304")
        #expect(claude.signIn?.method == .subscription)
        #expect(await fixture.shell.launches.isEmpty)
        #expect(Set(await fixture.claudeRunner.launches.map(\.display)) == ["claude --version", "claude auth status --json"])
    }

    /// The read the shell's screens use is the per-provider read, with the
    /// shell asked once however many providers are read.
    @Test func readingSeveralProvidersAsksTheShellOnce() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }

        let observations = await fixture.probe.read([.chatGPT, .claude, .claude], depth: .signInOnly)

        #expect(observations.map(\.provider) == [.claude, .chatGPT])
        #expect(await fixture.shell.launches.count == 1)
        #expect(observations.first?.shellOverrides == [.anthropicAPIKey])
        #expect(observations.last?.shellOverrides == [.codexHome])
        #expect(observations.last?.unavailableReason != nil, "Codex is not found in this fixture")
    }

    @Test func aProbeWithoutAShellHasNoOverrides() async throws {
        let fixture = try Fixture(withShell: false)
        defer { fixture.remove() }

        #expect(await fixture.probe.readShellOverrides() == nil)
        let claude = await fixture.probe.read(.claude, depth: .signInOnly, shellOverrides: nil)
        #expect(claude.shellOverrides.isEmpty)
    }

    @Test func aShellThatDoesNotAnswerHasNoOverrides() async throws {
        let fixture = try Fixture(shellAnswers: false)
        defer { fixture.remove() }

        #expect(await fixture.probe.readShellOverrides() == nil)
        #expect(await fixture.shell.launches.count == 1)
    }

    private struct Fixture {
        let home: FixtureHome
        let shell: ScriptedCommandRunner
        let claudeRunner: ScriptedCommandRunner
        let probe: AccountSurfaceProbe

        init(withShell: Bool = true, shellAnswers: Bool = true) throws {
            home = try FixtureHome("account-probe-per-provider")
            shell = ScriptedCommandRunner(
                byTool: shellAnswers ? ["zsh": [AccountShellEnvironmentProbe.arguments: .standardOutput(Self.shellAnswer)]] : [:])
            claudeRunner = ScriptedCommandRunner(byTool: [
                "claude": [
                    ["--version"]: .standardOutput("2.1.304 (Claude Code)\n"),
                    ["auth", "status", "--json"]: .standardOutput(
                        #"{"loggedIn":true,"authMethod":"claude.ai","email":"you@example.com","subscriptionType":"max"}"#),
                ]
            ])
            let claudeTool = home.appending(".local/bin/claude")
            probe = AccountSurfaceProbe(
                claude: ClaudeAccountReader(
                    runner: claudeRunner, homeURL: home.url, locate: { client, _ in client == .claude ? claudeTool : nil },
                    managedSettingsURL: home.appending("managed-settings.json")),
                codex: CodexAccountReader(homeURL: home.url, locate: { _, _ in nil }),
                shellRunner: withShell ? shell : nil)
        }

        private static var shellAnswer: String { AccountSurfaceProbePerProviderTests.shellAnswer }

        func remove() { home.remove() }
    }
}
