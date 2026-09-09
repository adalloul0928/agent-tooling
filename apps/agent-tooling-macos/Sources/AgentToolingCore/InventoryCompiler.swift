import Foundation

struct ScannedInventory: Sendable {
    var skills: [Skill]
    var mcpServers: [MCPServer]
    var plugins: [Plugin]

}

enum InventoryCompiler {
    static func compile(observations: [TargetObservation], homeURL: URL, fileManager: FileManager = .default) -> ScannedInventory {
        var byClient: [ClientKind: [TargetObservation]] = [:]
        for observation in observations {
            if let client = observation.surface.client { byClient[client, default: []].append(observation) }
        }
        let allSkillIDs = Set(observations.flatMap(\.discoveredSkills))
        let allMCPIDs = Set(observations.flatMap(\.discoveredMCPServers))
        let allPluginIDs = Set(observations.flatMap(\.discoveredPlugins))

        let skills = allSkillIDs.sorted().map { id in
            let metadata = skillMetadata(id: id, observations: observations, homeURL: homeURL, fileManager: fileManager)
            return Skill(
                id: id,
                name: id,
                displayName: metadata.displayName,
                summary: metadata.summary,
                bundle: metadata.bundle,
                scope: "This Mac",
                owned: metadata.isManaged,
                triggers: [],
                negativeTrigger: "",
                files: metadata.files,
                clients: ClientKind.allCases.map { client in
                    state(for: id, in: byClient[client] ?? [], type: .skill, client: client)
                },
                validationCount: 0
            )
        }

        let mcpServers = allMCPIDs.sorted().map { id in
            let metadata = observations.compactMap { $0.mcpMetadata[id] }.first
            return MCPServer(
                id: id,
                name: displayName(for: id),
                summary: metadata.map { "Discovered from \($0.source). Authentication and live tool health remain separate checks." }
                    ?? "Discovered in local agent configuration. Authentication and live tool health are checked separately.",
                endpoint: metadata?.source ?? "Local configuration",
                transport: metadata?.transport.lowercased().contains("http") == true ? .http : .stdio,
                authentication: metadata?.authentication ?? "Not inferred",
                scope: "This Mac",
                clients: ClientKind.allCases.map { client in
                    state(for: id, in: byClient[client] ?? [], type: .mcpServer, client: client)
                }
            )
        }

        let plugins = allPluginIDs.sorted().map { id in
            let metadata = observations.compactMap { $0.pluginMetadata[id] }.first
            let targets = ClientKind.allCases.map { client in
                state(for: id, in: byClient[client] ?? [], type: .plugin, client: client)
            }
            return Plugin(
                id: id,
                name: metadata?.name ?? displayName(for: id),
                summary: metadata.map {
                    $0.source.hasPrefix("/") ? "Installed from a local plugin source." : "Installed through \($0.source)."
                } ?? "Discovered from local \(id) plugin or extension metadata.",
                source: metadata?.source ?? "Observed local client state",
                scope: metadata?.scope ?? "This Mac",
                revision: metadata?.revision ?? "Unknown",
                skills: metadata?.skillIDs ?? [],
                profiles: [],
                clients: targets,
                installed: true
            )
        }
        return ScannedInventory(skills: skills, mcpServers: mcpServers, plugins: plugins)
    }

    private enum InventoryItem { case skill, mcpServer, plugin }

