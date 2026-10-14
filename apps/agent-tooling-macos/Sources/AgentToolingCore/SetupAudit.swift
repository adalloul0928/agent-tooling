import CryptoKit
import Foundation

// MARK: - Findings

/// What a deterministic look at one Mac's AI tooling turned up. Each finding
/// is a fact a script can prove, with the evidence attached, never an opinion.
/// Opinions come later, from the model pass, and cite these by id.
public struct SetupFinding: Identifiable, Codable, Hashable, Sendable {
    public enum Kind: String, Codable, CaseIterable, Sendable {
        /// A skill folder entry that points at nothing.
        case brokenSkillLink
        /// A plugin the client lists whose install folder is not on disk.
        case missingPluginInstall
        /// One client can reach the same skill by two paths.
        case duplicateSkillInClient
        /// A skill found in an app's folder that this library does not hold.
        case unmanagedSkill
        /// An MCP server whose command is not on disk or on the PATH.
        case unreachableMCPCommand
        /// Older cached versions of a plugin beside the one in use.
        case stalePluginCache
        /// The client's own tool could not be run.
        case toolUnavailable
        /// A client this Mac manages that has never been checked.
        case neverChecked
        /// A skill folder with no SKILL.md in it.
        case skillWithoutDefinition
        /// The same MCP server configured in more than one client by hand,
        /// each copy separately.
        case mcpServerRepeatedAcrossClients
        /// One client gets a server by one name from more than one place:
        /// its own configuration and plugins, or several plugins.
        case mcpServerDefinedSeveralTimes
        /// Two plugins in one client carry many of the same skills.
        case pluginSkillsOverlap
    }

    public enum Severity: String, Codable, Comparable, Sendable {
        case info, low, medium, high
        private var rank: Int { ["info": 0, "low": 1, "medium": 2, "high": 3][rawValue] ?? 0 }
        public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rank < rhs.rank }
    }

    /// Stable across runs for the same fact: a SHA-256 of kind, client, and
    /// the subject, so a finding somebody dismissed stays dismissed.
    public let id: String
    public let kind: Kind
    public let severity: Severity
    /// The client the fact is about, or nil for a fact about the Mac.
    public let client: ClientKind?
    /// The thing the fact is about: a skill id, plugin id, server name.
    public let subject: String
    public let title: String
    public let detail: String
    /// Paths, ids, or values that prove the finding. Redacted of /Users prefixes.
    public let evidence: [String]
    /// The actions the app can take for this finding, in order of preference.
    public let actions: [SetupAction]

    public init(
        kind: Kind, severity: Severity, client: ClientKind?, subject: String, title: String, detail: String,
        evidence: [String], actions: [SetupAction]
    ) {
        self.id = Self.identifier(kind: kind, client: client, subject: subject)
        self.kind = kind
        self.severity = severity
        self.client = client
        self.subject = subject
        self.title = title
        self.detail = detail
        self.evidence = evidence
        self.actions = actions
    }

    static func identifier(kind: Kind, client: ClientKind?, subject: String) -> String {
        let text = "\(kind.rawValue)|\(client?.rawValue ?? "-")|\(subject)"
        let digest = SHA256.hash(data: Data(text.utf8))
        return digest.prefix(8).map { String(format: "%02x", $0) }.joined()
    }
}

/// Something the app can do about a finding. Every case maps to an existing,
/// reviewed path in the app: nothing here is a free-form shell command.
public enum SetupAction: Codable, Hashable, Sendable {
    /// Bring an unmanaged skill into the library as yours, from this path.
    case adoptSkill(path: String, client: ClientKind)
    /// Remove one client's copy of a skill (a folder or a symlink), with a
    /// backup first. Never the library's copy.
    case removeSkillCopy(path: String, client: ClientKind)
    /// Remove a dangling symlink; there is nothing to back up.
    case removeBrokenLink(path: String, client: ClientKind)
    /// Re-run the client's own install for a plugin whose folder is gone.
    case reinstallPlugin(pluginID: String, client: ClientKind)
    /// Remove older cached versions of a plugin.
    case pruneStalePluginCache(paths: [String], client: ClientKind)
    /// Open the client's MCP configuration so the person can fix the command.
    case inspectMCPServer(name: String, client: ClientKind)
    /// Turn an MCP server off in a client without removing its configuration.
    case disableMCPServer(name: String, client: ClientKind)
    /// Run "Find missing tools" for the client.
    case locateTool(client: ClientKind)
    /// Run a check of this client.
    case checkClient(client: ClientKind)
    /// Put a hand-configured MCP server into the library once and place it
    /// from there.
    case manageMCPServer(name: String, clients: [ClientKind])

