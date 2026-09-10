import Foundation

/// Federates packages from sources the user has explicitly added. The app never
/// treats a catalog listing as a trusted or authenticated installation.
public final class MarketplaceService {
    private enum Limit {
        static let catalogBytes = 2_097_152
        static let manifestBytes = 262_144
        static let skillBytes = 1_048_576
        static let licenseBytes = 262_144
        static let directoryEntries = 4_096
        static let traversalDepth = 32
        static let packageNameCharacters = 128
        static let summaryCharacters = 8_192
    }

    private struct ManifestInspection {
        var manifest: [String: Any]
        var diagnostics: [AgentPluginManifestDiagnostic]
        var rawManifestData: Data
    }

    private enum FixedLocation {
        case absent
        case regularFile(URL)
        case directory(URL)
        case invalid(String)
    }

    private struct SkillInspection {
        var directories: [URL]
        var conflicts: [PackageConflict]
    }

    private let fileManager: FileManager

    public init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    public func inspect(_ source: ToolingSource) throws -> [MarketplacePackage] {
        switch source.kind {
        case .localFolder, .gitRepository:
            return try inspectFolder(source)
        case .agentPlugins, .claudeMarketplace, .openAIPluginDirectory, .geminiExtensionGallery, .mcpRegistry:
            // Vendor listings are intentionally represented as sources rather
            // than copied packages. Native CLIs remain the install authority.
            return []
        }
    }

    public func defaultSources() -> [ToolingSource] {
        [
            ToolingSource(
                name: "Agent Plugins format", kind: .agentPlugins, location: "https://agent-plugins.org",
                trustSummary: "Portable package format — add a local folder or Git checkout to inspect packages"),
            ToolingSource(
                name: "Claude marketplaces", kind: .claudeMarketplace, location: "https://code.claude.com/docs/en/discover-plugins",
                trustSummary: "Use Claude's native installer and marketplace provenance"),
            ToolingSource(
                name: "OpenAI plugin directory", kind: .openAIPluginDirectory, location: "https://developers.openai.com/codex/plugins",
                trustSummary: "Use Codex's native installer and configured marketplace provenance"),
            ToolingSource(
                name: "Gemini extensions", kind: .geminiExtensionGallery, location: "https://geminicli.com/extensions/",
                trustSummary: "Use Gemini CLI's native extension installer and explicit user or workspace scope"),
            ToolingSource(
                name: "MCP Registry", kind: .mcpRegistry, location: "https://registry.modelcontextprotocol.io",
                trustSummary: "Server metadata only; credentials and target bindings are reviewed separately"),
        ]
    }

    /// Queries only the documented, machine-readable local catalogs that each
    /// installed client exposes. No third-party web page is scraped or treated
    /// as an installer. Gemini's gallery has no equivalent local JSON catalog,
    /// so it remains a source link while installed extensions are discovered by
    /// the target scanner.
    public static func discoverNativeCatalogs(
        runner: any CommandRunning, clients: Set<ClientKind> = Set(ClientKind.allCases)
    ) async -> NativeCatalogDiscovery {
        let service = MarketplaceService()
        var packages: [MarketplacePackage] = []
        var notes: [ClientKind: String] = [:]
        var outcomes: [ClientKind: NativeCatalogClientOutcome] = [
            .claude: clients.contains(.claude) ? .incomplete : .excluded,
            .codex: clients.contains(.codex) ? .incomplete : .excluded,
        ]
        for client in [ClientKind.claude, .codex] where clients.contains(client) {
            do {
                let result = try await runner.run(
                    executable: client == .claude ? "claude" : "codex",
                    arguments: ["plugin", "list", "--available", "--json"], currentDirectory: nil)
                guard result.status == 0 else { throw NativeCatalogError.commandFailed(client.rawValue, result.standardError) }
                let truncated = result.standardOutput.contains("[output truncated")
                guard !truncated || client == .codex else {
                    throw NativeCatalogError.incompleteResponse(client.rawValue)
                }
                let complete = !truncated && (client == .claude
                    ? service.isCompleteClaudeCatalogJSON(result.standardOutput)
                    : service.isCompleteCodexCatalogJSON(result.standardOutput))
                var found =
                    client == .claude
                    ? service.packagesFromClaudeCatalogJSON(result.standardOutput)
                    : service.packagesFromCodexCatalogJSON(result.standardOutput)
                // Large Codex catalogs exceed the bounded command output. Query
                // installed marketplace names separately instead of parsing partial JSON.
                if client == .codex && result.standardOutput.contains("[output truncated") {
                    let installed = try await runner.run(
                        executable: "codex", arguments: ["plugin", "list", "--json"], currentDirectory: nil)
                    guard installed.status == 0,
                        let data = installed.standardOutput.data(using: .utf8),
                        data.count <= Limit.catalogBytes,
                        let document = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                        let entries = document["installed"] as? [[String: Any]],
                        entries.count <= Limit.directoryEntries
                    else { throw NativeCatalogError.commandFailed(client.rawValue, "Installed plugin inventory unavailable") }
                    let marketplaceValues = entries.map { entry -> String? in
                        guard let id = entry["pluginId"] as? String,
                              let name = id.split(separator: "@").last, id.contains("@"),
                              !name.isEmpty, name.allSatisfy({ $0.isLetter || $0.isNumber || "-_.".contains($0) })
                        else { return nil }
                        return String(name)
                    }
                    guard marketplaceValues.allSatisfy({ $0 != nil }) else {
                        throw NativeCatalogError.incompleteResponse(client.rawValue)
                    }
                    let marketplaces = Set(marketplaceValues.compactMap { $0 })
                    found = []
                    for marketplace in marketplaces.sorted().prefix(32) {
                        let page = try await runner.run(
                            executable: "codex",
                            arguments: ["plugin", "list", "--marketplace", marketplace, "--available", "--json"],
                            currentDirectory: nil)
                        guard page.status == 0,
                              !page.standardOutput.contains("[output truncated"),
                              service.isCompleteCodexCatalogJSON(page.standardOutput) else {
                            continue
                        }
                        found += service.packagesFromCodexCatalogJSON(page.standardOutput)
                    }
                    // Installed marketplace names cannot prove the global
                    // available catalog is complete. Overlay successful pages,
                    // but retain all unmatched cached Codex rows.
                    packages.append(contentsOf: found)
                    outcomes[client] = .incomplete
                    notes[client] = "\(client.rawValue) catalog response was incomplete; cached entries were retained"
                    continue
                }
                packages.append(contentsOf: found)
                outcomes[client] = complete ? .complete : .incomplete
                notes[client] = complete
                    ? "\(found.count) plugins reported by \(client.rawValue)"
                    : "\(client.rawValue) catalog response was incomplete; cached entries were retained"
            } catch {
                outcomes[client] = .incomplete
                notes[client] = "\(client.rawValue) catalog unavailable: \(service.safeDiagnostic(error))"
            }
        }
        return NativeCatalogDiscovery(
            packages: service.deduplicatedPackages(packages), notes: notes, outcomes: outcomes)
    }

