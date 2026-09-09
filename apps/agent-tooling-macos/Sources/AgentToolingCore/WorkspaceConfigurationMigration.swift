import Foundation

/// One translated legacy reference, retained even when its target is absent so
/// a preview never hides data loss behind a best-effort conversion.
public struct WorkspaceConfigurationMigrationCoverage: Hashable, Sendable {
    public var position: String
    public var reference: WorkspaceReference
    public var owner: LegacyReferenceKey?

    public init(position: String, reference: WorkspaceReference, owner: LegacyReferenceKey? = nil) {
        self.position = position
        self.reference = reference
        self.owner = owner
    }
}

public enum WorkspaceConfigurationMigrationBlockerKind: String, Hashable, Sendable {
    case duplicateIdentity, missingParent, inheritanceCycle, missingCollection, activeConfigurationAmbiguous, ambiguousReference
    case invalidPath, invalidCatalogLocation, unmappedArtifact, missingConfiguration, structuralValidation
}

public struct WorkspaceConfigurationMigrationBlocker: Hashable, Sendable {
    public var kind: WorkspaceConfigurationMigrationBlockerKind
    public var reference: LegacyReferenceKey?
    public var detail: String

    public init(kind: WorkspaceConfigurationMigrationBlockerKind, reference: LegacyReferenceKey? = nil, detail: String) {
        self.kind = kind
        self.reference = reference
        self.detail = detail
    }
}

public struct WorkspaceConfigurationMigrationPreview: Hashable, Sendable {
    public var state: WorkspaceConfigurationState
    public var deviceState: WorkspaceConfigurationDeviceState
    public var coverage: [WorkspaceConfigurationMigrationCoverage]
    public var blockers: [WorkspaceConfigurationMigrationBlocker]

    /// This only describes the configuration packet. Inventory, content,
    /// receipts, preferences, and other workspace records have separate
    /// migration work before a whole workspace can be declared ready.
    public var canMigrateConfigurations: Bool { blockers.isEmpty }

    public init(
        state: WorkspaceConfigurationState,
        deviceState: WorkspaceConfigurationDeviceState,
        coverage: [WorkspaceConfigurationMigrationCoverage],
        blockers: [WorkspaceConfigurationMigrationBlocker]
    ) {
        self.state = state
        self.deviceState = deviceState
        self.coverage = coverage
        self.blockers = blockers
    }
}

