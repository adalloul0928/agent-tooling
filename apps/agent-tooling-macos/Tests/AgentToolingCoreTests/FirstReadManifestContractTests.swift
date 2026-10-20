import AgentToolingTestSupport
import Foundation
import Testing
import os

@testable import AgentToolingCore

/// The first read's manifest as setup shows it before anything is read: its
/// counts in synthetic homes and the identifier
/// scheme other screens key their per-line states by. The real manifest built
/// from the adapters' own declarations must keep every pin here.
@Suite("First read manifest · contract")
struct FirstReadManifestContractTests {
    private static let home = URL(filePath: "/Users/example", directoryHint: .isDirectory)
    private static let juniper: Set<ClientKind> = [.codex, .claude, .gemini]

    private static func manifest(
        _ chosen: Set<ClientKind>, projects: Bool = true
    ) -> FirstReadManifest {
        FirstReadManifest.build(chosen: chosen, homeURL: home, includeProjectHistory: projects)
    }

    // MARK: Counts

    @Test func juniperReadsFourteenPlacesAndRunsNineCommands() {
        let manifest = Self.manifest(Self.juniper)
        #expect(manifest.placeCount == 14)
        #expect(manifest.commandCount == 9)
    }

    @Test func withoutProjectHistoryJuniperReadsThirteenPlaces() {
        let manifest = Self.manifest(Self.juniper, projects: false)
        #expect(manifest.placeCount == 13)
        #expect(manifest.commandCount == 9)
    }

    /// Cedar joins, and a join does not read project history.
    @Test func cedarReadsNinePlacesAndRunsEightCommands() {
        let manifest = Self.manifest([.codex, .claude], projects: false)
        #expect(manifest.placeCount == 9)
        #expect(manifest.commandCount == 8)
    }

    @Test func turningKiroCLIOnReadsSeventeenPlacesAndRunsTenCommands() {
        let manifest = Self.manifest(Set(ClientKind.allCases))
        #expect(manifest.placeCount == 17)
        #expect(manifest.commandCount == 10)
    }

    @Test func noAppReadsNothingAndRunsNothing() {
        let manifest = Self.manifest([])
        #expect(manifest.apps.isEmpty)
        #expect(manifest.signIn.places.isEmpty && manifest.signIn.commands.isEmpty)
        #expect(manifest.shared.isEmpty)
        #expect(manifest.placeCount == 0)
        #expect(manifest.commandCount == 0)
    }

    // MARK: What each line says