    func packagesFromCodexCatalogJSON(_ text: String) -> [MarketplacePackage] {
        guard let root = jsonDictionary(from: text) else { return [] }
        let sections = [("installed", true), ("available", false)]
        let packages = sections.flatMap { section, installed in
            let entries = root[section] as? [[String: Any]] ?? []
            return entries.compactMap { entry -> MarketplacePackage? in
                guard let pluginID = safeCatalogIdentifier(string("pluginId", in: entry) ?? string("id", in: entry)) else { return nil }
                let name =
                    string("name", in: entry, maximumCharacters: Limit.packageNameCharacters)
                    ?? pluginID.split(separator: "@").first.map(String.init)
                    ?? pluginID
                let marketplace = string("marketplaceName", in: entry, maximumCharacters: Limit.packageNameCharacters) ?? "Codex"
                let revision = string("version", in: entry, maximumCharacters: 256)
                let source =
                    nestedString("path", under: "source", in: entry)
                    ?? nestedString("package", under: "source", in: entry)
                    ?? nestedString("source", under: "source", in: entry)
                    ?? nestedString("source", under: "marketplaceSource", in: entry)
                    ?? pluginID
                let auth = string("authPolicy", in: entry, maximumCharacters: 256)
                return MarketplacePackage(
                    id: "codex:\(pluginID)",
                    name: name,
                    publisher: marketplace,
                    summary: installed ? MarketplaceCopy.installedCodexPlugin : MarketplaceCopy.availableCodexPlugin,
                    sourceName: marketplace,
                    revision: revision,
                    components: [.plugin],
                    supportedClients: [.codex],
                    authentication: auth,
                    trustSummary: "Native Codex catalog metadata — review the source and install policy before installing.",
                    location: source,
                    isInstalled: installed,
                    nativeInstalls: [
                        NativeInstall(
                            client: .codex, executable: "codex", arguments: ["plugin", "add", pluginID],
                            removalArguments: ["plugin", "remove", pluginID],
                            detail: "Install this exact plugin identifier from Codex's configured marketplace.", isInstalled: installed)
                    ]
                )
            }
        }
        return deduplicatedPackages(packages)
    }

    private func isCompleteCodexCatalogJSON(_ text: String) -> Bool {
        guard let root = jsonDictionary(from: text),
              root["error"] == nil, root["errors"] == nil,
              root["installed"] != nil, root["available"] != nil else { return false }
        var count = 0
        for key in ["installed", "available"] where root[key] != nil {
            guard let entries = root[key] as? [[String: Any]], entries.allSatisfy({ entry in
                safeCatalogIdentifier(string("pluginId", in: entry) ?? string("id", in: entry)) != nil
            }) else { return false }
            count += entries.count
            guard count <= Limit.directoryEntries else { return false }
        }
        return true
    }

    func packagesFromClaudeCatalogJSON(_ text: String) -> [MarketplacePackage] {
        guard let root = jsonObject(from: text) else { return [] }
        let entries = pluginObjects(in: root)
        let packages = entries.compactMap { entry -> MarketplacePackage? in
            let name = safeCatalogIdentifier(string("name", in: entry) ?? string("pluginName", in: entry) ?? string("pluginId", in: entry))
            let marketplace =
                (string("marketplace", in: entry, maximumCharacters: Limit.packageNameCharacters)
                ?? string("marketplaceName", in: entry, maximumCharacters: Limit.packageNameCharacters)
                ?? string("source", in: entry, maximumCharacters: Limit.packageNameCharacters)).flatMap { boundedCatalogName($0) }
            guard let name else { return nil }
            let rawPluginID = name.contains("@") ? name : marketplace.map { "\(name)@\($0)" } ?? name
            guard let pluginID = safeCatalogIdentifier(rawPluginID) else { return nil }
            let installed = (entry["installed"] as? Bool) ?? false
            let source = nestedString("path", under: "source", in: entry) ?? string("source", in: entry) ?? pluginID
            return MarketplacePackage(
                id: "claude:\(pluginID)",
                name: name.split(separator: "@").first.map(String.init) ?? name,
                publisher: marketplace.flatMap { boundedCatalogName($0) } ?? "Claude marketplace",
                summary: string("description", in: entry, maximumCharacters: Limit.summaryCharacters, allowLineBreaks: true)
                    ?? (installed ? MarketplaceCopy.installedClaudePlugin : MarketplaceCopy.availableClaudePlugin),
                sourceName: marketplace ?? "Claude marketplace",
                revision: string("version", in: entry, maximumCharacters: 256),
                components: [.plugin],
                supportedClients: [.claude],
                trustSummary: "Native Claude Code catalog metadata — review the source and permissions before installing.",
                location: source,
                isInstalled: installed,
                nativeInstalls: [
                    NativeInstall(
                        client: .claude, executable: "claude", arguments: ["plugin", "install", pluginID, "--scope", "user"],
                        removalArguments: ["plugin", "uninstall", pluginID, "--scope", "user"],
                        detail:
                            "Install this exact plugin identifier through Claude Code's configured marketplace at the \(ToolingScope.user.marketplaceInstallTitle) scope.",
                        isInstalled: installed)
                ]
            )
        }
        return deduplicatedPackages(packages)
    }