/// Stateless translation of the legacy snapshot into the portable
/// configuration records. It does not write a store, create artifacts, infer
/// authority, or turn observed client assignments into deployment routes.
public enum WorkspaceConfigurationMigration {
    public static func preview(
        snapshot: WorkspaceSnapshot,
        workspaceID: WorkspaceObjectID,
        artifactBindings: [LegacyReferenceKey: ArtifactID],
        projectBindings: [LegacyReferenceKey: ArtifactID] = [:],
        preserving: [WorkspaceMigrationIdentityEntry] = []
    ) throws -> WorkspaceConfigurationMigrationPreview {
        var keys = Set<LegacyReferenceKey>()
        var blockers: [WorkspaceConfigurationMigrationBlocker] = []
        var coverage: [WorkspaceConfigurationMigrationCoverage] = []
        var coverageOwner: LegacyReferenceKey?
        var ambiguousCoverageIndices: Set<Int> = []

        let personalProfiles = snapshot.profiles.map { (key: configurationKey($0.id), profile: $0, policyID: String?.none) }
        let managedProfiles = snapshot.managedPolicies.flatMap { policy in
            policy.profiles.map { (key: configurationKey($0.id, policyID: policy.id), profile: $0, policyID: policy.id) }
        }
        let allProfiles = personalProfiles + managedProfiles
        let profileKeys = Set(allProfiles.map(\.key))
        let projectProfileKeys = Set(allProfiles.compactMap { entry in
            [.project, .localProject].contains(entry.profile.scope) ? entry.key : nil
        })
        var acceptedProjectBindings: [LegacyReferenceKey: ArtifactID] = [:]
        for key in projectBindings.keys.sorted(by: { lhs, rhs in
            if lhs.domain != rhs.domain { return lhs.domain.rawValue < rhs.domain.rawValue }
            if lhs.ownerPolicyID != rhs.ownerPolicyID { return (lhs.ownerPolicyID ?? "") < (rhs.ownerPolicyID ?? "") }
            return lhs.identifier < rhs.identifier
        }) {
            guard projectProfileKeys.contains(key) else {
                blockers.append(.init(
                    kind: .invalidPath,
                    reference: key,
                    detail: "A supplied logical project binding does not identify a live project-scoped configuration."
                ))
                continue
            }
            acceptedProjectBindings[key] = projectBindings[key]
        }
        let collectionKeys = Set(snapshot.collections.map { collectionKey($0.id) })
        let policyKeys = Set(snapshot.managedPolicies.map { policyKey($0.id) })
        let catalogKeys = Set(snapshot.sources.map { catalogKey($0.id) })
        let existingObjectKeys = profileKeys.union(collectionKeys).union(policyKeys).union(catalogKeys)

        func add(_ key: LegacyReferenceKey) { keys.insert(key) }
        func artifactReference(_ key: LegacyReferenceKey, position: String) -> WorkspaceReference {
            add(key)
            let reference = WorkspaceReference(legacy: key, resolution: artifactBindings[key].map(WorkspaceReferenceResolution.artifact) ?? .unresolved)
            coverage.append(.init(position: "\(position)[\(coverage.count)]<\(key.domain.rawValue):\(key.ownerPolicyID ?? "personal"):\(key.identifier)>", reference: reference, owner: coverageOwner))
            return reference
        }
        func objectReference(_ key: LegacyReferenceKey, position: String) -> WorkspaceReference {
            add(key)
            // Filled after deterministic identity allocation below.
            let reference = WorkspaceReference(legacy: key, resolution: .unresolved)
            coverage.append(.init(position: "\(position)[\(coverage.count)]<\(key.domain.rawValue):\(key.ownerPolicyID ?? "personal"):\(key.identifier)>", reference: reference, owner: coverageOwner))
            return reference
        }

        if !snapshot.activeProfileID.isEmpty { add(configurationKey(snapshot.activeProfileID)) }
        for key in profileKeys { add(key) }
        for key in collectionKeys { add(key) }
        for policy in snapshot.managedPolicies { add(policyKey(policy.id)) }
        for source in snapshot.sources { add(catalogKey(source.id)) }
        // Allocation happens once, before translating records. Include every
        // referenced key now, including absent inventory rows, so unresolved
        // references retain deterministic identity-map coverage.
        for entry in allProfiles {
            let profile = entry.profile
            if let parent = profile.inheritedFrom { add(configurationKey(parent, policyID: entry.policyID)) }
            profile.enabledPlugins.forEach { add(artifactKey(domain: .plugin, $0)) }
            profile.requiredMCPs.forEach { add(artifactKey(domain: .mcpServer, $0)) }
            profile.requiredSkills.forEach { add(artifactKey(domain: .skill, $0)) }
            profile.includedCollections.forEach { add(collectionKey($0)) }
            profile.targetBindings?.forEach { add(artifactKey(item: $0.item.kind, $0.item.identifier)) }
        }
        for policy in snapshot.managedPolicies {
            policy.requiredPluginIDs.forEach { add(artifactKey(domain: .plugin, $0)) }
            policy.requiredMCPIDs.forEach { add(artifactKey(domain: .mcpServer, $0)) }
            policy.blockedPluginIDs.forEach { add(artifactKey(domain: .plugin, $0)) }
        }
        for collection in snapshot.collections {
            collection.items.forEach { add(artifactKey(item: $0.kind, $0.identifier)) }
        }
        for assignment in snapshot.tagAssignments { add(artifactKey(item: assignment.item.kind, assignment.item.identifier)) }
        for package in snapshot.marketplacePackages where package.sourceID != nil { add(catalogKey(package.sourceID!)) }
        for plugin in snapshot.plugins {
            add(artifactKey(domain: .plugin, plugin.id))
            plugin.skills.forEach { add(artifactKey(domain: .skill, $0)) }
            plugin.profiles.forEach { add(configurationKey($0)) }
        }
        for skill in snapshot.skills where !skill.bundle.isEmpty {
            add(artifactKey(domain: .skill, skill.id))
            add(artifactKey(domain: .plugin, skill.bundle))
        }

        // Artifact bindings only establish reference resolution. Reserving the
        // same UUID in the identity map makes that resolution deterministic;
        // it does not claim content ownership or manufacture an artifact.
        var seededByKey: [LegacyReferenceKey: WorkspaceMigrationIdentityEntry] = [:]
        var seededOwners: [WorkspaceObjectID: LegacyReferenceKey] = [:]
        func preserve(_ entry: WorkspaceMigrationIdentityEntry, reason: String) {
            if let existing = seededByKey[entry.legacy], existing.objectID != entry.objectID {
                blockers.append(.init(kind: .duplicateIdentity, reference: entry.legacy, detail: reason))
                return
            }
            if let owner = seededOwners[entry.objectID], owner != entry.legacy {
                blockers.append(.init(kind: .duplicateIdentity, reference: entry.legacy, detail: reason))
                return
            }
            seededByKey[entry.legacy] = entry
            seededOwners[entry.objectID] = entry.legacy
        }
        for entry in preserving {
            preserve(entry, reason: "Preserved migration identities conflict.")
        }
        for (key, artifactID) in artifactBindings.sorted(by: { lhs, rhs in
            let left = "\(lhs.key.domain.rawValue)|\(lhs.key.ownerPolicyID ?? "")|\(lhs.key.identifier)"
            let right = "\(rhs.key.domain.rawValue)|\(rhs.key.ownerPolicyID ?? "")|\(rhs.key.identifier)"
            return left < right
        }) where key.domain.isArtifact {
            let entry = WorkspaceMigrationIdentityEntry(legacy: key, objectID: WorkspaceObjectID(artifactID.rawValue))
            preserve(entry, reason: "Supplied artifact bindings assign the same legacy key or UUID more than once.")
            add(key)
        }
        let seeded = seededByKey.values.sorted {
            let left = "\($0.legacy.domain.rawValue)|\($0.legacy.ownerPolicyID ?? "")|\($0.legacy.identifier)"
            let right = "\($1.legacy.domain.rawValue)|\($1.legacy.ownerPolicyID ?? "")|\($1.legacy.identifier)"
            return left < right
        }
        let identityMap = try WorkspaceMigrationIdentity.mapping(keys: keys, workspaceID: workspaceID, preserving: seeded)
        let identities = Dictionary(uniqueKeysWithValues: identityMap.map { ($0.legacy, $0.objectID) })
        func resolvedObject(_ reference: WorkspaceReference) -> WorkspaceReference {
            guard existingObjectKeys.contains(reference.legacy), let id = identities[reference.legacy] else {
                blockers.append(.init(kind: reference.legacy.domain == .catalogSource ? .invalidCatalogLocation : .missingConfiguration,
                                      reference: reference.legacy, detail: "Referenced legacy object is absent."))
                return reference
            }
            return WorkspaceReference(legacy: reference.legacy, resolution: .object(id))
        }

        let knownArtifacts = Set(snapshot.skills.map { artifactKey(domain: .skill, $0.id) })
            .union(snapshot.plugins.map { artifactKey(domain: .plugin, $0.id) })
            .union(snapshot.mcpServers.map { artifactKey(domain: .mcpServer, $0.id) })
        for key in knownArtifacts where artifactBindings[key] == nil {
            blockers.append(.init(kind: .unmappedArtifact, reference: key, detail: "Present legacy artifact has no supplied artifact binding."))
        }

        var configurations: [WorkspaceConfigurationRecord] = []
        var deviceBindings: [ConfigurationDeviceBinding] = []
        var observations: [ConfigurationCheckObservation] = []
        for entry in allProfiles {
            let profile = entry.profile
            let key = entry.key
            coverageOwner = key
            let configurationID = identities[key]!
            let origin: WorkspaceConfigurationOrigin
            if let policyID = entry.policyID { origin = .managedPolicy(policyID: identities[policyKey(policyID)]!) }
            else { origin = .personal }
            let inheritedFrom = profile.inheritedFrom.map {
                objectReference(configurationKey($0, policyID: entry.policyID), position: "configuration.inheritedFrom")
            }.map(resolvedObject)
            if let parent = profile.inheritedFrom,
                !profileKeys.contains(configurationKey(parent, policyID: entry.policyID))
            {
                blockers.append(.init(kind: .missingParent, reference: key, detail: "Configuration inherits from missing configuration \(parent)."))
            }
            let collections = profile.includedCollections.map {
                objectReference(collectionKey($0), position: "configuration.includedCollections")
            }.map(resolvedObject)
            for collection in profile.includedCollections where !collectionKeys.contains(collectionKey(collection)) {
                blockers.append(.init(kind: .missingCollection, reference: key, detail: "Configuration includes missing collection \(collection)."))
            }
            let pluginReferences = profile.enabledPlugins.map {
                artifactReference(artifactKey(domain: .plugin, $0), position: "configuration.enabledPlugins")
            }
            let mcpReferences = profile.requiredMCPs.map {
                artifactReference(artifactKey(domain: .mcpServer, $0), position: "configuration.requiredMCPs")
            }
            let skillReferences = profile.requiredSkills.map {
                artifactReference(artifactKey(domain: .skill, $0), position: "configuration.requiredSkills")
            }
            let bindings: [WorkspaceConfigurationTargetBinding]? = profile.targetBindings.map { bindings in
                bindings.map { binding in
                    .init(item: artifactReference(artifactKey(item: binding.item.kind, binding.item.identifier), position: "configuration.targetBindings"),
                          client: binding.client, enabled: binding.enabled)
                }
            }
            var logicalProjectID: ArtifactID?
            if profile.scope == .project || profile.scope == .localProject {
                logicalProjectID = acceptedProjectBindings[key]
                if logicalProjectID == nil {
                    blockers.append(.init(kind: .invalidPath, reference: key, detail: "Project configuration has no supplied logical project binding."))
                }
            }
            if [.project, .localProject, .workspace].contains(profile.scope), profile.projectRoot == nil {
                blockers.append(.init(kind: .invalidPath, reference: key, detail: "Scoped configuration is missing its local project root."))
            }
            if let root = profile.projectRoot {
                if (try? WorkspaceDomainValidation.requireAbsolutePath(root, field: "configuration project root")) != nil {
                    deviceBindings.append(.init(configurationID: configurationID, projectRoot: root))
                } else {
                    blockers.append(.init(kind: .invalidPath, reference: key, detail: "Configuration project root is not absolute."))
                }
            }
            let definitions = profile.checks.map { WorkspaceConfigurationCheckDefinition(id: $0.id, name: $0.name, manual: $0.manual) }
            observations += profile.checks.map {
                .init(configurationID: configurationID, checkID: $0.id, detail: $0.detail, state: $0.state)
            }
            configurations.append(.init(
                id: configurationID, name: profile.name, summary: profile.summary, origin: origin, inheritedFrom: inheritedFrom,
                scope: profile.scope, logicalProjectID: logicalProjectID, enabledPlugins: pluginReferences,
                requiredMCPs: mcpReferences, requiredSkills: skillReferences, includedCollections: collections,
                checkDefinitions: definitions, targetBindings: bindings
            ))
        }

        var policies: [WorkspaceManagedPolicyRecord] = []
        var policyImports: [ManagedPolicyDeviceImport] = []
        for policy in snapshot.managedPolicies {
            coverageOwner = policyKey(policy.id)
            let policyID = identities[policyKey(policy.id)]!
            let configurationReferences = policy.profiles.map {
                objectReference(configurationKey($0.id, policyID: policy.id), position: "policy.configurations")
            }.map(resolvedObject)
            policies.append(.init(
                id: policyID, name: policy.name,
                requiredPlugins: policy.requiredPluginIDs.map { artifactReference(artifactKey(domain: .plugin, $0), position: "policy.requiredPlugins") },
                requiredMCPs: policy.requiredMCPIDs.map { artifactReference(artifactKey(domain: .mcpServer, $0), position: "policy.requiredMCPs") },
                blockedPlugins: policy.blockedPluginIDs.map { artifactReference(artifactKey(domain: .plugin, $0), position: "policy.blockedPlugins") },
                configurations: configurationReferences
            ))
            if policy.sourcePath.hasPrefix("/") {
                policyImports.append(.init(policyID: policyID, sourcePath: policy.sourcePath, importedAt: policy.importedAt))
            } else {
                blockers.append(.init(kind: .invalidPath, reference: policyKey(policy.id), detail: "Managed policy source path is not absolute."))
            }
        }

        let collections = snapshot.collections.map { collection -> WorkspaceCollectionRecord in
            let key = collectionKey(collection.id)
            coverageOwner = key
            return .init(id: identities[key]!, name: collection.name, summary: collection.summary,
                         items: collection.items.map { artifactReference(artifactKey(item: $0.kind, $0.identifier), position: "collection.items") },
                         createdAt: collection.createdAt)
        }
        coverageOwner = nil
        let tags = snapshot.tagAssignments.map {
            WorkspaceTagAssignment(item: artifactReference(artifactKey(item: $0.item.kind, $0.item.identifier), position: "tag.item"), tags: $0.tags)
        }

        var catalogs: [WorkspaceCatalogSourceRecord] = []
        var catalogDevice: [CatalogSourceDeviceState] = []
        for source in snapshot.sources {
            let key = catalogKey(source.id)
            let id = identities[key]!
            let location = source.location.trimmingCharacters(in: .whitespacesAndNewlines)
            let remote = credentialFreeRemote(location)
            let isAbsoluteLocal = (try? WorkspaceDomainValidation.requireAbsolutePath(location, field: "local catalog location")) != nil
            let localLocation = isAbsoluteLocal ? location : nil
            catalogDevice.append(.init(catalogSourceID: id, localLocation: localLocation, lastRefreshedAt: source.lastRefreshedAt,
                                       lastRevision: source.lastRevision, trustSummary: source.trustSummary))
            if let remote {
                catalogs.append(.init(id: id, name: source.name, kind: source.kind, remoteLocation: remote, isOptionalBackup: source.isOptionalBackup))
            } else {
                catalogs.append(.init(id: id, name: source.name, kind: source.kind, isOptionalBackup: source.isOptionalBackup))
                if !isAbsoluteLocal {
                    blockers.append(.init(kind: .invalidCatalogLocation, reference: key,
                                          detail: "Catalog location is neither an absolute local path nor a credential-free HTTP(S) URL."))
                }
            }
        }
        for package in snapshot.marketplacePackages {
            if let sourceID = package.sourceID {
                _ = resolvedObject(objectReference(catalogKey(sourceID), position: "marketplace[\(package.id)].sourceID"))
            }
        }

        var relationships: [WorkspaceLegacyRelationshipRecord] = []
        for plugin in snapshot.plugins {
            coverageOwner = artifactKey(domain: .plugin, plugin.id)
            let source = artifactReference(artifactKey(domain: .plugin, plugin.id), position: "relationship.plugin")
            for skillID in plugin.skills {
                relationships.append(.init(kind: .pluginSkill, source: source,
                                           destination: artifactReference(artifactKey(domain: .skill, skillID), position: "relationship.pluginSkill")))
            }
            for profileID in plugin.profiles {
                var destination = resolvedObject(objectReference(configurationKey(profileID), position: "relationship.pluginProfile"))
                if allProfiles.filter({ $0.profile.id == profileID }).count > 1 {
                    destination.resolution = .unresolved
                    ambiguousCoverageIndices.insert(coverage.count - 1)
                    blockers.append(.init(kind: .ambiguousReference, reference: configurationKey(profileID),
                        detail: "Plugin configuration reference matches more than one personal or policy configuration."))
                }
                if !profileKeys.contains(configurationKey(profileID)) {
                    blockers.append(.init(kind: .missingConfiguration, reference: configurationKey(profileID),
                                          detail: "Plugin references a missing personal configuration."))
                }
                relationships.append(.init(kind: .pluginProfile, source: source, destination: destination))
            }
        }
        for skill in snapshot.skills where !skill.bundle.isEmpty {
            coverageOwner = artifactKey(domain: .skill, skill.id)
            // Bundle names were labels, not native parentage. Preserve only the
            // weak legacy relationship and never derive ownership from it.
            relationships.append(.init(kind: .skillBundle,
                                       source: artifactReference(artifactKey(domain: .skill, skill.id), position: "relationship.skillBundle"),
                                       destination: artifactReference(artifactKey(domain: .plugin, skill.bundle), position: "relationship.skillBundle")))
        }

        let activeMatches = allProfiles.filter { $0.profile.id == snapshot.activeProfileID }
        let activeID: WorkspaceObjectID?
        if snapshot.activeProfileID.isEmpty { activeID = nil }
        else if activeMatches.count == 1, activeMatches[0].policyID == nil { activeID = identities[activeMatches[0].key] }
        else {
            activeID = nil
            blockers.append(.init(kind: .activeConfigurationAmbiguous, detail: "Active configuration is missing or ambiguous."))
        }
        if !snapshot.activeProfileID.isEmpty {
            let activeKey = configurationKey(snapshot.activeProfileID)
            coverage.append(.init(position: "activeConfigurationOverrideID[0]", reference: resolvedObject(
                WorkspaceReference(legacy: activeKey, resolution: .unresolved))))
        }
        for duplicate in duplicateKeys(allProfiles.map(\.key)) {
            blockers.append(.init(kind: .duplicateIdentity, reference: duplicate, detail: "Duplicate legacy configuration identity."))
        }
        for duplicate in duplicateKeys(snapshot.collections.map { collectionKey($0.id) }) {
            blockers.append(.init(kind: .duplicateIdentity, reference: duplicate, detail: "Duplicate legacy collection identity."))
        }
        blockers += inheritanceCycleBlockers(configurations: allProfiles)

        let state = WorkspaceConfigurationState(
            configurations: configurations, managedPolicies: policies, collections: collections, tagAssignments: tags,
            catalogSources: catalogs, legacyRelationships: relationships, identityMap: identityMap,
            defaultConfigurationID: nil // The shared default remains unset; active selection is device-local.
        )
        // Allocations do not imply the object exists. Artifact references remain
        // unresolved until an independently supplied artifact binding exists.
        coverage = coverage.enumerated().map { index, original in
            var item = original
            if ambiguousCoverageIndices.contains(index) {
                item.reference.resolution = .unresolved
            } else if !item.reference.legacy.domain.isArtifact {
                item.reference = resolvedObject(item.reference)
            }
            return item
        }
        let deviceState = WorkspaceConfigurationDeviceState(activeConfigurationOverrideID: activeID, configurationBindings: deviceBindings,
                                                             checkObservations: observations, catalogSources: catalogDevice, policyImports: policyImports)
        var validationArtifacts = artifactBindings.compactMap { key, id -> ArtifactRecord? in
            let kind: ArtifactKind
            switch key.domain {
            case .skill: kind = .skill
            case .plugin: kind = .nativePlugin
            case .mcpServer: kind = .mcpServer
            case .configuration, .collection, .catalogSource, .policy: return nil
            }
            return .init(identity: .init(id: id, kind: kind, displayName: key.identifier), authority: .trackedOnly)
        }
        let projectIDs = Set(acceptedProjectBindings.values)
        let artifactIDs = Set(validationArtifacts.map(\.identity.id))
        let objectIDs = Set(state.configurations.map(\.id)
            + state.managedPolicies.map(\.id)
            + state.collections.map(\.id)
            + state.catalogSources.map(\.id)).map { ArtifactID($0.rawValue) }
        for (key, projectID) in acceptedProjectBindings where artifactIDs.contains(projectID) || objectIDs.contains(projectID) {
            blockers.append(.init(kind: .duplicateIdentity, reference: key,
                                  detail: "Supplied logical project binding reuses an artifact or configuration object identity."))
        }
        validationArtifacts += projectIDs.sorted().map {
            .init(identity: .init(id: $0, kind: .logicalProject, displayName: "Migration binding"), authority: .trackedOnly)
        }
        let validationProjects = projectIDs.sorted().map { LogicalProjectRecord(id: $0, name: "Migration binding") }
        do {
            try state.validate(artifacts: validationArtifacts, logicalProjects: validationProjects)
            try deviceState.validate(against: state)
        } catch {
            blockers.append(.init(kind: .structuralValidation, detail: "Translated configuration records fail structural validation: \(error.localizedDescription)"))
        }
        return .init(state: state, deviceState: deviceState,
                     coverage: coverage, blockers: blockers)
    }

