import Foundation

public enum OnboardingDisposition: String, Codable, Sendable {
    case managed, copyAvailable, nativePlugin, nativeMCP, unavailable

    public var displayName: String {
        switch self {
        case .managed: "Managed library"
        case .copyAvailable: "Managed by its source"
        case .nativePlugin: "Native plugin"
        case .nativeMCP: "Native configuration"
        case .unavailable: "Needs review"
        }
    }
}

public struct OnboardingCandidate: Identifiable, Hashable, Sendable {
    public var id: String { "\(kind.rawValue):\(itemID)" }
    public let itemID: String
    public let kind: ToolingItemKind
    public let name: String
    public let summary: String
    public let disposition: OnboardingDisposition
    public let clients: [ClientKind]
    public let guidance: String
    public let sourcePath: String?
    public let repositoryBinding: SkillRepositoryBinding?
    /// Exact native identifiers; two marketplaces can publish plugins with the
    /// same name, and one component can be observed in different bundles.
    public let providerPluginIDs: Set<String>
    public var providerPluginID: String? { providerPluginIDs.sorted().first }
    public var canCopy: Bool { kind == .skill && disposition == .copyAvailable && providerPluginIDs.isEmpty }
    /// A missing source prevents ownership changes, not tracking an existing
    /// installation. Bundled components are selected through their plugin.
    public var canTrack: Bool { providerPluginIDs.isEmpty }
    public var item: ToolingItemReference { .init(kind: kind, identifier: itemID) }

    public init(
        itemID: String, kind: ToolingItemKind, name: String, summary: String,
        disposition: OnboardingDisposition, clients: [ClientKind], guidance: String,
        sourcePath: String?, providerPluginID: String?, providerPluginIDs: Set<String> = [],
        repositoryBinding: SkillRepositoryBinding? = nil
    ) {
        self.itemID = itemID
        self.kind = kind
        self.name = name
        self.summary = summary
        self.disposition = disposition
        self.clients = clients
        self.guidance = guidance
        self.sourcePath = sourcePath
        self.repositoryBinding = repositoryBinding
        self.providerPluginIDs = providerPluginIDs.union(providerPluginID.map { [$0] } ?? [])
    }
}

/// A single scan's presentation data. Keep this value in the wizard rather
/// than rebuilding provenance and filtering the whole inventory in every row.
public struct OnboardingInventory: Sendable {
    public let candidates: [OnboardingCandidate]
    public let plugins: [OnboardingCandidate]
    public let standaloneSkills: [OnboardingCandidate]
    public let standaloneServers: [OnboardingCandidate]
    public let childrenByPluginID: [String: [OnboardingCandidate]]
    /// Plugin ID -> kind-qualified component ID -> clients that observed this
    /// exact relationship. This prevents merged inventory IDs from extending a
    /// plugin's components to another client's independently installed copy.
    let dependencyClients: [String: [String: Set<ClientKind>]]

    public init(
        candidates: [OnboardingCandidate],
        dependencyClients: [String: [String: Set<ClientKind>]]? = nil
    ) {
        var seen: Set<String> = []
        self.candidates = candidates.filter { seen.insert($0.id).inserted }
        plugins = self.candidates.filter { $0.kind == .plugin }
        standaloneSkills = self.candidates.filter { $0.kind == .skill && $0.providerPluginIDs.isEmpty }
        standaloneServers = self.candidates.filter { $0.kind == .mcpServer && $0.providerPluginIDs.isEmpty }
        var children: [String: [OnboardingCandidate]] = [:]
        for item in self.candidates where item.kind != .plugin {
            for provider in item.providerPluginIDs { children[provider, default: []].append(item) }
        }
        childrenByPluginID = children
        if let dependencyClients {
            self.dependencyClients = dependencyClients
        } else {
            var placements: [String: [String: Set<ClientKind>]] = [:]
            for plugin in plugins {
                for child in children[plugin.itemID, default: []] {
                    placements[plugin.itemID, default: [:]][child.id] = Set(child.clients).intersection(plugin.clients)
                }
            }
            self.dependencyClients = placements
        }
    }