    private static func state(for id: String, in observations: [TargetObservation], type: InventoryItem, client: ClientKind) -> ClientState
    {
        guard !observations.isEmpty else {
            return ClientState(client: client, state: .unavailable, detail: "Client not found", isInstalled: false)
        }
        let ordered = observations.sorted { $0.surface.displayName < $1.surface.displayName }
        let discoveries = ordered.filter { observation in
            switch type {
            case .skill: observation.discoveredSkills.contains(id)
            case .mcpServer: observation.discoveredMCPServers.contains(id)
            case .plugin: observation.discoveredPlugins.contains(id)
            }
        }
        if let observation = discoveries.first(where: { candidate in
            guard candidate.isCommandAvailable else { return false }
            switch type {
            case .skill: return true
            case .mcpServer: return candidate.mcpMetadata[id]?.enabled != false
            case .plugin: return candidate.pluginMetadata[id]?.enabled != false
            }
        }) {
            switch type {
            case .plugin:
                return ClientState(
                    client: client, state: .healthy, detail: "Installed and enabled",
                    revision: observation.pluginMetadata[id]?.revision ?? observation.version, isInstalled: true)
            case .mcpServer:
                return ClientState(client: client, state: .healthy, detail: "Configured", revision: observation.version, isInstalled: true)
            case .skill:
                return ClientState(client: client, state: .healthy, detail: "Available", revision: observation.version, isInstalled: true)
            }
        }
        if let observation = discoveries.first {
            let commandUnavailableDetail: String
            switch type {
            case .skill: commandUnavailableDetail = "Files found; CLI unavailable"
            case .mcpServer: commandUnavailableDetail = "Configured; CLI unavailable"
            case .plugin: commandUnavailableDetail = "Plugin data found; CLI unavailable"
            }
            if !observation.isCommandAvailable {
                return ClientState(
                    client: client, state: .pending, detail: commandUnavailableDetail, revision: observation.version, isInstalled: true)
            }
            switch type {
            case .plugin:
                if let metadata = observation.pluginMetadata[id], !metadata.enabled {
                    return ClientState(
                        client: client, state: .pending, detail: "Installed but disabled",
                        revision: metadata.revision ?? observation.version, isInstalled: true)
                }
                return ClientState(
                    client: client, state: .healthy, detail: "Installed and enabled",
                    revision: observation.pluginMetadata[id]?.revision ?? observation.version, isInstalled: true)
            case .mcpServer:
                if let metadata = observation.mcpMetadata[id], !metadata.enabled {
                    return ClientState(
                        client: client, state: .pending, detail: "Configured but disabled", revision: observation.version, isInstalled: true
                    )
                }
                return ClientState(client: client, state: .healthy, detail: "Configured", revision: observation.version, isInstalled: true)
            case .skill:
                return ClientState(client: client, state: .healthy, detail: "Available", revision: observation.version, isInstalled: true)
            }
        }
        if ordered.contains(where: \.isCommandAvailable) {
            return ClientState(
                client: client, state: .pending, detail: "Not installed", revision: ordered.compactMap(\.version).first, isInstalled: false)
        }
        if let observation = ordered.first(where: \.installed) {
            return ClientState(
                client: client,
                state: .unavailable,
                detail: "Configuration found; CLI unavailable",
                revision: observation.version,
                isInstalled: false
            )
        }
        return ClientState(
            client: client, state: .unavailable, detail: "CLI not found", revision: ordered.compactMap(\.version).first, isInstalled: false)
    }

    private static func skillMetadata(id: String, observations: [TargetObservation], homeURL: URL, fileManager: FileManager) -> (
        displayName: String, summary: String, bundle: String, files: [String], isManaged: Bool
    ) {
        for observation in observations {
            guard let observed = observation.skillMetadata[id] else { continue }
            let root = URL(fileURLWithPath: observed.path)
            let skillFile = root.appending(path: "SKILL.md")
            let content = (try? BoundedFileAccess.readUTF8(at: skillFile)) ?? ""
            let fallbackName = id.split(separator: ":").last.map(String.init) ?? id
            let frontmatter = try? SkillFrontmatter.parse(content)
            let name = boundedText(frontmatter?.name, maximum: 4_096, required: true) ?? fallbackName
            let summary = boundedText(frontmatter?.description, maximum: 65_536) ?? "Portable agent skill"
            return (
                displayName(for: name), summary, observed.providerPluginID ?? observed.source, childFiles(root, fileManager: fileManager),
                false
            )
        }
        let roots = [
            homeURL.appending(path: ".claude/skills/\(id)"),
            homeURL.appending(path: ".agents/skills/\(id)"),
            homeURL.appending(path: ".gemini/skills/\(id)"),
            homeURL.appending(path: ".gemini/extensions/\(id)/skills/\(id)"),
        ]
        for root in roots where fileManager.fileExists(atPath: root.path(percentEncoded: false)) {
            let skillFile = root.appending(path: "SKILL.md")
            let content = (try? BoundedFileAccess.readUTF8(at: skillFile)) ?? ""
            let frontmatter = try? SkillFrontmatter.parse(content)
            let name = boundedText(frontmatter?.name, maximum: 4_096, required: true) ?? id
            let summary = boundedText(frontmatter?.description, maximum: 65_536) ?? "Portable agent skill"
            let files = childFiles(root, fileManager: fileManager)
            return (displayName(for: name), summary, "Local installation", files, false)
        }
        return (displayName(for: id), "Portable agent skill", "Local installation", ["SKILL.md"], false)
    }

