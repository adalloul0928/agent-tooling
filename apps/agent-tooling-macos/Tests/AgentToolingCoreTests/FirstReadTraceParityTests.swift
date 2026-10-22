import AgentToolingTestSupport
import Foundation
import Testing
import os

@testable import AgentToolingCore

/// Traces client, project-history and sign-in reads through setup and commit.
/// Every declared line must be touched; every read and command must be listed.
@Suite("First read · trace parity", .timeLimit(.minutes(5)))
struct FirstReadTraceParityTests {
    /// Claude Code's optional project history.
    struct Mode: CustomTestStringConvertible, Sendable {
        let projects: Bool

        var testDescription: String {
            "project history \(projects ? "on" : "off")"
        }
    }

    static let modes = [Mode(projects: true), Mode(projects: false)]

    @Test(arguments: modes)
    func juniperTouchesExactlyWhatItsManifestLists(mode: Mode) async throws {
        let world = try ClientHomeFixture(.juniper)
        defer { world.remove() }
        try world.plantDecoys()

        let read = try await TracedFirstRead.make(world, chosen: world.found, projects: mode.projects)

        #expect(read.manifest.placeCount == (mode.projects ? 14 : 13))
        #expect(read.manifest.commandCount == 9)
        #expect(read.unlistedPlaces.isEmpty, "not listed before: \(read.unlistedPlaces.map(\.path))")
        #expect(read.untouchedLines.isEmpty, "listed but never read: \(read.untouchedLines)")
        #expect(read.ranCommands == read.listedCommands)
        #expect(read.commitLaunches.isEmpty, "the commit replays the read and runs nothing")
    }

    @Test(arguments: modes)
    func juniperNeverOpensWhatNoFirstReadOpens(mode: Mode) async throws {
        let world = try ClientHomeFixture(.juniper)
        defer { world.remove() }
        try world.plantDecoys()
        var forbidden = [".kiro", ".codex/sessions", "Documents"]
        if !mode.projects { forbidden.append(".claude/projects") }

        let read = try await TracedFirstRead.make(world, chosen: world.found, projects: mode.projects)

        for folder in forbidden.map({ world.home.appending($0, directoryHint: .isDirectory) }) {
            let opened = read.places.filter { Self.isInside($0, folder) }
            #expect(opened.isEmpty, "\(folder.lastPathComponent): \(opened.map(\.path))")
        }
        #expect(!read.ranCommands.contains { $0.executableName == "kiro-cli" })
        let skills = Set(read.observations.flatMap(\.discoveredSkills))
        #expect(!skills.contains("kiro-notes"))
    }

    /// Each app's own read reports its lines: each of its places once, its
    /// commands as they start and end, then the observation it read.
    @Test(arguments: modes)
    func eachAppsReadReportsItsOwnLines(mode: Mode) async throws {
        let world = try ClientHomeFixture(.juniper)
        defer { world.remove() }

        let read = try await TracedFirstRead.make(world, chosen: world.found, projects: mode.projects)

        for app in read.manifest.apps {
            let events = read.events[app.client] ?? []
            let expectedPlaces = Set(app.places.filter { $0.role != .projectHistory }.map(\.id) + read.manifest.shared.map(\.id))
            let placesRead = events.compactMap { event -> String? in
                if case .placeRead(app.client, let id) = event { return id }
                return nil
            }
            #expect(Set(placesRead) == expectedPlaces, "\(app.client)")
            #expect(placesRead.count == Set(placesRead).count, "each line is reported once: \(app.client)")
            #expect(!events.contains { if case .unlisted = $0 { true } else { false } }, "\(app.client)")

            let started = events.compactMap { event -> String? in
                if case .commandStarted(app.client, let id) = event { return id }
                return nil
            }
            let finished = events.compactMap { event -> (String, FirstRead.Outcome)? in
                if case .commandFinished(app.client, let id, let outcome) = event { return (id, outcome) }
                return nil
            }
            #expect(Set(started) == Set(app.commands.map(\.id)), "\(app.client)")
            #expect(Set(finished.map(\.0)) == Set(started), "\(app.client)")
            for (id, outcome) in finished {
                let isVersion = id == "\(app.client.rawValue):\(ClientExecutableLocator.executableName(for: app.client)) --version"
                #expect(outcome == .answered(status: 0, firstLine: isVersion ? world.versionLine(for: app.client) : nil), "\(id)")
            }

            guard case .finished(let observation) = events.last else {
                Issue.record("\(app.client)'s read did not end with its observation")
                continue
            }
            #expect(observation.surface.client == app.client)
            #expect(events.filter { if case .finished = $0 { true } else { false } }.count == 1)
        }
    }

