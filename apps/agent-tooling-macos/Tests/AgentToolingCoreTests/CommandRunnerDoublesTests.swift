import AgentToolingTestSupport
import Foundation
import Testing

@testable import AgentToolingCore

/// The shared stand-ins for the command runner and a client adapter. Later
/// suites lean on them to hold work on events instead of time, so they are
/// pinned here first.
@Suite("Command runner doubles", .timeLimit(.minutes(5)))
struct CommandRunnerDoublesTests {
    @Test func aScriptByToolAnswersEachToolInItsOwnWords() async throws {
        let runner = ScriptedCommandRunner(
            byTool: [
                "codex": [["--version"]: .standardOutput("codex-cli 0.164.0")],
                "claude": [["--version"]: .standardOutput("2.1.304 (Claude Code)")],
            ],
            fallback: [["plugin", "list", "--json"]: .init(status: 0, standardOutput: "[]", standardError: "")])

        let codex = try await runner.run(executable: "/opt/homebrew/bin/codex", arguments: ["--version"], currentDirectory: nil)
        let claude = try await runner.run(executable: "/Users/example/.local/bin/claude", arguments: ["--version"], currentDirectory: nil)
        let fallback = try await runner.run(executable: "/x/claude", arguments: ["plugin", "list", "--json"], currentDirectory: nil)
        let unscripted = try await runner.run(executable: "/x/gemini", arguments: ["--version"], currentDirectory: nil)

        #expect(codex.standardOutput == "codex-cli 0.164.0")
        #expect(claude.standardOutput == "2.1.304 (Claude Code)")
        #expect(fallback.standardOutput == "[]")
        #expect(unscripted.status == 1)
        #expect(
            await runner.launches.map(\.display) == [
                "codex --version", "claude --version", "claude plugin list --json", "gemini --version",
            ])
        #expect(await runner.launches.first?.executable == "/opt/homebrew/bin/codex")
        #expect(await runner.calls == [["--version"], ["--version"], ["plugin", "list", "--json"], ["--version"]])
    }

    @Test func aScriptedTimeoutThrowsTheRunnersOwnError() async {
        let runner = ScriptedCommandRunner(byTool: ["codex": [["--version"]: .timeOut]])

        await #expect(throws: ProcessCommandRunnerError.timedOut("/x/codex")) {
            _ = try await runner.run(executable: "/x/codex", arguments: ["--version"], currentDirectory: nil)
        }
    }

    @Test func aScriptedHangLastsUntilTheCallerIsCancelled() async {
        let runner = ScriptedCommandRunner(byTool: ["codex": [["--version"]: .hangUntilCancelled]])
        let call = Task { try await runner.run(executable: "/x/codex", arguments: ["--version"], currentDirectory: nil) }
        while await runner.launches.isEmpty { await Task.yield() }

        call.cancel()

        await #expect(throws: CancellationError.self) { _ = try await call.value }
    }

    @Test func aGatedCallWaitsForItsRelease() async throws {
        let gate = GatedCommandRunner(answer: .init(status: 0, standardOutput: "done", standardError: ""))
        let call = Task { try await gate.run(executable: "/x/codex", arguments: ["--version"], currentDirectory: nil) }

        await gate.waitUntilCalled()
        #expect(gate.launches.map(\.display) == ["codex --version"])
        gate.release()

        #expect(try await call.value.standardOutput == "done")
        #expect(gate.cancelledCalls == 0)
    }

    @Test func aGatedCallEndsAtOnceWhenItsTaskIsCancelled() async {
        let gate = GatedCommandRunner()
        let call = Task { try await gate.run(executable: "/x/claude", arguments: ["--version"], currentDirectory: nil) }

        await gate.waitUntilCalled()
        call.cancel()

        await #expect(throws: CancellationError.self) { _ = try await call.value }
        #expect(gate.cancelledCalls == 1)
    }

    @Test func aCallFromACancelledTaskEndsWithoutBeingHeld() async {
        let gate = GatedCommandRunner()
        let call = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await gate.run(executable: "/x/gemini", arguments: ["--version"], currentDirectory: nil)
        }

        await #expect(throws: CancellationError.self) { _ = try await call.value }
        #expect(gate.cancelledCalls == 1)
    }

    @Test func aReleasedGateHoldsNothing() async throws {
        let gate = GatedCommandRunner()
        gate.release()

        _ = try await gate.run(executable: "/x/codex", arguments: [], currentDirectory: nil)
        _ = try await gate.run(executable: "/x/codex", arguments: [], currentDirectory: nil)

        await gate.waitUntilCalled(times: 2)
        #expect(gate.launches.count == 2)
    }

    @Test func waitingForSeveralCallsReturnsOnceTheyAllArrive() async throws {
        let gate = GatedCommandRunner()
        let first = Task { try await gate.run(executable: "/x/codex", arguments: ["one"], currentDirectory: nil) }
        let second = Task { try await gate.run(executable: "/x/codex", arguments: ["two"], currentDirectory: nil) }

        await gate.waitUntilCalled(times: 2)
        #expect(Set(gate.launches.map(\.arguments)) == [["one"], ["two"]])
        gate.release()
        _ = try await first.value
        _ = try await second.value
    }

    @Test func aScriptedAdapterAnswersItsObservationOnceReleased() async throws {
        let capabilities = try #require(ClientAdapterRegistry().adapter(for: .codex)?.capabilities)
        let observation = TargetObservation(surface: .codexCLI, installed: true, version: "codex-cli 0.164.0", capabilities: capabilities)
        let gate = GatedCommandRunner()
        let adapter = ScriptedClientAdapter(observation, client: .codex, gate: gate)
        let home = URL(filePath: "/Users/example", directoryHint: .isDirectory)
        let scan = Task { await adapter.scan(homeURL: home, runner: RefusingCommandRunner()) }

        await gate.waitUntilCalled()
        #expect(gate.launches.map(\.display) == ["scan Codex"])
        gate.release()

        #expect(await scan.value == observation)
        #expect(adapter.client == .codex)
        #expect(adapter.surface == .codexCLI)
        #expect(
            adapter.skillDestination(skillID: "release-notes", homeURL: home)
                == CodexAdapter().skillDestination(skillID: "release-notes", homeURL: home))
    }

    /// Without an app named, a scripted adapter takes the one its
    /// observation's surface belongs to, and there is none to take only when
    /// the surface belongs to no app.
    @Test func aScriptedAdapterTakesItsAppFromTheObservation() throws {
        let capabilities = try #require(ClientAdapterRegistry().adapter(for: .claude)?.capabilities)
        for surface in TargetSurface.allCases {
            let observation = TargetObservation(surface: surface, installed: true, version: nil, capabilities: capabilities)
            #expect(ScriptedClientAdapter(observation)?.client == surface.client, "\(surface)")
        }
    }
}
