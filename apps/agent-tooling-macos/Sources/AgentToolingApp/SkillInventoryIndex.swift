import AgentToolingCore
import Foundation

/// Derived once at the inventory boundary. Search, selection, and scrolling
/// read these values instead of repeatedly walking observations and decoding
/// saved classification JSON for each row.
struct SkillInventoryIndex {
    let skills: [Skill]
    let adoptableIDs: Set<String>
    let ownership: [String: String]
    let metadata: [String: ObservedSkillMetadata]
    let presentations: [String: SkillPresentation]
    let classifications: [String: SkillOrganization.Classification]
    let tags: [String: [String]]
    let collectionNames: [String: [String]]
    let skillTags: [String]
    let untaggedCount: Int
    let marketplaces: [(id: String, title: String)]
    let plugins: [(id: String, title: String)]
    let mineCount: Int
    let unknownCount: Int

    init(
        skills: [Skill], plugins: [Plugin], observations: [TargetObservation],
        tagAssignments: [TagAssignment], collections: [ToolingCollection],
        ownershipJSON: String, adoptableIDs: Set<String>
    ) {
        self.skills = skills
        self.adoptableIDs = adoptableIDs
        let ownership = (try? JSONDecoder().decode([String: String].self, from: Data(ownershipJSON.utf8))) ?? [:]
        self.ownership = ownership
        var metadata: [String: ObservedSkillMetadata] = [:]
        for observation in observations.sorted(by: { $0.surface.displayName < $1.surface.displayName }) {
            for (id, value) in observation.skillMetadata where metadata[id] == nil { metadata[id] = value }
        }
        self.metadata = metadata
        let pluginsByID = Dictionary(plugins.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var presentations: [String: SkillPresentation] = [:]
        var classifications: [String: SkillOrganization.Classification] = [:]
        var marketplaceNames: [String: String] = [:]
        var pluginNames: [String: String] = [:]
        var mineCount = 0
        var unknownCount = 0
        for skill in skills {
            let pluginID = metadata[skill.id]?.providerPluginID
            let origin = SkillPresentation(pluginID: pluginID, pluginDisplayName: pluginID.flatMap { pluginsByID[$0]?.name })
            presentations[skill.id] = origin
            let key = SkillOrganization.ownershipKey(skillID: skill.id, pluginID: pluginID)
            let classification = SkillOrganization.classify(maintainedHere: skill.owned, pluginID: pluginID, override: ownership[key])
            classifications[skill.id] = classification
            if classification.owner == "mine" { mineCount += 1 }
            if classification.owner == "unknown" { unknownCount += 1 }
            if let id = origin.marketplaceID { marketplaceNames[id] = ConnectionSource.title(id) }
            if let id = origin.pluginID, let name = origin.pluginName {
                pluginNames[id] = [name, origin.marketplaceName].compactMap { $0 }.joined(separator: " · ")
            }
        }
        self.presentations = presentations
        self.classifications = classifications
        self.mineCount = mineCount
        self.unknownCount = unknownCount
        self.marketplaces = marketplaceNames.map { (id: $0.key, title: $0.value) }
            .sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
        self.plugins = pluginNames.map { (id: $0.key, title: $0.value) }
            .sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
        var tags: [String: [String]] = [:]
        for assignment in tagAssignments where assignment.item.kind == .skill && tags[assignment.item.identifier] == nil {
            tags[assignment.item.identifier] = assignment.tags
        }
        self.tags = tags
        self.skillTags = Set(skills.flatMap { tags[$0.id] ?? [] })
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
        self.untaggedCount = skills.count { tags[$0.id, default: []].isEmpty }
        var collectionNames: [String: [String]] = [:]
        for collection in collections.sorted(by: { $0.name.localizedStandardCompare($1.name) == .orderedAscending }) {
            for item in Set(collection.items) where item.kind == .skill {
                collectionNames[item.identifier, default: []].append(collection.name)
            }
        }
        self.collectionNames = collectionNames
    }
}
