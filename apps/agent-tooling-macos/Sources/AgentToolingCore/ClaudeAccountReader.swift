import Foundation

/// The fixed, read-only commands the account reader runs against Claude Code.
/// Each is admitted by `OperationCommandPolicy` too, so a listing the policy
/// would refuse is a refused read rather than a different command.
enum ClaudeAccountCommands {
    static let authStatus = ["auth", "status", "--json"]
    static let pluginList = ["plugin", "list", "--json"]
    static let version = ["--version"]
}

/// What Claude Code's own settings say about the claude.ai account, read from
/// one settings file.
struct ClaudeAccountSettings: Hashable, Sendable {
    /// `syncClaudeAiSkills`: only `false` means anything.
    var skillSyncOff = false
    /// `syncClaudeAiPlugins`: only `false` means anything.
    var pluginSyncOff = false
    /// `disableClaudeAiConnectors`: only `true` means anything.
    var connectorsOff = false
    /// `deniedMcpServers` `serverName` entries for claude.ai connectors, by
    /// the connector's display name (the prefix removed).
    var deniedConnectors: Set<String> = []
    /// `enabledPlugins` entries for `<name>@synced`, by plugin name.
    var syncedPluginFlags: [String: Bool] = [:]

    init() {}

    var isEmpty: Bool {
        !skillSyncOff && !pluginSyncOff && !connectorsOff && deniedConnectors.isEmpty && syncedPluginFlags.isEmpty
    }

    /// The account switches this one file sets, keyed the way the shared
    /// choices are. A key it does not set is absent.
    var switches: [AccountPreferenceKey: AccountPreferenceValue] {
        var switches: [AccountPreferenceKey: AccountPreferenceValue] = [:]
        if skillSyncOff { switches[.init(.skillSync)] = .off }
        if pluginSyncOff { switches[.init(.pluginSync)] = .off }
        if connectorsOff { switches[.init(.connectors)] = .off }
        for name in deniedConnectors { switches[.init(.connector, subject: name)] = .off }
        for (name, flag) in syncedPluginFlags { switches[.init(.plugin, subject: name)] = flag ? .on : .off }
        return switches
    }
}

/// One plugin Claude Code loads from the claude.ai account.
struct ClaudeSyncedPlugin: Hashable, Sendable {
    var name: String
    var version: String?
    var enabled: Bool
    /// False for a row Claude Code lists without a folder: a synced plugin a
    /// local copy of the same name shadows, or one that failed to download.
    var isInstalled: Bool
    var mcpServers: [String]
    var errors: [String]
    var notes: [String]

    init(
        name: String, version: String? = nil, enabled: Bool, isInstalled: Bool, mcpServers: [String] = [],
        errors: [String] = [], notes: [String] = []
    ) {
        self.name = name
        self.version = version
        self.enabled = enabled
        self.isInstalled = isInstalled
        self.mcpServers = mcpServers
        self.errors = errors
        self.notes = notes
    }
}

/// One skill Claude Code downloaded from the claude.ai account.
struct ClaudeSyncedSkill: Hashable, Sendable {
    var folder: String
    var name: String
    var summary: String?

    init(folder: String, name: String, summary: String? = nil) {
        self.folder = folder
        self.name = name
        self.summary = summary
    }
}

/// Pure readings of Claude Code's own output. Each is a function over text or
/// one folder, so every shape the client prints is pinned by a fixed fixture.
enum ClaudeAccountParsing {
    /// `claude auth status --json`. Claude Code exits 1 when signed out but
    /// still prints the object, so the exit status is not consulted.
    static func signIn(fromAuthStatus text: String) -> AccountSignIn? {
        guard let object = jsonObject(text) else { return nil }
        let loggedIn = object["loggedIn"] as? Bool ?? false
        let method = (object["authMethod"] as? String)?.lowercased() ?? "none"
        let provider = bounded(object["apiProvider"] as? String)
        let configDirectory = bounded(object["configDirectory"] as? String, maximum: 4_096)
        let email = bounded(object["email"] as? String)
        let organizationID = bounded(object["orgId"] as? String)
        let organizationName = bounded(object["orgName"] as? String)
        guard loggedIn || method != "none" else {
            return AccountSignIn(method: .signedOut, configDirectory: configDirectory)
        }
        switch method {
        case "claude.ai":
            return AccountSignIn(
                method: .subscription, email: email, organizationID: organizationID,
                organizationName: organizationName, plan: bounded(object["subscriptionType"] as? String),
                configDirectory: configDirectory)
        case "oauth_token":
            return AccountSignIn(method: .token, configDirectory: configDirectory)
        case "api_key":
            return AccountSignIn(
                method: .apiKey, provider: bounded(object["apiKeySource"] as? String),
                configDirectory: configDirectory)
        case "api_key_helper":
            return AccountSignIn(method: .keyHelper, configDirectory: configDirectory)
        case "third_party":
            return AccountSignIn(method: .thirdParty, provider: provider, configDirectory: configDirectory)
        case "none":
            return AccountSignIn(method: .signedOut, configDirectory: configDirectory)
        default:
            return AccountSignIn(method: .unknown, provider: bounded(method), configDirectory: configDirectory)
        }
    }

