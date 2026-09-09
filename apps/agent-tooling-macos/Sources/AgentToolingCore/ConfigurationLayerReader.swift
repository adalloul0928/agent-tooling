import Foundation

public enum ConfigurationLayerReadError: Error, Equatable, Sendable {
    case invalidRoot
    case fileTooLarge
    case unreadable
}

/// Reads native configuration files into layers the resolver can explain.
///
/// It only reads. Files are never rewritten, reformatted or normalized, and a
/// file this build cannot parse is reported as unreadable rather than treated
/// as empty — an empty layer and a broken one mean very different things.
///
/// Keys the build does not interpret are collected as unrecognized so they stay
/// visible. Values are read shallowly: nested structures become opaque text
/// rather than being flattened into claims about their contents.
public struct ConfigurationLayerReader: Sendable {
    public static let maximumFileBytes = 1 << 20

    public init() {}

    /// Claude Code's documented layers for one home and optional project.
    /// Where a client reads an organization's policy on this platform.
    ///
    /// Recorded from the vendor's own page rather than guessed, because the
    /// consequence of guessing is reporting "no policy" for a Mac that has one —
    /// and then offering to change a setting the policy actually decides.
    ///
    /// macOS only. Linux and Windows have their own locations on that page, and
    /// this app does not run there, so claiming them would be recording a fact
    /// nothing here can check.
    ///
    /// Source: https://code.claude.com/docs/en/managed-settings
    public static func managedPolicyPath(for surface: TargetSurface) -> URL? {
        switch surface {
        case .claudeCode:
            URL(fileURLWithPath: "/Library/Application Support/ClaudeCode/managed-settings.json")
        default:
            // Codex documents no equivalent file this build has read, and an
            // invented one would be worse than none.
            nil
        }
    }

    public func claudeCodeLayers(
        homeRoot: URL,
        projectRoot: URL? = nil,
        managedPolicyPath: URL? = nil
    ) throws -> [ConfigurationLayer] {
        var layers: [ConfigurationLayer] = []
        if let managedPolicyPath,
           let layer = try jsonLayer(at: managedPolicyPath, kind: .managedPolicy, isWritable: false) {
            layers.append(layer)
        }
        if let projectRoot {
            try requireDirectoryRoot(projectRoot)
            if let layer = try jsonLayer(at: projectRoot.appending(path: ".claude/settings.local.json"),
                                         kind: .localProject, isWritable: true) {
                layers.append(layer)
            }
            if let layer = try jsonLayer(at: projectRoot.appending(path: ".claude/settings.json"),
                                         kind: .project, isWritable: true) {
                layers.append(layer)
            }
        }
        try requireDirectoryRoot(homeRoot)
        if let layer = try jsonLayer(at: homeRoot.appending(path: ".claude/settings.json"),
                                     kind: .user, isWritable: true) {
            layers.append(layer)
        }
        return layers
    }

    /// Codex's local configuration, plus the named profile when the installed
    /// release keeps profiles in their own files.
    public func codexLayers(
        homeRoot: URL,
        adapter: CodexConfigurationAdapter,
        profileName: String? = nil
    ) throws -> [ConfigurationLayer] {
        try requireDirectoryRoot(homeRoot)
        var layers: [ConfigurationLayer] = []
        if adapter.usesSeparateProfileFiles, let profileName, Self.isSafeComponent(profileName),
           let layer = try tomlLayer(at: homeRoot.appending(path: ".codex/\(profileName).config.toml"),
                                     kind: .project, isWritable: true) {
            // A named profile takes precedence over the base configuration; it
            // is not a project file, but it occupies that layer for this vendor.
            layers.append(layer)
        }
        if let layer = try tomlLayer(at: homeRoot.appending(path: ".codex/config.toml"),
                                     kind: .user, isWritable: true) {
            layers.append(layer)
        }
        return layers
    }
}

extension ConfigurationLayerReader {
    func requireDirectoryRoot(_ url: URL) throws {
        guard url.isFileURL, url.path.hasPrefix("/"), !url.path.contains("\0"),
              url.standardizedFileURL.path == url.path else {
            throw ConfigurationLayerReadError.invalidRoot
        }
    }