    private static func childFiles(_ root: URL, fileManager: FileManager) -> [String] {
        let files = BoundedFileAccess.relativeRegularFiles(under: root, fileManager: fileManager)
        let safeFiles = files.filter {
            $0.count <= 8_192 && !$0.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
        }
        return (safeFiles.isEmpty ? ["SKILL.md"] : safeFiles).sorted { lhs, rhs in
            if lhs == "SKILL.md" { return true }
            if rhs == "SKILL.md" { return false }
            return lhs < rhs
        }
    }

    private static func displayName(for value: String) -> String {
        value.split(whereSeparator: { $0 == "-" || $0 == "_" }).map(preferredToken).joined(separator: " ")
    }

    private static func preferredToken(_ token: Substring) -> String {
        switch token.lowercased() {
        case "mcp": return "MCP"
        case "cli": return "CLI"
        case "api": return "API"
        case "ios": return "iOS"
        case "pdf": return "PDF"
        case "github": return "GitHub"
        case "oauth": return "OAuth"
        case "repl": return "REPL"
        case "heroui": return "HeroUI"
        default: return token.capitalized
        }
    }

    private static func boundedText(_ value: String?, maximum: Int, required: Bool = false) -> String? {
        guard let value else { return nil }
        let redacted = SensitiveValueRedactor.redact(value)
        guard redacted.count <= maximum,
            !required || !redacted.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
            !redacted.unicodeScalars.contains(where: isUnsafeControlCharacter)
        else { return nil }
        return redacted
    }

    private static func isUnsafeControlCharacter(_ scalar: UnicodeScalar) -> Bool {
        scalar.value < 0x20 && ![0x09, 0x0A, 0x0D].contains(scalar.value)
    }

}

