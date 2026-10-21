import Foundation
import Testing

@testable import AgentToolingCore

/// What Home's connection check says it runs before it runs: the same list
/// command the probe runs, for each app, word for word.
@Suite("Connection health list command text")
struct ConnectionHealthListCommandTextTests {
    @Test func eachAppsListCommandReadsAsTyped() {
        #expect(ConnectionHealthProbe.listCommandText(for: .claude) == "claude mcp list")
        #expect(ConnectionHealthProbe.listCommandText(for: .codex) == "codex mcp list --json")
        #expect(ConnectionHealthProbe.listCommandText(for: .kiro) == "kiro-cli mcp list")
        #expect(ConnectionHealthProbe.listCommandText(for: .gemini) == nil)
    }

    /// The text is the probe's own command: the tool's name, then the
    /// arguments a check passes, so the two can never drift apart.
    @Test func theTextIsWhatTheProbeRuns() async {
        final class Recorder: CommandRunning, @unchecked Sendable {
            private let lock = NSLock()
            private var seen: [String] = []
            var commands: [String] { lock.withLock { seen } }

            func run(executable: String, arguments: [String], currentDirectory: URL?) async throws -> CommandOutput {
                let line = ([URL(filePath: executable).lastPathComponent] + arguments).joined(separator: " ")
                lock.withLock { seen.append(line) }
                return CommandOutput(status: 0, standardOutput: "", standardError: "")
            }
        }
        let recorder = Recorder()
        let probe = ConnectionHealthProbe(
            runner: recorder, homeURL: URL(filePath: "/tmp/home"),
            locate: { client, _ in URL(filePath: "/opt/homebrew/bin/\(MCPClientCommand.executable(for: client))") })

        _ = await probe.probe([.claude, .codex, .gemini, .kiro])

        #expect(recorder.commands == [ClientKind.claude, .codex, .kiro].compactMap(ConnectionHealthProbe.listCommandText(for:)))
    }
}
