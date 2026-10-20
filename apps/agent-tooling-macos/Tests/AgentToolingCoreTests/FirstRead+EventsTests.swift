import AgentToolingTestSupport
import Foundation
import Testing

@testable import AgentToolingCore

/// What a first read says as it goes: how each command ended, and which line
/// each place it looks at is told under.
///
/// Setup words a command by how it ended — a `--version` that exits non-zero
/// "did not answer", a runner that fails is neither slow nor missing — and
/// ticks a line only in the column of the app whose read it was, so these
/// pin both.
@Suite("First read · events", .timeLimit(.minutes(5)))
struct FirstReadEventsTests {
    /// A `--version` that exits non-zero answered, with its status and no
    /// version line, and the app stays found with its version unknown.
    @Test func aVersionThatExitsNonZeroAnswersWithItsStatus() async throws {
        let world = try ClientHomeFixture(.juniper)
        defer { world.remove() }
        var replies = world.replies
        replies["codex"]?[ClientReadLocations.versionArguments] = .output(
            CommandOutput(status: 3, standardOutput: "", standardError: "boom"))

        let events = await Self.read(.codex, world, runner: ScriptedCommandRunner(byTool: replies))

        #expect(events.contains(.commandFinished(.codex, "Codex:codex --version", .answered(status: 3, firstLine: nil))))
        guard case .finished(let observation) = events.last else {
            Issue.record("the read did not finish: \(events)")
            return
        }
        #expect(observation.commandAvailable)
        #expect(observation.version == nil)
        #expect(observation.notes.contains { $0.contains("did not answer --version (exit 3)") }, "\(observation.notes)")
    }

    /// A runner that fails for another reason than a time-out or a stop
    /// reports the command as failed, and the read still finishes.
    @Test func aCommandTheRunnerFailsIsReportedAsFailed() async throws {
        let world = try ClientHomeFixture(.juniper)
        defer { world.remove() }

        let events = await Self.read(.codex, world, runner: VersionFailingRunner(base: world.scriptedRunner()))

        #expect(events.contains(.commandFinished(.codex, "Codex:codex --version", .failed)))
        #expect(events.contains(.commandFinished(.codex, "Codex:codex plugin list --json", .answered(status: 0, firstLine: nil))))
        guard case .finished = events.last else {
            Issue.record("the read did not finish: \(events)")
            return
        }
    }

    /// A read ticks the lines of its own app's column and the shared ones,
    /// each once. A place another read's line holds — another chosen app's
    /// folder, or a sign-in file — is said nothing of, and only a place no
    /// line holds is reported as not listed, once.
    @Test func aReadTicksOnlyItsOwnColumnsLines() async {
        let home = URL(filePath: "/Users/example", directoryHint: .isDirectory)
        let manifest = FirstReadManifest.build(chosen: [.codex, .claude], homeURL: home, includeProjectHistory: false)
        let (stream, continuation) = AsyncStream.makeStream(of: FirstRead.Event.self)
        let reporter = FirstRead.Reporter(client: .claude, manifest: manifest, continuation: continuation)
        let unlisted = home.appending(path: "Documents/notes.md")

        for url in [
            home.appending(path: ".claude/skills/notes/SKILL.md"), home.appending(path: ".claude/skills/drafts"),
            home.appending(path: ".agents/skills/shared-notes"),
            ClaudeAccountReader.managedSettingsURL, unlisted, unlisted,
        ] {
            reporter.read(url)
        }
        continuation.finish()
        var events: [FirstRead.Event] = []
        for await event in stream { events.append(event) }

        #expect(
            events == [
                .placeRead(.claude, "Claude Code:skills:~/.claude/skills"),
                .unlisted(.claude, unlisted),
            ])
        #expect(manifest.lists(home.appending(path: ".agents/skills/shared-notes")), "Codex's folder is listed")
        #expect(manifest.lists(ClaudeAccountReader.managedSettingsURL), "the sign-in file is listed")
        #expect(!manifest.lists(unlisted))
    }

    // MARK: - Helpers

    /// Runs a client read against the same manifest used by setup.
    private static func read(_ client: ClientKind, _ world: ClientHomeFixture, runner: any CommandRunning) async -> [FirstRead.Event] {
        let manifest = FirstReadManifest.build(chosen: world.found, homeURL: world.url, includeProjectHistory: false)
        var events: [FirstRead.Event] = []
        for await event in FirstRead.read(client, homeURL: world.url, manifest: manifest, runner: runner, registry: world.registry) {
            events.append(event)
        }
        return events
    }
}

/// Answers as `base` does, except that `--version` fails the way a runner
/// can besides a time-out or a stop: its result never came back.
private struct VersionFailingRunner: CommandRunning {
    let base: ScriptedCommandRunner

    func run(executable: String, arguments: [String], currentDirectory: URL?) async throws -> CommandOutput {
        if arguments == ClientReadLocations.versionArguments { throw ProcessCommandRunnerError.missingResult(executable) }
        return try await base.run(executable: executable, arguments: arguments, currentDirectory: currentDirectory)
    }
}
