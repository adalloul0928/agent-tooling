import Foundation

/// Ownership describes the author, independently of who maintains an installed copy.
/// Plugin attribution comes from scan metadata, never a package name or cache path guess.
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
        // Exact marketplace identities, not skill names or the fact that a file is local.
        // Agent Tooling is this application's personal workflow catalog.
        let publisher = pluginID?.split(separator: "@", maxSplits: 1).dropFirst().first.map(String.init)?.lowercased()
        if publisher == "agent-tooling" {
            return Classification(owner: "mine", reason: "From your Agent Tooling marketplace")
        }
        let externalPublishers: Set<String> = [
            "claude-plugins-official", "anthropic-agent-skills", "callstack-agent-skills",
            "openai-bundled", "openai-curated-remote", "openai-primary-runtime", "toolingtools",
        ]
        if let publisher, externalPublishers.contains(publisher) {
            return Classification(owner: "thirdParty", reason: "Published by \(publisher)")
        }
        return Classification(owner: "unknown", reason: "No recognized publisher; a local installation alone does not establish authorship")
    }
}
