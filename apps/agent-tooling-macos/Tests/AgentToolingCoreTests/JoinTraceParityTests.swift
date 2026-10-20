import AgentToolingTestSupport
import Foundation
import Testing
import os

@testable import AgentToolingCore

/// Verifies join reads match the consent manifest and Git stays within
/// application-owned support and scratch folders.
@Suite("Join · trace parity", .serialized, .timeLimit(.minutes(5)))
struct JoinTraceParityTests {
    @Test func cedarsJoinTouchesExactlyWhatJ01Lists() async throws {
        let traced = try await TracedJoin.make()
        defer { traced.remove() }
        let manifest = traced.manifest

        // What J01 counts.
        #expect(manifest.placeCount == 9)
        #expect(manifest.commandCount == 8)

        // Every place looked at in this Mac's apps falls under a line J01
        // lists, and every line was read. What Git and the store do inside
        // Agent Tooling's own folder is the fetch J01 names, not a read of an
        // app.
        let appPlaces = traced.places.filter { !TracedJoin.isInside($0, traced.support) }
        #expect(appPlaces.filter { !manifest.lists($0) }.isEmpty, "not listed: \(appPlaces.filter { !manifest.lists($0) })")
        #expect(traced.untouchedLines.isEmpty, "listed but never read: \(traced.untouchedLines)")

        // The apps' commands are exactly the ones J01 lists.
        #expect(traced.appCommands == traced.listedCommands)

        // Git: J01's checks first (is Git installed, does the repository
        // answer, does it hold a library this build reads), in a scratch
        // folder; then the join's own work, inside Agent Tooling's own
        // folders only, never in the person's.
        #expect(traced.gitCalls.prefix(2).map(\.description) == ["xcode-select -p", "git --version"])
        for call in traced.gitCalls where call.executableName != "xcode-select" && call.arguments != ["--version"] {
            let folder = try #require(call.currentDirectory, "\(call) ran with no folder")
            #expect(
                TracedJoin.isInside(folder, traced.support) || TracedJoin.isInside(folder, traced.scratch),
                "\(call) ran in \(folder.path(percentEncoded: false))")
        }
        #expect(traced.gitSubcommands == TracedJoin.disclosedGit, "\(traced.gitCalls.map(\.description))")
        let firstWrite = try #require(
            traced.gitCalls.firstIndex { TracedJoin.isInside($0.currentDirectory ?? traced.scratch, traced.support) })
        #expect(
            traced.gitCalls[..<firstWrite].contains { $0.subcommand == "ls-remote" },
            "the repository is checked before anything is made in Agent Tooling's own folder")

        // And the join it ran is a join: Cedar, registered, with the
        // library Juniper shares.
        #expect(traced.registeredName == "Cedar")
    }
}

/// One traced join: Cedar's home as the sample world plants it, the library
/// Juniper published, and everything the join touched.
private struct TracedJoin {
    /// A command by the tool's own name, with its arguments and where it ran.
    struct Call: CustomStringConvertible {
        let executableName: String
        let arguments: [String]
        let currentDirectory: URL?

        /// Git's own subcommand, after its global options (`--no-pager`,
        /// `-c <setting>`, `-C <folder>`), or the tool's name for anything
        /// else.
        var subcommand: String {
            guard executableName == "git" else { return executableName }
            var rest = arguments[...]
            while let first = rest.first {
                if ["-C", "-c"].contains(first) {
                    rest = rest.dropFirst(2)
                } else if first.hasPrefix("--"), first != "--version" {
                    rest = rest.dropFirst()
                } else {
                    break
                }
            }
            return rest.first ?? ""
        }

        var description: String { ([executableName] + arguments).joined(separator: " ") }
    }

