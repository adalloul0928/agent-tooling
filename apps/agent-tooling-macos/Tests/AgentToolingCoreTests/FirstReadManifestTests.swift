import AgentToolingTestSupport
import Foundation
import Testing

@testable import AgentToolingCore

/// The first read's manifest is the adapters' own declarations, shown.
///
/// Each app's scan takes its files, folders and commands from its adapter's
/// `ClientReadLocations`, and the manifest is built from the same values, so
/// these tests hold the two to each other rather than to a list of their own:
/// what an app declares is what its column lists, folded where one folder
/// holds another or two apps read one folder; what its scan runs is what its
/// column says it runs; and the sign-in strip is the sign-in readers' own
/// files and commands.
@Suite("First read manifest")
struct FirstReadManifestTests {
    private static let home = URL(filePath: "/Users/example", directoryHint: .isDirectory)

    private static func manifest(_ chosen: Set<ClientKind>, projects: Bool = false) -> FirstReadManifest {
        FirstReadManifest.build(chosen: chosen, homeURL: home, includeProjectHistory: projects)
    }

    private static func isInside(_ url: URL, _ folder: URL) -> Bool {
        PathContainment.isContained(normalizedChild: FirstReadManifest.key(url), inNormalizedRoot: FirstReadManifest.key(folder))
    }

    /// Every set of apps a person can choose.
    private static let everyChoice: [Set<ClientKind>] = (0..<(1 << ClientKind.allCases.count)).map { bits in
        Set(ClientKind.allCases.enumerated().filter { bits & (1 << $0.offset) != 0 }.map(\.element))
    }

    // MARK: The declarations

    /// The four apps this build reads all declare what their scans read, and
    /// each declaration is its own app's.
    @Test func everyBundledAdapterDeclaresItsReads() throws {
        #expect(ClientAdapterRegistry.bundledAdapters.count == ClientKind.allCases.count)
        for adapter in ClientAdapterRegistry.bundledAdapters {
            let declaring = try #require(adapter as? any DeclaresLocalReads, "\(adapter.client)")
            let locations = declaring.readLocations(homeURL: Self.home)
            #expect(locations.client == adapter.client)
            #expect(locations == ClientReadLocations.declared(for: adapter.client, homeURL: Self.home))
            #expect(locations.commands.first == ClientReadLocations.versionArguments, "\(adapter.client) asks its version first")
        }
    }

    /// An app's column is its declaration: every place it lists is a file or
    /// folder the app declares, and every file and folder the app declares is
    /// in a place it lists.
    @Test(arguments: ClientKind.allCases)
    func eachAppsColumnIsItsDeclaration(client: ClientKind) throws {
        let declared = ClientReadLocations.declared(for: client, homeURL: Self.home)
        let urls = declared.configurationFiles + declared.skillRoots + declared.pluginRoots
        let app = try #require(Self.manifest([client]).apps.first)

        #expect(app.client == client)
        for place in app.places {
            #expect(urls.contains { FirstReadManifest.key($0) == FirstReadManifest.key(place.url) }, "\(place.id)")
        }
        for url in urls {
            #expect(app.places.contains { Self.isInside(url, $0.url) }, "\(url.path(percentEncoded: false))")
        }
        #expect(app.commands.map(\.arguments) == declared.commands)
        #expect(app.commands.allSatisfy { $0.executableName == ClientExecutableLocator.executableName(for: client) })
    }

    /// A scan runs its declared commands and nothing else, so the column's
    /// commands are the commands the read runs. An app that is not here still
    /// runs them, and each answers that there is nothing to run.
    @Test(arguments: ClientKind.allCases)
    func aScanRunsExactlyWhatItsAppDeclares(client: ClientKind) async throws {
        let world = try ClientHomeFixture(.juniper)
        defer { world.remove() }
        let runner = world.scriptedRunner()
        let adapter = try #require(world.registry.adapter(for: client))

        _ = await adapter.scan(homeURL: world.url, runner: runner)

        let launches = await runner.launches
        let declared = ClientReadLocations.declared(for: client, homeURL: world.url)
        #expect(launches.map(\.basename).allSatisfy { $0 == ClientExecutableLocator.executableName(for: client) })
        #expect(Set(launches.map(\.arguments)) == Set(declared.commands))
        #expect(launches.count == declared.commands.count, "each command runs once")
    }

    // MARK: Folding

    /// A folder inside another of the same app's folders is part of it, for
    /// every app: Codex's plugin cache is part of `~/.codex/plugins`, and
    /// Gemini CLI's extensions folder, walked for skills and listed for
    /// extensions, is one place.
    @Test(arguments: ClientKind.allCases)
    func noPlaceIsInsideAnotherOfTheSameApps(client: ClientKind) throws {
        let places = try #require(Self.manifest([client]).apps.first?.places)
        for place in places {
            let holders = places.filter { $0.id != place.id && Self.isInside(place.url, $0.url) }
            #expect(holders.isEmpty, "\(place.id) is inside \(holders.map(\.id))")
        }
        #expect(Set(places.map(\.id)).count == places.count, "each place once")
    }

