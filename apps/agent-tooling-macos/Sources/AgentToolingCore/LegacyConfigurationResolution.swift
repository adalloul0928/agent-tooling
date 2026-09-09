import Foundation

/// Names a configuration in the state shape that existed before the portable
/// configuration migration. Policy-template resolution is a comparison-only
/// extension: the old app resolved `WorkspaceSnapshot.profiles`, while this
/// identity can also address a raw profile retained under `managedPolicies`.
/// A policy profile is qualified by its policy because those identifiers are
/// independent from workspace configuration identifiers.
public enum LegacyConfigurationIdentity: Hashable, Sendable {
    case personal(String)
    case policy(policyID: String, profileID: String)

    public var rawConfigurationID: String {
        switch self {
        case .personal(let id): id
        case .policy(_, let profileID): profileID
        }
    }
}

/// The old resolver's observable contract, kept separate so a
/// migration can compare both representations without making either one the
/// implementation of the other.
public struct LegacyConfigurationResolution: Hashable, Sendable {
    /// Unqualified IDs as they appeared in the contributing configurations,
    /// ordered from oldest ancestor to selected configuration.
    public var contributingConfigurationIDs: [String]
    /// The same contribution chain with policy provenance retained.
    public var contributingIdentities: [LegacyConfigurationIdentity]
    public var requiredSkills: [String]
    public var enabledPlugins: [String]
    public var requiredMCPs: [String]
    public var includedCollections: [String]
    /// Ancestor-first. A child cannot repeat an ancestor check; duplicate IDs
    /// within one contributing configuration retain the legacy batch behavior.
    public var checks: [ProfileCheck]
    /// The nearest non-nil binding list. `nil` and `[]` have distinct legacy
    /// meanings, and each binding retains its optional enabled value.
    public var targetBindings: [OnboardingTargetBinding]?

    public init(
        contributingConfigurationIDs: [String],
        contributingIdentities: [LegacyConfigurationIdentity],
        requiredSkills: [String],
        enabledPlugins: [String],
        requiredMCPs: [String],
        includedCollections: [String],
        checks: [ProfileCheck],
        targetBindings: [OnboardingTargetBinding]?
    ) {
        self.contributingConfigurationIDs = contributingConfigurationIDs
        self.contributingIdentities = contributingIdentities
        self.requiredSkills = requiredSkills
        self.enabledPlugins = enabledPlugins
        self.requiredMCPs = requiredMCPs
        self.includedCollections = includedCollections
        self.checks = checks
        self.targetBindings = targetBindings
    }
}

public enum LegacyConfigurationResolutionError: Error, Equatable, LocalizedError, Sendable {
    case missingConfiguration(LegacyConfigurationIdentity)
    case ambiguousConfiguration(LegacyConfigurationIdentity)
    case ambiguousConfigurationID(String, [LegacyConfigurationIdentity])
    case missingParent(child: LegacyConfigurationIdentity, parentID: String)
    case inheritanceCycle([LegacyConfigurationIdentity])
    case missingPolicy(String)
    case conflictingPolicyPluginRule(policyID: String, pluginID: String)

    public var errorDescription: String? {
        switch self {
        case .missingConfiguration(let identity):
            return "The configuration \(identity.rawConfigurationID) does not exist."
        case .ambiguousConfiguration(let identity):
            return "The configuration \(identity.rawConfigurationID) has more than one matching record."
        case .ambiguousConfigurationID(let id, _):
            return "The configuration identifier \(id) is ambiguous between workspace and policy configurations."
        case .missingParent(let child, let parentID):
            return "Configuration \(child.rawConfigurationID) inherits from missing configuration \(parentID)."
        case .inheritanceCycle(let chain):
            return "Configuration inheritance contains a cycle: \(chain.map(\.rawConfigurationID).joined(separator: ", "))."
        case .missingPolicy(let id):
            return "The managed policy \(id) does not exist."
        case .conflictingPolicyPluginRule(let policyID, let pluginID):
            return "Managed policy \(policyID) both requires and blocks plugin \(pluginID)."
        }
    }
}