    public var title: String {
        switch self {
        case .adoptSkill: "Add to library"
        case .removeSkillCopy: "Remove this copy"
        case .removeBrokenLink: "Remove the broken link"
        case .reinstallPlugin: "Reinstall the plugin"
        case .pruneStalePluginCache(let paths, _): paths.count == 1 ? "Remove the old version" : "Remove \(paths.count) old versions"
        case .inspectMCPServer: "Open its configuration"
        case .disableMCPServer: "Turn it off"
        case .locateTool: "Find the tool"
        case .checkClient: "Check this app"
        case .manageMCPServer: "Manage from the library"
        }
    }

    /// Whether taking the action changes a client's files. A read or an open
    /// does not; anything else goes through a reviewed plan.
    public var changesFiles: Bool {
        switch self {
        case .inspectMCPServer, .locateTool, .checkClient: false
        default: true
        }
    }
}

/// One deterministic pass over the Mac.
public struct SetupAuditReport: Codable, Hashable, Sendable {
    public var generatedAt: Date
    public var clients: [ClientKind]
    public var findings: [SetupFinding]
    /// How many skills, plugins, and servers each client was seen to hold, so
    /// the report can say "68 skills, 3 problems" rather than only the problems.
    public var counts: [ClientKind: HeldCounts]

    public struct HeldCounts: Codable, Hashable, Sendable {
        public var skills: Int
        public var plugins: Int
        public var mcpServers: Int
        public init(skills: Int, plugins: Int, mcpServers: Int) {
            self.skills = skills
            self.plugins = plugins
            self.mcpServers = mcpServers
        }
    }

    public init(generatedAt: Date = .now, clients: [ClientKind], findings: [SetupFinding], counts: [ClientKind: HeldCounts]) {
        self.generatedAt = generatedAt
        self.clients = clients
        self.findings = findings.sorted { lhs, rhs in
            if lhs.severity != rhs.severity { return lhs.severity > rhs.severity }
            if lhs.kind != rhs.kind { return lhs.kind.rawValue < rhs.kind.rawValue }
            return lhs.subject < rhs.subject
        }
        self.counts = counts
    }

    public func findings(for client: ClientKind) -> [SetupFinding] { findings.filter { $0.client == client } }
    public var highestSeverity: SetupFinding.Severity? { findings.map(\.severity).max() }
}

// MARK: - The auditor

/// Turns what the device check saw, plus a bounded look at the folders it
/// named, into findings. Reads only. Runs the same way every time.
public struct SetupAuditor: Sendable {
    public struct LibraryFacts: Sendable {
        /// Declared names of skills the library holds with an authority other
        /// than tracked-only: the ones this app manages.
        public var managedSkillNames: Set<String>
        public init(managedSkillNames: Set<String>) { self.managedSkillNames = managedSkillNames }
    }

    private let homeURL: URL
    private var fileManager: FileManager { .default }
    /// Where commands are looked for when a server names one bare.
    private let searchPath: [URL]

    public init(homeURL: URL, searchPath: [URL]? = nil) {
        self.homeURL = homeURL
        self.searchPath = searchPath ?? Self.defaultSearchPath(homeURL: homeURL)
    }

    /// Where a bare command is looked for when the login shell has not been
    /// asked: the usual places, plus the version managers' active shims.
    static func defaultSearchPath(homeURL: URL) -> [URL] {
        let fixed = ["/usr/local/bin", "/opt/homebrew/bin", "/usr/bin", "/bin"].map { URL(filePath: $0, directoryHint: .isDirectory) }
        let home = [
            ".toolbox/bin", ".local/bin", ".aim/mcp-servers", ".cargo/bin", ".npm-global/bin", "bin",
            ".local/share/mise/shims", ".asdf/shims", ".volta/bin", ".bun/bin",
        ].map { homeURL.appending(path: $0, directoryHint: .isDirectory) }
        return home + fixed
    }

