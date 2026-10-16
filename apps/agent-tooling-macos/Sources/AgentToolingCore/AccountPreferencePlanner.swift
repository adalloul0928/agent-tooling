import Foundation

/// What applying the shared account choices would change in one client's
/// settings file on this Mac.
///
/// Built from three facts: the choices in the portable document, the switches
/// this Mac's client reported, and the text of the one file this app edits.
/// Every change is a `ClientConfigurationEdit` the operation engine already
/// knows how to make, after copying the file into the workspace trash.
public struct AccountPreferencePlan: Hashable, Sendable {
    public struct Change: Identifiable, Hashable, Sendable {
        public var key: AccountPreferenceKey
        public var desired: AccountPreferenceValue
        /// What the client uses now; nil when nothing says and the vendor
        /// documents no default.
        public var current: AccountPreferenceValue?
        public var edits: [ClientConfigurationEdit]
        public var id: AccountPreferenceKey { key }

        public var summary: String {
            let from = current.map { " (now \($0.label.lowercased()))" } ?? ""
            return "\(key.label.prefix(1).uppercased() + key.label.dropFirst()): \(desired.label.lowercased())\(from)"
        }
    }

    /// A choice this Mac cannot follow by editing its file, and why.
    public struct Held: Identifiable, Hashable, Sendable {
        public var key: AccountPreferenceKey
        public var desired: AccountPreferenceValue
        public var reason: String
        public var id: AccountPreferenceKey { key }
    }

    public var provider: AccountProvider
    public var changes: [Change]
    public var held: [Held]
    /// Choices this Mac already follows.
    public var following: [AccountPreferenceKey]

    public init(provider: AccountProvider, changes: [Change] = [], held: [Held] = [], following: [AccountPreferenceKey] = []) {
        self.provider = provider
        self.changes = changes
        self.held = held
        self.following = following
    }

    public var isEmpty: Bool { changes.isEmpty }
    /// How many shared choices this Mac does not follow yet, held or not.
    public var outOfStep: Int { changes.count + held.count }

    public var file: ClientConfigurationFile { ClientConfigurationFile.settings(for: provider.client) }

    /// The reviewed plan that makes the changes. One step per edit, each a
    /// configuration edit the engine backs up before making.
    public func operationPlan(homeURL: URL) throws -> OperationPlan {
        let destination = file.url(homeURL: homeURL).path(percentEncoded: false)
        let steps = try changes.flatMap(\.edits).map { edit in
            OperationStep(
                kind: .editClientConfiguration, title: edit.summary, detail: edit.file.relativePath,
                destinationPath: destination, contents: try edit.encoded(), isReversible: true)
        }
        let count = changes.count
        return OperationPlan(
            kind: .configureMCP,
            title: "Apply \(count) shared \(provider.accountName) choice\(count == 1 ? "" : "s") to \(provider.client.rawValue)",
            summary: "Changes \(file.relativePath) so \(provider.client.rawValue) on this Mac follows the account choices every Mac shares. The file is copied into this workspace's trash first. Sessions already open keep their old settings until they restart.",
            targetSurfaces: [provider.surface], scope: .user, steps: steps)
    }
}

public enum AccountPreferencePlanner {
    /// Decides what to change on this Mac for one provider. Pure: it reads
    /// nothing and writes nothing.
    ///
    /// - Parameter configurationText: the current text of the file this app
    ///   edits, or nil when it does not exist. Edits are rehearsed against it,
    ///   so a file the editor would refuse is reported here rather than as a
    ///   failed step.
    public static func plan(
        preferences: AccountPreferences, observation: AccountObservation, configurationText: String?
    ) -> AccountPreferencePlan {
        plan(preferences: preferences, observation: observation, configuration: .success(configurationText))
    }