/// A bounded, pure copy of the legacy configuration-resolution behavior.
///
/// It intentionally accepts a snapshot rather than a live model: migration
/// comparisons must not depend on live UI caches, file access, or model state.
public enum LegacyConfigurationResolver {
    public static func resolve(
        _ snapshot: WorkspaceSnapshot,
        configuration identity: LegacyConfigurationIdentity
    ) throws -> LegacyConfigurationResolution {
        let selected = try profile(for: identity, in: snapshot)
        try validatePolicy(for: identity, in: snapshot)

        var selectedToAncestor: [(LegacyConfigurationIdentity, ToolingProfile)] = []
        var visited: [LegacyConfigurationIdentity: Int] = [:]
        var cursor: (LegacyConfigurationIdentity, ToolingProfile)? = (identity, selected)
        while let current = cursor {
            if let cycleStart = visited[current.0] {
                throw LegacyConfigurationResolutionError.inheritanceCycle(
                    Array(selectedToAncestor[cycleStart...].map(\.0)) + [current.0]
                )
            }
            visited[current.0] = selectedToAncestor.count
            selectedToAncestor.append(current)

            guard let parentID = current.1.inheritedFrom else {
                cursor = nil
                continue
            }
            let parentIdentity = parentIdentity(for: parentID, child: current.0)
            do {
                cursor = (parentIdentity, try profile(for: parentIdentity, in: snapshot))
            } catch LegacyConfigurationResolutionError.missingConfiguration {
                throw LegacyConfigurationResolutionError.missingParent(child: current.0, parentID: parentID)
            }
        }

        let chain = selectedToAncestor.reversed()
        var enabledPlugins = Set<String>()
        var requiredMCPs = Set<String>()
        var requiredSkills = Set<String>()
        var includedCollections = Set<String>()
        var checks: [ProfileCheck] = []
        for (_, profile) in chain {
            enabledPlugins.formUnion(profile.enabledPlugins)
            requiredMCPs.formUnion(profile.requiredMCPs)
            requiredSkills.formUnion(profile.requiredSkills)
            includedCollections.formUnion(profile.includedCollections)
            // This intentionally filters against the checks accumulated before
            // this profile's batch. The live resolver therefore retains two
            // duplicate IDs written in the same profile, while a child cannot
            // repeat an inherited check ID.
            checks.append(contentsOf: profile.checks.filter { candidate in
                !checks.contains(where: { $0.id == candidate.id })
            })
        }

        // The old resolver walks the stored collection order, rather than the
        // sorted configuration list, and keeps the first occurrence of an item.
        var seenCollectionItems = Set<String>()
        for collection in snapshot.collections where includedCollections.contains(collection.id) {
            for item in collection.items where seenCollectionItems.insert(item.id).inserted {
                switch item.kind {
                case .skill: requiredSkills.insert(item.identifier)
                case .plugin: enabledPlugins.insert(item.identifier)
                case .mcpServer: requiredMCPs.insert(item.identifier)
                }
            }
        }

        // Bindings resolve in the opposite direction: the selected profile's
        // first explicit list replaces every ancestor, including an empty list.
        let targetBindings = selectedToAncestor.lazy.compactMap { $0.1.targetBindings }.first
        let contributors = Array(chain)
        return LegacyConfigurationResolution(
            contributingConfigurationIDs: contributors.map { $0.1.id },
            contributingIdentities: contributors.map(\.0),
            requiredSkills: requiredSkills.filter { isVisible(.skill, id: $0, snapshot: snapshot) }.sorted(),
            enabledPlugins: enabledPlugins.filter { isVisible(.plugin, id: $0, snapshot: snapshot) }.sorted(),
            requiredMCPs: requiredMCPs.filter { isVisible(.mcpServer, id: $0, snapshot: snapshot) }.sorted(),
            includedCollections: includedCollections.sorted(),
            checks: checks,
            targetBindings: targetBindings
        )
    }

    /// Convenience for old callers that only had an unqualified identifier.
    /// Ambiguity is an error so a migration cannot accidentally select a policy
    /// profile over a workspace profile (or vice versa).
    public static func resolve(
        _ snapshot: WorkspaceSnapshot,
        configurationID: String
    ) throws -> LegacyConfigurationResolution {
        var matches = snapshot.profiles.filter { $0.id == configurationID }
            .map { LegacyConfigurationIdentity.personal($0.id) }
        for policy in snapshot.managedPolicies {
            matches += policy.profiles.filter { $0.id == configurationID }
                .map { .policy(policyID: policy.id, profileID: $0.id) }
        }
        guard matches.count == 1, let identity = matches.first else {
            if matches.isEmpty {
                throw LegacyConfigurationResolutionError.missingConfiguration(.personal(configurationID))
            }
            throw LegacyConfigurationResolutionError.ambiguousConfigurationID(configurationID, matches)
        }
        return try resolve(snapshot, configuration: identity)
    }

