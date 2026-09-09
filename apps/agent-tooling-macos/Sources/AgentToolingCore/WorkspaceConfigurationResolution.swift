import Foundation

public enum WorkspaceConfigurationResolutionError: Error, Equatable, Sendable {
    case missingConfigurationState
    case missingConfiguration(WorkspaceObjectID)
    case managedPolicyTemplate(WorkspaceObjectID)
    case invalidInheritanceOrigin(child: WorkspaceObjectID, parent: WorkspaceObjectID)
}

/// Portable configuration intent resolved without consulting device inventory,
/// app visibility, or the retained legacy snapshot.
public struct WorkspaceConfigurationResolution: Hashable, Sendable {
    public let selectedConfigurationID: WorkspaceObjectID
    public let selectedOrigin: WorkspaceConfigurationOrigin
    /// Ordered from the oldest ancestor to the selected configuration.
    public let contributingConfigurationIDs: [WorkspaceObjectID]
    public let requiredSkills: [WorkspaceReference]
    public let enabledPlugins: [WorkspaceReference]
    public let requiredMCPs: [WorkspaceReference]
    public let includedCollections: [WorkspaceReference]
    /// Ordered by contributing configuration, with inherited duplicate IDs removed.
    public let checkDefinitions: [WorkspaceConfigurationCheckDefinition]
    /// The selected-to-root chain's first non-nil value. Nil and empty remain distinct.
    public let targetBindings: [WorkspaceConfigurationTargetBinding]?
}

public enum WorkspaceConfigurationResolver {
    public static func resolve(
        document: PortableWorkspaceDocument,
        configurationID: WorkspaceObjectID
    ) throws -> WorkspaceConfigurationResolution {
        try document.validateStructure()
        guard let state = document.configurationState else {
            throw WorkspaceConfigurationResolutionError.missingConfigurationState
        }

        let configurations = Dictionary(uniqueKeysWithValues: state.configurations.map { ($0.id, $0) })
        guard let selected = configurations[configurationID] else {
            throw WorkspaceConfigurationResolutionError.missingConfiguration(configurationID)
        }
        guard selected.origin == .personal else {
            throw WorkspaceConfigurationResolutionError.managedPolicyTemplate(configurationID)
        }

        var selectedToRoot: [WorkspaceConfigurationRecord] = []
        var cursor: WorkspaceConfigurationRecord? = selected
        while let configuration = cursor {
            selectedToRoot.append(configuration)
            guard let parentReference = configuration.inheritedFrom,
                  case .object(let parentID) = parentReference.resolution,
                  let parent = configurations[parentID]
            else {
                cursor = nil
                continue
            }
            guard parent.origin == .personal else {
                throw WorkspaceConfigurationResolutionError.invalidInheritanceOrigin(
                    child: configuration.id, parent: parent.id)
            }
            cursor = parent
        }

        let ancestorFirst = Array(selectedToRoot.reversed())
        var requiredSkills = ReferenceUnion()
        var enabledPlugins = ReferenceUnion()
        var requiredMCPs = ReferenceUnion()
        var includedCollections = ReferenceUnion()
        var checkDefinitions: [WorkspaceConfigurationCheckDefinition] = []
        var seenCheckIDs = Set<String>()

        for configuration in ancestorFirst {
            requiredSkills.insert(contentsOf: configuration.requiredSkills)
            enabledPlugins.insert(contentsOf: configuration.enabledPlugins)
            requiredMCPs.insert(contentsOf: configuration.requiredMCPs)
            includedCollections.insert(contentsOf: configuration.includedCollections)
            for check in configuration.checkDefinitions where seenCheckIDs.insert(check.id).inserted {
                checkDefinitions.append(check)
            }
        }

        let collections = Dictionary(uniqueKeysWithValues: state.collections.map { ($0.id, $0) })
        for reference in includedCollections.values {
            guard case .object(let collectionID) = reference.resolution,
                  let collection = collections[collectionID]
            else {
                // Full document validation rejects an unresolved or absent included collection.
                continue
            }
            for item in collection.items {
                switch item.legacy.domain {
                case .skill: requiredSkills.insert(item)
                case .plugin: enabledPlugins.insert(item)
                case .mcpServer: requiredMCPs.insert(item)
                case .configuration, .collection, .catalogSource, .policy: break
                }
            }
        }

        return WorkspaceConfigurationResolution(
            selectedConfigurationID: configurationID,
            selectedOrigin: selected.origin,
            contributingConfigurationIDs: ancestorFirst.map(\.id),
            requiredSkills: requiredSkills.sortedValues,
            enabledPlugins: enabledPlugins.sortedValues,
            requiredMCPs: requiredMCPs.sortedValues,
            includedCollections: includedCollections.sortedValues,
            checkDefinitions: checkDefinitions,
            targetBindings: selectedToRoot.lazy.compactMap(\.targetBindings).first)
    }
}

private struct ReferenceUnion {
    private var references: [LegacyReferenceKey: WorkspaceReference] = [:]

    var values: [WorkspaceReference] { Array(references.values) }
    var sortedValues: [WorkspaceReference] { values.sorted(by: referenceLessThan) }

    mutating func insert(_ reference: WorkspaceReference) {
        references[reference.legacy] = reference
    }

    mutating func insert(contentsOf newReferences: [WorkspaceReference]) {
        for reference in newReferences { insert(reference) }
    }
}

private func referenceLessThan(_ lhs: WorkspaceReference, _ rhs: WorkspaceReference) -> Bool {
    let left = lhs.legacy
    let right = rhs.legacy
    if left.domain != right.domain { return left.domain.rawValue < right.domain.rawValue }
    if left.ownerPolicyID != right.ownerPolicyID {
        return (left.ownerPolicyID ?? "") < (right.ownerPolicyID ?? "")
    }
    if left.identifier != right.identifier { return left.identifier < right.identifier }
    return resolutionSortKey(lhs.resolution) < resolutionSortKey(rhs.resolution)
}

private func resolutionSortKey(_ resolution: WorkspaceReferenceResolution) -> String {
    switch resolution {
    case .artifact(let id): "artifact:\(id.rawValue.uuidString.lowercased())"
    case .object(let id): "object:\(id.rawValue.uuidString.lowercased())"
    case .unresolved: "unresolved"
    }
}