    /// The `<name>@synced` rows of `claude plugin list --json`. Every other
    /// row belongs to this Mac and is read by the device scan instead.
    static func syncedPlugins(fromPluginList text: String) -> [ClaudeSyncedPlugin] {
        guard let data = text.data(using: .utf8),
            let rows = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]]
        else { return [] }
        var byName: [String: ClaudeSyncedPlugin] = [:]
        for row in rows.prefix(BoundedFileAccess.maximumDirectoryEntries) {
            guard let id = row["id"] as? String, ClaudeAccountSync.isSyncedPluginID(id) else { continue }
            let name = ClaudeAccountSync.pluginName(ofPluginID: id)
            guard !name.isEmpty, name.count <= 256 else { continue }
            let installPath = row["installPath"] as? String ?? ""
            let servers = (row["mcpServers"] as? [String: Any]).map { Array($0.keys).sorted() } ?? []
            let errors = strings(row["errors"])
            let notes = strings(row["notes"])
            let version = bounded(row["version"] as? String).flatMap { $0 == "unknown" ? nil : $0 }
            let plugin = ClaudeSyncedPlugin(
                name: name, version: version, enabled: row["enabled"] as? Bool ?? true,
                isInstalled: !installPath.isEmpty, mcpServers: Array(servers.prefix(64)),
                errors: errors, notes: notes)
            // A shadowed or failing copy can be listed beside the loaded row;
            // the loaded one is the one to describe, with the others' notes.
            if var earlier = byName[name] {
                if !earlier.isInstalled && plugin.isInstalled {
                    var merged = plugin
                    merged.notes += earlier.notes
                    merged.errors += earlier.errors
                    byName[name] = merged
                } else {
                    earlier.notes += plugin.notes
                    earlier.errors += plugin.errors
                    byName[name] = earlier
                }
            } else {
                byName[name] = plugin
            }
        }
        return byName.values.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// The account switches one Claude settings file holds.
    static func settings(fromJSON text: String) -> ClaudeAccountSettings {
        var result = ClaudeAccountSettings()
        guard let object = jsonObject(text) else { return result }
        result.skillSyncOff = (object["syncClaudeAiSkills"] as? Bool) == false
        result.pluginSyncOff = (object["syncClaudeAiPlugins"] as? Bool) == false
        result.connectorsOff = (object["disableClaudeAiConnectors"] as? Bool) == true
        for entry in (object["deniedMcpServers"] as? [Any] ?? []).prefix(1_024) {
            guard let fields = entry as? [String: Any], let name = fields["serverName"] as? String,
                ConnectionHealthReport.isClaudeAIConnectorName(name)
            else { continue }
            result.deniedConnectors.insert(String(name.dropFirst(ConnectionHealthReport.claudeAIConnectorPrefix.count)))
        }
        for (id, value) in (object["enabledPlugins"] as? [String: Any] ?? [:]).prefix(2_048) {
            guard ClaudeAccountSync.isSyncedPluginID(id), let flag = value as? Bool else { continue }
            result.syncedPluginFlags[ClaudeAccountSync.pluginName(ofPluginID: id)] = flag
        }
        return result
    }

    /// Skills under `~/.claude/skills/synced`. A folder with a `SKILL.md`
    /// is one skill, named by its frontmatter when it has a readable one.
    static func syncedSkills(in directory: URL, fileManager: FileManager = .default) -> [ClaudeSyncedSkill] {
        var skills: [String: ClaudeSyncedSkill] = [:]
        for url in BoundedFileAccess.descendantDirectories(under: directory, fileManager: fileManager, maximumDepth: 3) {
            let definition = url.appending(path: "SKILL.md")
            guard BoundedFileAccess.isRegularFile(definition) else { continue }
            let folder = url.lastPathComponent
            guard !folder.hasPrefix("."), folder.count <= 256 else { continue }
            let frontmatter = (try? BoundedFileAccess.readUTF8(at: definition, maximumBytes: 256 * 1_024))
                .flatMap { try? SkillFrontmatter.parse($0) }
            let summary = frontmatter.map(\.description).flatMap { text -> String? in
                let line = text.split(whereSeparator: \.isNewline).first.map(String.init) ?? text
                return line.isEmpty ? nil : String(line.prefix(240))
            }
            let skill = ClaudeSyncedSkill(folder: folder, name: frontmatter?.name ?? folder, summary: summary)
            if skills[folder] == nil { skills[folder] = skill }
        }
        return skills.values.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// `claude --version` prints `2.1.300 (Claude Code)` or a vendor build
    /// line; the first token that starts with a digit is the version.
    static func version(fromVersionOutput text: String) -> String? {
        text.split(whereSeparator: { $0 == " " || $0.isNewline })
            .first { $0.first?.isNumber == true }
            .map(String.init)
    }

    static func jsonObject(_ text: String) -> [String: Any]? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let data = trimmed.data(using: .utf8) else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    static func bounded(_ value: String?, maximum: Int = 512) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty,
            value.count <= maximum,
            !value.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
        else { return nil }
        return value
    }

    private static func strings(_ value: Any?) -> [String] {
        (value as? [Any] ?? []).prefix(16).compactMap { item in
            if let text = item as? String { return bounded(SensitiveValueRedactor.redact(text), maximum: 2_000) }
            if let object = item as? [String: Any], let text = object["message"] as? String {
                return bounded(SensitiveValueRedactor.redact(text), maximum: 2_000)
            }
            return nil
        }
    }
}

