import Foundation

/// Which tools inside one MCP server a person has decided they want.
///
/// This is an **intent record**, not an enforced restriction. Agent Tooling
/// writes no per-tool switch into Claude Code, Codex, or Gemini CLI, because
/// none of them exposes one that this app configures. The record travels with
/// the server's desired state and the interface says so in as many words.
public struct MCPCapabilityIntent: Codable, Hashable, Sendable, Identifiable {
    public static let maximumToolNames = 500
    public static let maximumToolNameCharacters = 256

    /// The one sentence the interface must show wherever these toggles appear.
    public static let enforcementNotice =
        "Recorded intent, not an enforced restriction. Agent Tooling does not write a per-tool rule into any client, "
        + "so every tool this server exposes still reaches Claude Code, Codex, and Gemini CLI. "
        + "Enforcing it needs a per-tool permission rule in the client's own settings, which Agent Tooling does not manage."

    public var id: String { serverID }
    public var serverID: String
    /// Only the tools explicitly turned off are stored. A tool with no recorded
    /// decision counts as wanted, which matches what the clients do today.
    public var disabledToolNames: [String]
    /// The tool names the last live test observed, so the row can say "3 of 4"
    /// without opening another connection.
    public var knownToolNames: [String]
    public var updatedAt: Date

    public init(serverID: String, disabledToolNames: [String] = [], knownToolNames: [String] = [], updatedAt: Date = .now) {
        self.serverID = serverID
        self.disabledToolNames = Self.normalized(disabledToolNames)
        self.knownToolNames = Self.normalized(knownToolNames)
        self.updatedAt = updatedAt
    }

    public var totalCount: Int { knownToolNames.count }

    public var enabledCount: Int {
        let disabled = Set(disabledToolNames)
        return knownToolNames.filter { !disabled.contains($0) }.count
    }

    /// `nil` until a live test has told the app which tools exist.
    public var summary: String? {
        guard totalCount > 0 else { return nil }
        return "\(enabledCount)/\(totalCount) enabled"
    }

    public var hasDecisions: Bool { !disabledToolNames.isEmpty }

    public func isEnabled(_ toolName: String) -> Bool { !disabledToolNames.contains(toolName) }

    public mutating func setEnabled(_ enabled: Bool, tool toolName: String, at date: Date = .now) {
        let name = Self.bounded(toolName)
        guard !name.isEmpty else { return }
        var disabled = Set(disabledToolNames)
        if enabled {
            disabled.remove(name)
        } else {
            guard disabled.count < Self.maximumToolNames else { return }
            disabled.insert(name)
        }
        disabledToolNames = Self.normalized(Array(disabled))
        updatedAt = date
    }

    /// Records what a live connection just observed, and forgets decisions about
    /// tools the server no longer offers so a stale "3/4" cannot linger.
    public mutating func observe(toolNames: [String], at date: Date = .now) {
        knownToolNames = Self.normalized(toolNames)
        let known = Set(knownToolNames)
        disabledToolNames = disabledToolNames.filter(known.contains)
        updatedAt = date
    }

    static func normalized(_ names: [String]) -> [String] {
        var seen: Set<String> = []
        var result: [String] = []
        for name in names {
            let bounded = Self.bounded(name)
            guard !bounded.isEmpty, seen.insert(bounded).inserted else { continue }
            result.append(bounded)
            if result.count >= maximumToolNames { break }
        }
        return result.sorted()
    }

    static func bounded(_ name: String) -> String {
        let cleaned = name.filter { !$0.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) }
        return String(cleaned.trimmingCharacters(in: .whitespacesAndNewlines).prefix(maximumToolNameCharacters))
    }
}

public struct MCPCapabilityIntentRecord: Codable, Hashable, Sendable {
    public static let currentVersion = 1
    public static let maximumServers = 512

    public var version: Int
    public var servers: [MCPCapabilityIntent]