    private static func parentIdentity(for parentID: String, child: LegacyConfigurationIdentity) -> LegacyConfigurationIdentity {
        switch child {
        case .personal: .personal(parentID)
        case .policy(let policyID, _): .policy(policyID: policyID, profileID: parentID)
        }
    }

    private static func profile(
        for identity: LegacyConfigurationIdentity,
        in snapshot: WorkspaceSnapshot
    ) throws -> ToolingProfile {
        switch identity {
        case .personal(let id):
            let matches = snapshot.profiles.filter { $0.id == id }
            guard let profile = matches.first else {
                throw LegacyConfigurationResolutionError.missingConfiguration(identity)
            }
            guard matches.count == 1 else { throw LegacyConfigurationResolutionError.ambiguousConfiguration(identity) }
            return profile
        case .policy(let policyID, let profileID):
            let policies = snapshot.managedPolicies.filter { $0.id == policyID }
            guard let policy = policies.first else {
                throw LegacyConfigurationResolutionError.missingPolicy(policyID)
            }
            guard policies.count == 1 else { throw LegacyConfigurationResolutionError.ambiguousConfiguration(identity) }
            let matches = policy.profiles.filter { $0.id == profileID }
            guard let profile = matches.first else {
                throw LegacyConfigurationResolutionError.missingConfiguration(identity)
            }
            guard matches.count == 1 else { throw LegacyConfigurationResolutionError.ambiguousConfiguration(identity) }
            return profile
        }
    }

    private static func validatePolicy(for identity: LegacyConfigurationIdentity, in snapshot: WorkspaceSnapshot) throws {
        guard case .policy(let policyID, _) = identity else { return }
        guard let policy = snapshot.managedPolicies.first(where: { $0.id == policyID }) else {
            throw LegacyConfigurationResolutionError.missingPolicy(policyID)
        }
        if let conflict = Set(policy.requiredPluginIDs).intersection(policy.blockedPluginIDs).sorted().first {
            throw LegacyConfigurationResolutionError.conflictingPolicyPluginRule(policyID: policyID, pluginID: conflict)
        }
    }

    private static func isVisible(_ kind: ToolingItemKind, id: String, snapshot: WorkspaceSnapshot) -> Bool {
        switch kind {
        case .skill:
            guard let item = snapshot.skills.first(where: { $0.id == id }) else { return true }
            let enabledClients = snapshot.preferences.enabledClients
            let linkedToEnabledClient = item.repositoryBinding?.installedFingerprints.keys.contains { path in
                guard let client = client(forInstalledPath: path) else { return false }
                return enabledClients.contains(client)
            } == true
            return item.owned || item.clients.contains {
                enabledClients.contains($0.client) && $0.reportsLocalPresence
            } || linkedToEnabledClient
        case .plugin:
            guard let item = snapshot.plugins.first(where: { $0.id == id }) else { return true }
            return item.clients.contains { snapshot.preferences.enabledClients.contains($0.client) && $0.reportsLocalPresence }
        case .mcpServer:
            guard let item = snapshot.mcpServers.first(where: { $0.id == id }) else { return true }
            return item.isManagedDefinition || item.clients.contains {
                snapshot.preferences.enabledClients.contains($0.client) && $0.reportsLocalPresence
            }
        }
    }

    /// Mirrors the legacy client selection used by `AppModel.visibleSkills`.
    /// Repository fingerprints are a device-local path fact, so an explicit
    /// upstream relationship remains visible even after its client row becomes
    /// an unavailable placeholder.
    private static func client(forInstalledPath path: String) -> ClientKind? {
        let parts = URL(fileURLWithPath: path).standardizedFileURL.pathComponents
        if parts.contains(".claude") { return .claude }
        if parts.contains(".codex") || parts.contains(".agents") { return .codex }
        if parts.contains(".gemini") { return .gemini }
        return nil
    }
}