    /// The search path a real audit should use: the login shell's, with the
    /// defaults behind it. Asked once per audit, never once per command.
    public static func searchPath(homeURL: URL, runner: any CommandRunning) async -> [URL] {
        let shell = await SmartToolFinder.loginShellSearchPath(runner: runner)
        var seen = Set<String>()
        return (shell + defaultSearchPath(homeURL: homeURL)).filter { seen.insert($0.path(percentEncoded: false)).inserted }
    }

    public func audit(observations: [TargetObservation], managed clients: [ClientKind], library: LibraryFacts) -> SetupAuditReport {
        var findings: [SetupFinding] = []
        var counts: [ClientKind: SetupAuditReport.HeldCounts] = [:]
        var mcpOwners: [String: [ClientKind]] = [:]

        for client in clients {
            let mine = observations.filter { $0.surface.client == client }
            guard let observation = mine.first else {
                findings.append(
                    SetupFinding(
                        kind: .neverChecked, severity: .low, client: client, subject: client.rawValue,
                        title: "\(client.rawValue) has not been checked",
                        detail: "This Mac manages \(client.rawValue) but has never read what it holds, so nothing about it can be confirmed.",
                        evidence: [], actions: [.checkClient(client: client)]))
                continue
            }
            counts[client] = .init(
                skills: observation.discoveredSkills.count, plugins: observation.discoveredPlugins.count,
                mcpServers: observation.discoveredMCPServers.count)
            if !observation.commandAvailable {
                findings.append(
                    SetupFinding(
                        kind: .toolUnavailable, severity: .medium, client: client, subject: client.rawValue,
                        title: "\(client.rawValue)'s command could not be run",
                        detail: "Its configuration was read from disk, but without the tool the app cannot confirm its version or ask it what it has installed.",
                        evidence: observation.notes.filter { $0.contains("not available") }.map(redact),
                        actions: [.locateTool(client: client), .checkClient(client: client)]))
            }
            findings += skillFindings(client: client, observation: observation, library: library)
            findings += pluginFindings(client: client, observation: observation)
            findings += mcpFindings(client: client, observation: observation)
            for server in observation.discoveredMCPServers
            where observation.mcpMetadata[server]?.allSources.contains(where: { $0.hasSuffix("configuration") }) == true {
                mcpOwners[server, default: []].append(client)
            }
        }

        // A server each client was given by hand is one thing configured
        // several times; the library can hold it once.
        for (server, owners) in mcpOwners where owners.count > 1 {
            findings.append(
                SetupFinding(
                    kind: .mcpServerRepeatedAcrossClients, severity: .info, client: nil, subject: server,
                    title: "\(server) is configured separately in \(owners.count) apps",
                    detail: "Each app has its own copy of this server's configuration. Managed from the library it would be one definition placed in each.",
                    evidence: owners.map(\.rawValue), actions: [.manageMCPServer(name: server, clients: owners.sorted { $0.rawValue < $1.rawValue })]))
        }
        return SetupAuditReport(clients: clients, findings: findings, counts: counts)
    }

    // MARK: Skills

    private func skillFindings(client: ClientKind, observation: TargetObservation, library: LibraryFacts) -> [SetupFinding] {
        var findings: [SetupFinding] = []
        // Where a client keeps standalone skills; the check names each folder it
        // saw, and this pass looks at the entries it could not turn into skills.
        for root in Self.standaloneSkillRoots(client: client, homeURL: homeURL) {
            guard let entries = try? fileManager.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isSymbolicLinkKey, .isDirectoryKey]) else { continue }
            for entry in entries.prefix(BoundedFileAccess.maximumDirectoryEntries) where !entry.lastPathComponent.hasPrefix(".") {
                let values = try? entry.resourceValues(forKeys: [.isSymbolicLinkKey, .isDirectoryKey])
                if values?.isSymbolicLink == true {
                    let target = (try? fileManager.destinationOfSymbolicLink(atPath: entry.path(percentEncoded: false))) ?? ""
                    let resolved = target.hasPrefix("/") ? URL(filePath: target) : root.appending(path: target)
                    if !fileManager.fileExists(atPath: resolved.path(percentEncoded: false)) {
                        findings.append(
                            SetupFinding(
                                kind: .brokenSkillLink, severity: .medium, client: client, subject: entry.lastPathComponent,
                                title: "\(entry.lastPathComponent) points at nothing",
                                detail: "The entry in \(client.rawValue)'s skills folder is a link to a folder that is no longer there. \(client.rawValue) skips it.",
                                evidence: [redact(entry.path(percentEncoded: false)), "→ \(redact(target))"],
                                actions: [.removeBrokenLink(path: normalized(entry.path(percentEncoded: false)), client: client)]))
                        continue
                    }
                }
                let isDirectory = (try? entry.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
                if isDirectory, !BoundedFileAccess.isRegularFile(entry.appending(path: "SKILL.md")) {
                    findings.append(
                        SetupFinding(
                            kind: .skillWithoutDefinition, severity: .low, client: client, subject: entry.lastPathComponent,
                            title: "\(entry.lastPathComponent) has no SKILL.md",
                            detail: "A folder in \(client.rawValue)'s skills folder with no definition in it. \(client.rawValue) does not load it.",
                            evidence: [redact(entry.path(percentEncoded: false))],
                            actions: [.removeSkillCopy(path: normalized(entry.path(percentEncoded: false)), client: client)]))
                }
            }
        }