    /// The Git commands joining runs, by subcommand, in the order each first
    /// runs, under what J01 says of it:
    /// - "Git is installed": `xcode-select -p`, `git --version`;
    /// - "<host> answered", "holds a library", "can be read": a scratch
    ///   repository that lists the branch, fetches its head and reads the
    ///   library's record from it;
    /// - "Then Git fetches your library into Agent Tooling's own folder": the
    ///   checkout, and the skills' files unpacked from it;
    /// - Registering this Mac, then Sharing: the first sync's commit and push.
    static let disclosedGit: [String] = [
        "xcode-select", "--version",
        "init", "ls-remote", "fetch", "rev-parse", "show", "ls-tree",
        "remote", "checkout", "archive", "tar",
        "status", "add", "diff", "config", "commit", "push",
    ]

    let manifest: FirstReadManifest
    let support: URL
    /// Where J01's checks fetch to look at the library, removed after.
    let scratch: URL
    let places: [URL]
    let appLaunches: [CommandLaunch]
    let gitCalls: [Call]
    let registeredName: String?
    private let removeAll: @Sendable () -> Void

    func remove() { removeAll() }

    /// The Git commands run, by subcommand, in the order first run.
    var gitSubcommands: [String] {
        var seen: Set<String> = []
        return gitCalls.map(\.subcommand).filter { seen.insert($0).inserted }
    }

    var appCommands: Set<FirstReadTraceCommand> {
        Set(appLaunches.map { FirstReadTraceCommand(executableName: $0.basename, arguments: $0.arguments) })
    }

    var listedCommands: Set<FirstReadTraceCommand> {
        Set(
            (manifest.apps.flatMap(\.commands) + manifest.signIn.commands).map {
                FirstReadTraceCommand(executableName: $0.executableName, arguments: $0.arguments)
            })
    }

    /// Lines nothing was looked at under.
    var untouchedLines: [String] {
        var seen: Set<String> = []
        let lines = (manifest.apps.flatMap(\.places) + manifest.shared + manifest.signIn.places).filter { seen.insert($0.id).inserted }
        return lines.filter { line in !places.contains { Self.isInside($0, line.url) } }.map(\.id)
    }