    private func isCompleteClaudeCatalogJSON(_ text: String) -> Bool {
        guard let root = jsonObject(from: text), catalogTreeIsBounded(root) else { return false }
        let entries: [[String: Any]]
        if let array = root as? [Any] {
            guard array.count <= Limit.directoryEntries,
                  let typed = array as? [[String: Any]], typed.count == array.count else { return false }
            entries = typed
        } else if let dictionary = root as? [String: Any] {
            guard dictionary["error"] == nil, dictionary["errors"] == nil else { return false }
            let knownKeys = ["plugins", "installed", "available"].filter { dictionary[$0] != nil }
            guard !knownKeys.isEmpty else { return false }
            var values: [[String: Any]] = []
            for key in knownKeys {
                guard let raw = dictionary[key] as? [Any],
                      let typed = raw as? [[String: Any]], typed.count == raw.count,
                      values.count + typed.count <= Limit.directoryEntries else { return false }
                values += typed
            }
            entries = values
        } else {
            return false
        }
        guard pluginObjects(in: root).count == entries.count else { return false }
        return entries.allSatisfy { entry in
            let isCandidate = entry["pluginName"] is String || entry["pluginId"] is String
                || (entry["name"] is String && ["installed", "enabled", "version", "installPath", "scope", "description"]
                    .contains { entry[$0] != nil })
            guard isCandidate else { return false }
            let name = safeCatalogIdentifier(
                string("name", in: entry) ?? string("pluginName", in: entry) ?? string("pluginId", in: entry))
            let marketplace =
                (string("marketplace", in: entry, maximumCharacters: Limit.packageNameCharacters)
                ?? string("marketplaceName", in: entry, maximumCharacters: Limit.packageNameCharacters)
                ?? string("source", in: entry, maximumCharacters: Limit.packageNameCharacters))
                .flatMap { boundedCatalogName($0) }
            guard let name else { return false }
            let rawPluginID = name.contains("@") ? name : marketplace.map { "\(name)@\($0)" } ?? name
            return safeCatalogIdentifier(rawPluginID) != nil
        }
    }

    private func catalogTreeIsBounded(_ root: Any) -> Bool {
        var remaining = Limit.directoryEntries
        func visit(_ value: Any, depth: Int) -> Bool {
            guard depth <= Limit.traversalDepth, remaining > 0 else { return false }
            remaining -= 1
            if let dictionary = value as? [String: Any] {
                return dictionary.values.allSatisfy { visit($0, depth: depth + 1) }
            }
            if let array = value as? [Any] {
                return array.allSatisfy { visit($0, depth: depth + 1) }
            }
            return true
        }
        return visit(root, depth: 0)
    }