    /// An app turned on but not found is still read: its three places are
    /// looked at and its `--version` runs, which answers that there is
    /// nothing to run.
    @Test func kiroCLITurnedOnButNotFoundStillReadsWhatItLists() async throws {
        let world = try ClientHomeFixture(.juniper)
        defer { world.remove() }

        let read = try await TracedFirstRead.make(world, chosen: Set(ClientKind.allCases), projects: true)

        #expect(read.manifest.placeCount == 17)
        #expect(read.manifest.commandCount == 10)
        #expect(read.unlistedPlaces.isEmpty, "not listed before: \(read.unlistedPlaces.map(\.path))")
        #expect(read.untouchedLines.isEmpty, "listed but never read: \(read.untouchedLines)")
        #expect(read.ranCommands == read.listedCommands)
        #expect(read.events[.kiro]?.contains(.commandFinished(.kiro, "Kiro CLI:kiro-cli --version", .notFound)) == true)
    }

    /// Cedar reads two apps and nothing of the third.
    @Test func cedarTouchesExactlyWhatItsManifestLists() async throws {
        let world = try ClientHomeFixture(.cedar)
        defer { world.remove() }
        try world.plantDecoys()

        let read = try await TracedFirstRead.make(world, chosen: world.found, projects: false)

        #expect(read.manifest.placeCount == 9)
        #expect(read.manifest.commandCount == 8)
        #expect(read.unlistedPlaces.isEmpty, "not listed before: \(read.unlistedPlaces.map(\.path))")
        #expect(read.untouchedLines.isEmpty, "listed but never read: \(read.untouchedLines)")
        #expect(read.ranCommands == read.listedCommands)
        #expect(!read.places.contains { Self.isInside($0, world.home.appending(".gemini", directoryHint: .isDirectory)) })
    }

    /// A read of Codex alone, or of Gemini CLI alone, looks at nothing of
    /// Claude Code's, though each checks every skill it finds against the
    /// folder Claude Code keeps its account's skills in.
    @Test(arguments: [ClientKind.codex, .gemini])
    func aReadOfAnotherAppAloneLooksAtNothingOfClaudeCodes(client: ClientKind) async throws {
        let world = try ClientHomeFixture(.juniper)
        defer { world.remove() }

        let read = try await TracedFirstRead.make(world, chosen: [client], projects: false)

        let claude = read.places.filter { Self.isInside($0, world.home.appending(".claude", directoryHint: .isDirectory)) }
        #expect(claude.isEmpty, "\(claude.map(\.path))")
        #expect(read.unlistedPlaces.isEmpty, "not listed before: \(read.unlistedPlaces.map(\.path))")
        #expect(read.untouchedLines.isEmpty, "listed but never read: \(read.untouchedLines)")
        #expect(read.ranCommands == read.listedCommands)
    }