        // One skill name reachable by more than one path in this client.
        var byName: [String: [ObservedSkillMetadata]] = [:]
        for (id, metadata) in observation.skillMetadata {
            let bare = id.split(separator: ":").last.map(String.init) ?? id
            byName[bare, default: []].append(metadata)
        }
        for (name, copies) in byName where copies.count > 1 {
            let paths = copies.map(\.path)
            let distinct = Set(paths.map { resolvedPath($0) })
            let plugins = copies.compactMap(\.providerPluginID).sorted()
            // Only a loose copy is offered for removal. A plugin's copy is the
            // plugin's, and one another tool placed comes back on its next sync.
            let removable = copies.filter { $0.providerPluginID == nil && $0.externalManager == nil }.map(\.path).sorted()
            let placed = copies.compactMap(\.externalManager).map(\.label)
            let digests = copies.map(\.definitionDigest)
            let compared = !digests.contains(nil)
            let identical = compared && Set(digests).count == 1
            let comparison = identical
                ? " The copies are identical apart from their packaging stamp."
                : Set(digests.compactMap { $0 }).count > 1 ? " The copies differ, so what the skill does depends on which one loads." : ""
            let detail: String
            if distinct.count == 1 {
                detail = "Two entries point at the same files. Harmless, but one is enough."
            } else if copies.allSatisfy({ $0.providerPluginID != nil }) {
                detail = "Each of \(plugins.joined(separator: ", ")) brings its own copy, and \(client.rawValue) lists every one." + comparison
            } else {
                detail = "Two different copies answer to the same name" + (plugins.isEmpty ? "." : ", one of them inside \(plugins.joined(separator: ", ")).")
                    + " Which one \(client.rawValue) uses depends on its load order." + comparison
                    + (placed.isEmpty ? "" : " The loose copy was placed by \(placed.joined(separator: ", ")), which keeps it in step, so it is left alone.")
            }
            findings.append(
                SetupFinding(
                    kind: .duplicateSkillInClient, severity: distinct.count > 1 && !identical ? .medium : .low, client: client, subject: name,
                    title: "\(client.rawValue) can reach \(name) \(paths.count) ways",
                    detail: detail,
                    evidence: paths.sorted().map(redact),
                    actions: removable.map { .removeSkillCopy(path: normalized($0), client: client) }))
        }