    private func inspectFolder(_ source: ToolingSource) throws -> [MarketplacePackage] {
        let selectedRoot = URL(fileURLWithPath: source.location).standardizedFileURL
        guard fileManager.fileExists(atPath: selectedRoot.path(percentEncoded: false)) else {
            throw MarketplaceError.missingSource(source.location)
        }
        let directValues = try selectedRoot.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard directValues.isDirectory == true, directValues.isSymbolicLink != true else {
            throw MarketplaceError.invalidSource(source.location)
        }
        let root = selectedRoot.resolvingSymlinksInPath().standardizedFileURL
        guard try isDirectory(root) else { throw MarketplaceError.invalidSource(source.location) }
        let candidates = try packageCandidates(root: root)
        return try candidates.compactMap { candidate in
            try inspectPackage(at: candidate, source: source)
        }.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    private func jsonObject(from text: String) -> Any? {
        guard let data = text.data(using: .utf8), data.count <= Limit.catalogBytes else { return nil }
        return try? JSONSerialization.jsonObject(with: data)
    }

    private func safeDiagnostic(_ error: any Error) -> String {
        let redacted = SensitiveValueRedactor.redact(error.localizedDescription)
        return String(redacted.prefix(1_024))
    }

    private func jsonDictionary(from text: String) -> [String: Any]? {
        jsonObject(from: text) as? [String: Any]
    }

    private func pluginObjects(in object: Any) -> [[String: Any]] {
        var remaining = Limit.directoryEntries
        return pluginObjects(in: object, depth: 0, remaining: &remaining)
    }

    private func pluginObjects(in object: Any, depth: Int, remaining: inout Int) -> [[String: Any]] {
        guard depth <= Limit.traversalDepth, remaining > 0 else { return [] }
        remaining -= 1
        switch object {
        case let dictionary as [String: Any]:
            let hasIdentifier =
                dictionary["pluginName"] is String
                || dictionary["pluginId"] is String
            let hasPluginMetadata = ["installed", "enabled", "version", "installPath", "scope", "description"]
                .contains { dictionary[$0] != nil }
            let isCandidate = hasIdentifier || (dictionary["name"] is String && hasPluginMetadata)
            let nested = dictionary.values.flatMap { pluginObjects(in: $0, depth: depth + 1, remaining: &remaining) }
            return (isCandidate ? [dictionary] : []) + nested
        case let array as [Any]:
            return array.flatMap { pluginObjects(in: $0, depth: depth + 1, remaining: &remaining) }
        default:
            return []
        }
    }

    private func string(
        _ key: String,
        in dictionary: [String: Any],
        maximumCharacters: Int = Limit.summaryCharacters,
        allowLineBreaks: Bool = false
    ) -> String? {
        if let value = dictionary[key] as? String {
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty, trimmed.count <= maximumCharacters,
                !trimmed.unicodeScalars.contains(where: { scalar in
                    allowLineBreaks
                        ? scalar.value < 0x20 && ![0x09, 0x0A, 0x0D].contains(scalar.value)
                        : CharacterSet.controlCharacters.contains(scalar)
                })
            {
                return SensitiveValueRedactor.redact(trimmed)
            }
        }
        if let value = dictionary[key] as? NSNumber, value.stringValue.count <= maximumCharacters {
            return value.stringValue
        }
        return nil
    }

    private func safeCatalogIdentifier(_ rawValue: String?) -> String? {
        guard let value = rawValue?.trimmingCharacters(in: .whitespacesAndNewlines),
            !value.isEmpty,
            value.count <= Limit.packageNameCharacters,
            !value.hasPrefix("-"),
            value.unicodeScalars.allSatisfy({ scalar in
                CharacterSet.alphanumerics.contains(scalar) || "._-@".unicodeScalars.contains(scalar)
            })
        else { return nil }
        return value
    }

    private func boundedCatalogName(_ rawValue: String) -> String? {
        let value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty,
            value.count <= Limit.packageNameCharacters,
            !value.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
        else { return nil }
        return value
    }

    public func deduplicatedPackages(_ packages: [MarketplacePackage]) -> [MarketplacePackage] {
        var packagesByID: [String: MarketplacePackage] = [:]
        for package in packages.sorted(by: Self.packageSort) {
            guard let current = packagesByID[package.id] else {
                packagesByID[package.id] = package
                continue
            }
            packagesByID[package.id] = merge(current, with: package)
        }
        return packagesByID.values.sorted(by: Self.packageSort)
    }

    private func merge(_ current: MarketplacePackage, with candidate: MarketplacePackage) -> MarketplacePackage {
        var merged = current
        let preferred = candidate.isInstalled && !current.isInstalled ? candidate : current
        merged.name = preferred.name
        merged.publisher = preferred.publisher
        merged.summary = preferred.summary
        merged.sourceID = preferred.sourceID ?? current.sourceID ?? candidate.sourceID
        merged.sourceName = preferred.sourceName
        merged.revision = preferred.revision ?? current.revision ?? candidate.revision
        merged.license = preferred.license ?? current.license ?? candidate.license
        merged.components.formUnion(candidate.components)
        merged.supportedClients.formUnion(candidate.supportedClients)
        merged.authentication = preferred.authentication ?? current.authentication ?? candidate.authentication
        merged.hasExecutableContent = current.hasExecutableContent || candidate.hasExecutableContent
        merged.trustSummary = preferred.trustSummary
        merged.location = preferred.location
        merged.isInstalled = current.isInstalled || candidate.isInstalled
        // Two catalogs can describe the same package. Keep the newer update
        // record and the tool list that actually exists, never an empty one.
        merged.lastUpdate = [current.lastUpdate, candidate.lastUpdate].compactMap { $0 }.max { $0.date < $1.date }
        merged.tools = preferred.tools ?? current.tools ?? candidate.tools

        var routesByID = Dictionary(uniqueKeysWithValues: current.nativeInstalls.map { ($0.id, $0) })
        for route in candidate.nativeInstalls {
            if var existing = routesByID[route.id] {
                let installed = (existing.isInstalled == true) || (route.isInstalled == true)
                if route.isInstalled == true { existing = route }
                existing.isInstalled = installed
                routesByID[route.id] = existing
            } else {
                routesByID[route.id] = route
            }
        }
        merged.nativeInstalls = routesByID.values.sorted {
            if $0.client != $1.client { return $0.client.rawValue < $1.client.rawValue }
            return $0.id < $1.id
        }
        return merged
    }

    private static func packageSort(_ lhs: MarketplacePackage, _ rhs: MarketplacePackage) -> Bool {
        let nameOrder = lhs.name.localizedCaseInsensitiveCompare(rhs.name)
        if nameOrder != .orderedSame { return nameOrder == .orderedAscending }
        if lhs.id != rhs.id { return lhs.id < rhs.id }
        return lhs.isInstalled && !rhs.isInstalled
    }

    private func nestedString(_ key: String, under parent: String, in dictionary: [String: Any]) -> String? {
        guard let nested = dictionary[parent] as? [String: Any] else { return nil }
        return string(key, in: nested)
    }

    private func packageCandidates(root: URL) throws -> [URL] {
        var candidates: Set<URL> = []
        let directFiles = ["plugin.json", ".claude-plugin/plugin.json", ".codex-plugin/plugin.json", "SKILL.md"]
        if try directFiles.contains(where: { try regularFile(root.appending(path: $0), within: root) != nil }) {
            candidates.insert(root)
        }
        let skillsRoot = root.appending(path: "skills", directoryHint: .isDirectory)
        if let resolvedSkillsRoot = try directory(skillsRoot, within: root),
            try directoryEntries(at: resolvedSkillsRoot).contains(where: { entry in
                guard let skillDirectory = try directory(entry, within: root) else { return false }
                return try regularFile(skillDirectory.appending(path: "SKILL.md"), within: root) != nil
            })
        {
            candidates.insert(root)
        }
        let pluginRoot = root.appending(path: "plugins", directoryHint: .isDirectory)
        if let resolvedPluginRoot = try directory(pluginRoot, within: root) {
            for entry in try directoryEntries(at: resolvedPluginRoot) {
                if let pluginDirectory = try directory(entry, within: root) {
                    candidates.insert(pluginDirectory)
                }
            }
        }
        return candidates.sorted { $0.path(percentEncoded: false) < $1.path(percentEncoded: false) }
    }

    private func inspectPackage(at root: URL, source: ToolingSource) throws -> MarketplacePackage? {
        let packageRoot = root.resolvingSymlinksInPath().standardizedFileURL
        guard try isDirectory(packageRoot) else { throw MarketplaceError.invalidPackage(root.path(percentEncoded: false)) }

        let portableManifestLocation = fixedLocation(packageRoot.appending(path: "plugin.json"), within: packageRoot)
        let portableManifestURL: URL?
        switch portableManifestLocation {
        case .absent: portableManifestURL = nil
        case .regularFile(let url): portableManifestURL = url
        case .directory, .invalid:
            throw MarketplaceError.invalidManifest(packageRoot.appending(path: "plugin.json").path(percentEncoded: false), "plugin.json must be a regular file inside the package.")
        }
        let claudeManifestURL = try regularFile(packageRoot.appending(path: ".claude-plugin/plugin.json"), within: packageRoot)
        let codexManifestURL = try regularFile(packageRoot.appending(path: ".codex-plugin/plugin.json"), within: packageRoot)
        let manifestURL = portableManifestURL ?? claudeManifestURL ?? codexManifestURL
        let manifestInspection: ManifestInspection?
        if let manifestURL {
            let isPortableManifest = portableManifestURL == manifestURL
            manifestInspection = try self.manifest(at: manifestURL, portable: isPortableManifest)
        } else {
            manifestInspection = nil
        }
        let manifest = manifestInspection?.manifest

        let skills = try validSkillDirectories(at: packageRoot)
        let skillDirectories = skills.directories
        let skillNames = skillDirectories.map(\.lastPathComponent)
        let rootSkillURL = try regularFile(packageRoot.appending(path: "SKILL.md"), within: packageRoot)
        let rootIsSkill: Bool
        if let rootSkillURL {
            rootIsSkill = try validSkill(at: rootSkillURL, expectedName: packageRoot.lastPathComponent)
        } else {
            rootIsSkill = false
        }
        guard manifest != nil || !skillNames.isEmpty || rootIsSkill else { return nil }

        let manifestName = manifest?["name"] as? String
        let rawName = try packageName(manifestName ?? packageRoot.lastPathComponent)
        let rootSkillDescription: String?
        if let rootSkillURL {
            rootSkillDescription = try skillDescription(at: rootSkillURL)
        } else {
            rootSkillDescription = nil
        }
        let manifestDescriptionValue = manifest?["description"] as? String
        let manifestDescription = boundedSummary(manifestDescriptionValue)
        let skillCount = skillNames.count + (rootIsSkill ? 1 : 0)
        let fallbackDescription = "\(MarketplaceCopy.localPackagePrefix)\(skillCount) skill\(skillCount == 1 ? "" : "s")."
        let description = manifestDescription ?? rootSkillDescription ?? fallbackDescription
        var components: Set<ComponentKind> = []
        if !skillNames.isEmpty || rootIsSkill { components.insert(.skill) }
        let portableMCPLocation = fixedLocation(packageRoot.appending(path: "mcp.json"), within: packageRoot)
        let portableMCPURL: URL?
        var componentConflicts = skills.conflicts
        switch portableMCPLocation {
        case .absent: portableMCPURL = nil
        case .regularFile(let url): portableMCPURL = url
        case .directory, .invalid:
            portableMCPURL = nil
            componentConflicts.append(PackageConflict(id: "mcp:location", summary: "mcp.json: invalid component location."))
        }
        let portableMCP: AgentPluginMCPLoadResult?
        do {
            if let portableMCPURL {
                let mcpData = try readData(at: portableMCPURL, maximumBytes: Limit.manifestBytes)
                portableMCP = try AgentPluginMCPConfigurationLoader.load(mcpData, packageRoot: packageRoot)
            } else {
                portableMCP = nil
            }
        } catch {
            portableMCP = nil
            let summary: String
            if portableManifestURL != nil,
                let mcpError = error as? AgentPluginMCPValidationError,
                case .unsupportedSchema = mcpError
            {
                summary = "mcp.json: schema version does not match plugin.json."
            } else {
                summary = "mcp.json: invalid component configuration."
            }
            componentConflicts.append(PackageConflict(id: "mcp:configuration", summary: summary))
        }
        let hasLegacyMCP = try regularFile(packageRoot.appending(path: ".mcp.json"), within: packageRoot) != nil
        let hasMCP = !(portableMCP?.servers.isEmpty ?? true) || hasLegacyMCP
        if hasMCP { components.insert(.mcpServer) }
        if try directory(packageRoot.appending(path: "agents"), within: packageRoot) != nil { components.insert(.agent) }
        if try directory(packageRoot.appending(path: "commands"), within: packageRoot) != nil { components.insert(.command) }
        if try directory(packageRoot.appending(path: "hooks"), within: packageRoot) != nil { components.insert(.hook) }
        if manifest != nil { components.insert(.plugin) }
        let executable = try hasActiveContent(at: packageRoot, skillDirectories: skillDirectories, manifest: manifest, hasMCP: hasMCP)
        let packageLicense: String?
        let manifestLicenseValue = manifest?["license"] as? String
        if let manifestLicense = boundedSummary(manifestLicenseValue) {
            packageLicense = manifestLicense
        } else {
            packageLicense = try license(at: packageRoot)
        }
        let portableMCPConflicts = portableMCP?.issues.map {
            PackageConflict(id: "mcp:\($0.serverName)", summary: "\($0.serverName): \($0.message)")
        } ?? []
        let manifestConflicts = (manifestInspection?.diagnostics ?? []).enumerated().map { index, diagnostic in
            PackageConflict(id: "manifest:\(index)", summary: manifestDiagnosticSummary(diagnostic))
        }
        let packageConflicts = portableMCPConflicts + manifestConflicts + componentConflicts
        let lastUpdate = localUpdateRecord(
            root: packageRoot,
            files: [manifestURL, rootSkillURL, portableMCPURL] + skillDirectories.map { $0.appending(path: "SKILL.md") }
        )
        return MarketplacePackage(
            id: "\(source.id.uuidString):\(rawName)",
            name: rawName,
            publisher: source.name,
            summary: description,
            sourceID: source.id,
            sourceName: source.name,
            revision: source.lastRevision,
            license: packageLicense,
            components: components,
            supportedClients: try supportedClients(
                at: packageRoot, hasPortableManifest: portableManifestURL != nil, hasPortableSkill: !skillNames.isEmpty || rootIsSkill),
            hasExecutableContent: executable,
            trustSummary: !portableMCPConflicts.isEmpty
                ? "Review invalid portable MCP entries before installing"
                : !(manifestConflicts + componentConflicts).isEmpty
                    ? "Review manifest warnings before installing"
                : executable
                    ? "Review scripts, hooks, and permissions before installing" : "Review manifest and license before installing",
            location: packageRoot.path(percentEncoded: false),
            conflicts: packageConflicts.isEmpty ? nil : packageConflicts,
            lastUpdate: lastUpdate
        )
    }

    /// The newest modification time among the files this inspection actually
    /// read. It is a fact about this Mac — not a claim about a release — so it
    /// travels with its origin and is labeled that way wherever it is shown.
    private func localUpdateRecord(root: URL, files: [URL?]) -> PackageUpdateRecord? {
        let candidates = [root] + files.compactMap { $0 }
        let dates = candidates.compactMap { url -> Date? in
            try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
        }
        guard let newest = dates.max() else { return nil }
        return PackageUpdateRecord(date: newest, origin: .localFiles)
    }

    private func supportedClients(at root: URL, hasPortableManifest: Bool, hasPortableSkill: Bool) throws -> Set<ClientKind> {
        var clients: Set<ClientKind> = []
        if try directory(root.appending(path: ".claude-plugin"), within: root) != nil { clients.insert(.claude) }
        if try directory(root.appending(path: ".codex-plugin"), within: root) != nil { clients.insert(.codex) }
        if try regularFile(root.appending(path: "gemini-extension.json"), within: root) != nil { clients.insert(.gemini) }
        if hasPortableManifest || (clients.isEmpty && hasPortableSkill) {
            clients.formUnion(ClientKind.allCases)
        }
        return clients
    }

    private func skillDescription(at url: URL) throws -> String? {
        let contents = try readString(at: url, maximumBytes: Limit.skillBytes)
        for line in contents.split(separator: "\n") where line.hasPrefix("description:") {
            return boundedSummary(
                line.dropFirst("description:".count).trimmingCharacters(in: .whitespaces).trimmingCharacters(
                    in: CharacterSet(charactersIn: "\"'")))
        }
        return nil
    }

    private func license(at root: URL) throws -> String? {
        let names = ["LICENSE", "LICENSE.md", "LICENSE.txt"]
        for name in names {
            if let url = try regularFile(root.appending(path: name), within: root) {
                return try readString(at: url, maximumBytes: Limit.licenseBytes)
                    .split(separator: "\n")
                    .first
                    .map(String.init)?
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        return nil
    }

    private func manifest(at url: URL, portable: Bool) throws -> ManifestInspection {
        let data = try readData(at: url, maximumBytes: Limit.manifestBytes)
        if portable {
            do {
                let result = try AgentPluginManifest.load(data)
                return ManifestInspection(
                    manifest: portableManifestMetadata(result),
                    diagnostics: result.diagnostics,
                    rawManifestData: result.rawManifestData
                )
            } catch {
                throw MarketplaceError.invalidManifest(
                    url.path(percentEncoded: false),
                    error.localizedDescription
                )
            }
        }
        guard let object = try? JSONSerialization.jsonObject(with: data),
            let manifest = object as? [String: Any]
        else {
            throw MarketplaceError.invalidManifest(url.path(percentEncoded: false), "The file must contain one JSON object.")
        }
        if !portable, manifest["name"] != nil, safeCatalogIdentifier(manifest["name"] as? String) == nil {
            throw MarketplaceError.invalidManifest(url.path(percentEncoded: false), "The name is not a safe package identifier.")
        }
        return ManifestInspection(manifest: manifest, diagnostics: [], rawManifestData: data)
    }

    /// Portable manifest fields are a safe metadata projection. Unknown root
    /// values and opaque extension values remain in rawManifestData only.
    private func portableManifestMetadata(_ result: AgentPluginManifestLoadResult) -> [String: Any] {
        let manifest = result.manifest
        var metadata: [String: Any] = ["$schema": manifest.schema, "name": manifest.name]
        if let value = manifest.version { metadata["version"] = value }
        if let value = manifest.description { metadata["description"] = value }
        if let author = manifest.author {
            var authorMetadata: [String: String] = [:]
            if let value = author.name { authorMetadata["name"] = value }
            if let value = author.email { authorMetadata["email"] = value }
            if let value = author.url { authorMetadata["url"] = value }
            metadata["author"] = authorMetadata
        }
        if let value = manifest.homepage { metadata["homepage"] = value }
        if let value = manifest.repository { metadata["repository"] = value }
        if let value = manifest.license { metadata["license"] = value }
        if let value = manifest.keywords { metadata["keywords"] = value }
        if !result.extensionNamespaces.isEmpty {
            metadata["extensions"] = Dictionary(uniqueKeysWithValues: result.extensionNamespaces.map { ($0, true) })
        }
        return metadata
    }

    private func manifestDiagnosticSummary(_ diagnostic: AgentPluginManifestDiagnostic) -> String {
        switch diagnostic.kind {
        case .ignoredUnknownRootField(let field):
            guard let field = boundedSummary(field) else {
                return "plugin.json: ignored an unsafe unknown field."
            }
            return "plugin.json: ignored unknown field \"\(field)\"."
        case .ignoredNonObjectExtensions:
            return "plugin.json: ignored non-object extensions."
        }
    }

    private func packageName(_ rawValue: String) throws -> String {
        let value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty,
            value.count <= Limit.packageNameCharacters,
            !value.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
        else {
            throw MarketplaceError.invalidPackageName(rawValue)
        }
        return value
    }

    private func boundedSummary(_ rawValue: String?) -> String? {
        guard let value = rawValue?.trimmingCharacters(in: .whitespacesAndNewlines),
            !value.isEmpty,
            value.count <= Limit.summaryCharacters,
            !value.unicodeScalars.contains(where: { scalar in
                scalar.value < 0x20 && ![0x09, 0x0A, 0x0D].contains(scalar.value)
            })
        else { return nil }
        return SensitiveValueRedactor.redact(value)
    }

    private func validSkillDirectories(at root: URL) throws -> SkillInspection {
        let location = fixedLocation(root.appending(path: "skills"), within: root)
        guard case .directory(let skillsRoot) = location else {
            switch location {
            case .absent: return SkillInspection(directories: [], conflicts: [])
            default: return SkillInspection(directories: [], conflicts: [PackageConflict(id: "skills:location", summary: "skills: invalid component location.")])
            }
        }
        var result: [URL] = []
        var conflicts: [PackageConflict] = []
        do {
            for entry in try directoryEntries(at: skillsRoot) {
                do {
                    let entryLocation = fixedLocation(entry, within: root)
                    guard case .directory(let skillDirectory) = entryLocation else {
                        if case .invalid = entryLocation {
                            conflicts.append(PackageConflict(id: "skill:\(entry.lastPathComponent)", summary: "\(entry.lastPathComponent): invalid skill location."))
                        }
                        continue
                    }
                    let skillFileLocation = fixedLocation(skillDirectory.appending(path: "SKILL.md"), within: root)
                    guard case .regularFile(let skillFile) = skillFileLocation else {
                        if case .absent = skillFileLocation { continue }
                        conflicts.append(PackageConflict(id: "skill:\(skillDirectory.lastPathComponent)", summary: "\(skillDirectory.lastPathComponent): invalid SKILL.md location."))
                        continue
                    }
                    guard try validSkill(at: skillFile, expectedName: skillDirectory.lastPathComponent) else {
                        conflicts.append(PackageConflict(id: "skill:\(skillDirectory.lastPathComponent)", summary: "\(skillDirectory.lastPathComponent): invalid skill."))
                        continue
                    }
                    result.append(skillDirectory)
                } catch {
                    conflicts.append(PackageConflict(id: "skill:\(entry.lastPathComponent)", summary: "\(entry.lastPathComponent): invalid skill."))
                }
            }
        } catch {
            conflicts.append(PackageConflict(id: "skills:scan", summary: "skills: unable to inspect component."))
        }
        return SkillInspection(directories: result.sorted { $0.lastPathComponent.localizedCaseInsensitiveCompare($1.lastPathComponent) == .orderedAscending }, conflicts: conflicts)
    }

    private func fixedLocation(_ url: URL, within root: URL) -> FixedLocation {
        let path = url.path(percentEncoded: false)
        let exists = (try? fileManager.attributesOfItem(atPath: path)) != nil
            || (try? fileManager.destinationOfSymbolicLink(atPath: path)) != nil
        guard exists else { return .absent }
        let resolved = url.resolvingSymlinksInPath().standardizedFileURL
        guard contains(resolved, in: root) else { return .invalid("escapes") }
        guard let values = try? resolved.resourceValues(forKeys: [.isRegularFileKey, .isDirectoryKey]) else { return .invalid("unreadable") }
        if values.isRegularFile == true { return .regularFile(resolved) }
        if values.isDirectory == true { return .directory(resolved) }
        return .invalid("wrong kind")
    }

    private func validSkill(at url: URL, expectedName: String?) throws -> Bool {
        let contents = try readString(at: url, maximumBytes: Limit.skillBytes)
        let frontmatter = try SkillFrontmatter.parse(contents)
        guard let normalized = try? WorkspaceLibrary.normalizedIdentifier(frontmatter.name),
            normalized == frontmatter.name,
            expectedName == nil || expectedName == frontmatter.name,
            boundedSummary(frontmatter.description) != nil
        else { return false }
        return true
    }

    private func hasActiveContent(at root: URL, skillDirectories: [URL], manifest: [String: Any]?, hasMCP: Bool) throws -> Bool {
        if hasMCP { return true }
        for name in ["scripts", "hooks", "agents", "commands"] where try directory(root.appending(path: name), within: root) != nil {
            return true
        }
        for skillDirectory in skillDirectories where try directory(skillDirectory.appending(path: "scripts"), within: root) != nil {
            return true
        }
        if try containsExecutableFile(at: root) { return true }
        guard let manifest else { return false }
        if let extensions = manifest["extensions"] as? [String: Any], !extensions.isEmpty { return true }
        return containsActiveManifestKey(manifest, depth: 0)
    }

    private func containsExecutableFile(at root: URL) throws -> Bool {
        guard
            let enumerator = fileManager.enumerator(
                at: root,
                includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey],
                options: [.skipsPackageDescendants]
            )
        else { throw MarketplaceError.invalidPackage(root.path(percentEncoded: false)) }
        var inspected = 0
        while let item = enumerator.nextObject() as? URL {
            inspected += 1
            guard inspected <= Limit.directoryEntries else {
                throw MarketplaceError.tooManyEntries(root.path(percentEncoded: false), Limit.directoryEntries)
            }
            let relative = item.path(percentEncoded: false).dropFirst(canonicalPath(root).count + 1)
            let depth = relative.split(separator: "/", omittingEmptySubsequences: false).count
            if depth > Limit.traversalDepth {
                enumerator.skipDescendants()
                continue
            }
            if item.lastPathComponent == ".git" || item.lastPathComponent == ".build" || item.lastPathComponent == "node_modules" {
                enumerator.skipDescendants()
                continue
            }
            let values = try item.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey])
            if values.isSymbolicLink == true {
                // Even an in-package link deserves explicit review before an
                // installer consumes it, although bounded readers may inspect it.
                return true
            }
            guard values.isRegularFile == true else { continue }
            let attributes = try fileManager.attributesOfItem(atPath: item.path(percentEncoded: false))
            let permissions = (attributes[.posixPermissions] as? NSNumber)?.intValue ?? 0
            if permissions & 0o111 != 0 { return true }
        }
        return false
    }

