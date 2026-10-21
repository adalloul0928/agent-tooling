import Foundation

/// Lists the selected clients' files, commands and sign-in reads before execution.
/// Built from scanner declarations and checked against traces. Shared or nested
/// roots count once.
public struct FirstReadManifest: Sendable, Equatable {
    /// A file or folder the read opens.
    public struct Place: Sendable, Hashable, Identifiable {
        /// What the read looks for there.
        public enum Role: String, CaseIterable, Sendable {
            case configuration
            case skills
            case plugins
            /// Claude Code's project history: only its folder names are read.
            case projectHistory
            case signIn
        }

        /// `<scope>:<role>:<display>`, where the scope is the app's name,
        /// `shared` for a place read for more than one app, or `signIn`.
        public let id: String
        public let url: URL
        /// The path as a person reads it, the home folder shown as `~`.
        public let display: String
        public let role: Role
        /// The other chosen apps this same place is read for, in the app
        /// order; for one of the manifest's `shared` places, every chosen app.
        public let sharedWith: [ClientKind]
        /// True when an earlier app in this manifest already lists the place:
        /// it is drawn with the link glyph, after the app's own places, and
        /// counted once.
        public let isLinked: Bool
    }

    /// A command the read runs.
    public struct Command: Sendable, Hashable, Identifiable {
        /// `<scope>:<display>`, the scope as for a place.
        public let id: String
        /// The tool's own name, which is what a trace compares, because the
        /// folder it was found in differs between Macs: `codex`, `zsh`.
        public let executableName: String
        public let arguments: [String]
        /// The command as a person reads it: `codex plugin list --json`.
        public let display: String
    }

    /// One chosen app's own read.
    public struct App: Sendable, Equatable, Identifiable {
        public var id: ClientKind { client }
        public let client: ClientKind
        /// Its own places in the order it reads them, then the linked ones.
        public let places: [Place]
        public let commands: [Command]
    }

    /// How the chosen apps sign in: the reads the sign-in check makes that no
    /// app's own list already holds. Empty when no chosen app has an account
    /// to read, and then no login shell runs either.
    public struct SignIn: Sendable, Equatable {
        public let places: [Place]
        public let commands: [Command]
    }

    /// The chosen apps, in the app order.
    public let apps: [App]
    public let signIn: SignIn
    /// Additional places read jointly by the chosen apps.
    public let shared: [Place]

    /// Every place, each once: one read for two apps counts once, and one
    /// inside another listed place is part of it.
    public var placeCount: Int {
        let urls = apps.flatMap { $0.places.map(\.url) } + signIn.places.map(\.url) + shared.map(\.url)
        return Self.outermost(urls.map(Self.key)).count
    }

    /// Every command, each once by what it reads as.
    public var commandCount: Int {
        Set(apps.flatMap { $0.commands.map(\.display) } + signIn.commands.map(\.display)).count
    }