    /// Drafts contain only whole plugins and standalone choices. Rebuilding
    /// inclusion from those roots makes removing a plugin remove its children,
    /// including when a caller passes a previously expanded selection.
    public func expandedSelection(_ selection: OnboardingSelection) -> OnboardingSelection {
        let bundledIDs = Set(candidates.filter { !$0.providerPluginIDs.isEmpty }.map(\.id))
        var result = selection
        result.itemIDs.subtract(bundledIDs)
        for plugin in plugins where result.itemIDs.contains(plugin.id) {
            result.itemIDs.formUnion(childrenByPluginID[plugin.itemID, default: []].map(\.id))
        }
        return result
    }

    public func selectedCandidates(for selection: OnboardingSelection) -> [OnboardingCandidate] {
        let expanded = expandedSelection(selection)
        return candidates.filter { expanded.itemIDs.contains($0.id) }
    }

    func clients(for item: OnboardingCandidate, selection: OnboardingSelection) -> Set<ClientKind> {
        guard !item.providerPluginIDs.isEmpty else { return Set(item.clients) }
        return item.providerPluginIDs.reduce(into: Set<ClientKind>()) { clients, provider in
            guard selection.itemIDs.contains("\(ToolingItemKind.plugin.rawValue):\(provider)") else { return }
            clients.formUnion(dependencyClients[provider]?[item.id] ?? [])
        }.intersection(item.clients)
    }
}

/// Saved with a configuration so a setup captured from one Mac does not turn
/// into an instruction to install every item into every enabled client.
public struct OnboardingTargetBinding: Identifiable, Codable, Hashable, Sendable {
    public var id: String { "\(item.id):\(client.rawValue)" }
    public let item: ToolingItemReference
    public let client: ClientKind
    public let enabled: Bool?

    public init(item: ToolingItemReference, client: ClientKind, enabled: Bool? = nil) {
        self.item = item
        self.client = client
        self.enabled = enabled
    }
}

public struct OnboardingSelection: Hashable, Sendable {
    public var configurationName: String
    /// Kind-qualified candidate IDs, such as `plugin:reviews@personal`.
    public var itemIDs: Set<String>
    /// Raw skill IDs. Copying is a separate, explicitly reviewed action.
    public var copySkillIDs: Set<String>

    public init(configurationName: String = "My setup", itemIDs: Set<String> = [], copySkillIDs: Set<String> = []) {
        self.configurationName = configurationName
        self.itemIDs = itemIDs
        self.copySkillIDs = copySkillIDs
    }

    /// Selecting an item records it without changing who owns its files.
    /// This is also the only selection path used by Select all.
    public mutating func setTracked(_ candidate: OnboardingCandidate, selected: Bool) {
        guard candidate.canTrack else { return }
        if selected {
            itemIDs.insert(candidate.id)
        } else {
            itemIDs.remove(candidate.id)
            copySkillIDs.remove(candidate.itemID)
        }
    }

    /// A personal copy is a separate opt-in, never a consequence of tracking.
    /// Cancelling the copy keeps the original installation in the setup.
    public mutating func setPersonalCopy(_ candidate: OnboardingCandidate, enabled: Bool) {
        guard candidate.canCopy else { return }
        if enabled {
            itemIDs.insert(candidate.id)
            copySkillIDs.insert(candidate.itemID)
        } else {
            copySkillIDs.remove(candidate.itemID)
        }
    }
}

public struct OnboardingPreview: Identifiable, Sendable {
    public let id: UUID
    public let selection: OnboardingSelection
    public let configurationID: String
    public let candidates: [OnboardingCandidate]
    public let targetBindings: [OnboardingTargetBinding]
    public let warnings: [String]
    public var copySkillIDs: Set<String> { selection.copySkillIDs }
    public var managedSkillCount: Int {
        candidates.count { $0.kind == .skill && ($0.disposition == .managed || copySkillIDs.contains($0.itemID)) }
    }
    public var nativeItemCount: Int {
        candidates.count { $0.kind != .skill || ($0.disposition != .managed && !copySkillIDs.contains($0.itemID)) }
    }
}

public struct OnboardingCompletion: Sendable {
    public let configurationID: String
    public let configurationName: String
    public let copiedSkillCount: Int
    public let managedSkillCount: Int
    public let trackedItemCount: Int
}