    private func containsActiveManifestKey(_ value: Any, depth: Int) -> Bool {
        guard depth <= Limit.traversalDepth else { return true }
        if let dictionary = value as? [String: Any] {
            let activeKeys = Set(["hooks", "commands", "mcpServers", "mcp_servers", "agents", "scripts"])
            if !activeKeys.isDisjoint(with: dictionary.keys) { return true }
            return dictionary.values.contains { containsActiveManifestKey($0, depth: depth + 1) }
        }
        if let array = value as? [Any] {
            return array.contains { containsActiveManifestKey($0, depth: depth + 1) }
        }
        return false
    }

    private func isDirectory(_ url: URL) throws -> Bool {
        let values = try url.resourceValues(forKeys: [.isDirectoryKey])
        return values.isDirectory == true
    }

    private func directory(_ url: URL, within root: URL) throws -> URL? {
        guard fileManager.fileExists(atPath: url.path(percentEncoded: false)) else { return nil }
        let resolved = url.resolvingSymlinksInPath().standardizedFileURL
        guard contains(resolved, in: root) else {
            throw MarketplaceError.pathEscapesPackage(url.path(percentEncoded: false))
        }
        return try isDirectory(resolved) ? resolved : nil
    }

    private func regularFile(_ url: URL, within root: URL) throws -> URL? {
        guard fileManager.fileExists(atPath: url.path(percentEncoded: false)) else { return nil }
        let resolved = url.resolvingSymlinksInPath().standardizedFileURL
        guard contains(resolved, in: root) else {
            throw MarketplaceError.pathEscapesPackage(url.path(percentEncoded: false))
        }
        let values = try resolved.resourceValues(forKeys: [.isRegularFileKey])
        return values.isRegularFile == true ? resolved : nil
    }

