import AgentToolingTestSupport
import Darwin
import Foundation
import Testing

@testable import AgentToolingCore

/// Stopping a first read keeps nothing and leaves nothing running.
///
/// A read that is stopped, or whose reader goes away, must never hand back an
/// observation: one made from a scan cut short says the app is missing, and a
/// library made from it would say so for good. And the commands it started
/// must end with it, so a person who stops setup, or quits, leaves no tool
/// running behind them.
@Suite("First read · cancellation", .timeLimit(.minutes(5)))
struct FirstReadCancellationTests {
    @Test func cancellingTheReaderWhileItsCommandsRunKeepsNothing() async throws {
        let world = try ClientHomeFixture(.juniper)
        defer { world.remove() }
        let gate = GatedCommandRunner()
        let reading = FirstRead.read(
            .codex, homeURL: world.url, manifest: Self.manifest(world), runner: gate, registry: world.registry)
        let reader = Task {
            var events: [FirstRead.Event] = []
            for await event in reading { events.append(event) }
            return events
        }

        await gate.waitUntilCalled(times: 3)
        reader.cancel()
        let events = await reader.value
        await reading.stop()

        #expect(!events.contains { if case .finished = $0 { true } else { false } }, "a stopped read is never kept")
        #expect(gate.cancelledCalls == 3, "every command the read had started was stopped")
        #expect(Set(gate.launches.map(\.display)) == ["codex --version", "codex plugin list --json", "codex mcp list --json"])
    }

    @Test func stoppingWhileItsCommandsRunKeepsNothing() async throws {
        let world = try ClientHomeFixture(.juniper)
        defer { world.remove() }
        let gate = GatedCommandRunner()
        let reading = FirstRead.read(
            .claude, homeURL: world.url, manifest: Self.manifest(world), runner: gate, registry: world.registry)
        let reader = Task {
            var events: [FirstRead.Event] = []
            for await event in reading { events.append(event) }
            return events
        }

        await gate.waitUntilCalled(times: 2)
        await reading.stop()
        let events = await reader.value

        #expect(!events.contains { if case .finished = $0 { true } else { false } }, "a stopped read is never kept")
        #expect(gate.cancelledCalls == 2)
        // Nothing reaches the reader once the read was stopped, the
        // commands' own endings included.
        #expect(!events.contains { if case .commandFinished = $0 { true } else { false } })
    }

    /// A `--version` that never answers holds the read until it is stopped,
    /// and then the read keeps nothing.
    @Test func aHungVersionThatIsStoppedKeepsNothing() async throws {
        let world = try ClientHomeFixture(.juniper)
        defer { world.remove() }
        var replies = world.replies
        replies["gemini"]?[ClientReadLocations.versionArguments] = .hangUntilCancelled
        let runner = ScriptedCommandRunner(byTool: replies)
        let reading = FirstRead.read(
            .gemini, homeURL: world.url, manifest: Self.manifest(world), runner: runner, registry: world.registry)
        var events: [FirstRead.Event] = []

        for await event in reading {
            events.append(event)
            if case .commandStarted = event { await reading.stop() }
        }

        // Places read while the command was held may come before it; nothing
        // comes after the stop.
        #expect(events.last == .commandStarted(.gemini, "Gemini CLI:gemini --version"))
        #expect(!events.contains { if case .finished = $0 { true } else { false } }, "a stopped read is never kept")
        #expect(await runner.launches.map(\.display) == ["gemini --version"])
    }

