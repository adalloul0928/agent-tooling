import AgentToolingCore
import Foundation

/// Authorship, maintenance, and distribution are separate dimensions. A catalog
/// listing alone does not establish that OpenAI or Anthropic wrote a skill.
enum SkillOrganization {
    static func ownershipKey(skillID: String, pluginID: String?) -> String {
        if let pluginID, !pluginID.isEmpty { return "source:" + pluginID }
        return "skill:" + skillID
    }

    struct Classification {
        var owner: String
        var reason: String
    }

    static func classify(maintainedHere: Bool, pluginID: String?, override: String?) -> Classification {
        if let override, ["mine", "thirdParty", "unknown"].contains(override) {
            return Classification(owner: override, reason: "Your saved classification")
        }
        if maintainedHere {
            return Classification(owner: "mine", reason: "Created or copied into your library")
        }
        let source = ConnectionSource(pluginID ?? "")
        if source.marketplace == "agent-tooling" {
            return Classification(owner: "mine", reason: "From your Agent Tooling marketplace")
        }
        if let provider = directProvider(pluginID: pluginID) {
            return Classification(owner: "provider", reason: "Supplied directly by \(provider)")
        }
        // These catalogs have a known independent publisher. The general
        // OpenAI/Claude directories mix authors, so they remain unclassified.
        if let marketplace = source.marketplace, ["callstack-agent-skills", "toolingtools"].contains(marketplace) {
            return Classification(owner: "thirdParty", reason: "From \(source.marketplaceTitle ?? marketplace)")
        }
        return Classification(
            owner: "unknown",
            reason: "Publisher not established. A marketplace listing or local installation does not establish authorship.")
    }

    static func directProvider(pluginID: String?) -> String? {
        let source = ConnectionSource(pluginID ?? "")
        guard let plugin = source.plugin, let marketplace = source.marketplace else { return nil }
        if ["openai-bundled", "openai-primary-runtime"].contains(marketplace) { return "OpenAI" }
        // This exact package declares Anthropic as its author. Other entries
        // in the same marketplace may be third-party and do not inherit it.
        // https://github.com/anthropics/claude-plugins-official/blob/main/plugins/frontend-design/.claude-plugin/plugin.json
        if marketplace == "claude-plugins-official", plugin == "frontend-design" { return "Anthropic" }
        if marketplace == "anthropic-agent-skills", ["document-skills", "example-skills"].contains(plugin) { return "Anthropic" }
        return nil
    }
}

enum SkillScope: String, CaseIterable, Identifiable {
    case all = "All skills"
    case mine = "My skills"
    case provider = "OpenAI & Anthropic"
    case thirdParty = "Third-party"
    var id: String { rawValue }

    func matches(owner: String) -> Bool {
        switch self {
        case .all: true
        case .mine: owner == "mine"
        case .provider: owner == "provider"
        case .thirdParty: owner == "thirdParty"
        }
    }
}

enum SkillGrouping: String, CaseIterable, Identifiable {
    case none = "None"
    case plugin = "Plugin"
    case marketplace = "Marketplace"
    case maintenance = "Maintenance"
    var id: String { rawValue }

    /// Source was the old default, not a deliberate request for the new Plugin
    /// grouping. Preserve other valid saved choices; callers persist this once.
    static func migratedValue(_ value: String) -> Self {
        Self(rawValue: value) ?? .none
    }
}

struct SkillPresentation: Equatable {
    var pluginID: String?
    var pluginName: String?
    var marketplaceID: String?
    var marketplaceName: String?

    init(pluginID: String?, pluginDisplayName: String? = nil) {
        self.pluginID = pluginID?.isEmpty == false ? pluginID : nil
        let source = ConnectionSource(pluginID ?? "")
        marketplaceID = source.marketplace
        marketplaceName = source.marketplaceTitle
        if let pluginID = self.pluginID {
            pluginName = ConnectionSource.pluginName(pluginDisplayName ?? source.pluginTitle ?? pluginID, identifier: pluginID)
        }
    }

    func matches(marketplace: String, plugin: String) -> Bool {
        (marketplace.isEmpty || marketplaceID == marketplace) && (plugin.isEmpty || pluginID == plugin)
    }

    var compactDescription: String? {
        let parts = [pluginName, marketplaceName].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}

struct SkillListGroup: Identifiable {
    var id: String
    var title: String
    var subtitle: String?
    var skills: [Skill]
}

enum SkillListPresentation {
    static func groups(
        skills: [Skill], grouping: SkillGrouping, presentation: (Skill) -> SkillPresentation
    ) -> [SkillListGroup] {
        var groups: [String: SkillListGroup] = [:]
        for skill in skills {
            let id: String
            let title: String
            var subtitle: String? = nil
            switch grouping {
            case .none:
                id = "none"
                title = ""
            case .plugin:
                let origin = presentation(skill)
                id = "plugin:" + (origin.pluginID ?? "standalone")
                title = origin.pluginName ?? "Standalone"
                subtitle = origin.marketplaceName
            case .marketplace:
                let origin = presentation(skill)
                id = "marketplace:" + (origin.marketplaceID ?? "none")
                title = origin.marketplaceName ?? "No marketplace"
            case .maintenance:
                id = skill.owned ? "maintenance:here" : "maintenance:elsewhere"
                title = skill.owned ? "Maintained here" : "Maintained elsewhere"
            }
            if groups[id] == nil { groups[id] = SkillListGroup(id: id, title: title, subtitle: subtitle, skills: []) }
            groups[id]?.skills.append(skill)
        }
        return groups.values.map { group in
            var sorted = group
            sorted.skills.sort {
                let order = $0.displayName.localizedStandardCompare($1.displayName)
                return order == .orderedSame ? $0.id < $1.id : order == .orderedAscending
            }
            return sorted
        }.sorted {
            let order = $0.title.localizedStandardCompare($1.title)
            return order == .orderedSame ? $0.id < $1.id : order == .orderedAscending
        }
    }
}