    private func contains(_ candidate: URL, in root: URL) -> Bool {
        let rootPath = canonicalPath(root)
        let candidatePath = canonicalPath(candidate)
        return candidatePath == rootPath || candidatePath.hasPrefix(rootPath + "/")
    }

    private func canonicalPath(_ url: URL) -> String {
        var path = url.resolvingSymlinksInPath().standardizedFileURL.path(percentEncoded: false)
        while path.count > 1, path.hasSuffix("/") { path.removeLast() }
        return path
    }

    private func directoryEntries(at url: URL) throws -> [URL] {
        let entries = try fileManager.contentsOfDirectory(
            at: url,
            includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey],
            options: [.skipsHiddenFiles]
        )
        guard entries.count <= Limit.directoryEntries else {
            throw MarketplaceError.tooManyEntries(url.path(percentEncoded: false), Limit.directoryEntries)
        }
        return entries
    }

    private func readData(at url: URL, maximumBytes: Int) throws -> Data {
        let values = try url.resourceValues(forKeys: [
            .contentModificationDateKey, .fileResourceIdentifierKey, .fileSizeKey, .isRegularFileKey,
        ])
        guard values.isRegularFile == true else { throw MarketplaceError.invalidPackage(url.path(percentEncoded: false)) }
        guard let size = values.fileSize, size >= 0, size <= maximumBytes else {
            throw MarketplaceError.fileTooLarge(url.path(percentEncoded: false), maximumBytes)
        }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let data = try handle.read(upToCount: maximumBytes + 1) ?? Data()
        guard data.count <= maximumBytes else { throw MarketplaceError.fileTooLarge(url.path(percentEncoded: false), maximumBytes) }
        guard data.count == size else { throw MarketplaceError.changedWhileReading(url.path(percentEncoded: false)) }
        let resourceIdentifier = values.fileResourceIdentifier.map { String(describing: $0) }
        let finalValues = try url.resourceValues(forKeys: [
            .contentModificationDateKey, .fileResourceIdentifierKey, .fileSizeKey, .isRegularFileKey,
        ])
        guard finalValues.isRegularFile == true,
            let finalSize = finalValues.fileSize,
            finalSize <= maximumBytes,
            finalSize == data.count,
            finalValues.contentModificationDate == values.contentModificationDate,
            finalValues.fileResourceIdentifier.map({ String(describing: $0) }) == resourceIdentifier
        else {
            throw MarketplaceError.changedWhileReading(url.path(percentEncoded: false))
        }
        return data
    }

    private func readString(at url: URL, maximumBytes: Int) throws -> String {
        let data = try readData(at: url, maximumBytes: maximumBytes)
        guard let value = String(data: data, encoding: .utf8) else {
            throw MarketplaceError.invalidTextFile(url.path(percentEncoded: false))
        }
        return value
    }
}