    /// Uses real child processes to verify `stop()` waits for termination, including
    /// SIGKILL escalation after one second. Three- and four-second bounds allow
    /// test scheduling while remaining below the commands' sixty-second sleep.
    @Test(arguments: [false, true])
    func aStoppedReadsCommandsAreGoneWhenStopReturns(ignoringTheStop: Bool) async throws {
        let home = try FixtureHome("first-read-stop")
        defer { home.remove() }
        let started = home.appending("started.txt")
        // Each run notes its process, then becomes `sleep` in place, so the
        // number noted is the one that has to go. An ignored signal stays
        // ignored across `exec`.
        let script = """
            #!/bin/sh
            \(ignoringTheStop ? "trap '' TERM" : ":")
            echo "$$" >> '\(started.path(percentEncoded: false))'
            exec /bin/sleep 60
            """
        try home.installTool(.codex, in: ".local/bin", script: script)
        let manifest = FirstReadManifest.build(chosen: [.codex], homeURL: home.url, includeProjectHistory: false)
        let reading = FirstRead.read(
            .codex, homeURL: home.url, manifest: manifest, runner: ProcessCommandRunner(timeout: .seconds(50), homeURL: home.url),
            registry: .bundled(locate: { client, _ in home.locate(client) }))
        let reader = Task {
            var events: [FirstRead.Event] = []
            for await event in reading { events.append(event) }
            return events
        }

        let children = try await Self.processes(notedIn: started, count: 3)
        #expect(children.count == 3 && children.allSatisfy(Self.isRunning), "the commands were running when the read was stopped")
        let stopping = ContinuousClock.now
        await reading.stop()
        let took = ContinuousClock.now - stopping
        let events = await reader.value

        #expect(took < (ignoringTheStop ? .seconds(4) : .seconds(3)), "stop returned after \(took)")
        #expect(!children.contains(where: Self.isRunning), "no command the read started outlives it")
        #expect(!events.contains { if case .finished = $0 { true } else { false } })
    }

    /// A `--version` that runs past its time is the app being slow, not the
    /// app being missing: the read finishes, the command says it timed out,
    /// and the observation keeps the tool with its version unknown.
    @Test func aTimedOutVersionIsReportedAndTheAppStaysFound() async throws {
        let world = try ClientHomeFixture(.juniper)
        defer { world.remove() }
        var replies = world.replies
        replies["codex"]?[ClientReadLocations.versionArguments] = .timeOut
        let runner = ScriptedCommandRunner(byTool: replies)
        var events: [FirstRead.Event] = []

        for await event in FirstRead.read(
            .codex, homeURL: world.url, manifest: Self.manifest(world), runner: runner, registry: world.registry)
        {
            events.append(event)
        }

        #expect(events.contains(.commandFinished(.codex, "Codex:codex --version", .timedOut)))
        guard case .finished(let observation) = events.last else {
            Issue.record("the read did not finish: \(events)")
            return
        }
        #expect(observation.commandAvailable)
        #expect(observation.installed)
        #expect(observation.version == nil)
        #expect(observation.notes.contains { $0.contains("did not answer --version in the time allowed") }, "\(observation.notes)")
        #expect(!observation.notes.contains { $0.contains("not available in any known install location") })
        #expect(observation.discoveredPlugins == ["linear@openai-curated"], "the rest of the read still landed")
    }

    // MARK: - Helpers

    private static func manifest(_ world: ClientHomeFixture) -> FirstReadManifest {
        FirstReadManifest.build(chosen: world.found, homeURL: world.url, includeProjectHistory: false)
    }

    /// The process numbers the stand-in tool noted in `file`, once there are
    /// `count` of them. The child is another process, so there is nothing to
    /// wait on but the file it writes; it is looked at every 20 ms, for at
    /// most thirty seconds, which a Mac busy with other tests can need.
    private static func processes(notedIn file: URL, count: Int) async throws -> [pid_t] {
        for _ in 0..<1_500 {
            let text = (try? String(contentsOf: file, encoding: .utf8)) ?? ""
            let noted = text.split(whereSeparator: \.isNewline).compactMap { pid_t(String($0)) }
            if noted.count >= count { return noted }
            try await Task.sleep(for: .milliseconds(20))
        }
        Issue.record("the stand-in tool never started \(count) times")
        return []
    }

    /// Whether the process is still there. A child the runner already waited
    /// for is gone entirely, so signal 0 finds nothing.
    private static func isRunning(_ process: pid_t) -> Bool {
        kill(process, 0) == 0 || errno != ESRCH
    }
}