    /// The folder two apps declare is listed under each, counted once, and
    /// is the one the declarations share — not one named here.
    @Test func aFolderTwoAppsDeclareIsSharedAndCountedOnce() throws {
        let codex = ClientReadLocations.declared(for: .codex, homeURL: Self.home)
        let gemini = ClientReadLocations.declared(for: .gemini, homeURL: Self.home)
        let both = Set((codex.skillRoots + codex.pluginRoots).map(FirstReadManifest.key))
            .intersection((gemini.skillRoots + gemini.pluginRoots).map(FirstReadManifest.key))
        #expect(both == [FirstReadManifest.key(Self.home.appending(path: ".agents/skills"))])

        let manifest = Self.manifest([.codex, .gemini])
        let shared = manifest.apps.flatMap(\.places).filter { both.contains(FirstReadManifest.key($0.url)) }
        #expect(shared.map(\.isLinked) == [false, true], "listed under each, linked under the later app")
        #expect(Set(shared.map(\.id)).count == 1, "one place, one identifier")
        let alone = [Self.manifest([.codex]).placeCount, Self.manifest([.gemini]).placeCount]
        #expect(manifest.placeCount == alone.reduce(0, +) - 1)
    }

    /// The counts, for every choice a person can make, with the project
    /// history on or off, are the places and
    /// commands the declarations hold, each once.
    @Test(arguments: [false, true])
    func theCountsAreTheDeclarationsCountedOnce(projects: Bool) {
        for chosen in Self.everyChoice {
            let manifest = Self.manifest(chosen, projects: projects)
            var urls: [URL] = []
            var commands: Set<String> = []
            for client in chosen {
                let declared = ClientReadLocations.declared(for: client, homeURL: Self.home)
                urls += declared.configurationFiles + declared.skillRoots + declared.pluginRoots
                commands.formUnion(declared.commands.map { "\(client.rawValue) \($0)" })
            }
            if projects, chosen.contains(.claude) { urls.append(ProjectDiscovery.sessionIndexURL(homeURL: Self.home)) }
            if chosen.contains(.claude) { urls.append(ClaudeAccountReader.managedSettingsURL) }
            let keys = Set(urls.map(FirstReadManifest.key))
            let outermost = keys.filter { key in
                !keys.contains { $0 != key && PathContainment.isContained(normalizedChild: key, inNormalizedRoot: $0) }
            }
            let signIn =
                (chosen.contains(.codex) ? 1 : 0) + (chosen.contains(.claude) ? 1 : 0)
                + (chosen.isDisjoint(with: [.codex, .claude]) ? 0 : 1)

            #expect(manifest.placeCount == outermost.count, "\(chosen.sorted { $0.rawValue < $1.rawValue })")
            #expect(manifest.commandCount == commands.count + signIn, "\(chosen.sorted { $0.rawValue < $1.rawValue })")
        }
    }

    /// Each line has one identifier wherever it is listed, so a tally of
    /// the lines a read has reported, by identifier, reaches exactly the
    /// counts the screen promised.
    @Test(arguments: [false, true])
    func countingLinesByIdentifierGivesTheCounts(projects: Bool) {
        for chosen in Self.everyChoice {
            let manifest = Self.manifest(chosen, projects: projects)
            let places = manifest.apps.flatMap(\.places) + manifest.shared + manifest.signIn.places
            let commands = manifest.apps.flatMap(\.commands) + manifest.signIn.commands
            #expect(Set(places.map(\.id)).count == manifest.placeCount, "\(chosen)")
            #expect(Set(commands.map(\.id)).count == manifest.commandCount, "\(chosen)")
        }
    }

    // MARK: Order

    /// The apps come in the app order whatever order they were chosen in, and
    /// each app's places in the order its scan reads them: its configuration,
    /// then its skills, then its plugins, the project history after them, and
    /// a place another app already lists last.
    @Test func theAppsAndTheirPlacesComeInTheirOrder() {
        for chosen in Self.everyChoice {
            let manifest = Self.manifest(chosen, projects: true)
            #expect(manifest.apps.map(\.client) == ClientKind.allCases.filter(chosen.contains))
            for app in manifest.apps {
                let roles = app.places.filter { !$0.isLinked }.map(\.role)
                let rank: [FirstReadManifest.Place.Role: Int] = [.configuration: 0, .skills: 1, .plugins: 2, .projectHistory: 3]
                #expect(roles.map { rank[$0] ?? 9 } == roles.map { rank[$0] ?? 9 }.sorted(), "\(app.client)")
                if let firstLinked = app.places.firstIndex(where: \.isLinked) {
                    #expect(app.places[firstLinked...].allSatisfy { $0.isLinked }, "\(app.client)")
                }
            }
        }
    }