    /// The check has teeth: a skill a link leads outside the folder it sits
    /// in is read where the link leads, which no line lists, and the read
    /// says so.
    @Test func aReadOutsideTheListIsReportedAsNotListed() async throws {
        let world = try ClientHomeFixture(.juniper)
        defer { world.remove() }
        try world.home.plantSkill("Documents/drafts/storyboard", name: "storyboard", description: "Sketches a storyboard.")
        let target = world.home.appending("Documents/drafts/storyboard", directoryHint: .isDirectory)
        try FileManager.default.createSymbolicLink(
            at: world.home.appending(".claude/skills/storyboard"), withDestinationURL: target)

        let read = try await TracedFirstRead.make(world, chosen: world.found, projects: true)

        #expect(read.unlistedPlaces.contains { Self.isInside($0, target) })
        let unlisted = (read.events[.claude] ?? []).compactMap { event -> URL? in
            if case .unlisted(.claude, let url) = event { return url }
            return nil
        }
        #expect(unlisted.contains { Self.isInside($0, target) }, "Claude Code's read says it read outside its list")
    }

    /// A link to a file elsewhere is looked at where it leads too, though it
    /// is no skill, and the read says so.
    @Test func aLinkToAFileElsewhereIsReportedAsNotListed() async throws {
        let world = try ClientHomeFixture(.juniper)
        defer { world.remove() }
        try world.home.plant("Documents/notes.md", "Notes kept in Documents.\n")
        let target = world.home.appending("Documents/notes.md")
        try FileManager.default.createSymbolicLink(at: world.home.appending(".codex/skills/notes.md"), withDestinationURL: target)

        let read = try await TracedFirstRead.make(world, chosen: world.found, projects: false)

        #expect(read.unlistedPlaces.map(FirstReadManifest.key) == [FirstReadManifest.key(target)])
        let unlisted = (read.events[.codex] ?? []).compactMap { event -> String? in
            if case .unlisted(.codex, let url) = event { return FirstReadManifest.key(url) }
            return nil
        }
        #expect(unlisted == [FirstReadManifest.key(target)])
    }

    /// A link from one app's folder into a folder another chosen app reads,
    /// the way skills.sh-style installers lay skills out, is read where it
    /// leads, and that folder is listed: the person was shown it under the
    /// other app. Claude Code's read says nothing of it and names only its
    /// own lines; Codex's read ticks the folder's line; the skill is still
    /// Claude Code's.
    @Test
    func aLinkIntoAnotherChosenAppsFolderIsListed() async throws {
        let world = try ClientHomeFixture(.juniper)
        defer { world.remove() }
        let target = try Self.linkSharedNotes(in: world)

        let read = try await TracedFirstRead.make(world, chosen: [.codex, .claude], projects: false)

        #expect(read.places.contains { Self.isInside($0, target) }, "the link was read where it leads")
        #expect(read.unlistedPlaces.isEmpty, "not listed before: \(read.unlistedPlaces.map(\.path))")
        let claude = read.events[.claude] ?? []
        #expect(!claude.contains { if case .unlisted = $0 { true } else { false } }, "\(claude)")
        let column = try #require(read.manifest.apps.first { $0.client == .claude })
        let lines = Set((column.places + read.manifest.shared).map(\.id))
        for case .placeRead(_, let id) in claude {
            #expect(lines.contains(id), "Claude Code's read names only its own lines: \(id)")
        }
        #expect(read.events[.codex]?.contains(.placeRead(.codex, "Codex:skills:~/.agents/skills")) == true)
        let observation = read.observations.first { $0.surface.client == .claude }
        #expect(observation?.discoveredSkills.contains("shared-notes") == true)
    }

    /// The same link with Codex not chosen leads into a folder no line of
    /// the manifest holds, and Claude Code's read says so.
    @Test
    func aLinkIntoAFolderNoChosenAppReadsIsNotListed() async throws {
        let world = try ClientHomeFixture(.juniper)
        defer { world.remove() }
        let target = try Self.linkSharedNotes(in: world)

        let read = try await TracedFirstRead.make(world, chosen: [.claude], projects: false)

        let unlisted = (read.events[.claude] ?? []).compactMap { event -> String? in
            if case .unlisted(.claude, let url) = event { return FirstReadManifest.key(url) }
            return nil
        }
        #expect(unlisted.contains(FirstReadManifest.key(target)), "\(unlisted)")
        #expect(read.unlistedPlaces.contains { Self.isInside($0, target) })
    }