    /// The same decision, from the file as it was read: its text, nil when
    /// there is no file, or the error that kept a file that is there from
    /// being read, such as one over the size limit. A file that could not be
    /// read is never planned against as though it were empty, because the
    /// engine would refuse the edit too: every choice that needs one is held,
    /// with the error's own words as the reason.
    public static func plan(
        preferences: AccountPreferences, observation: AccountObservation, configuration: Result<String?, any Error>
    ) -> AccountPreferencePlan {
        let provider = observation.provider
        var plan = AccountPreferencePlan(provider: provider)
        let entries = preferences.entries.filter { $0.provider == provider }.sorted { $0.key < $1.key }
        guard !entries.isEmpty else { return plan }

        if let reason = observation.unavailableReason ?? observation.writeBlocker {
            plan.held = entries.map { .init(key: $0.key, desired: $0.value, reason: reason) }
            return plan
        }

        var text = ""
        var unreadable: String?
        switch configuration {
        case .success(let read): text = read ?? ""
        case .failure(let error): unreadable = (error as? any LocalizedError)?.errorDescription ?? error.localizedDescription
        }
        for entry in entries {
            let key = entry.key
            let current = observation.effectiveValue(of: key)
            if current == entry.value {
                plan.following.append(key)
                continue
            }
            if let policy = observation.constrained[key] {
                plan.held.append(.init(key: key, desired: entry.value, reason: policy))
                continue
            }
            let edits: [ClientConfigurationEdit]
            switch makeEdits(for: entry, observation: observation) {
            case .success(let made): edits = made
            case .failure(let reason):
                plan.held.append(.init(key: key, desired: entry.value, reason: reason.message))
                continue
            }
            if let unreadable {
                plan.held.append(.init(key: key, desired: entry.value, reason: unreadable))
                continue
            }
            if provider == .chatGPT, let obstacle = edits.lazy.compactMap({ CodexConfigurationShape.obstacle(in: text, keyPath: $0.keyPath) }).first {
                plan.held.append(.init(key: key, desired: entry.value, reason: obstacle))
                continue
            }
            // Rehearse against the file as the earlier edits leave it, so the
            // plan on screen is exactly what the engine will make.
            do {
                var rehearsed = text
                for edit in edits { rehearsed = try ClientConfigurationEditor.apply(edit, to: rehearsed) }
                guard rehearsed != text else {
                    plan.held.append(.init(
                        key: key, desired: entry.value,
                        reason: "\(observation.provider.client.rawValue)'s \(plan.file.relativePath) already says this, so another settings layer decides it."))
                    continue
                }
                text = rehearsed
            } catch {
                plan.held.append(.init(
                    key: key, desired: entry.value,
                    reason: (error as? any LocalizedError)?.errorDescription ?? "The file could not be changed safely."))
                continue
            }
            plan.changes.append(.init(key: key, desired: entry.value, current: current, edits: edits))
        }
        return plan
    }

    struct Refusal: Error {
        var message: String
    }

    /// The edits one choice needs, from the documented meaning of each key.
    static func makeEdits(for entry: AccountPreference, observation: AccountObservation) -> Result<[ClientConfigurationEdit], Refusal> {
        let key = entry.key
        let fileSays = observation.fileValues[key]
        let notThisFile = Refusal(message: "Another settings file turns this off on this Mac, not \(ClientConfigurationFile.settings(for: entry.provider.client).relativePath).")
        switch entry.setting {
        case .skillSync:
            // `syncClaudeAiSkills`: only false means anything; true is unset.
            if entry.value == .off { return .success([.init(file: .claudeSettings, keyPath: ["syncClaudeAiSkills"], value: .bool(false))]) }
            return fileSays == .off ? .success([.init(file: .claudeSettings, keyPath: ["syncClaudeAiSkills"], value: .remove)]) : .failure(notThisFile)
        case .pluginSync:
            if entry.value == .off { return .success([.init(file: .claudeSettings, keyPath: ["syncClaudeAiPlugins"], value: .bool(false))]) }
            return fileSays == .off ? .success([.init(file: .claudeSettings, keyPath: ["syncClaudeAiPlugins"], value: .remove)]) : .failure(notThisFile)
        case .connectors:
            // `disableClaudeAiConnectors`: a true in any settings file applies.
            if entry.value == .off { return .success([.init(file: .claudeSettings, keyPath: ["disableClaudeAiConnectors"], value: .bool(true))]) }
            return fileSays == .off ? .success([.init(file: .claudeSettings, keyPath: ["disableClaudeAiConnectors"], value: .remove)]) : .failure(notThisFile)
        case .plugin:
            guard let name = entry.subject else { return .failure(.init(message: "This choice names no plugin.")) }
            // Explicit either way: a synced plugin whose manifest starts it
            // turned off stays off when the key is only removed.
            return .success([.init(
                file: .claudeSettings, keyPath: ["enabledPlugins", ClaudeAccountSync.syncedPluginID(name: name)],
                value: .bool(entry.value == .on))])
        case .connector:
            guard let name = entry.subject else { return .failure(.init(message: "This choice names no connector.")) }
            let serverName = ConnectionHealthReport.claudeAIConnectorPrefix + name
            if entry.value == .off {
                return .success([.init(file: .claudeSettings, keyPath: ["deniedMcpServers"], value: .appendObjectToList(field: "serverName", value: serverName))])
            }
            return fileSays == .off
                ? .success([.init(file: .claudeSettings, keyPath: ["deniedMcpServers"], value: .removeObjectFromList(field: "serverName", value: serverName))])
                : .failure(notThisFile)
        case .apps:
            return .success([.init(file: .codexConfig, keyPath: ["features", "apps"], value: .bool(entry.value == .on))])
        case .app:
            guard let id = entry.subject else { return .failure(.init(message: "This choice names no app.")) }
            return .success([.init(file: .codexConfig, keyPath: ["apps", id, "enabled"], value: .bool(entry.value == .on))])
        case .destructiveTools:
            return .success([.init(file: .codexConfig, keyPath: ["apps", entry.subject ?? "_default", "destructive_enabled"], value: .bool(entry.value == .on))])
        case .openWorldTools:
            return .success([.init(file: .codexConfig, keyPath: ["apps", entry.subject ?? "_default", "open_world_enabled"], value: .bool(entry.value == .on))])
        case .approvalMode:
            return .success([.init(
                file: .codexConfig, keyPath: ["apps", entry.subject ?? "_default", "default_tools_approval_mode"],
                value: .string(entry.value.rawValue))])
        }
    }
}