    // MARK: Signing in

    /// The sign-in strip runs only for an app with an account to read. No
    /// choice without Codex or Claude Code starts anything, the login shell
    /// included.
    @Test func noSignInReadRunsWithoutAnAppThatHasAnAccount() {
        for chosen in Self.everyChoice {
            let signIn = Self.manifest(chosen).signIn
            if chosen.isDisjoint(with: [.codex, .claude]) {
                #expect(signIn.commands.isEmpty && signIn.places.isEmpty, "\(chosen)")
            } else {
                #expect(signIn.commands.last?.display == "zsh -l -i", "\(chosen)")
                #expect(signIn.places.isEmpty != chosen.contains(.claude), "\(chosen)")
            }
        }
    }

    /// The strip's lines are the sign-in readers' own: Codex's app server as
    /// its transport starts it, Claude Code's status as its reader asks it,
    /// its managed settings where the reader reads them, and the login shell
    /// the override check starts.
    @Test func theSignInLinesAreTheReadersOwn() throws {
        let signIn = Self.manifest([.codex, .claude]).signIn
        let commands = Dictionary(uniqueKeysWithValues: signIn.commands.map { ($0.display, $0) })

        let codex = try #require(commands["codex app-server"])
        #expect(codex.executableName == ClientExecutableLocator.executableName(for: .codex))
        #expect(codex.arguments == CodexAppServerProcessTransport.arguments)
        let claude = try #require(commands["claude auth status --json"])
        #expect(claude.executableName == ClientExecutableLocator.executableName(for: .claude))
        #expect(claude.arguments == ClaudeAccountCommands.authStatus)
        let shell = try #require(commands["zsh -l -i"])
        #expect(shell.executableName == AccountShellEnvironmentProbe.shell.lastPathComponent)
        #expect(shell.arguments == AccountShellEnvironmentProbe.arguments)
        #expect(signIn.places.map(\.url) == [ClaudeAccountReader.managedSettingsURL])
    }

    /// Project history uses Claude Code's declared session index.
    @Test func theProjectHistoryIsWhereItIsRead() throws {
        let manifest = Self.manifest([.claude], projects: true)
        let history = try #require(manifest.apps.first?.places.first { $0.role == .projectHistory })
        #expect(history.url == ProjectDiscovery.sessionIndexURL(homeURL: Self.home))
        #expect(manifest.shared.isEmpty)
    }

    // MARK: Identifying a read

    /// A command is named by the tool's own name wherever the tool was found,
    /// and one the manifest does not list is named as it would have been, a
    /// name no line has.
    @Test func aCommandIsNamedByItsToolWhereverTheToolIs() {
        let manifest = Self.manifest([.codex, .claude])
        #expect(manifest.commandID(executable: "/opt/homebrew/bin/codex", arguments: ["--version"], for: .codex) == "Codex:codex --version")
        #expect(
            manifest.commandID(executable: "codex", arguments: ["mcp", "list", "--json"], for: .codex) == "Codex:codex mcp list --json")
        let unlisted = manifest.commandID(executable: "/opt/homebrew/bin/codex", arguments: ["login"], for: .codex)
        #expect(unlisted == "Codex:codex login")
        #expect(!manifest.apps.flatMap(\.commands).map(\.id).contains(unlisted))
        // Codex's command run for Claude Code is not Claude Code's line.
        #expect(
            !manifest.apps.flatMap(\.commands).map(\.id).contains(
                manifest.commandID(executable: "codex", arguments: ["--version"], for: .claude)))
    }

    /// A place reached through a link is still that place: a `~/.claude`
    /// that is a link into a dotfiles folder is read where the link leads.
    /// A link from a listed folder to somewhere else is not listed.
    @Test func aPlaceReachedThroughALinkIsStillThatPlace() throws {
        let home = try FixtureHome("manifest-links")
        defer { home.remove() }
        try home.plantSkill("dotfiles/claude/skills/notes", name: "notes", description: "Notes.")
        try home.plantSkill("Documents/drafts", name: "drafts", description: "Drafts.")
        try FileManager.default.createSymbolicLink(
            at: home.appending(".claude"), withDestinationURL: home.appending("dotfiles/claude", directoryHint: .isDirectory))
        try FileManager.default.createSymbolicLink(
            at: home.appending("dotfiles/claude/skills/drafts"),
            withDestinationURL: home.appending("Documents/drafts", directoryHint: .isDirectory))
        let manifest = FirstReadManifest.build(chosen: [.claude], homeURL: home.url, includeProjectHistory: false)

        let throughLink = manifest.place(containing: home.appending("dotfiles/claude/skills/notes/SKILL.md"), for: .claude)
        #expect(throughLink?.id == "Claude Code:skills:~/.claude/skills")
        let elsewhere = home.appending("Documents/drafts/SKILL.md")
        #expect(manifest.place(containing: elsewhere, for: .claude) == nil)
    }
}