public enum NativeCatalogClientOutcome: String, Equatable, Sendable {
    case excluded
    case complete
    case incomplete
}

public struct NativeCatalogDiscovery: Sendable {
    public var packages: [MarketplacePackage]
    public var notes: [ClientKind: String]
    public var outcomes: [ClientKind: NativeCatalogClientOutcome]

    public func retainedCachedPackages(from cached: [MarketplacePackage]) -> [MarketplacePackage] {
        let discoveredIDs = Set(packages.map(\.id))
        return cached.filter { package in
            guard !discoveredIDs.contains(package.id), let client = Self.client(for: package.id) else { return false }
            return outcomes[client] != .complete
        }
    }

    private static func client(for packageID: String) -> ClientKind? {
        if packageID.hasPrefix("claude:") { return .claude }
        if packageID.hasPrefix("codex:") { return .codex }
        return nil
    }
}

private enum NativeCatalogError: LocalizedError {
    case commandFailed(String, String)
    case incompleteResponse(String)

    var errorDescription: String? {
        switch self {
        case .commandFailed(let client, let output):
            let diagnostic = String(SensitiveValueRedactor.redact(output).prefix(1_024))
            return "\(client) catalog command failed\(diagnostic.isEmpty ? "" : ": \(diagnostic)")"
        case .incompleteResponse(let client):
            return "\(client) catalog response was incomplete"
        }
    }
}

