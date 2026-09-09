import CryptoKit
import Foundation

/// Suggestions from one checkpoint, without accessing source trees or inventing
/// ownership from publisher labels. Candidate preparation verifies every choice.
public struct WorkspaceMigrationIntake: Sendable {
    public let choices: [WorkspaceMigrationInventoryChoice]
    public let issues: [WorkspaceMigrationIntakeIssue]
    public let snapshot: WorkspaceSnapshot

    /// Only existing explicit bindings create assignments. Observation scope
    /// supplies placement, never enabled/present intent. Project placement is
    /// left unresolved until its logical project has been mapped.
    public func nativePlacements(workspaceID: WorkspaceObjectID) throws -> [WorkspaceNativePluginMigrationPlacement] {
        try WorkspaceMigrationNativePlacementIntake.review(
            intake: self, workspaceID: workspaceID, projects: []
        ).placements
    }

    public static func review(checkpoint: WorkspaceLegacyCheckpoint, workspaceID: WorkspaceObjectID) throws -> Self {
        guard let snapshot = try checkpoint.workspaceSnapshot() else {
            throw WorkspaceLegacyCheckpointError.missingSnapshot
        }
        var choices: [WorkspaceMigrationInventoryChoice] = []
        var issues: [WorkspaceMigrationIntakeIssue] = []
        var bundledSkills = Set(snapshot.plugins.flatMap(\.skills))
        var bundledServers = Set<String>()
        var skillParents: [String: Set<String>] = [:]
        var serverParents: [String: Set<String>] = [:]
        for plugin in snapshot.plugins {
            for id in plugin.skills { skillParents[id, default: []].insert(plugin.id) }
        }
        for observation in snapshot.targetObservations {
            for (id, metadata) in observation.skillMetadata {
                guard let parent = metadata.providerPluginID else { continue }
                bundledSkills.insert(id)
                skillParents[id, default: []].insert(parent)
            }
            for (parent, metadata) in observation.pluginMetadata {
                bundledSkills.formUnion(metadata.skillIDs)
                bundledServers.formUnion(metadata.mcpServerIDs)
                for id in metadata.skillIDs { skillParents[id, default: []].insert(parent) }
                for id in metadata.mcpServerIDs { serverParents[id, default: []].insert(parent) }
            }
        }
        let liveSkills = Set(snapshot.skills.map(\.id))
        let liveServers = Set(snapshot.mcpServers.map(\.id))
        for plugin in snapshot.plugins {
            let key = LegacyReferenceKey(domain: .plugin, identifier: plugin.id)
            var routes = Set<NativePackageRoute>()
            var paths: [LegacyReferenceKey: Set<String>] = [:]
            var requiredSkills = Set(plugin.skills)
            var requiredServers = Set<String>()
            for observation in snapshot.targetObservations {
                guard let client = observation.surface.client,
                      observation.discoveredPlugins.contains(plugin.id),
                      let metadata = observation.pluginMetadata[plugin.id] else { continue }
                routes.insert(.init(client: client, externalPluginID: plugin.id))
                requiredSkills.formUnion(metadata.skillIDs)
                requiredServers.formUnion(metadata.mcpServerIDs)
                for (id, child) in observation.skillMetadata where child.providerPluginID == plugin.id {
                    requiredSkills.insert(id)
                    if let relative = relativeSkillDirectory(child.path, packageRoot: metadata.source) {
                        paths[.init(domain: .skill, identifier: id), default: []].insert(relative)
                    }
                }
            }
            let missing = requiredSkills.contains { paths[.init(domain: .skill, identifier: $0)]?.count != 1 }
            let ambiguous = requiredSkills.contains { skillParents[$0] != [plugin.id] }
                || requiredServers.contains { serverParents[$0] != [plugin.id] }
            // MCP declarations keep their observed identity and parent. They
            // need no invented file path or separate managed definition.
            guard !routes.isEmpty, !missing, !ambiguous,
                  requiredSkills.isSubset(of: liveSkills), requiredServers.isSubset(of: liveServers) else {
                issues.append(.init(legacy: key, displayName: plugin.name,
                    reason: routes.isEmpty ? .nativeRoute : .pluginContents))
                continue
            }
            var children = requiredSkills.sorted().compactMap { id -> WorkspaceMigrationNativeChildChoice? in
                let child = LegacyReferenceKey(domain: .skill, identifier: id)
                guard let path = paths[child]?.first else { return nil }
                return .init(legacy: child, packageRelativePath: path)
            }
            children += requiredServers.sorted().map {
                .init(legacy: .init(domain: .mcpServer, identifier: $0))
            }
            choices.append(.init(legacy: key, strategy: .nativePackage(
                routes: routes.sorted { $0.client.rawValue < $1.client.rawValue }, children: children)))
        }
        for skill in snapshot.skills where !bundledSkills.contains(skill.id) {
            let key = LegacyReferenceKey(domain: .skill, identifier: skill.id)
            if let binding = skill.repositoryBinding {
                let directories = binding.installedFingerprints.keys.sorted()
                guard directories.count == 1, let path = directories.first,
                      path.hasPrefix("/"), binding.installedRevision != nil else {
                    issues.append(.init(legacy: key, displayName: skill.displayName, reason: .upstreamInstallation))
                    continue
                }
                choices.append(.init(legacy: key, strategy: .centralUpstream(
                    installedDirectory: URL(fileURLWithPath: path),
                    sourceID: try stableID(workspaceID: workspaceID, skillID: skill.id, role: "source"),
                    subscriptionID: try stableID(workspaceID: workspaceID, skillID: skill.id, role: "subscription"))))
            } else {
                choices.append(.init(legacy: key, strategy: skill.owned ? .centralPersonal : .trackedOnly))
            }
        }
        for server in snapshot.mcpServers where !bundledServers.contains(server.id) {
            let key = LegacyReferenceKey(domain: .mcpServer, identifier: server.id)
            if server.isManagedDefinition {
                issues.append(.init(legacy: key, displayName: server.name, reason: .managedConnection))
            } else {
                choices.append(.init(legacy: key, strategy: .trackedOnly))
            }
        }
        return Self(choices: choices, issues: issues.sorted { $0.displayName < $1.displayName }, snapshot: snapshot)
    }