/// Reads what the claude.ai account puts in front of Claude Code on this Mac.
///
/// It runs Claude Code's own read-only commands and reads its own files; it
/// writes nothing and holds no credential. A light read asks only how Claude
/// Code signs in and what its switches say; a full read also lists the
/// account's connectors, plugins and skills, which means asking Claude Code
/// to health-check its servers.
public struct ClaudeAccountReader: Sendable {
    public static let managedSettingsURL = URL(filePath: "/Library/Application Support/ClaudeCode/managed-settings.json")

    private let runner: any CommandRunning
    private let homeURL: URL
    private let locate: @Sendable (ClientKind, URL) -> URL?
    private let managedSettingsURL: URL

    public init(
        runner: any CommandRunning, homeURL: URL,
        locate: @escaping @Sendable (ClientKind, URL) -> URL? = { ClientExecutableLocator.locate($0, homeURL: $1) },
        managedSettingsURL: URL = ClaudeAccountReader.managedSettingsURL
    ) {
        self.runner = runner
        self.homeURL = homeURL
        self.locate = locate
        self.managedSettingsURL = managedSettingsURL
    }

    public func read(contents: Bool, shellOverrides: [AccountShellOverride] = [], now: Date = .now) async -> AccountObservation {
        let provider = AccountProvider.claude
        let overrides = shellOverrides.filter { $0.provider == provider }
        guard let executable = locate(.claude, homeURL)?.path(percentEncoded: false) else {
            return AccountObservation(
                provider: provider, observedAt: now,
                unavailableReason: "Claude Code's command-line tool was not found on this Mac, so its claude.ai account could not be read.",
                shellOverrides: overrides)
        }
        async let versionOutput = try? runner.run(executable: executable, arguments: ClaudeAccountCommands.version, currentDirectory: nil)
        async let authOutput = try? runner.run(executable: executable, arguments: ClaudeAccountCommands.authStatus, currentDirectory: nil)
        let version = (await versionOutput).flatMap {
            $0.status == 0 ? ClaudeAccountParsing.version(fromVersionOutput: $0.standardOutput) : nil
        }
        let signIn = (await authOutput).flatMap { ClaudeAccountParsing.signIn(fromAuthStatus: $0.standardOutput) }

        let userSettings = readSettings(at: ClientConfigurationFile.claudeSettings.url(homeURL: homeURL))
        let managedSettings = readSettings(at: managedSettingsURL)
        var observation = AccountObservation(
            provider: provider, observedAt: now, clientVersion: version, signIn: signIn,
            contentsRead: contents, shellOverrides: overrides)
        if signIn == nil {
            observation.notes.append("Claude Code did not say how it signs in, so this Mac's account could not be confirmed.")
        }
        observation.writeBlocker = configurationBlocker(signIn: signIn)
        applySwitches(user: userSettings, managed: managedSettings, to: &observation)

        guard contents else { return observation }
        if signIn?.method.reachesAccount != true {
            observation.notes.append(
                "claude.ai connectors, skills and plugins reach Claude Code only when it signs in with your claude.ai subscription. On this Mac it uses \(signIn?.summary(for: provider) ?? "an unknown sign-in")."
            )
        }
        async let pluginOutput = try? runner.run(executable: executable, arguments: ClaudeAccountCommands.pluginList, currentDirectory: nil)
        async let connectorResult = ConnectionHealthProbe(runner: runner, homeURL: homeURL, locate: locate).probe(.claude)
        let plugins = (await pluginOutput).flatMap {
            $0.status == 0 ? ClaudeAccountParsing.syncedPlugins(fromPluginList: $0.standardOutput) : nil
        }
        if plugins == nil {
            observation.notes.append("Claude Code did not list its plugins, so the account's plugins are not shown.")
        }
        let connectors = await connectorResult
        if let reason = connectors.unavailableReason { observation.notes.append(reason) }
        let skills = ClaudeAccountParsing.syncedSkills(in: ClaudeAccountSync.syncedSkillsDirectory(homeURL: homeURL))

        observation.items =
            connectorItems(connectors.entries, settings: userSettings, managed: managedSettings)
            + pluginItems(plugins ?? [], settings: userSettings)
            + skillItems(skills)
        for plugin in plugins ?? [] {
            observation.switches[AccountPreferenceKey(.plugin, subject: plugin.name)] = plugin.enabled ? .on : .off
        }
        if userSettings.skillSyncOff {
            observation.notes.append("Claude Code's own settings turn off claude.ai skills on this Mac (syncClaudeAiSkills is false).")
        }
        if userSettings.pluginSyncOff {
            observation.notes.append("Claude Code's own settings turn off claude.ai plugins on this Mac (syncClaudeAiPlugins is false).")
        }
        if userSettings.connectorsOff || managedSettings.connectorsOff {
            observation.notes.append(
                "claude.ai connectors are turned off in Claude Code on this Mac (disableClaudeAiConnectors), so none are listed.")
        }
        observation.notes.append(
            "The Claude desktop app's Code tab gets connectors from claude.ai directly; the switches here reach terminal and IDE sessions only."
        )
        return observation
    }