    /// The manifest for the apps a person chose. `includeProjectHistory` is
    /// the setup switch that also finds projects from Claude Code's history;
    /// it adds `~/.claude/projects` only when Claude Code is chosen.
    public static func build(chosen: Set<ClientKind>, homeURL: URL, includeProjectHistory: Bool) -> FirstReadManifest {
        let home = homeURL.standardizedFileURL
        let order = ClientKind.allCases.filter(chosen.contains)
        let declared = Dictionary(uniqueKeysWithValues: order.map { ($0, ClientReadLocations.declared(for: $0, homeURL: home)) })
        var own: [ClientKind: [Entry]] = [:]
        for client in order {
            guard let locations = declared[client] else { continue }
            var entries =
                locations.configurationFiles.map { Entry(url: $0, role: .configuration) }
                + locations.skillRoots.map { Entry(url: $0, role: .skills) }
                + locations.pluginRoots.map { Entry(url: $0, role: .plugins) }
            if client == .claude, includeProjectHistory {
                entries.append(Entry(url: ProjectDiscovery.sessionIndexURL(homeURL: home), role: .projectHistory))
            }
            own[client] = collapsed(entries)
        }

        // Who reads each place, and the role its first reader reads it for,
        // so one place has one identifier under every app that lists it.
        var readers: [String: [ClientKind]] = [:]
        var firstRole: [String: Place.Role] = [:]
        for client in order {
            for entry in own[client] ?? [] {
                let path = key(entry.url)
                readers[path, default: []].append(client)
                if firstRole[path] == nil { firstRole[path] = entry.role }
            }
        }

        let apps = order.map { client in
            var first: [Place] = []
            var linked: [Place] = []
            for entry in own[client] ?? [] {
                let path = key(entry.url)
                let all = readers[path] ?? [client]
                let item = place(
                    url: entry.url, role: firstRole[path] ?? entry.role, scope: all.count > 1 ? "shared" : client.rawValue,
                    sharedWith: all.filter { $0 != client }, isLinked: all.first != client, home: home)
                if item.isLinked { linked.append(item) } else { first.append(item) }
            }
            let name = ClientExecutableLocator.executableName(for: client)
            let commands = (declared[client]?.commands ?? []).map {
                command(scope: client.rawValue, executableName: name, arguments: $0, display: display(name, $0))
            }
            return App(client: client, places: first + linked, commands: commands)
        }

        return FirstReadManifest(apps: apps, signIn: signIn(for: Set(order), home: home), shared: [])
    }

    /// Finds an own, shared or sign-in place containing `url`. `lists(_:)` also
    /// checks other clients' places. Compare lexical paths first, then resolve
    /// symlinks on both sides: a linked root remains valid, but links escaping all
    /// declared roots are unlisted.
    func place(containing url: URL, for client: ClientKind) -> Place? {
        let own = apps.first { $0.client == client }?.places ?? []
        return Self.firstPlace(containing: url, among: own + shared + signIn.places)
    }

    /// Whether any line of the manifest holds `url`: a place of any chosen
    /// app, a shared place or a sign-in place, compared as
    /// `place(containing:for:)` compares. False is what "not listed before"
    /// means. A link from one app's folder into a folder another chosen app
    /// reads, such as a `~/.claude/skills/notes` that leads into
    /// `~/.agents/skills`, reads a place the person was shown.
    func lists(_ url: URL) -> Bool {
        Self.firstPlace(containing: url, among: apps.flatMap(\.places) + shared + signIn.places) != nil
    }

    /// The first of `places` that holds `url` as written, or else the first
    /// that holds it with links followed on both sides.
    private static func firstPlace(containing url: URL, among places: [Place]) -> Place? {
        let target = key(url)
        if let place = places.first(where: { PathContainment.isContained(normalizedChild: target, inNormalizedRoot: key($0.url)) }) {
            return place
        }
        let resolved = key(url.resolvingSymlinksInPath())
        return places.first {
            PathContainment.isContained(normalizedChild: resolved, inNormalizedRoot: key($0.url.resolvingSymlinksInPath()))
        }
    }

    /// The identifier of the command `client`'s read runs as `executable`
    /// with `arguments`, matched by the tool's own name, because the folder
    /// it was found in differs between Macs. A command this manifest does not
    /// list gets the identifier it would have had, which names no line.
    func commandID(executable: String, arguments: [String], for client: ClientKind) -> Command.ID {
        let name = URL(filePath: executable).lastPathComponent
        let listed = apps.first { $0.client == client }?.commands.first { $0.executableName == name && $0.arguments == arguments }
        return listed?.id ?? "\(client.rawValue):\(Self.display(name, arguments))"
    }

    // MARK: - The sign-in reads