    static func stableID(workspaceID: WorkspaceObjectID, skillID: String, role: String) throws -> WorkspaceObjectID {
        let payload = try JSONEncoder().encode(["migration-intake.v1", workspaceID.rawValue.uuidString.lowercased(),
            role, skillID.precomposedStringWithCanonicalMapping])
        var bytes = Array(SHA256.hash(data: payload).prefix(16))
        bytes[6] = (bytes[6] & 0x0f) | 0x80
        bytes[8] = (bytes[8] & 0x3f) | 0x80
        let hex = bytes.map { String(format: "%02x", $0) }.joined()
        let uuid = [0..<8, 8..<12, 12..<16, 16..<20, 20..<32].map {
            String(hex.dropFirst($0.lowerBound).prefix($0.count))
        }.joined(separator: "-")
        return WorkspaceObjectID(UUID(uuidString: uuid)!)
    }

    private static func relativeSkillDirectory(_ path: String, packageRoot: String) -> String? {
        guard path.hasPrefix("/"), packageRoot.hasPrefix("/"),
              !path.contains("\0"), !packageRoot.contains("\0") else { return nil }
        let root = URL(fileURLWithPath: packageRoot).standardizedFileURL
        var child = URL(fileURLWithPath: path).standardizedFileURL
        if child.lastPathComponent == "SKILL.md" { child.deleteLastPathComponent() }
        let prefix = root.path.hasSuffix("/") ? root.path : root.path + "/"
        guard child.path.hasPrefix(prefix) else { return nil }
        let relative = String(child.path.dropFirst(prefix.count))
        return relative.isEmpty ? nil : relative
    }
}

public struct WorkspaceMigrationIntakeIssue: Sendable, Equatable {
    public enum Reason: String, Sendable {
        case nativeRoute, pluginContents, upstreamInstallation, managedConnection
    }
    public let legacy: LegacyReferenceKey
    public let displayName: String
    public let reason: Reason
}