enum MarketplaceError: LocalizedError, Sendable {
    case missingSource(String)
    case invalidSource(String)
    case invalidPackage(String)
    case invalidPackageName(String)
    case invalidManifest(String, String)
    case pathEscapesPackage(String)
    case fileTooLarge(String, Int)
    case tooManyEntries(String, Int)
    case invalidTextFile(String)
    case changedWhileReading(String)

    var errorDescription: String? {
        switch self {
        case .missingSource(let location): "The marketplace source at \(location) could not be found."
        case .invalidSource(let location): "The marketplace source at \(location) must resolve to a local directory."
        case .invalidPackage(let location): "The marketplace package at \(location) is not a readable directory or regular file."
        case .invalidPackageName(let name): "The marketplace package name is empty, unsafe, or too long: \(name)."
        case .invalidManifest(let path, let detail): "The package manifest at \(path) is invalid. \(detail)"
        case .pathEscapesPackage(let path): "The package path resolves outside the selected package: \(path)."
        case .fileTooLarge(let path, let maximum): "The package file at \(path) exceeds the \(maximum)-byte inspection limit."
        case .tooManyEntries(let path, let maximum): "The package directory at \(path) contains more than \(maximum) entries."
        case .invalidTextFile(let path): "The package text file at \(path) is not valid UTF-8."
        case .changedWhileReading(let path): "The package file changed while it was being inspected: \(path). Refresh and review it again."
        }
    }
}