enum LocalTargetScan {
    static func perform(
        surface: TargetSurface,
        executable: String,
        configurationURLs: [URL],
        skillRoots: [URL],
        pluginRoots: [URL],
        capabilities: TargetCapabilities,
        runner: any CommandRunning
    ) async -> TargetObservation {
        let fileManager = FileManager.default
        async let commandProbe = probe(executable: executable, runner: runner)
        async let nativeInventory = nativeInventory(executable: executable, runner: runner)
        let existingConfig = configurationURLs.filter { fileManager.fileExists(atPath: $0.path(percentEncoded: false)) }
        var configurationDocuments: [String] = []
        var notes: [String] = []
        for configURL in existingConfig {
            do {
                configurationDocuments.append(
                    try BoundedFileAccess.readUTF8(at: configURL, maximumBytes: BoundedFileAccess.maximumConfigurationBytes))
            } catch {
                notes.append("Skipped \(configURL.lastPathComponent): \(error.localizedDescription)")
            }
        }
        let probe = await commandProbe
        let native = await nativeInventory
        var skillMetadata: [String: ObservedSkillMetadata] = [:]
        for root in skillRoots {
            skillMetadata.merge(skillRecords(under: root, source: "Standalone \(surface.displayName) skill", fileManager: fileManager)) {
                current, _ in current
            }
        }
        skillMetadata.merge(native.skillMetadata) { _, native in native }

        var pluginMetadata = native.pluginMetadata
        let configuredPlugins = configurationDocuments.flatMap(pluginNames(from:))
        for id in configuredPlugins where pluginMetadata[id] == nil {
            pluginMetadata[id] = ObservedPluginMetadata(
                name: displayName(forPluginID: id), source: "\(surface.displayName) configuration", scope: "This Mac", enabled: true)
        }
        if executable == "gemini" {
            for id in pluginRoots.flatMap({ childDirectories(under: $0, fileManager: fileManager) }) where pluginMetadata[id] == nil {
                pluginMetadata[id] = ObservedPluginMetadata(
                    name: displayName(forPluginID: id), source: "Gemini extension directory", scope: "This Mac", enabled: true)
            }
        }

        var mcpMetadata: [String: ObservedMCPMetadata] = [:]
        for document in configurationDocuments {
            mcpMetadata.merge(mcpRecords(from: document, source: "\(surface.displayName) configuration")) { current, _ in current }
        }
        mcpMetadata.merge(native.mcpMetadata) { _, native in native }
        let installed =
            probe.available || !existingConfig.isEmpty
            || skillRoots.contains {
                fileManager.fileExists(atPath: $0.path(percentEncoded: false))
            }
            || pluginRoots.contains {
                fileManager.fileExists(atPath: $0.path(percentEncoded: false))
            }
        if !probe.available { notes.append("The \(executable) CLI was not available on PATH; configuration was scanned from disk only.") }
        notes.append(contentsOf: native.notes)
        if surface.isCloud { notes.append("Cloud state is not inferred from local configuration.") }
        return TargetObservation(
            surface: surface,
            installed: installed,
            commandAvailable: probe.available,
            version: probe.version,
            configurationPaths: existingConfig.map { $0.path(percentEncoded: false) },
            discoveredSkills: skillMetadata.keys.sorted(),
            discoveredPlugins: pluginMetadata.keys.sorted(),
            discoveredMCPServers: mcpMetadata.keys.sorted(),
            skillMetadata: skillMetadata,
            pluginMetadata: pluginMetadata,
            mcpMetadata: mcpMetadata,
            capabilities: capabilities,
            notes: notes
        )
    }

    private struct NativeInventory {
        var skillMetadata: [String: ObservedSkillMetadata] = [:]
        var pluginMetadata: [String: ObservedPluginMetadata] = [:]
        var mcpMetadata: [String: ObservedMCPMetadata] = [:]
        var notes: [String] = []
    }

    private static func nativeInventory(executable: String, runner: any CommandRunning) async -> NativeInventory {
        let fileManager = FileManager.default
        switch executable {
        case "claude":
            guard
                let output = try? await runner.run(executable: executable, arguments: ["plugin", "list", "--json"], currentDirectory: nil),
                output.status == 0
            else {
                return NativeInventory(notes: ["Claude's native plugin inventory was unavailable; disk configuration was used instead."])
            }
            return claudeInventory(from: output.standardOutput, fileManager: fileManager)
        case "codex":
            async let pluginOutput = runner.run(
                executable: executable, arguments: ["plugin", "list", "--json"], currentDirectory: nil)
            async let mcpOutput = runner.run(executable: executable, arguments: ["mcp", "list", "--json"], currentDirectory: nil)
            var inventory = NativeInventory()
            if let output = try? await pluginOutput, output.status == 0 {
                inventory = codexPluginInventory(from: output.standardOutput, fileManager: fileManager)
            } else {
                inventory.notes.append("Codex's native plugin inventory was unavailable; config.toml was used instead.")
            }
            if let output = try? await mcpOutput, output.status == 0 {
                inventory.mcpMetadata.merge(codexMCPInventory(from: output.standardOutput)) { _, native in native }
            } else {
                inventory.notes.append("Codex's native MCP inventory was unavailable; config.toml was used instead.")
            }
            return inventory
        default:
            return NativeInventory()
        }
    }