    /// The sign-in check's own reads, for the chosen apps that have an
    /// account: Codex's app server, Claude Code's status and its managed
    /// settings, and the login shell asked which overriding variables it
    /// exports. The check also runs `claude --version` and reads
    /// `~/.claude/settings.json`; Claude Code's own list already holds both.
    private static func signIn(for chosen: Set<ClientKind>, home: URL) -> SignIn {
        var places: [Place] = []
        var commands: [Command] = []
        if chosen.contains(.codex) {
            let codex = ClientExecutableLocator.executableName(for: .codex)
            let arguments = CodexAppServerProcessTransport.arguments
            commands.append(
                command(scope: "signIn", executableName: codex, arguments: arguments, display: display(codex, arguments)))
        }
        if chosen.contains(.claude) {
            let claude = ClientExecutableLocator.executableName(for: .claude)
            let arguments = ClaudeAccountCommands.authStatus
            commands.append(
                command(scope: "signIn", executableName: claude, arguments: arguments, display: display(claude, arguments)))
            places.append(
                place(
                    url: ClaudeAccountReader.managedSettingsURL, role: .signIn, scope: "signIn", sharedWith: [], isLinked: false,
                    home: home))
        }
        if chosen.contains(.codex) || chosen.contains(.claude) {
            // The script it runs is named by what it does, on the strip and in
            // its caption, rather than shown: `zsh -l -i`.
            let shell = AccountShellEnvironmentProbe.shell.lastPathComponent
            let arguments = AccountShellEnvironmentProbe.arguments
            commands.append(
                command(
                    scope: "signIn", executableName: shell, arguments: arguments,
                    display: display(shell, Array(arguments.prefix { $0 != "-c" }))))
        }
        return SignIn(places: places, commands: commands)
    }

    // MARK: - Building

    private struct Entry {
        let url: URL
        let role: Place.Role
    }

    private static func place(
        url: URL, role: Place.Role, scope: String, sharedWith: [ClientKind], isLinked: Bool, home: URL
    ) -> Place {
        let display = PathDisplay.abbreviatingHome(url.path(percentEncoded: false), home: home)
        return Place(
            id: "\(scope):\(role.rawValue):\(display)", url: url, display: display, role: role, sharedWith: sharedWith,
            isLinked: isLinked)
    }

    private static func command(scope: String, executableName: String, arguments: [String], display: String) -> Command {
        Command(id: "\(scope):\(display)", executableName: executableName, arguments: arguments, display: display)
    }

    /// A command as a person reads it: the tool's name, then its arguments.
    private static func display(_ executableName: String, _ arguments: [String]) -> String {
        ([executableName] + arguments).joined(separator: " ")
    }

    /// One app's entries with repeats and nested ones folded into the place
    /// that holds them, in the order first declared.
    private static func collapsed(_ entries: [Entry]) -> [Entry] {
        var kept: [Entry] = []
        for entry in entries {
            let path = key(entry.url)
            if kept.contains(where: { PathContainment.isContained(normalizedChild: path, inNormalizedRoot: key($0.url)) }) { continue }
            if let index = kept.firstIndex(where: { PathContainment.isContained(normalizedChild: key($0.url), inNormalizedRoot: path) }) {
                kept.removeAll { PathContainment.isContained(normalizedChild: key($0.url), inNormalizedRoot: path) }
                kept.insert(entry, at: min(index, kept.count))
            } else {
                kept.append(entry)
            }
        }
        return kept
    }

    /// Paths that are not inside another of `paths`, each once.
    private static func outermost(_ paths: [String]) -> Set<String> {
        let unique = Set(paths)
        return unique.filter { path in
            !unique.contains { other in
                other != path && PathContainment.isContained(normalizedChild: path, inNormalizedRoot: other)
            }
        }
    }

    /// A path compared as written, without a trailing separator and with the
    /// `/private` the temporary folder resolves through folded away, so a
    /// read recorded either way finds its place.
    static func key(_ url: URL) -> String {
        let path = PathContainment.lexicalPath(url)
        return path.hasPrefix("/private/") ? String(path.dropFirst("/private".count)) : path
    }
}