    // MARK: Switches

    private func applySwitches(user: ClaudeAccountSettings, managed: ClaudeAccountSettings, to observation: inout AccountObservation) {
        observation.fileValues = user.switches
        // Managed settings sit above the user file, so the value Claude Code
        // uses is the file's with the policy's values laid over it.
        observation.switches = user.switches.merging(managed.switches) { _, policy in policy }

        let policy = "Set by your organization's managed settings"
        if managed.skillSyncOff { observation.constrained[.init(.skillSync)] = policy }
        if managed.pluginSyncOff { observation.constrained[.init(.pluginSync)] = policy }
        if managed.connectorsOff { observation.constrained[.init(.connectors)] = policy }
        for name in managed.deniedConnectors { observation.constrained[.init(.connector, subject: name)] = policy }
        for name in managed.syncedPluginFlags.keys { observation.constrained[.init(.plugin, subject: name)] = policy }
    }

    /// The one settings file this app edits is `~/.claude/settings.json`. A
    /// Claude Code that reports another configuration folder reads another
    /// file, and editing this one would change nothing it does.
    private func configurationBlocker(signIn: AccountSignIn?) -> String? {
        guard let reported = signIn?.configDirectory else { return nil }
        let expected = homeURL.appending(path: ".claude", directoryHint: .isDirectory).standardizedFileURL
        let actual = URL(filePath: reported, directoryHint: .isDirectory).standardizedFileURL
        guard expected.path(percentEncoded: false) != actual.path(percentEncoded: false),
            expected.resolvingSymlinksInPath().path(percentEncoded: false) != actual.resolvingSymlinksInPath().path(percentEncoded: false)
        else { return nil }
        return "Claude Code on this Mac reads its settings from \(reported), and this app only edits ~/.claude/settings.json."
    }