    private static func claudeInventory(from text: String, fileManager: FileManager) -> NativeInventory {
        guard let data = text.data(using: .utf8), let entries = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            return NativeInventory()
        }
        var inventory = NativeInventory()
        for entry in entries.prefix(BoundedFileAccess.maximumDirectoryEntries) {
            guard let id = boundedIdentifier(entry["id"] as? String) else { continue }
            let name = displayName(forPluginID: id)
            let source = boundedText(entry["installPath"] as? String, maximum: 8_192) ?? "Claude plugin inventory"
            let scope = boundedText((entry["scope"] as? String)?.capitalized, maximum: 4_096) ?? "This Mac"
            let enabled = entry["enabled"] as? Bool ?? true
            let revision = boundedText(entry["version"] as? String, maximum: 4_096)
            let namespace = id.split(separator: "@").first.map(String.init) ?? id
            let skills =
                source.hasPrefix("/")
                ? skillRecords(
                    under: URL(fileURLWithPath: source), namespace: namespace, source: id, providerPluginID: id, fileManager: fileManager)
                : [:]
            inventory.skillMetadata.merge(skills) { current, _ in current }
            var mcpIDs: [String] = []
            if let servers = entry["mcpServers"] as? [String: Any] {
                for (rawServerID, value) in servers.prefix(BoundedFileAccess.maximumDirectoryEntries) {
                    guard let serverID = boundedIdentifier(rawServerID) else { continue }
                    mcpIDs.append(serverID)
                    inventory.mcpMetadata[serverID] = mcpMetadata(from: value, source: id)
                }
            }
            inventory.pluginMetadata[id] = ObservedPluginMetadata(
                name: name, source: source, scope: scope, revision: revision, enabled: enabled, skillIDs: skills.keys.sorted(),
                mcpServerIDs: mcpIDs.sorted())
        }
        return inventory
    }

    private static func codexPluginInventory(from text: String, fileManager: FileManager) -> NativeInventory {
        guard let data = text.data(using: .utf8), let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let entries = root["installed"] as? [[String: Any]]
        else { return NativeInventory() }
        var inventory = NativeInventory()
        for entry in entries.prefix(BoundedFileAccess.maximumDirectoryEntries) {
            guard let id = boundedIdentifier(entry["pluginId"] as? String) else { continue }
            let rawName =
                boundedText(entry["name"] as? String, maximum: 4_096, required: true)
                ?? id.split(separator: "@").first.map(String.init)
                ?? id
            let sourceObject = entry["source"] as? [String: Any]
            let source =
                boundedText(sourceObject?["path"] as? String, maximum: 8_192)
                ?? boundedText(sourceObject?["package"] as? String, maximum: 8_192)
                ?? "Codex plugin inventory"
            let enabled = entry["enabled"] as? Bool ?? true
            let revision = boundedText(entry["version"] as? String, maximum: 4_096)
            let skills =
                source.hasPrefix("/")
                ? skillRecords(
                    under: URL(fileURLWithPath: source), namespace: rawName, source: id, providerPluginID: id, fileManager: fileManager)
                : [:]
            inventory.skillMetadata.merge(skills) { current, _ in current }
            inventory.pluginMetadata[id] = ObservedPluginMetadata(
                name: displayName(forPluginID: rawName), source: source, scope: "This Mac", revision: revision, enabled: enabled,
                skillIDs: skills.keys.sorted())
        }
        return inventory
    }

    private static func codexMCPInventory(from text: String) -> [String: ObservedMCPMetadata] {
        guard let data = text.data(using: .utf8), let entries = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            return [:]
        }
        var result: [String: ObservedMCPMetadata] = [:]
        for entry in entries.prefix(BoundedFileAccess.maximumDirectoryEntries) {
            guard let id = boundedIdentifier(entry["name"] as? String) else { continue }
            let transport = boundedText((entry["transport"] as? [String: Any])?["type"] as? String, maximum: 4_096) ?? "stdio"
            let auth = boundedText(entry["auth_status"] as? String, maximum: 4_096) ?? "Not inferred"
            let enabled = entry["enabled"] as? Bool ?? true
            result[id] = ObservedMCPMetadata(
                transport: transport, authentication: auth.replacingOccurrences(of: "_", with: " ").capitalized,
                source: "Codex native MCP inventory", enabled: enabled)
        }
        return result
    }

    private static func skillRecords(
        under root: URL, namespace: String? = nil, source: String, providerPluginID: String? = nil, fileManager: FileManager
    ) -> [String: ObservedSkillMetadata] {
        var records: [String: ObservedSkillMetadata] = [:]
        for url in BoundedFileAccess.descendantDirectories(under: root, fileManager: fileManager) {
            guard BoundedFileAccess.isRegularFile(url.appending(path: "SKILL.md")) else { continue }
            let id = namespace.map { "\($0):\(url.lastPathComponent)" } ?? url.lastPathComponent
            guard boundedIdentifier(id) != nil else { continue }
            records[id] = ObservedSkillMetadata(path: url.path(percentEncoded: false), source: source, providerPluginID: providerPluginID)
        }
        return records
    }

    private struct CommandProbe {
        var available: Bool
        var version: String?
    }

    private static func probe(executable: String, runner: any CommandRunning) async -> CommandProbe {
        guard let output = try? await runner.run(executable: executable, arguments: ["--version"], currentDirectory: nil),
            output.status != 126,
            output.status != 127
        else {
            return CommandProbe(available: false, version: nil)
        }
        let value = (output.standardOutput.isEmpty ? output.standardError : output.standardOutput)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let version = output.status == 0 && !value.isEmpty ? value.components(separatedBy: "\n").first : nil
        return CommandProbe(available: true, version: version)
    }

    private static func childDirectories(under root: URL, fileManager: FileManager) -> [String] {
        guard
            let contents = try? fileManager.contentsOfDirectory(
                at: root,
                includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
                options: [.skipsHiddenFiles]
            )
        else { return [] }
        return contents.compactMap { url in
            guard let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]),
                values.isDirectory == true,
                values.isSymbolicLink != true
            else { return nil }
            return url.lastPathComponent
        }
    }

    private static func pluginNames(from configuration: String) -> [String] {
        var names: Set<String> = []
        if let data = configuration.data(using: .utf8), let root = try? JSONSerialization.jsonObject(with: data) {
            collectEnabledPluginNames(in: root, into: &names)
        }
        for path in TOMLTableScanner.tablePaths(in: configuration) {
            guard path.count == 2,
                path[0] == "plugins",
                !path[1].isEmpty
            else { continue }
            names.insert(path[1])
        }
        return names.sorted()
    }

    private static func collectEnabledPluginNames(in object: Any, into names: inout Set<String>) {
        var remainingNodes = 10_000
        collectEnabledPluginNames(in: object, depth: 0, remainingNodes: &remainingNodes, into: &names)
    }

    private static func collectEnabledPluginNames(in object: Any, depth: Int, remainingNodes: inout Int, into names: inout Set<String>) {
        guard depth <= 32, remainingNodes > 0 else { return }
        remainingNodes -= 1
        if let dictionary = object as? [String: Any] {
            if let plugins = dictionary["enabledPlugins"] as? [String: Any] {
                names.formUnion(plugins.keys.prefix(BoundedFileAccess.maximumDirectoryEntries).compactMap(boundedIdentifier))
            }
            for value in dictionary.values {
                collectEnabledPluginNames(in: value, depth: depth + 1, remainingNodes: &remainingNodes, into: &names)
            }
        } else if let array = object as? [Any] {
            for value in array { collectEnabledPluginNames(in: value, depth: depth + 1, remainingNodes: &remainingNodes, into: &names) }
        }
    }

    private static func mcpRecords(from configuration: String, source: String) -> [String: ObservedMCPMetadata] {
        var records: [String: ObservedMCPMetadata] = [:]
        if let data = configuration.data(using: .utf8),
            let root = try? JSONSerialization.jsonObject(with: data)
        {
            collectJSONMCPRecords(in: root, source: source, into: &records)
        }
        for path in TOMLTableScanner.tablePaths(in: configuration) {
            guard path.count == 2,
                ["mcp", "mcp_servers"].contains(path[0]), !path[1].isEmpty
            else { continue }
            records[path[1]] = ObservedMCPMetadata(transport: "stdio", authentication: "Not inferred", source: source)
        }
        return records
    }

    private static func collectJSONMCPRecords(in object: Any, source: String, into records: inout [String: ObservedMCPMetadata]) {
        var remainingNodes = 10_000
        collectJSONMCPRecords(in: object, source: source, depth: 0, remainingNodes: &remainingNodes, into: &records)
    }

    private static func collectJSONMCPRecords(
        in object: Any, source: String, depth: Int, remainingNodes: inout Int, into records: inout [String: ObservedMCPMetadata]
    ) {
        guard depth <= 32, remainingNodes > 0 else { return }
        remainingNodes -= 1
        if let dictionary = object as? [String: Any] {
            for key in ["mcpServers", "mcp_servers"] {
                if let servers = dictionary[key] as? [String: Any] {
                    for (rawID, value) in servers.prefix(BoundedFileAccess.maximumDirectoryEntries) {
                        guard let id = boundedIdentifier(rawID) else { continue }
                        records[id] = mcpMetadata(from: value, source: source)
                    }
                }
            }
            for value in dictionary.values {
                collectJSONMCPRecords(in: value, source: source, depth: depth + 1, remainingNodes: &remainingNodes, into: &records)
            }
        } else if let array = object as? [Any] {
            for value in array {
                collectJSONMCPRecords(in: value, source: source, depth: depth + 1, remainingNodes: &remainingNodes, into: &records)
            }
        }
    }

    private static func boundedIdentifier(_ value: String?) -> String? {
        guard let value,
            !value.isEmpty,
            value.count <= 256,
            !value.hasPrefix("-"),
            !value.contains("/"),
            !value.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
        else { return nil }
        return value
    }

    private static func boundedText(_ value: String?, maximum: Int, required: Bool = false) -> String? {
        guard let value else { return nil }
        let redacted = SensitiveValueRedactor.redact(value)
        guard redacted.count <= maximum,
            !required || !redacted.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
            !redacted.unicodeScalars.contains(where: isUnsafeControlCharacter)
        else { return nil }
        return redacted
    }

    private static func isUnsafeControlCharacter(_ scalar: UnicodeScalar) -> Bool {
        scalar.value < 0x20 && ![0x09, 0x0A, 0x0D].contains(scalar.value)
    }

    private static func mcpMetadata(from value: Any, source: String) -> ObservedMCPMetadata {
        let dictionary = value as? [String: Any]
        let declaredType = boundedText(dictionary?["type"] as? String, maximum: 4_096)
        let transport = declaredType ?? (dictionary?["url"] == nil ? "stdio" : "streamable_http")
        let authentication =
            boundedText(dictionary?["auth_status"] as? String, maximum: 4_096)
            ?? (dictionary?["url"] == nil ? "Not inferred" : "Account or OAuth")
        return ObservedMCPMetadata(
            transport: transport, authentication: authentication, source: source, enabled: dictionary?["enabled"] as? Bool ?? true)
    }

    private static func displayName(forPluginID id: String) -> String {
        let name = id.split(separator: "@").first.map(String.init) ?? id
        return name.split(whereSeparator: { $0 == "-" || $0 == "_" }).map { token in
            switch token.lowercased() {
            case "mcp": return "MCP"
            case "cli": return "CLI"
            case "api": return "API"
            case "ios": return "iOS"
            case "pdf": return "PDF"
            case "github": return "GitHub"
            case "oauth": return "OAuth"
            case "heroui": return "HeroUI"
            default: return token.capitalized
            }
        }.joined(separator: " ")
    }
}