    public init(version: Int = MCPCapabilityIntentRecord.currentVersion, servers: [MCPCapabilityIntent] = []) {
        self.version = version
        self.servers = Self.normalized(servers)
    }

    public func intent(for serverID: String) -> MCPCapabilityIntent? {
        servers.first { $0.serverID == serverID }
    }

    public mutating func update(_ intent: MCPCapabilityIntent) {
        var updated = servers.filter { $0.serverID != intent.serverID }
        if intent.hasDecisions || !intent.knownToolNames.isEmpty {
            updated.append(intent)
        }
        servers = Self.normalized(updated)
    }

    public mutating func remove(serverID: String) {
        servers = servers.filter { $0.serverID != serverID }
    }

    private static func normalized(_ values: [MCPCapabilityIntent]) -> [MCPCapabilityIntent] {
        var seen: Set<String> = []
        let unique = values.filter { seen.insert($0.serverID).inserted }
        return Array(unique.sorted { $0.serverID < $1.serverID }.prefix(maximumServers))
    }
}

/// Reads and writes the intent record beside the workspace database.
///
/// A separate small file rather than a new column keeps this readable, easy to
/// back up with the rest of the workspace, and impossible to confuse with an
/// observed client fact.
public struct MCPCapabilityIntentStore: Sendable {
    public static let fileName = "mcp-capability-intent.json"
    public static let maximumFileBytes = 1_048_576

    public let fileURL: URL

    public init(workspaceRootURL: URL) {
        self.fileURL = workspaceRootURL.appending(path: Self.fileName, directoryHint: .notDirectory).standardizedFileURL
    }

    public func load(fileManager: FileManager = .default) throws -> MCPCapabilityIntentRecord {
        guard fileManager.fileExists(atPath: fileURL.path(percentEncoded: false)) else {
            return MCPCapabilityIntentRecord()
        }
        try refuseSymbolicLink()
        let data = try Data(contentsOf: fileURL)
        guard data.count <= Self.maximumFileBytes else {
            throw MCPCapabilityIntentError.recordTooLarge
        }
        do {
            let record = try AgentToolingCoding.decoder().decode(MCPCapabilityIntentRecord.self, from: data)
            guard record.version <= MCPCapabilityIntentRecord.currentVersion else {
                throw MCPCapabilityIntentError.unsupportedVersion(record.version)
            }
            return record
        } catch let error as MCPCapabilityIntentError {
            throw error
        } catch {
            throw MCPCapabilityIntentError.unreadable
        }
    }

    public func save(_ record: MCPCapabilityIntentRecord, fileManager: FileManager = .default) throws {
        try refuseSymbolicLink()
        var stored = record
        stored.version = MCPCapabilityIntentRecord.currentVersion
        let data = try AgentToolingCoding.encoder(prettyPrinted: true).encode(stored)
        guard data.count <= Self.maximumFileBytes else {
            throw MCPCapabilityIntentError.recordTooLarge
        }
        try data.write(to: fileURL, options: [.atomic])
        try? fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path(percentEncoded: false))
    }

    private func refuseSymbolicLink() throws {
        let values = try? fileURL.resourceValues(forKeys: [.isSymbolicLinkKey])
        guard values?.isSymbolicLink != true else {
            throw MCPCapabilityIntentError.unsafePath(fileURL.lastPathComponent)
        }
    }
}

public enum MCPCapabilityIntentError: LocalizedError, Equatable, Sendable {
    case recordTooLarge
    case unreadable
    case unsupportedVersion(Int)
    case unsafePath(String)

    public var errorDescription: String? {
        switch self {
        case .recordTooLarge: "The recorded MCP capability choices exceed the safe file size limit."
        case .unreadable: "The recorded MCP capability choices could not be read."
        case .unsupportedVersion(let version):
            "The recorded MCP capability choices use format version \(version), which this build cannot read."
        case .unsafePath(let name): "\(name) is a symbolic link, so Agent Tooling will not write capability choices through it."
        }
    }
}