/// Finds the ways a `config.toml` can already define a key that the line
/// editor would not see, so it is never asked to make a second definition.
///
/// The editor works by table header: it replaces `key = …` under `[table]`,
/// or adds the header and the key. TOML can also define the same key with a
/// dotted key elsewhere (`apps.github.enabled = false` at the top), inside an
/// inline table (`apps = { github = { enabled = false } }`), under an array of
/// tables, or with quoting the editor does not match. Writing a second
/// definition beside any of those makes the file invalid, and Codex would
/// refuse to start, so each is reported instead.
enum CodexConfigurationShape {
    static func obstacle(in text: String, keyPath: [String]) -> String? {
        guard let key = keyPath.last, keyPath.count >= 2 else { return nil }
        let table = Array(keyPath.dropLast())
        let target = keyPath
        let message = "config.toml already sets \(keyPath.joined(separator: ".")) in a form this app does not rewrite. Change it in Codex or by hand."
        var current: [String] = []
        var depth = 0
        var multilineQuote: String?
        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if let quote = multilineQuote {
                if line.components(separatedBy: quote).count % 2 == 0 { multilineQuote = nil }
                continue
            }
            if depth > 0 {
                depth += bracketBalance(line)
                continue
            }
            if line.isEmpty || line.hasPrefix("#") { continue }
            if TOMLTableScanner.isArrayTableHeader(line) {
                let inner = line.dropFirst(2).prefix { $0 != "]" }
                let path = TOMLTableScanner.dottedKey(String(inner)) ?? []
                if !path.isEmpty, target.starts(with: path) || path.starts(with: table) { return message }
                current = path
                continue
            }
            if let path = TOMLTableScanner.headerPath(line) {
                current = path
                // The same table spelled in a way the editor's own header
                // match (quotes removed, whitespace trimmed) does not see.
                if path == table, ClientConfigurationEditor.headerName(line) != table.joined(separator: ".") { return message }
                continue
            }
            guard let equals = assignmentSeparator(line) else { continue }
            let rawKey = String(line[line.startIndex..<equals]).trimmingCharacters(in: .whitespaces)
            let value = String(line[line.index(after: equals)...]).trimmingCharacters(in: .whitespaces)
            guard let keyParts = TOMLTableScanner.dottedKey(rawKey) else { continue }
            let full = current + keyParts
            if value.hasPrefix("\"\"\"") || value.hasPrefix("'''") {
                let quote = String(value.prefix(3))
                if value.components(separatedBy: quote).count == 2 { multilineQuote = quote }
            } else if value.hasPrefix("[") {
                depth = bracketBalance(value)
            }
            if current == table {
                // Under the right header: only a key the editor would not
                // recognise as the same key is a problem.
                if full == target, rawKey != key { return message }
                if keyParts.count > 1, target.starts(with: full) || full.starts(with: target) { return message }
                if keyParts.count == 1, full != target, target.starts(with: full), value.hasPrefix("{") { return message }
                continue
            }
            // Anywhere else: a definition of the key itself, of a table on
            // its path through an inline table, or of something inside the
            // table through a dotted key, all collide with a new header.
            if full == target { return message }
            if target.starts(with: full), value.hasPrefix("{") { return message }
            if full.count > table.count, full.starts(with: table), keyParts.count > 1 { return message }
        }
        return nil
    }

    /// The `=` that separates a key from its value, outside quotes.
    private static func assignmentSeparator(_ line: String) -> String.Index? {
        var quote: Character?
        var index = line.startIndex
        while index < line.endIndex {
            let character = line[index]
            if let open = quote {
                if character == open { quote = nil }
            } else if character == "\"" || character == "'" {
                quote = character
            } else if character == "=" {
                return index
            } else if character == "#" {
                return nil
            }
            index = line.index(after: index)
        }
        return nil
    }

    private static func bracketBalance(_ text: String) -> Int {
        var balance = 0
        var quote: Character?
        for character in text {
            if let open = quote {
                if character == open { quote = nil }
                continue
            }
            switch character {
            case "\"", "'": quote = character
            case "[": balance += 1
            case "]": balance -= 1
            case "#": return balance
            default: break
            }
        }
        return balance
    }
}