    private func readSettings(at url: URL) -> ClaudeAccountSettings {
        guard let text = try? BoundedFileAccess.readUTF8(at: url, maximumBytes: BoundedFileAccess.maximumConfigurationBytes)
        else { return ClaudeAccountSettings() }
        return ClaudeAccountParsing.settings(fromJSON: text)
    }

    // MARK: Items

    private func connectorItems(
        _ entries: [ConnectionHealthEntry], settings: ClaudeAccountSettings, managed: ClaudeAccountSettings
    ) -> [AccountItem] {
        let page = ConnectionHealthAction.claudeAIConnectorsURL
        var items = entries.filter(\.isClaudeAIConnector).map { entry -> AccountItem in
            AccountItem(
                provider: .claude, kind: .connector, key: entry.displayName, name: entry.displayName,
                detail: Self.connectorDetail(entry.status), state: Self.connectorState(entry.status),
                setting: .connector, url: page)
        }
        // A connector a deniedMcpServers entry names is never loaded, so the
        // listing leaves it out. It is still the account's; show it as off.
        let listed = Set(items.map(\.key))
        for name in settings.deniedConnectors.union(managed.deniedConnectors).sorted() where !listed.contains(name) {
            items.append(
                AccountItem(
                    provider: .claude, kind: .connector, key: name, name: name,
                    detail: managed.deniedConnectors.contains(name)
                        ? "Your organization's managed settings keep it out of Claude Code."
                        : "Claude Code's settings keep it out of terminal and IDE sessions on this Mac.",
                    state: .init(tone: .off, label: "Off in Claude Code"), setting: .connector, url: page))
        }
        return items
    }

    static func connectorState(_ status: ConnectionHealthStatus) -> AccountItemState {
        switch status {
        case .connected: .init(tone: .ready, label: "Connected")
        case .needsAuthentication: .init(tone: .attention, label: "Needs sign-in on claude.ai")
        case .failed: .init(tone: .attention, label: "Failed to connect")
        case .pendingApproval: .init(tone: .attention, label: "Waiting for approval")
        case .disabled: .init(tone: .off, label: "Off for one project")
        case .notConfigured: .init(tone: .neutral, label: "Not connected on claude.ai")
        case .unknown(let text): .init(tone: .neutral, label: text.isEmpty ? "Status unknown" : String(text.prefix(80)))
        }
    }

    static func connectorDetail(_ status: ConnectionHealthStatus) -> String? {
        switch status {
        case .failed(let detail) where !detail.isEmpty: detail
        case .needsAuthentication: "Connect it on claude.ai; Claude Code cannot sign in to an account connector itself."
        default: nil
        }
    }

    private func pluginItems(_ plugins: [ClaudeSyncedPlugin], settings: ClaudeAccountSettings) -> [AccountItem] {
        let page = URL(string: "https://claude.ai/customize/plugins")
        return plugins.map { plugin in
            let state: AccountItemState
            let detail: String?
            if let error = plugin.errors.first {
                state = .init(tone: .attention, label: "Did not load")
                detail = error
            } else if !plugin.isInstalled {
                state = .init(tone: .neutral, label: "Not loaded")
                detail = plugin.notes.first ?? "A plugin of the same name from another source loads instead."
            } else if !plugin.enabled {
                state = .init(tone: .off, label: "Off in Claude Code")
                detail =
                    settings.syncedPluginFlags[plugin.name] == false
                    ? "Claude Code's settings turn it off on this Mac."
                    : "The plugin starts turned off until a settings file turns it on."
            } else {
                state = .init(tone: .ready, label: "Loads in Claude Code")
                detail = plugin.notes.first
            }
            var facts: [String] = []
            if let version = plugin.version { facts.append("Version \(version)") }
            if !plugin.mcpServers.isEmpty {
                facts.append(
                    "Brings \(plugin.mcpServers.count) server\(plugin.mcpServers.count == 1 ? "" : "s"): \(plugin.mcpServers.joined(separator: ", "))"
                )
            }
            return AccountItem(
                provider: .claude, kind: .plugin, key: plugin.name, name: plugin.name, detail: detail, state: state,
                setting: .plugin, url: page, facts: facts)
        }
    }

    private func skillItems(_ skills: [ClaudeSyncedSkill]) -> [AccountItem] {
        let page = URL(string: "https://claude.ai/customize/skills")
        return skills.map { skill in
            AccountItem(
                provider: .claude, kind: .skill, key: skill.folder, name: skill.name, detail: skill.summary,
                state: .init(tone: .ready, label: "Synced to this Mac"), url: page)
        }
    }
}