    /// A first read reads: nothing in the home is written or changed.
    @Test func aFirstReadWritesNothingInTheHome() async throws {
        let world = try ClientHomeFixture(.juniper)
        defer { world.remove() }
        try world.plantDecoys()
        let before = try Self.snapshot(of: world.url)

        _ = try await TracedFirstRead.make(world, chosen: world.found, projects: true)

        #expect(try Self.snapshot(of: world.url) == before)
    }

    // MARK: - Helpers

    static func isInside(_ url: URL, _ folder: URL) -> Bool {
        PathContainment.isContained(normalizedChild: FirstReadManifest.key(url), inNormalizedRoot: FirstReadManifest.key(folder))
    }

    /// Plants a skill in Codex's `~/.agents/skills` and links it from Claude
    /// Code's `~/.claude/skills`. Returns the skill's folder.
    private static func linkSharedNotes(in world: ClientHomeFixture) throws -> URL {
        try world.home.plantSkill(".agents/skills/shared-notes", name: "shared-notes", description: "Notes two apps share.")
        let target = world.home.appending(".agents/skills/shared-notes", directoryHint: .isDirectory)
        try FileManager.default.createSymbolicLink(at: world.home.appending(".claude/skills/shared-notes"), withDestinationURL: target)
        return target
    }

    /// Every file and folder under `root`, with its size and when it last
    /// changed.
    private static func snapshot(of root: URL) throws -> [String: String] {
        let keys: [URLResourceKey] = [.contentModificationDateKey, .fileSizeKey, .isSymbolicLinkKey]
        guard let walk = FileManager.default.enumerator(at: root, includingPropertiesForKeys: keys) else { return [:] }
        var entries: [String: String] = [:]
        let base = FirstReadManifest.key(root)
        while let item = walk.nextObject() as? URL {
            let values = try item.resourceValues(forKeys: Set(keys))
            let date = values.contentModificationDate?.timeIntervalSince1970 ?? 0
            entries[String(FirstReadManifest.key(item).dropFirst(base.count))] = "\(values.fileSize ?? -1) \(date)"
        }
        return entries
    }
}

/// One first read of a sample-world Mac as setup makes it, written down.
struct TracedFirstRead {
    /// A command by the tool's own name and its arguments, the way a trace
    /// compares them.
    struct Command: Hashable, CustomStringConvertible {
        let executableName: String
        let arguments: [String]

        var description: String { ([executableName] + arguments.prefix { $0 != "-c" }).joined(separator: " ") }
    }

    let manifest: FirstReadManifest
    /// Every place looked at, in order, the commit's reads included.
    let places: [URL]
    /// Each chosen app's read, as its reading reported it.
    let events: [ClientKind: [FirstRead.Event]]
    let observations: [TargetObservation]
    /// Every command the read and the sign-in reads ran.
    let launches: [CommandLaunch]
    /// The commands the commit ran.
    let commitLaunches: [CommandLaunch]

    var ranCommands: Set<Command> {
        Set(launches.map { Command(executableName: $0.basename, arguments: $0.arguments) })
    }

    var listedCommands: Set<Command> {
        Set(
            (manifest.apps.flatMap(\.commands) + manifest.signIn.commands).map {
                Command(executableName: $0.executableName, arguments: $0.arguments)
            })
    }

    /// Every line the manifest lists, each once.
    var lines: [FirstReadManifest.Place] {
        var seen: Set<String> = []
        return (manifest.apps.flatMap(\.places) + manifest.shared + manifest.signIn.places).filter { seen.insert($0.id).inserted }
    }