    static func make() async throws -> TracedJoin {
        let library = try GitLibraryFixture("join-trace")
        do {
            _ = try await library.publishLibrary(from: "Juniper", skills: ["release-notes", "frontend-design"])
            let world = try ClientHomeFixture(.cedar)
            let support = library.root.appending(path: "Cedar/support", directoryHint: .isDirectory)
            let scratch = library.root.appending(path: "Cedar/scratch", directoryHint: .isDirectory)
            for folder in [support, scratch] {
                try FileManager.default.createDirectory(
                    at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            }
            let manifest = FirstReadManifest.build(chosen: world.found, homeURL: world.url, includeProjectHistory: false)
            let trace = FirstReadPlaceLog()
            let tools = world.scriptedRunner()
            let git = JoinTraceRunner(tools: tools, homeURL: world.url)
            let locate: @Sendable (ClientKind, URL) -> URL? = { client, _ in world.locate(client) }
            let appServer = FirstReadLaunchLog()
            let observe: @Sendable () async throws -> [TargetObservation] = {
                var observations: [TargetObservation] = []
                for client in ClientKind.allCases where world.found.contains(client) {
                    for await event in FirstRead.read(
                        client, homeURL: world.url, manifest: manifest, runner: tools, registry: world.registry)
                    {
                        if case .finished(let observation) = event { observations.append(observation) }
                    }
                }
                // How the apps sign in, read during Checking this Mac's apps.
                let probe = AccountSurfaceProbe(
                    claude: ClaudeAccountReader(runner: tools, homeURL: world.url, locate: locate),
                    codex: CodexAccountReader(
                        homeURL: world.url, locate: locate,
                        makeSession: { executable, _ in
                            appServer.append(
                                CommandLaunch(
                                    executable: executable.path(percentEncoded: false), arguments: CodexAppServerProcessTransport.arguments)
                            )
                            throw CodexAppServerError.launchFailed("The sample world has no app server.")
                        }),
                    shellRunner: tools)
                let overrides = await probe.readShellOverrides()
                for provider in AccountProvider.allCases where world.found.contains(provider.client) {
                    _ = await probe.read(provider, depth: .signInOnly, shellOverrides: overrides)
                }
                return observations
            }
            let aside = library.root.appending(path: "Cedar/set-aside", directoryHint: .isDirectory)
            let result = try await ScanTrace.$current.withValue(trace) {
                // J01's four checks, as the address is typed.
                guard
                    case .success = try await GitRemotePreflight.run(
                        remote: library.remote.path(percentEncoded: false), deviceName: "Cedar", runner: git, scratch: scratch)
                else { throw TracedJoinError.checksFailed }
                return try await WorkspaceJoin.join(
                    remote: library.remote.path(percentEncoded: false),
                    checkout: support.appending(path: "sync-checkout", directoryHint: .isDirectory), containerRoot: support,
                    homeURL: world.url, deviceName: "Cedar", runner: git, registry: world.registry, clients: world.found,
                    locator: try WorkspaceLocator(root: support), observe: observe,
                    devicePreferences: DeviceWorkspacePreferences(
                        enabledClients: ClientKind.allCases.filter(world.found.contains),
                        chosenClients: ClientKind.allCases.filter(world.found.contains), assistantRuns: .off,
                        findsProjectsFromClaudeHistory: false),
                    contentStoreAt: { container in
                        let folder = container.appending(path: "content", directoryHint: .isDirectory)
                        try FileManager.default.createDirectory(
                            at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
                        return try CentralPackageContentStore(directory: folder)
                    },
                    discardStaleCheckout: { item in
                        try FileManager.default.createDirectory(at: aside, withIntermediateDirectories: true)
                        try FileManager.default.moveItem(at: item, to: aside.appending(path: UUID().uuidString))
                    })
            }
            return TracedJoin(
                manifest: manifest, support: support, scratch: scratch, places: trace.places,
                appLaunches: await tools.launches + appServer.entries,
                gitCalls: git.calls, registeredName: result.registeredName,
                removeAll: {
                    world.remove()
                    library.remove()
                })
        } catch {
            library.remove()
            throw error
        }
    }

    static func isInside(_ url: URL, _ folder: URL) -> Bool {
        let path = url.standardizedFileURL.resolvingSymlinksInPath().path(percentEncoded: false)
        let root = folder.standardizedFileURL.resolvingSymlinksInPath().path(percentEncoded: false)
        let prefix = root.hasSuffix("/") ? root : root + "/"
        return path == root || path == String(prefix.dropLast()) || path.hasPrefix(prefix)
    }
}

private enum TracedJoinError: Error {
    case checksFailed
}

/// A command the way a trace compares them: the tool's own name and its
/// arguments.
struct FirstReadTraceCommand: Hashable, CustomStringConvertible {
    let executableName: String
    let arguments: [String]

    var description: String { ([executableName] + arguments.prefix { $0 != "-c" }).joined(separator: " ") }
}

/// A join's runner: the system's own tools run for real against the
/// repository on this Mac, each call kept with where it ran; every app's
/// command is answered from the sample world's script.
private final class JoinTraceRunner: CommandRunning, Sendable {
    let tools: ScriptedCommandRunner
    let homeURL: URL
    private let made = OSAllocatedUnfairLock<[TracedJoin.Call]>(initialState: [])

    init(tools: ScriptedCommandRunner, homeURL: URL) {
        self.tools = tools
        self.homeURL = homeURL
    }

    var calls: [TracedJoin.Call] { made.withLock { $0 } }

    func run(executable: String, arguments: [String], currentDirectory: URL?) async throws -> CommandOutput {
        guard executable.hasPrefix("/usr/bin/") else {
            return try await tools.run(executable: executable, arguments: arguments, currentDirectory: currentDirectory)
        }
        made.withLock {
            $0.append(
                .init(
                    executableName: URL(filePath: executable).lastPathComponent, arguments: arguments,
                    currentDirectory: currentDirectory))
        }
        return try await ProcessCommandRunner(timeout: .seconds(60), homeURL: homeURL)
            .run(executable: executable, arguments: arguments, currentDirectory: currentDirectory)
    }
}