    private static func artifactKey(item kind: ToolingItemKind, _ id: String) -> LegacyReferenceKey {
        artifactKey(domain: kind == .skill ? .skill : kind == .plugin ? .plugin : .mcpServer, id)
    }
    private static func artifactKey(domain: LegacyReferenceDomain, _ id: String) -> LegacyReferenceKey { .init(domain: domain, identifier: id) }
    private static func configurationKey(_ id: String, policyID: String? = nil) -> LegacyReferenceKey {
        .init(domain: .configuration, identifier: id, ownerPolicyID: policyID)
    }
    private static func collectionKey(_ id: String) -> LegacyReferenceKey { .init(domain: .collection, identifier: id) }
    private static func policyKey(_ id: String) -> LegacyReferenceKey { .init(domain: .policy, identifier: id) }
    private static func catalogKey(_ id: UUID) -> LegacyReferenceKey { .init(domain: .catalogSource, identifier: id.uuidString.lowercased()) }

    private static func credentialFreeRemote(_ value: String) -> String? {
        guard let components = URLComponents(string: value), let scheme = components.scheme?.lowercased(),
              ["http", "https"].contains(scheme), components.host?.isEmpty == false, components.user == nil,
              components.password == nil, components.query == nil, components.fragment == nil
        else { return nil }
        return value
    }

    private static func duplicateKeys(_ keys: [LegacyReferenceKey]) -> [LegacyReferenceKey] {
        Dictionary(grouping: keys, by: { $0 }).compactMap { $0.value.count > 1 ? $0.key : nil }
    }

    private static func inheritanceCycleBlockers(
        configurations: [(key: LegacyReferenceKey, profile: ToolingProfile, policyID: String?)]
    ) -> [WorkspaceConfigurationMigrationBlocker] {
        let byKey = Dictionary(grouping: configurations, by: \.key)
        var result: [WorkspaceConfigurationMigrationBlocker] = []
        for configuration in configurations {
            var seen = Set<LegacyReferenceKey>()
            var current: LegacyReferenceKey? = configuration.key
            while let key = current {
                guard seen.insert(key).inserted else {
                    result.append(.init(kind: .inheritanceCycle, reference: configuration.key, detail: "Configuration inheritance contains a cycle."))
                    break
                }
                guard let next = byKey[key]?.first?.profile.inheritedFrom else { break }
                current = configurationKey(next, policyID: key.ownerPolicyID)
            }
        }
        return result
    }
}