    /// Places looked at that fall under no line.
    var unlistedPlaces: [URL] {
        places.filter { !manifest.lists($0) }
    }

    /// Lines nothing was looked at under.
    var untouchedLines: [String] {
        lines.filter { line in !places.contains { FirstReadTraceParityTests.isInside($0, line.url) } }.map(\.id)
    }

    /// Reads `chosen` on `world`: each app's first read, then the project
    /// history's names when `projects` is on, then the sign-in reads, then
    /// the commit, all under one trace.
    static func make(_ world: ClientHomeFixture, chosen: Set<ClientKind>, projects: Bool) async throws -> TracedFirstRead {
        let support = try TemporaryFolder("first-read-trace-support").url
        defer { try? FileManager.default.removeItem(at: support) }
        let trace = FirstReadPlaceLog()
        let appServer = FirstReadLaunchLog()
        let runner = world.scriptedRunner()
        let commitRunner = ScriptedCommandRunner([:])
        let locate: @Sendable (ClientKind, URL) -> URL? = { client, _ in world.locate(client) }

        let manifest = FirstReadManifest.build(chosen: chosen, homeURL: world.url, includeProjectHistory: projects)
        return try await ScanTrace.$current.withValue(trace) {
            var events: [ClientKind: [FirstRead.Event]] = [:]
            var observations: [TargetObservation] = []
            for client in ClientKind.allCases where chosen.contains(client) {
                for await event in FirstRead.read(
                    client, homeURL: world.url, manifest: manifest, runner: runner, registry: world.registry)
                {
                    events[client, default: []].append(event)
                    if case .finished(let observation) = event { observations.append(observation) }
                }
            }
            if projects, chosen.contains(.claude) { _ = ProjectDiscovery.sessionIndexEntryNames(homeURL: world.url) }

            let probe = AccountSurfaceProbe(
                claude: ClaudeAccountReader(runner: runner, homeURL: world.url, locate: locate),
                codex: CodexAccountReader(
                    homeURL: world.url, locate: locate,
                    makeSession: { executable, _ in
                        appServer.append(
                            CommandLaunch(
                                executable: executable.path(percentEncoded: false), arguments: CodexAppServerProcessTransport.arguments)
                        )
                        throw CodexAppServerError.launchFailed("The sample world has no app server.")
                    }),
                shellRunner: runner)
            let providers = AccountProvider.allCases.filter { chosen.contains($0.client) }
            if !providers.isEmpty {
                let overrides = await probe.readShellOverrides()
                for provider in providers { _ = await probe.read(provider, depth: .signInOnly, shellOverrides: overrides) }
            }

            _ = try await WorkspaceLocator(root: support).create(
                homeURL: world.url, runner: commitRunner, registry: .replaying(observations),
                preferences: DeviceWorkspacePreferences(
                    chosenClients: ClientKind.allCases.filter(chosen.contains), assistantRuns: .off,
                    findsProjectsFromClaudeHistory: projects))

            return TracedFirstRead(
                manifest: manifest, places: trace.places, events: events, observations: observations,
                launches: await runner.launches + appServer.entries, commitLaunches: await commitRunner.launches)
        }
    }
}

/// Every place a read looked at, in order.
final class FirstReadPlaceLog: ScanTraceRecording {
    private let lock = OSAllocatedUnfairLock<[URL]>(initialState: [])

    var places: [URL] { lock.withLock { $0 } }

    func read(_ url: URL) {
        lock.withLock { $0.append(url) }
    }
}

/// Commands started outside a runner, in order.
final class FirstReadLaunchLog: Sendable {
    private let lock = OSAllocatedUnfairLock<[CommandLaunch]>(initialState: [])

    var entries: [CommandLaunch] { lock.withLock { $0 } }

    func append(_ launch: CommandLaunch) {
        lock.withLock { $0.append(launch) }
    }
}