        // Standalone skills the library does not manage. One another tool
        // placed and keeps in step is managed, just not by this app.
        for (id, metadata) in observation.skillMetadata.sorted(by: { $0.key < $1.key })
        where metadata.providerPluginID == nil && metadata.externalManager == nil && !library.managedSkillNames.contains(id) {
            findings.append(
                SetupFinding(
                    kind: .unmanagedSkill, severity: .info, client: client, subject: id,
                    title: "\(id) is not managed by this app",
                    detail: "\(client.rawValue) has this skill, but the library holds no copy, so it cannot be placed in another app, edited here, or checked for updates.",
                    evidence: [redact(metadata.path)],
                    actions: [.adoptSkill(path: normalized(metadata.path), client: client), .removeSkillCopy(path: normalized(metadata.path), client: client)]))
        }
        return findings
    }

    static func standaloneSkillRoots(client: ClientKind, homeURL: URL) -> [URL] {
        switch client {
        case .claude: [homeURL.appending(path: ".claude/skills", directoryHint: .isDirectory)]
        case .codex: [homeURL.appending(path: ".codex/skills", directoryHint: .isDirectory), homeURL.appending(path: ".agents/skills", directoryHint: .isDirectory)]
        case .gemini: [homeURL.appending(path: ".gemini/skills", directoryHint: .isDirectory)]
        case .kiro: [homeURL.appending(path: ".kiro/skills", directoryHint: .isDirectory)]
        }
    }

    // MARK: Plugins

    private func pluginFindings(client: ClientKind, observation: TargetObservation) -> [SetupFinding] {
        var findings: [SetupFinding] = []
        let marketplaceDirectories = directoryMarketplaces(client: client, configurationPaths: observation.configurationPaths)
        for (id, plugin) in observation.pluginMetadata.sorted(by: { $0.key < $1.key }) {
            guard plugin.source.hasPrefix("/") else { continue }
            let install = URL(filePath: plugin.source)
            if !fileManager.fileExists(atPath: install.path(percentEncoded: false)) {
                // A plugin from a directory marketplace loads from that
                // directory, whatever the install record's cache path says.
                // The record is stale; the plugin is not missing.
                let name = id.split(separator: "@").first.map(String.init) ?? id
                let marketplace = id.split(separator: "@").dropFirst().first.map(String.init)
                if let marketplace, let directory = marketplaceDirectories[marketplace],
                    fileManager.fileExists(atPath: directory.appending(path: name).appending(path: ".claude-plugin/plugin.json").path(percentEncoded: false))
                {
                    continue
                }
                findings.append(
                    SetupFinding(
                        kind: .missingPluginInstall, severity: .high, client: client, subject: id,
                        title: "\(plugin.name) is listed but its files are gone",
                        detail: "\(client.rawValue) records this plugin as installed at a folder that does not exist, so its skills and servers do not load.",
                        evidence: [redact(plugin.source)], actions: [.reinstallPlugin(pluginID: id, client: client)]))
            }
            // Sibling version folders beside the one in use. Only where the
            // install path is a version folder inside a plugin cache
            // (`…/cache/<marketplace>/<plugin>/<version>`): a plugin kept flat
            // by name, as AIM keeps Codex's, has siblings that are other
            // plugins, not old versions.
            let versionsRoot = install.deletingLastPathComponent()
            let isVersionedCache = versionsRoot.deletingLastPathComponent().deletingLastPathComponent().lastPathComponent == "cache"
                && Self.looksLikeVersion(install.lastPathComponent)
            if isVersionedCache, let siblings = try? fileManager.contentsOfDirectory(at: versionsRoot, includingPropertiesForKeys: [.isDirectoryKey]) {
                let stale = siblings.filter {
                    $0.lastPathComponent != install.lastPathComponent && !$0.lastPathComponent.hasPrefix(".")
                        && ((try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false)
                }
                if !stale.isEmpty {
                    findings.append(
                        SetupFinding(
                            kind: .stalePluginCache, severity: .low, client: client, subject: id,
                            title: "\(plugin.name) keeps \(stale.count) old version\(stale.count == 1 ? "" : "s") on disk",
                            detail: "Only \(install.lastPathComponent) is in use. The others take space and can confuse a search for a skill's file.",
                            evidence: stale.map { redact($0.path(percentEncoded: false)) }.sorted(),
                            actions: [.pruneStalePluginCache(paths: stale.map { normalized($0.path(percentEncoded: false)) }.sorted(), client: client)]))
                }
            }
        }
        findings += pluginOverlapFindings(client: client, observation: observation)
        return findings
    }

    /// Two plugins whose skills are largely the same ones: at least three
    /// shared, and at least half of the smaller plugin. The client lists each
    /// plugin's copy, so every shared skill appears twice. Removing a plugin
    /// takes its other skills and servers with it, so nothing is offered.
    private func pluginOverlapFindings(client: ClientKind, observation: TargetObservation) -> [SetupFinding] {
        let skills = observation.pluginMetadata.compactMapValues { plugin -> Set<String>? in
            let names = Set(plugin.skillIDs.map { $0.split(separator: ":").last.map(String.init) ?? $0 })
            return plugin.enabled && !names.isEmpty ? names : nil
        }
        let ids = skills.keys.sorted()
        var findings: [SetupFinding] = []
        for (index, left) in ids.enumerated() {
            for right in ids[(index + 1)...] {
                guard let a = skills[left], let b = skills[right] else { continue }
                let shared = a.intersection(b)
                let smaller = min(a.count, b.count)
                guard shared.count >= 3, shared.count * 2 >= smaller else { continue }
                // The smaller plugin is named first: it is the one whose skills
                // are all, or mostly, somewhere else already.
                let (small, large) = a.count <= b.count ? (left, right) : (right, left)
                let smallName = observation.pluginMetadata[small]?.name ?? small
                let largeName = observation.pluginMetadata[large]?.name ?? large
                let contained = shared.count == smaller
                findings.append(
                    SetupFinding(
                        kind: .pluginSkillsOverlap, severity: .info, client: client, subject: "\(small)|\(large)",
                        title: contained
                            ? "Every skill in \(smallName) also comes with \(largeName)"
                            : "\(smallName) and \(largeName) share \(shared.count) skills",
                        detail: "\(client.rawValue) lists each plugin's copy, so these \(shared.count) skills appear twice. Removing a plugin is a decision about all of it: its other skills and servers go with it.",
                        evidence: shared.sorted(), actions: []))
            }
        }
        return findings
    }

    /// A version folder's name: digits and dots (`1.0.6484223236`), or a git
    /// revision (`fa59bc903774`, `unknown` as Claude writes it).
    static func looksLikeVersion(_ name: String) -> Bool {
        if name == "unknown" { return true }
        if name.allSatisfy({ $0.isNumber || $0 == "." }), name.contains(".") { return true }
        return name.count >= 7 && name.count <= 40 && name.allSatisfy { $0.isHexDigit }
    }

    // MARK: MCP servers

    private func mcpFindings(client: ClientKind, observation: TargetObservation) -> [SetupFinding] {
        var findings: [SetupFinding] = []
        // A plugin's server is its own server unless it is configured exactly
        // like one already defined, so the same name from several places can
        // mean several processes and the same tools listed more than once.
        // https://github.com/anthropics/claude-code/issues/85862
        for (server, metadata) in observation.mcpMetadata.sorted(by: { $0.key < $1.key }) where metadata.allSources.count > 1 {
            let sources = metadata.allSources
            let configured = sources.filter { !$0.contains("@") }
            let plugins = sources.filter { $0.contains("@") }.sorted()
            let from = (configured.isEmpty ? [] : ["its own configuration"]) + plugins
            findings.append(
                SetupFinding(
                    kind: .mcpServerDefinedSeveralTimes, severity: .low, client: client, subject: server,
                    title: "\(client.rawValue) gets \(server) from \(sources.count) places",
                    detail: "\(server) is defined by \(from.joined(separator: ", ")). \(client.rawValue) treats each one as its own server unless two are configured identically, so each can start its own process and list its own tools."
                        + (configured.isEmpty
                            ? " Each copy comes with a plugin, so there is nothing here to remove."
                            : " If a plugin's copy does what you need, the one in \(client.rawValue)'s configuration can go."),
                    evidence: sources.map(redact),
                    actions: configured.isEmpty ? [] : [.inspectMCPServer(name: server, client: client)]))
        }
        let commands = configuredCommands(client: client, configurationPaths: observation.configurationPaths)
        for (server, metadata) in observation.mcpMetadata.sorted(by: { $0.key < $1.key }) where metadata.transport == "stdio" {
            guard let command = commands[server] else { continue }
            if !commandIsReachable(command) {
                findings.append(
                    SetupFinding(
                        kind: .unreachableMCPCommand, severity: .medium, client: client, subject: server,
                        title: "\(server)'s command was not found",
                        detail: "\(client.rawValue) is set to start this server with `\(redact(command))`, which is not on this Mac in any place the app knows to look. The server fails to start.",
                        evidence: [redact(command)],
                        actions: metadata.enabled
                            ? [.disableMCPServer(name: server, client: client), .inspectMCPServer(name: server, client: client)]
                            : [.inspectMCPServer(name: server, client: client)]))
            }
        }
        return findings
    }

    /// Marketplaces a client reads from a folder on disk, by name: Claude's
    /// `extraKnownMarketplaces` in settings.json and its known_marketplaces
    /// record. A plugin from one of these loads from the folder directly.
    func directoryMarketplaces(client: ClientKind, configurationPaths: [String]) -> [String: URL] {
        guard client == .claude else { return [:] }
        var found: [String: URL] = [:]
        let candidates = configurationPaths.map { URL(filePath: $0) } + [homeURL.appending(path: ".claude/plugins/known_marketplaces.json")]
        for url in candidates {
            guard let text = try? BoundedFileAccess.readUTF8(at: url, maximumBytes: BoundedFileAccess.maximumConfigurationBytes),
                let data = text.data(using: .utf8), let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { continue }
            let entries = (root["extraKnownMarketplaces"] as? [String: Any]) ?? (url.lastPathComponent == "known_marketplaces.json" ? root : [:])
            for (name, value) in entries {
                guard let source = (value as? [String: Any])?["source"] as? [String: Any],
                    source["source"] as? String == "directory", let path = source["path"] as? String
                else { continue }
                found[name] = URL(filePath: path.hasPrefix("~/") ? homeURL.appending(path: String(path.dropFirst(2))).path(percentEncoded: false) : path, directoryHint: .isDirectory)
            }
        }
        return found
    }

    /// The `command` of every stdio server in the client's own configuration
    /// files. Reads the same files the check read; understands the two
    /// formats the clients use (JSON `mcpServers`, TOML `[mcp_servers.x]`).
    func configuredCommands(client: ClientKind, configurationPaths: [String]) -> [String: String] {
        var commands: [String: String] = [:]
        for path in configurationPaths {
            guard let text = try? BoundedFileAccess.readUTF8(at: URL(filePath: path), maximumBytes: BoundedFileAccess.maximumConfigurationBytes) else { continue }
            if path.hasSuffix(".toml") {
                var current: String?
                for line in text.split(separator: "\n") {
                    let trimmed = line.trimmingCharacters(in: .whitespaces)
                    if trimmed.hasPrefix("[mcp_servers."), trimmed.hasSuffix("]") {
                        current = String(trimmed.dropFirst("[mcp_servers.".count).dropLast()).trimmingCharacters(in: CharacterSet(charactersIn: "\""))
                    } else if trimmed.hasPrefix("["), trimmed.hasSuffix("]") {
                        current = nil
                    } else if let current, trimmed.hasPrefix("command"), let equals = trimmed.firstIndex(of: "=") {
                        commands[current] = trimmed[trimmed.index(after: equals)...].trimmingCharacters(in: CharacterSet(charactersIn: " \""))
                    }
                }
            } else if let data = text.data(using: .utf8), let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                var servers: [String: Any] = root["mcpServers"] as? [String: Any] ?? [:]
                // Claude keeps per-project servers under `projects`; those are
                // configured by hand too.
                if let projects = root["projects"] as? [String: Any] {
                    for project in projects.values {
                        if let inner = (project as? [String: Any])?["mcpServers"] as? [String: Any] {
                            servers.merge(inner) { current, _ in current }
                        }
                    }
                }
                for (name, value) in servers {
                    if let command = (value as? [String: Any])?["command"] as? String { commands[name] = command }
                }
            }
        }
        return commands
    }

    func commandIsReachable(_ command: String) -> Bool {
        let expanded = command.hasPrefix("~/") ? homeURL.appending(path: String(command.dropFirst(2))).path(percentEncoded: false) : command
        if expanded.contains("/") { return fileManager.isExecutableFile(atPath: expanded) }
        return searchPath.contains { fileManager.isExecutableFile(atPath: $0.appending(path: expanded).path(percentEncoded: false)) }
    }

    // MARK: Helpers

    private func resolvedPath(_ path: String) -> String {
        URL(filePath: path).resolvingSymlinksInPath().path(percentEncoded: false)
    }

    /// A path as the report shows it: standardized, without a trailing slash,
    /// and with the home folder as `~`. Applied to evidence and to the paths
    /// an action carries alike, so the two never disagree about one file.
    private func normalized(_ path: String) -> String {
        var standard = URL(filePath: path).standardizedFileURL.path(percentEncoded: false)
        // The temporary folder resolves through /private; a home given that way
        // and a folder listed the other way must still be one path.
        if standard.hasPrefix("/private/") { standard = String(standard.dropFirst("/private".count)) }
        if standard.count > 1, standard.hasSuffix("/") { standard.removeLast() }
        return standard
    }

    private func redact(_ text: String) -> String {
        var home = normalized(homeURL.path(percentEncoded: false))
        if home.hasSuffix("/") { home.removeLast() }
        let path = text.hasPrefix("/") ? normalized(text) : text
        return path.hasPrefix(home) ? "~" + path.dropFirst(home.count) : path
    }
}