    /// `nil` when the file simply is not there. A file that exists but cannot be
    /// read is an error: silently treating it as absent would present a partial
    /// picture as complete.
    func jsonLayer(at url: URL, kind: ConfigurationLayerKind, isWritable: Bool) throws -> ConfigurationLayer? {
        guard let bytes = try read(url) else { return nil }
        guard let object = try? JSONSerialization.jsonObject(with: bytes) as? [String: Any] else {
            throw ConfigurationLayerReadError.unreadable
        }
        var values: [String: ConfigurationValue] = [:]
        var unrecognized: [String] = []
        for (key, raw) in object {
            // Permissions are documented as a nested object with named lists;
            // reading those two lists is interpretation this build can defend.
            if key == "permissions", let nested = raw as? [String: Any] {
                for (child, value) in nested {
                    guard ["allow", "deny"].contains(child) else {
                        unrecognized.append("permissions.\(child)")
                        continue
                    }
                    values["permissions.\(child)"] = Self.value(value)
                }
                continue
            }
            values[key] = Self.value(raw)
        }
        return .init(kind: kind, sourcePath: url.path, isWritable: isWritable,
                     values: values, unrecognizedKeys: unrecognized.sorted())
    }

    /// Codex's configuration is TOML. Only top-level scalar assignments are
    /// interpreted; tables are recorded by name so they stay visible without
    /// this build claiming to understand their contents.
    func tomlLayer(at url: URL, kind: ConfigurationLayerKind, isWritable: Bool) throws -> ConfigurationLayer? {
        guard let bytes = try read(url) else { return nil }
        guard let text = String(data: bytes, encoding: .utf8) else {
            throw ConfigurationLayerReadError.unreadable
        }
        var values: [String: ConfigurationValue] = [:]
        var unrecognized: [String] = []
        var insideTable = false
        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }
            if line.hasPrefix("[") {
                insideTable = true
                let name = line.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
                if !name.isEmpty { values[name] = .opaque("Configured") }
                continue
            }
            guard !insideTable, let separator = line.firstIndex(of: "=") else {
                if insideTable, let separator = line.firstIndex(of: "=") {
                    unrecognized.append(String(line[line.startIndex..<separator])
                        .trimmingCharacters(in: .whitespaces))
                }
                continue
            }
            let key = String(line[line.startIndex..<separator]).trimmingCharacters(in: .whitespaces)
            let raw = String(line[line.index(after: separator)...]).trimmingCharacters(in: .whitespaces)
            guard !key.isEmpty else { continue }
            values[key] = Self.tomlValue(raw)
        }
        return .init(kind: kind, sourcePath: url.path, isWritable: isWritable,
                     values: values, unrecognizedKeys: unrecognized.sorted())
    }

    func read(_ url: URL) throws -> Data? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let bytes: Data
        do { bytes = try Data(contentsOf: url, options: [.mappedIfSafe]) }
        catch { throw ConfigurationLayerReadError.unreadable }
        guard bytes.count <= Self.maximumFileBytes else { throw ConfigurationLayerReadError.fileTooLarge }
        return bytes
    }

    static func value(_ raw: Any) -> ConfigurationValue {
        switch raw {
        case let value as String: .string(value)
        case let value as Bool: .boolean(value)
        case let value as NSNumber:
            // NSNumber bridges booleans too; the Bool case above catches those.
            .number(value.doubleValue)
        case let value as [Any]: .list(value.map { self.value($0) })
        default: .opaque("Configured")
        }
    }

    static func tomlValue(_ raw: String) -> ConfigurationValue {
        if raw.hasPrefix("\""), raw.hasSuffix("\""), raw.count >= 2 {
            return .string(String(raw.dropFirst().dropLast()))
        }
        if raw == "true" || raw == "false" { return .boolean(raw == "true") }
        if let number = Double(raw) { return .number(number) }
        if raw.hasPrefix("[") { return .opaque(raw.count > 80 ? "Configured" : raw) }
        return .string(raw)
    }

    static func isSafeComponent(_ value: String) -> Bool {
        !value.isEmpty && value.count <= 128 && !value.contains("/") && !value.contains("\0")
            && value != "." && value != ".."
    }
}