    /// The columns as the reads screen draws them, line for line.
    @Test func eachAppListsWhatItReadsAndRunsInTheAppOrder() {
        let manifest = Self.manifest(Self.juniper)

        #expect(manifest.apps.map(\.client) == [.codex, .claude, .gemini])
        #expect(
            manifest.apps.map { $0.places.map(\.display) } == [
                ["~/.codex/config.toml", "~/.agents/skills", "~/.codex/skills", "~/.codex/plugins"],
                ["~/.claude/settings.json", "~/.claude.json", "~/.claude/skills", "~/.claude/plugins", "~/.claude/projects"],
                ["~/.gemini/settings.json", "~/.gemini/settings.toml", "~/.gemini/skills", "~/.gemini/extensions", "~/.agents/skills"],
            ])
        #expect(
            manifest.apps.map { $0.commands.map(\.display) } == [
                ["codex --version", "codex plugin list --json", "codex mcp list --json"],
                ["claude --version", "claude plugin list --json"],
                ["gemini --version"],
            ])
        #expect(manifest.signIn.places.map(\.display) == ["/Library/Application Support/ClaudeCode/managed-settings.json"])
        #expect(manifest.signIn.commands.map(\.display) == ["codex app-server", "claude auth status --json", "zsh -l -i"])
    }

    /// `<scope>:<role>:<display>` for a place and `<scope>:<display>` for a
    /// command; the scope is the app's name, `shared` or `signIn`.
    @Test func theIdentifiersFollowTheScheme() {
        let manifest = Self.manifest(Self.juniper)

        #expect(
            manifest.apps.flatMap { $0.places.map(\.id) } == [
                "Codex:configuration:~/.codex/config.toml",
                "shared:skills:~/.agents/skills",
                "Codex:skills:~/.codex/skills",
                "Codex:plugins:~/.codex/plugins",
                "Claude Code:configuration:~/.claude/settings.json",
                "Claude Code:configuration:~/.claude.json",
                "Claude Code:skills:~/.claude/skills",
                "Claude Code:plugins:~/.claude/plugins",
                "Claude Code:projectHistory:~/.claude/projects",
                "Gemini CLI:configuration:~/.gemini/settings.json",
                "Gemini CLI:configuration:~/.gemini/settings.toml",
                "Gemini CLI:skills:~/.gemini/skills",
                "Gemini CLI:skills:~/.gemini/extensions",
                "shared:skills:~/.agents/skills",
            ])
        #expect(
            manifest.apps.flatMap { $0.commands.map(\.id) } + manifest.signIn.commands.map(\.id) == [
                "Codex:codex --version",
                "Codex:codex plugin list --json",
                "Codex:codex mcp list --json",
                "Claude Code:claude --version",
                "Claude Code:claude plugin list --json",
                "Gemini CLI:gemini --version",
                "signIn:codex app-server",
                "signIn:claude auth status --json",
                "signIn:zsh -l -i",
            ])
        #expect(manifest.signIn.places.map(\.id) == ["signIn:signIn:/Library/Application Support/ClaudeCode/managed-settings.json"])
    }

    /// An identifier names the place, not the folder this Mac's home is in.
    @Test func identifiersAreTheSameInEveryHome() {
        let elsewhere = FirstReadManifest.build(
            chosen: Self.juniper, homeURL: URL(filePath: "/Users/another-person"), includeProjectHistory: true)
        let here = Self.manifest(Self.juniper)
        #expect(elsewhere.apps.map { $0.places.map(\.id) } == here.apps.map { $0.places.map(\.id) })
        #expect(elsewhere.apps.first?.places.first?.url.path(percentEncoded: false) == "/Users/another-person/.codex/config.toml")
    }

    /// Gemini CLI also reads Codex's `~/.agents/skills`: listed under both,
    /// linked under Gemini CLI, and counted once.
    @Test func aPlaceReadForTwoAppsIsLinkedUnderTheLaterOne() throws {
        let manifest = Self.manifest(Self.juniper)
        let codex = try #require(manifest.apps.first { $0.client == .codex }?.places.first { $0.display == "~/.agents/skills" })
        let gemini = try #require(manifest.apps.first { $0.client == .gemini }?.places.first { $0.display == "~/.agents/skills" })

        #expect(!codex.isLinked)
        #expect(codex.sharedWith == [.gemini])
        #expect(gemini.isLinked)
        #expect(gemini.sharedWith == [.codex])
        #expect(gemini.id == codex.id)
        #expect(manifest.apps.flatMap(\.places).filter(\.isLinked).count == 1)

        // Without Codex the folder is Gemini CLI's own.
        let alone = try #require(Self.manifest([.gemini]).apps.first?.places.first { $0.display == "~/.agents/skills" })
        #expect(!alone.isLinked)
        #expect(alone.sharedWith.isEmpty)
        #expect(alone.id == "Gemini CLI:skills:~/.agents/skills")
    }

    /// Codex also declares its plugin cache, inside `~/.codex/plugins`, and
    /// Gemini CLI declares `~/.gemini/extensions` twice; each is one place.
    @Test func nestedAndRepeatedRootsAreOnePlace() {
        let manifest = Self.manifest([.codex, .gemini])
        let displays = manifest.apps.flatMap { $0.places.map(\.display) }
        #expect(!displays.contains("~/.codex/plugins/cache"))
        #expect(displays.filter { $0 == "~/.gemini/extensions" }.count == 1)
        #expect(manifest.apps.map { $0.places.count } == [4, 5])
    }

    @Test func projectHistoryIsReadOnlyForClaudeCodeAndOnlyWhenAsked() {
        func lists(_ chosen: Set<ClientKind>, _ projects: Bool) -> Bool {
            Self.manifest(chosen, projects: projects).apps.flatMap(\.places).contains { $0.role == .projectHistory }
        }
        #expect(lists([.claude], true))
        #expect(!lists([.claude], false))
        #expect(!lists([.codex, .gemini], true))
    }

    /// The sign-in reads run only for an app with an account to read: no
    /// login shell starts for Gemini CLI or Kiro CLI alone.
    @Test func theSignInReadsFollowTheAppsThatHaveAnAccount() {
        #expect(Self.manifest([.gemini, .kiro]).signIn.commands.isEmpty)
        #expect(Self.manifest([.gemini, .kiro]).signIn.places.isEmpty)
        #expect(Self.manifest([.codex]).signIn.commands.map(\.display) == ["codex app-server", "zsh -l -i"])
        #expect(Self.manifest([.codex]).signIn.places.isEmpty)
        #expect(Self.manifest([.claude]).signIn.commands.map(\.display) == ["claude auth status --json", "zsh -l -i"])
        #expect(Self.manifest([.claude]).signIn.places.count == 1)
    }

    @Test func theLoginShellIsTheProbesOwnCommand() throws {
        let shell = try #require(Self.manifest([.claude]).signIn.commands.last)
        #expect(shell.executableName == "zsh")
        #expect(shell.arguments == AccountShellEnvironmentProbe.arguments)
        #expect(Array(shell.arguments.prefix(2)) == ["-l", "-i"])
    }

    /// Asking Claude Code for its servers health-checks every one of them, so
    /// it is never part of a first read.
    @Test func claudeMCPListIsNeverRun() {
        let manifest = Self.manifest(Set(ClientKind.allCases))
        let commands = manifest.apps.flatMap(\.commands) + manifest.signIn.commands
        #expect(!commands.contains { $0.display.hasPrefix("claude mcp") })
    }

    @Test func kiroCLIReadsItsOwnThreePlacesAndRunsOneCommand() throws {
        let kiro = try #require(Self.manifest(Set(ClientKind.allCases)).apps.last)
        #expect(kiro.client == .kiro)
        #expect(kiro.places.map(\.display) == ["~/.kiro/settings/mcp.json", "~/.kiro/settings/cli.json", "~/.kiro/skills"])
        #expect(kiro.commands.map(\.display) == ["kiro-cli --version"])
    }

    // MARK: Finding a read's line

    @Test func aReadFindsTheLineItFallsUnder() throws {
        let manifest = Self.manifest(Self.juniper)
        func place(_ path: String, _ client: ClientKind) -> String? {
            manifest.place(containing: Self.home.appending(path: path), for: client)?.id
        }

        #expect(
            place(".codex/plugins/cache/openai-curated/linear/1.2.0/.codex-plugin/plugin.json", .codex) == "Codex:plugins:~/.codex/plugins")
        #expect(place(".agents/skills/frontend-design/SKILL.md", .gemini) == "shared:skills:~/.agents/skills")
        #expect(place(".claude.json", .claude) == "Claude Code:configuration:~/.claude.json")
        #expect(place(".codex/sessions/2026/10/16/rollout.jsonl", .codex) == nil, "not listed before")
        #expect(place(".claude/skills/release-notes", .codex) == nil, "Claude Code's folder is not Codex's read")
        #expect(
            manifest.place(containing: ClaudeAccountReader.managedSettingsURL, for: .claude)?.id
                == "signIn:signIn:/Library/Application Support/ClaudeCode/managed-settings.json")
    }

    // MARK: The read itself

    @Test(.timeLimit(.minutes(5)))
    func aFinishedReadYieldsItsObservation() async throws {
        let observation = try Self.observation(.codexCLI, version: "codex-cli 0.164.0")
        let registry = ClientAdapterRegistry(adapters: [try #require(ScriptedClientAdapter(observation))])

        var events: [FirstRead.Event] = []
        for await event in FirstRead.read(
            .codex, homeURL: Self.home, manifest: Self.manifest([.codex]), runner: RefusingCommandRunner(), registry: registry)
        {
            events.append(event)
        }

        #expect(events == [.finished(observation)])
    }

    @Test(.timeLimit(.minutes(5)))
    func anAppWithNoAdapterFinishesWithNothing() async {
        var events: [FirstRead.Event] = []
        for await event in FirstRead.read(
            .kiro, homeURL: Self.home, manifest: Self.manifest([.kiro]), runner: RefusingCommandRunner(),
            registry: ClientAdapterRegistry(adapters: []))
        {
            events.append(event)
        }
        #expect(events.isEmpty)
    }

    /// A stopped read keeps nothing, not even what it had read, so a Stop can
    /// never be recorded as "this app is not installed".
    @Test(.timeLimit(.minutes(5)))
    func aStoppedReadYieldsNothingAndStopsTheScan() async throws {
        let gate = GatedCommandRunner()
        let observation = try Self.observation(.claudeCode, version: "2.1.304 (Claude Code)")
        let registry = ClientAdapterRegistry(adapters: [try #require(ScriptedClientAdapter(observation, gate: gate))])
        let stream = FirstRead.read(
            .claude, homeURL: Self.home, manifest: Self.manifest([.claude]), runner: RefusingCommandRunner(), registry: registry)
        let reading = Task {
            var events: [FirstRead.Event] = []
            for await event in stream { events.append(event) }
            return events
        }

        await gate.waitUntilCalled()
        reading.cancel()
        let events = await reading.value

        #expect(events.isEmpty)
        #expect(gate.cancelledCalls == 1, "stopping the read cancels the scan under way")
    }

    @Test(.timeLimit(.minutes(5)))
    func aReadReleasedLaterStillFinishes() async throws {
        let gate = GatedCommandRunner()
        let observation = try Self.observation(.geminiCLI, version: "0.38.2")
        let registry = ClientAdapterRegistry(adapters: [try #require(ScriptedClientAdapter(observation, gate: gate))])
        let stream = FirstRead.read(
            .gemini, homeURL: Self.home, manifest: Self.manifest([.gemini]), runner: RefusingCommandRunner(), registry: registry)
        let reading = Task {
            var events: [FirstRead.Event] = []
            for await event in stream { events.append(event) }
            return events
        }

        await gate.waitUntilCalled()
        gate.release()

        #expect(await reading.value == [.finished(observation)])
        #expect(gate.cancelledCalls == 0)
    }

    /// `stop()` returns only once the scan has wound down, so quitting can
    /// wait for the commands a read started instead of guessing how long
    /// they take to exit.
    @Test(.timeLimit(.minutes(5)))
    func stoppingAReadReturnsOnceItsScanHasReturned() async throws {
        let gate = GatedCommandRunner()
        let windDown = GatedCommandRunner()
        let order = OrderLog()
        let observation = try Self.observation(.claudeCode, version: "2.1.304 (Claude Code)")
        let adapter = SlowToStopAdapter(
            base: ScriptedClientAdapter(observation, client: .claude, gate: gate), windDown: windDown, order: order)
        let reading = FirstRead.read(
            .claude, homeURL: Self.home, manifest: Self.manifest([.claude]), runner: RefusingCommandRunner(),
            registry: ClientAdapterRegistry(adapters: [adapter]))
        let reader = Task {
            var events: [FirstRead.Event] = []
            for await event in reading { events.append(event) }
            return events
        }

        await gate.waitUntilCalled()
        let stopping = Task {
            await reading.stop()
            order.append("stop returned")
        }
        await windDown.waitUntilCalled()
        windDown.release()
        await stopping.value

        #expect(order.entries == ["scan returned", "stop returned"])
        #expect(await reader.value.isEmpty, "a stopped read keeps nothing")
        #expect(gate.cancelledCalls == 1, "stopping the read cancels the scan under way")
    }

    /// Once stopped, a reading yields nothing more, not even an event it
    /// already holds.
    @Test(.timeLimit(.minutes(5)))
    func aStoppedReadingYieldsNothingItStillHeld() async throws {
        let observation = try Self.observation(.codexCLI, version: "codex-cli 0.164.0")
        let (events, continuation) = AsyncStream.makeStream(of: FirstRead.Event.self)
        continuation.yield(.finished(observation))
        let reading = FirstRead.Reading(events, onStop: { continuation.finish() })

        await reading.stop()

        var seen: [FirstRead.Event] = []
        for await event in reading { seen.append(event) }
        #expect(seen.isEmpty)
    }

    /// A reader that is cancelled gets nothing the reading still held, and the
    /// stream it wraps sees the cancellation, which is what stops a live scan.
    @Test(.timeLimit(.minutes(5)))
    func aCancelledReaderGetsNothingTheReadingStillHeld() async throws {
        let observation = try Self.observation(.geminiCLI, version: "0.38.2")
        let order = OrderLog()
        let (events, continuation) = AsyncStream.makeStream(of: FirstRead.Event.self)
        continuation.onTermination = { order.append("\($0)") }
        continuation.yield(.finished(observation))
        let reading = FirstRead.Reading(events)

        let reader = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            var seen: [FirstRead.Event] = []
            for await event in reading { seen.append(event) }
            return seen
        }

        #expect(await reader.value.isEmpty)
        #expect(order.entries == ["cancelled"])
    }

    /// Every `stop()` waits for the same wind-down, which runs once.
    @Test(.timeLimit(.minutes(5)))
    func stoppingAgainWindsDownOnlyOnce() async {
        let order = OrderLog()
        let (events, continuation) = AsyncStream.makeStream(of: FirstRead.Event.self)
        let reading = FirstRead.Reading(events) {
            order.append("wound down")
            continuation.finish()
        }

        async let first: Void = reading.stop()
        async let second: Void = reading.stop()
        _ = await (first, second)
        await reading.stop()

        #expect(order.entries == ["wound down"])
    }

    /// A scripted reading, as a stage test or a preview feeds one, yields
    /// what it is given, in order.
    @Test(.timeLimit(.minutes(5)))
    func aScriptedReadingYieldsWhatItIsGiven() async throws {
        let observation = try Self.observation(.codexCLI, version: "codex-cli 0.164.0")
        let script: [FirstRead.Event] = [
            .commandStarted(.codex, "Codex:codex --version"),
            .commandFinished(.codex, "Codex:codex --version", .answered(status: 0, firstLine: "codex-cli 0.164.0")),
            .finished(observation),
        ]
        let (events, continuation) = AsyncStream.makeStream(of: FirstRead.Event.self)
        for event in script { continuation.yield(event) }
        continuation.finish()

        var seen: [FirstRead.Event] = []
        for await event in FirstRead.Reading(events) { seen.append(event) }
        #expect(seen == script)
    }

    /// The sample world read through the bundled adapters, in memory.
    @Test(.timeLimit(.minutes(5)))
    func readingJuniperThroughTheFixtureFindsItsVersions() async throws {
        let world = try ClientHomeFixture(.juniper)
        defer { world.remove() }
        let manifest = FirstReadManifest.build(chosen: world.found, homeURL: world.url, includeProjectHistory: true)
        var versions: [ClientKind: String] = [:]
        for client in [ClientKind.codex, .claude, .gemini] {
            for await event in FirstRead.read(
                client, homeURL: world.url, manifest: manifest, runner: world.scriptedRunner(), registry: world.registry)
            {
                if case .finished(let observation) = event { versions[client] = observation.version }
            }
        }
        #expect(versions == [.codex: "codex-cli 0.164.0", .claude: "2.1.304 (Claude Code)", .gemini: "0.38.2"])
    }

    private static func observation(_ surface: TargetSurface, version: String) throws -> TargetObservation {
        let client = try #require(surface.client)
        let capabilities = try #require(ClientAdapterRegistry().adapter(for: client)?.capabilities)
        return TargetObservation(
            surface: surface, installed: true, version: version, capabilities: capabilities,
            lastScannedAt: Date(timeIntervalSince1970: 1_792_300_000))
    }
}

/// The order things happened in, across tasks.
private final class OrderLog: Sendable {
    private let lock = OSAllocatedUnfairLock<[String]>(initialState: [])

    var entries: [String] { lock.withLock { $0 } }

    func append(_ entry: String) {
        lock.withLock { $0.append(entry) }
    }
}

/// A scan that, once its base has answered, takes as long to wind down as the
/// test says, cancelled or not, the way a stopped command can take a moment
/// to exit. It notes when it returns.
private struct SlowToStopAdapter: ClientAdapter {
    let base: ScriptedClientAdapter
    let windDown: GatedCommandRunner
    let order: OrderLog

    var client: ClientKind { base.client }
    var surface: TargetSurface { base.surface }
    var capabilities: TargetCapabilities { base.capabilities }

    func scan(homeURL: URL, runner: any CommandRunning) async -> TargetObservation {
        let observation = await base.scan(homeURL: homeURL, runner: runner)
        let windDown = windDown
        // A detached task, so the scan's own cancellation does not end the
        // wind-down early.
        await Task.detached {
            _ = try? await windDown.run(executable: "wind-down", arguments: [], currentDirectory: nil)
        }.value
        order.append("scan returned")
        return observation
    }

    func skillDestination(skillID: String, homeURL: URL) -> URL {
        base.skillDestination(skillID: skillID, homeURL: homeURL)
    }
}
