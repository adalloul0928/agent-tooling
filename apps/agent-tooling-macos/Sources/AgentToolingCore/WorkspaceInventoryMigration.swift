import Foundation

/// A decision supplied by an importer after it has verified source/package
/// identity and, for central content, complete-tree bytes. This is not evidence
/// that a filesystem operation has run. The pure converter cannot verify disk.
public struct WorkspaceInventoryMigrationResolution: Sendable {
    public var legacy: LegacyReferenceKey
    public var artifact: ArtifactRecord

    public init(legacy: LegacyReferenceKey, artifact: ArtifactRecord) {
        self.legacy = legacy
        self.artifact = artifact
    }
}

/// An explicit reviewed link from a locally relevant catalog row to one root
/// artifact. Catalog labels, install argv and package names never create it.
public struct WorkspaceMarketplaceMigrationResolution: Sendable {
    public var packageID: String
    public var artifact: ArtifactRecord
    public var linkedLegacy: LegacyReferenceKey?

    public init(packageID: String, artifact: ArtifactRecord, linkedLegacy: LegacyReferenceKey? = nil) {
        self.packageID = packageID
        self.artifact = artifact
        self.linkedLegacy = linkedLegacy
    }
}

public enum WorkspaceInventoryMigrationIssueKind: String, Hashable, Sendable {
    case unresolvedAuthority, invalidResolution, conflictingParentage
    case missingNativeEvidence, missingMaterialization, upstreamOwnershipLost
    case structuralValidation
    case unmappedMarketplacePackage
}

public struct WorkspaceInventoryMigrationIssue: Hashable, Sendable {
    public var kind: WorkspaceInventoryMigrationIssueKind
    public var legacy: LegacyReferenceKey?
    /// Static descriptions never include raw paths, endpoints or source URLs.
    public var detail: String
    public var marketplacePackageID: String? = nil
}

public enum WorkspaceInventoryMigrationFieldGroup: String, CaseIterable, Hashable, Sendable {
    case identity, authority, parentage, sourceUpdates, deviceObservations, legacyMetadata
}

public enum WorkspaceInventoryMigrationDisposition: String, Hashable, Sendable {
    case mapped, retainedLocally, needsReview
}

public struct WorkspaceInventoryMigrationCoverage: Hashable, Sendable {
    public var legacy: LegacyReferenceKey
    public var group: WorkspaceInventoryMigrationFieldGroup
    public var disposition: WorkspaceInventoryMigrationDisposition
}

public struct WorkspaceMarketplaceMigrationCoverage: Hashable, Sendable {
    public var packageID: String
    public var disposition: WorkspaceInventoryMigrationDisposition
}

public enum WorkspaceInventoryMigrationError: Error, Equatable, Sendable {
    case duplicateInventoryIdentity
    case duplicateResolution
    case unknownResolution
}

/// Deliberately not Codable: the retained legacy snapshot contains device
/// paths and observations and must never become portable sync content. The
/// later durable checkpoint must also retain the original store's raw bytes.
public struct WorkspaceInventoryMigrationPreview: Sendable {
    public var artifacts: [ArtifactRecord]
    public var sources: [PortableSourceDescriptor]
    public var subscriptions: [UpstreamSubscription]
    public var identityMap: [WorkspaceMigrationIdentityEntry]
    public var observations: [TargetObservation]
    public var retainedLegacySnapshot: WorkspaceSnapshot
    public var coverage: [WorkspaceInventoryMigrationCoverage]
    public var marketplaceCoverage: [WorkspaceMarketplaceMigrationCoverage]
    public var marketplaceArtifactBindings: [String: ArtifactID]
    public var mcpDefinitions: [PortableMCPDefinitionRecord]
    public var mcpBindings: [DeviceMCPDefinitionBinding]
    public var managedMCPAssignments: [AssignmentContribution]
    /// Reviewed device-only mappings, not durable project enrollment.
    public var mcpProjectMappings: [WorkspaceMCPMigrationProject]
    public var issues: [WorkspaceInventoryMigrationIssue]

    public var logicalProjects: [LogicalProjectRecord] { mcpProjectMappings.map(\.project) }

    /// Inventory conversion only. A migration checkpoint, assignment parity,
    /// complete content capture and a reviewed application step remain required.
    public var canMigrateInventory: Bool { issues.isEmpty }

    public var artifactBindings: [LegacyReferenceKey: ArtifactID] {
        let live = Set(artifacts.map(\.identity.id))
        return Dictionary(uniqueKeysWithValues: identityMap.compactMap { entry in
            let id = ArtifactID(entry.objectID.rawValue)
            return entry.legacy.domain.isArtifact && live.contains(id) ? (entry.legacy, id) : nil
        })
    }
}

/// Converts legacy inventory identity without inferring ownership from names,
/// health, installed flags, catalog labels, or untyped upstream fingerprints.
/// All unrepresented legacy fields remain in a device-only retention snapshot.
public enum WorkspaceInventoryMigration {
    public static func preview(
        snapshot: WorkspaceSnapshot,
        workspaceID: WorkspaceObjectID,
        resolutions: [WorkspaceInventoryMigrationResolution] = [],
        sources: [PortableSourceDescriptor] = [],
        subscriptions: [UpstreamSubscription] = [],
        preserving: [WorkspaceMigrationIdentityEntry] = [],
        marketplaceResolutions: [WorkspaceMarketplaceMigrationResolution] = [],
        preservingMarketplaceBindings: [String: ArtifactID] = [:],
        deviceID: WorkspaceObjectID? = nil,
        managedMCPResolutions: [WorkspaceManagedMCPMigrationResolution] = [],
        preservingMCPProjectMappings: [WorkspaceMCPMigrationProject] = []
    ) throws -> WorkspaceInventoryMigrationPreview {
        let skills = snapshot.skills.map { (key(.skill, $0.id), $0) }
        let plugins = snapshot.plugins.map { (key(.plugin, $0.id), $0) }
        let servers = snapshot.mcpServers.map { (key(.mcpServer, $0.id), $0) }
        let allKeys = skills.map(\.0) + plugins.map(\.0) + servers.map(\.0)
        guard Set(allKeys).count == allKeys.count,
              Set(snapshot.marketplacePackages.map(\.id)).count == snapshot.marketplacePackages.count else {
            throw WorkspaceInventoryMigrationError.duplicateInventoryIdentity
        }
        guard Set(resolutions.map(\.legacy)).count == resolutions.count else {
            throw WorkspaceInventoryMigrationError.duplicateResolution
        }
        guard Set(marketplaceResolutions.map(\.packageID)).count == marketplaceResolutions.count else {
            throw WorkspaceInventoryMigrationError.duplicateResolution
        }
        guard Set(managedMCPResolutions.map(\.legacyServerID)).count == managedMCPResolutions.count else {
            throw WorkspaceInventoryMigrationError.duplicateResolution
        }
        guard Set(preservingMCPProjectMappings.map(\.project.id)).count == preservingMCPProjectMappings.count,
              Set(preservingMCPProjectMappings.map(\.rootPath)).count == preservingMCPProjectMappings.count else {
            throw WorkspaceInventoryMigrationError.duplicateResolution
        }
        let managedServerIDs = Set(servers.filter { $0.1.isManagedDefinition }.map { $0.1.id })
        guard managedMCPResolutions.allSatisfy({ managedServerIDs.contains($0.legacyServerID) }) else {
            throw WorkspaceInventoryMigrationError.unknownResolution
        }
        let liveKeys = Set(allKeys)
        guard resolutions.allSatisfy({ liveKeys.contains($0.legacy) }) else {
            throw WorkspaceInventoryMigrationError.unknownResolution
        }
        let packagesByID = Dictionary(uniqueKeysWithValues: snapshot.marketplacePackages.map { ($0.id, $0) })
        // One native plugin can be listed by both client catalogs. Sharing a
        // reviewed root is valid only for distinct exact native client identities.
        for group in Dictionary(grouping: preservingMarketplaceBindings.keys,
            by: { preservingMarketplaceBindings[$0]! }).values where group.count > 1 {
            let recognized = group.compactMap { packagesByID[$0].flatMap(NativeCatalogPackageIdentity.recognize) }
            guard recognized.count == group.count, Set(recognized.map(\.client)).count == group.count else {
                throw WorkspaceInventoryMigrationError.duplicateResolution
            }
        }
        guard marketplaceResolutions.allSatisfy({ packagesByID[$0.packageID] != nil }) else {
            throw WorkspaceInventoryMigrationError.unknownResolution
        }
        guard preservingMarketplaceBindings.keys.allSatisfy({ packagesByID[$0] != nil }) else {
            throw WorkspaceInventoryMigrationError.unknownResolution
        }
        let identities = try WorkspaceMigrationIdentity.mapping(keys: liveKeys, workspaceID: workspaceID, preserving: preserving)
        let ids = Dictionary(uniqueKeysWithValues: identities.map { ($0.legacy, ArtifactID($0.objectID.rawValue)) })
        let decisions = Dictionary(uniqueKeysWithValues: resolutions.map { ($0.legacy, $0.artifact) })
        let skillByKey = Dictionary(uniqueKeysWithValues: skills)
        let serverByKey = Dictionary(uniqueKeysWithValues: servers)
        let mcpDecisions = Dictionary(uniqueKeysWithValues: managedMCPResolutions.map { ($0.legacyServerID, $0) })
        var names = Dictionary(uniqueKeysWithValues: skills.map { ($0.0, $0.1.displayName) })
        for (key, value) in plugins { names[key] = value.name }
        for (key, value) in servers { names[key] = value.name }

        // Typed observed membership is stronger than presentation-level bundle
        // strings. Neither can manufacture a relative package path.
        var nativeParents: [LegacyReferenceKey: Set<LegacyReferenceKey>] = [:]
        var declaredParents: [LegacyReferenceKey: Set<LegacyReferenceKey>] = [:]
        var needsDecision = Set(plugins.map(\.0))
        for (key, skill) in skills where skill.owned || skill.repositoryBinding != nil { needsDecision.insert(key) }
        for (key, server) in servers where server.isManagedDefinition { needsDecision.insert(key) }
        for plugin in snapshot.plugins {
            for child in plugin.skills {
                needsDecision.insert(key(.skill, child))
                declaredParents[key(.skill, child), default: []].insert(key(.plugin, plugin.id))
            }
        }
        for observation in snapshot.targetObservations {
            for (id, metadata) in observation.skillMetadata {
                if let parent = metadata.providerPluginID {
                    nativeParents[key(.skill, id), default: []].insert(key(.plugin, parent))
                }
            }
            for (parent, metadata) in observation.pluginMetadata {
                for id in metadata.skillIDs {
                    nativeParents[key(.skill, id), default: []].insert(key(.plugin, parent))
                }
                for id in metadata.mcpServerIDs {
                    nativeParents[key(.mcpServer, id), default: []].insert(key(.plugin, parent))
                }
            }
        }
        needsDecision.formUnion(nativeParents.keys)
        var artifacts: [ArtifactRecord] = []
        var issues: [WorkspaceInventoryMigrationIssue] = []
        var coverage: [WorkspaceInventoryMigrationCoverage] = []
        var marketplaceCoverage: [WorkspaceMarketplaceMigrationCoverage] = []
        var mcpDefinitions: [PortableMCPDefinitionRecord] = []
        var mcpBindings: [DeviceMCPDefinitionBinding] = []
        var managedMCPAssignments: [AssignmentContribution] = []
        var mcpProjects: [ArtifactID: WorkspaceMCPMigrationProject] = [:]
        func issue(_ kind: WorkspaceInventoryMigrationIssueKind, _ legacy: LegacyReferenceKey?, _ detail: String) {
            issues.append(.init(kind: kind, legacy: legacy, detail: detail))
        }
        for child in Set(nativeParents.keys).union(declaredParents.keys).sorted(by: order) where !liveKeys.contains(child) {
            issue(.conflictingParentage, child, "An observed native child is absent from the captured inventory.")
        }
        let subscriptionsByID = Dictionary(grouping: subscriptions, by: \.id)
        let sourcesByID = Dictionary(grouping: sources, by: \.id)

        for legacy in allKeys.sorted(by: order) {
            let issueCount = issues.count
            let id = ids[legacy]!
            let alias = ExternalAlias(namespace: "legacy.\(legacy.domain.rawValue)", value: legacy.identifier)
            var artifact = decisions[legacy] ?? ArtifactRecord(
                identity: .init(id: id, kind: defaultKind(legacy.domain), displayName: names[legacy]!, aliases: [alias]),
                authority: .trackedOnly)
            if decisions[legacy] == nil, needsDecision.contains(legacy) {
                issue(.unresolvedAuthority, legacy, "Existing management, source linkage or package ownership needs a verified decision.")
            }
            if artifact.identity.id != id || !kindMatches(artifact.identity.kind, legacy.domain) {
                issue(.invalidResolution, legacy, "The resolution does not match the reserved legacy identity and kind.")
            }
            if !artifact.identity.aliases.contains(alias) { artifact.identity.aliases.append(alias) }
            if skillByKey[legacy]?.repositoryBinding != nil {
                switch artifact.authority {
                case .centralUpstream: break
                default:
                    issue(.upstreamOwnershipLost, legacy, "An existing upstream update relationship cannot be replaced by another ownership mode during migration.")
                }
            }
            if let server = serverByKey[legacy], server.isManagedDefinition {
                if let resolution = mcpDecisions[server.id], let deviceID {
                    do {
                        guard artifact.authority == .centralPersonal, artifact.identity.parentPackageID == nil,
                              artifact.identity.kind == .mcpServer, artifact.contentDigest == nil else {
                            throw WorkspaceDomainValidationError.invalidField("managed MCP artifact")
                        }
                        try WorkspaceManagedMCPMigrationValidation.validate(
                            resolution, server: server, artifactID: id, deviceID: deviceID)
                        if let project = resolution.project {
                            guard !ids.values.contains(project.project.id),
                                  !preservingMCPProjectMappings.contains(where: {
                                      ($0.rootPath == project.rootPath) != ($0.project.id == project.project.id)
                                  }),
                                  mcpProjects[project.project.id].map({ $0.project == project.project && $0.rootPath == project.rootPath }) ?? true,
                                  !mcpProjects.values.contains(where: { $0.rootPath == project.rootPath && $0.project.id != project.project.id }) else {
                                throw WorkspaceDomainValidationError.invalidField("MCP project identity")
                            }
                            mcpProjects[project.project.id] = project
                        }
                        mcpDefinitions.append(resolution.definition)
                        if let binding = resolution.deviceBinding { mcpBindings.append(binding) }
                        managedMCPAssignments.append(contentsOf: resolution.assignments)
                    } catch {
                        issue(.invalidResolution, legacy, "The MCP resolution does not preserve its definition, credential requirements, project and current-device app assignments.")
                    }
                } else {
                    issue(.unresolvedAuthority, legacy, "A managed MCP definition needs an explicit definition and current-device assignment resolution.")
                }
            }

            // Legacy declarations do not prove native ownership. They do
            // prohibit silently extracting a listed child as a standalone
            // item. Its resolved parent graph must be reviewed as a whole.
            if let parents = declaredParents[legacy], !parents.isEmpty {
                if parents.count != 1 || parents.first.flatMap({ ids[$0] }) != artifact.identity.parentPackageID {
                    issue(.conflictingParentage, legacy, "A legacy package declaration needs a consistent whole-package resolution.")
                }
            }
            if let parents = nativeParents[legacy], !parents.isEmpty {
                if parents.count != 1 || parents.contains(where: { !liveKeys.contains($0) }) {
                    issue(.conflictingParentage, legacy, "Observed package membership is missing or ambiguous.")
                } else if let parent = parents.first,
                          artifact.identity.parentPackageID != ids[parent] || artifact.authority != .nativeOwned {
                    issue(.conflictingParentage, legacy, "An observed native package child must remain with its native parent.")
                }
            }
            switch artifact.authority {
            case .centralPersonal:
                if serverByKey[legacy]?.isManagedDefinition != true {
                    // Migration is not an implicit fork. Managed MCP records
                    // use the explicit definition contract above, not a tree.
                    if skillByKey[legacy]?.owned != true || skillByKey[legacy]?.repositoryBinding != nil {
                        issue(.upstreamOwnershipLost, legacy, "Personal ownership requires existing personal content; source ownership cannot be dropped during migration.")
                    }
                    if artifact.contentDigest == nil {
                        issue(.missingMaterialization, legacy, "Central content requires a verified complete-tree digest.")
                    }
                }
            case .centralUpstream(let subscriptionID):
                if artifact.contentDigest == nil {
                    issue(.missingMaterialization, legacy, "Upstream content requires its complete package and typed approved lock.")
                }
                if let binding = skillByKey[legacy]?.repositoryBinding {
                    let matches = subscriptionsByID[subscriptionID] ?? []
                    let subscription = matches.count == 1 ? matches[0] : nil
                    let source = subscription.flatMap { sourcesByID[$0.sourceID]?.first }
                    // Existing explicit source intent is preserved. An upstream
                    // change or an intentional fork is a separate reviewed act.
                    if (try? binding.validate()) == nil || source?.repositoryURL != binding.repositoryURL
                        || source?.requestedRef != binding.ref || subscription?.lock.requestedRef != binding.ref
                        || subscription?.lock.packageRelativePath != (binding.subdirectory.isEmpty ? "." : binding.subdirectory) {
                        issue(.upstreamOwnershipLost, legacy, "The resolved upstream source differs from the existing repository binding.")
                    }
                }
            case .nativeOwned:
                if artifact.identity.parentPackageID == nil {
                    if legacy.domain != .plugin || artifact.identity.kind != .nativePlugin || artifact.nativeRoutes.isEmpty {
                        issue(.missingNativeEvidence, legacy, "Native ownership requires a whole plugin and explicit client routes.")
                    }
                    for route in artifact.nativeRoutes {
                        let observed = snapshot.targetObservations.contains { observation in
                            observation.surface.client == route.client
                                && observation.discoveredPlugins.contains(route.externalPluginID)
                                && observation.pluginMetadata[route.externalPluginID] != nil
                        }
                        if !observed {
                            issue(.missingNativeEvidence, legacy, "A native route is absent from the captured client inventory.")
                        }
                    }
                } else if nativeParents[legacy]?.isEmpty != false {
                    issue(.missingNativeEvidence, legacy, "Native child ownership requires explicit observed package membership.")
                }
            case .attachedAuthoring:
                if legacy.domain != .skill || skillByKey[legacy]?.repositoryBinding != nil {
                    issue(.invalidResolution, legacy, "Attaching an authoring checkout cannot replace an existing upstream update relationship.")
                }
            case .trackedOnly:
                // Explicitly choosing tracking still cannot silently weaken an
                // existing editable library or upstream update relationship.
                if skillByKey[legacy]?.owned == true || skillByKey[legacy]?.repositoryBinding != nil {
                    issue(.unresolvedAuthority, legacy, "Existing managed content or settings need representation before cutover.")
                }
            }
            artifacts.append(artifact)
            let blocked = issues.count != issueCount
            for group in WorkspaceInventoryMigrationFieldGroup.allCases {
                let disposition: WorkspaceInventoryMigrationDisposition
                switch group {
                case .identity: disposition = .mapped
                case .authority, .parentage: disposition = blocked ? .needsReview : .mapped
                case .sourceUpdates: disposition = skillByKey[legacy]?.repositoryBinding == nil ? .retainedLocally : (blocked ? .needsReview : .mapped)
                case .deviceObservations, .legacyMetadata: disposition = .retainedLocally
                }
                coverage.append(.init(legacy: legacy, group: group, disposition: disposition))
            }
        }
        let mcpProjectMappings = mcpProjects.values.sorted { $0.project.id < $1.project.id }
        for mapping in mcpProjectMappings {
            artifacts.append(.init(identity: .init(id: mapping.project.id, kind: .logicalProject,
                                                  displayName: mapping.project.name), authority: .trackedOnly))
        }
        let marketplaceDecisions = Dictionary(uniqueKeysWithValues: marketplaceResolutions.map { ($0.packageID, $0) })
        let resolvedIDs = Set(artifacts.map { $0.identity.id })
        let observedRoutes = Set(snapshot.targetObservations.flatMap { observation -> [NativePackageRoute] in
            guard let client = observation.surface.client else { return [] }
            return observation.discoveredPlugins.compactMap { id in
                observation.pluginMetadata[id] == nil ? nil : .init(client: client, externalPluginID: id)
            }
        })
        var nativeRootsByRoute: [NativePackageRoute: [WorkspaceInventoryMigrationResolution]] = [:]
        for decision in resolutions where decision.legacy.domain == .plugin {
            let artifact = decision.artifact
            guard artifact.identity.parentPackageID == nil, artifact.identity.kind == .nativePlugin,
                  artifact.authority == .nativeOwned, resolvedIDs.contains(artifact.identity.id) else { continue }
            for route in Set(artifact.nativeRoutes) where observedRoutes.contains(route) {
                nativeRootsByRoute[route, default: []].append(decision)
            }
        }
        var marketplaceArtifactBindings: [String: ArtifactID] = [:]
        var marketplaceArtifactOwners: [ArtifactID: [String]] = [:]
        for package in snapshot.marketplacePackages.sorted(by: { $0.id < $1.id }) {
            let nativeIdentity = NativeCatalogPackageIdentity.recognize(package)
            var resolution = marketplaceDecisions[package.id]
            let hasReservedNativePrefix = package.id.hasPrefix("codex:") || package.id.hasPrefix("claude:")
            guard nativeIdentity != nil || !hasReservedNativePrefix else {
                marketplaceCoverage.append(.init(packageID: package.id, disposition: .needsReview))
                issues.append(.init(
                    kind: .invalidResolution,
                    legacy: resolution?.linkedLegacy,
                    detail: "The reserved native catalog identity has contradictory or malformed metadata.",
                    marketplacePackageID: package.id
                ))
                continue
            }
            if let nativeIdentity {
                let matching = nativeRootsByRoute[.init(client: nativeIdentity.client,
                    externalPluginID: nativeIdentity.externalPluginID)] ?? []
                guard matching.count <= 1 else {
                    marketplaceCoverage.append(.init(packageID: package.id, disposition: .needsReview))
                    issues.append(.init(kind: .invalidResolution, legacy: nil,
                        detail: "The native catalog identity matches more than one observed plugin root.", marketplacePackageID: package.id))
                    continue
                }
                guard let match = matching.first else {
                    // Installed flags in a native catalog are cached discovery,
                    // not standalone ownership or new assignment intent.
                    if resolution != nil || preservingMarketplaceBindings[package.id] != nil {
                        marketplaceCoverage.append(.init(packageID: package.id, disposition: .needsReview))
                        issues.append(.init(kind: .invalidResolution, legacy: resolution?.linkedLegacy,
                            detail: "The reviewed native catalog link no longer matches an observed plugin root.", marketplacePackageID: package.id))
                    } else {
                        marketplaceCoverage.append(.init(packageID: package.id, disposition: .retainedLocally))
                    }
                    continue
                }
                if let explicit = resolution,
                   explicit.linkedLegacy != match.legacy || !artifactAgreement(explicit.artifact, match.artifact) {
                    marketplaceCoverage.append(.init(packageID: package.id, disposition: .needsReview))
                    issues.append(.init(kind: .invalidResolution, legacy: explicit.linkedLegacy,
                        detail: "The supplied catalog link conflicts with its exact observed native identity.", marketplacePackageID: package.id))
                    continue
                }
                resolution = .init(packageID: package.id, artifact: match.artifact, linkedLegacy: match.legacy)
            }
            // Catalog providers also populate ownership to describe an install
            // route. That label alone is not an existing local installation.
            let locallyRelevant = nativeIdentity != nil || package.isInstalled
                || package.nativeInstalls.contains { $0.reportsInstalled(in: package) }
            guard locallyRelevant else {
                if marketplaceDecisions[package.id] == nil {
                    marketplaceCoverage.append(.init(packageID: package.id, disposition: .retainedLocally))
                } else {
                    marketplaceCoverage.append(.init(packageID: package.id, disposition: .needsReview))
                    issues.append(.init(
                        kind: .invalidResolution, legacy: nil,
                        detail: "A catalog-only package does not create a portable artifact.",
                        marketplacePackageID: package.id))
                }
                continue
            }
            guard let resolution else {
                marketplaceCoverage.append(.init(packageID: package.id, disposition: .needsReview))
                issues.append(.init(
                    kind: .unmappedMarketplacePackage, legacy: nil,
                    detail: "An installed or locally owned marketplace package needs an explicit inventory link before migration.",
                    marketplacePackageID: package.id))
                continue
            }

            let alias = ExternalAlias(namespace: "legacy.marketplacePackage", value: package.id)
            var resolvedArtifact = resolution.artifact
            var linkedArtifactIndex: Int?
            var valid = true
            func marketplaceIssue(_ detail: String) {
                valid = false
                issues.append(.init(
                    kind: .invalidResolution, legacy: resolution.linkedLegacy,
                    detail: detail, marketplacePackageID: package.id))
            }

            if let preserved = preservingMarketplaceBindings[package.id], preserved != resolvedArtifact.identity.id {
                marketplaceIssue("The marketplace artifact identity differs from the preserved reviewed link.")
            }

            if let linkedLegacy = resolution.linkedLegacy {
                guard liveKeys.contains(linkedLegacy), decisions[linkedLegacy] != nil,
                      resolution.artifact.identity.id == ids[linkedLegacy],
                      let index = artifacts.firstIndex(where: { $0.identity.id == resolution.artifact.identity.id }),
                      artifacts[index].identity.parentPackageID == nil,
                      artifactAgreement(artifacts[index], resolution.artifact)
                else {
                    marketplaceIssue("The marketplace link does not match one explicitly resolved root inventory artifact.")
                    marketplaceCoverage.append(.init(packageID: package.id, disposition: .needsReview))
                    continue
                }
                resolvedArtifact = artifacts[index]
                linkedArtifactIndex = index
            } else {
                if resolvedArtifact.identity.parentPackageID != nil {
                    marketplaceIssue("A marketplace-only resolution must identify a root artifact.")
                }
                if artifacts.contains(where: { $0.identity.id == resolvedArtifact.identity.id }) {
                    marketplaceIssue("A marketplace-only resolution reuses an existing inventory identity without an explicit link.")
                }
                if !resolvedArtifact.identity.aliases.contains(alias) {
                    resolvedArtifact.identity.aliases.append(alias)
                }
            }

            if let owners = marketplaceArtifactOwners[resolvedArtifact.identity.id] {
                let priorClients = owners.compactMap { packagesByID[$0].flatMap(NativeCatalogPackageIdentity.recognize)?.client }
                if let nativeIdentity, priorClients.count == owners.count,
                   !priorClients.contains(nativeIdentity.client) {
                    // Distinct client listings are aliases of the same intact root.
                } else {
                    marketplaceIssue("More than one incompatible marketplace row claims the same artifact identity.")
                }
            }
            if !marketplaceKindMatches(resolvedArtifact.identity.kind, components: package.components) {
                marketplaceIssue("The marketplace package components do not match the resolved root artifact kind.")
            }
            switch nativeIdentity == nil ? package.ownership : .nativeClient {
            case .managed:
                if case .centralUpstream(let subscriptionID) = resolvedArtifact.authority {
                    if resolvedArtifact.contentDigest == nil {
                        marketplaceIssue("Managed upstream marketplace content needs a verified complete-tree digest.")
                    }
                    if let origin = package.provenance?.source, origin.kind == .gitRepository {
                        let matches = subscriptionsByID[subscriptionID] ?? []
                        let source = matches.count == 1 ? sourcesByID[matches[0].sourceID] : nil
                        if source?.count != 1 || source?.first?.repositoryURL != origin.location {
                            marketplaceIssue("The resolved marketplace repository differs from the existing explicit Git source.")
                        }
                    }
                } else {
                    marketplaceIssue("Managed marketplace ownership requires verified upstream authority; it does not prove personal authorship.")
                }
            case .nativeClient:
                guard resolvedArtifact.authority == .nativeOwned,
                      resolvedArtifact.identity.kind == .nativePlugin,
                      resolvedArtifact.nativeRoutes.isEmpty == false
                else {
                    marketplaceIssue("Native marketplace ownership requires a native plugin root and explicit observed client routes.")
                    break
                }
                for route in resolvedArtifact.nativeRoutes where !nativeRouteIsObserved(route, snapshot: snapshot) {
                    marketplaceIssue("A native marketplace route is absent from the captured client inventory.")
                }
            case .unmanaged, nil:
                if resolvedArtifact.authority != .trackedOnly {
                    marketplaceIssue("An unmanaged marketplace installation can migrate only as explicitly tracked content.")
                }
            }

            if valid {
                if let linkedArtifactIndex {
                    if !artifacts[linkedArtifactIndex].identity.aliases.contains(alias) {
                        artifacts[linkedArtifactIndex].identity.aliases.append(alias)
                    }
                } else {
                    artifacts.append(resolvedArtifact)
                }
                marketplaceArtifactOwners[resolvedArtifact.identity.id, default: []].append(package.id)
                marketplaceArtifactBindings[package.id] = resolvedArtifact.identity.id
                marketplaceCoverage.append(.init(packageID: package.id, disposition: .mapped))
            } else {
                marketplaceCoverage.append(.init(packageID: package.id, disposition: .needsReview))
            }
        }
        // Validate real supplied artifacts, sources and subscriptions together,
        // rather than passing the configuration converter's temporary shapes.
        let candidate = PortableWorkspaceDocument(
            workspaceID: workspaceID, revision: .init(writerID: workspaceID), artifacts: artifacts,
            sources: sources, subscriptions: subscriptions, logicalProjects: mcpProjectMappings.map(\.project),
            assignments: managedMCPAssignments, mcpDefinitions: mcpDefinitions)
        do {
            try candidate.validateStructure()
            try WorkspaceMCPDefinitionValidation.validateDevice(mcpBindings, definitions: mcpDefinitions)
        }
        catch { issue(.structuralValidation, nil, "The supplied inventory/source graph does not satisfy the workspace contract.") }
        return .init(
            artifacts: artifacts, sources: sources, subscriptions: subscriptions, identityMap: identities,
            observations: snapshot.targetObservations, retainedLegacySnapshot: snapshot, coverage: coverage,
            marketplaceCoverage: marketplaceCoverage, marketplaceArtifactBindings: marketplaceArtifactBindings,
            mcpDefinitions: mcpDefinitions, mcpBindings: mcpBindings,
            managedMCPAssignments: managedMCPAssignments, mcpProjectMappings: mcpProjectMappings,
            issues: issues)
    }

    private static func key(_ domain: LegacyReferenceDomain, _ identifier: String) -> LegacyReferenceKey {
        .init(domain: domain, identifier: identifier)
    }

    private static func defaultKind(_ domain: LegacyReferenceDomain) -> ArtifactKind {
        switch domain {
        case .skill: .skill
        case .mcpServer: .mcpServer
        default: .package
        }
    }

    private static func kindMatches(_ kind: ArtifactKind, _ domain: LegacyReferenceDomain) -> Bool {
        switch domain {
        case .skill: kind == .skill
        case .plugin: kind == .package || kind == .nativePlugin
        case .mcpServer: kind == .mcpServer
        default: false
        }
    }

    private static func artifactAgreement(_ lhs: ArtifactRecord, _ rhs: ArtifactRecord) -> Bool {
        lhs.identity.id == rhs.identity.id
            && lhs.identity.kind == rhs.identity.kind
            && lhs.identity.parentPackageID == rhs.identity.parentPackageID
            && lhs.identity.derivedFrom == rhs.identity.derivedFrom
            && lhs.authority == rhs.authority
            && lhs.declaredName == rhs.declaredName
            && lhs.packageRelativePath == rhs.packageRelativePath
            && lhs.contentDigest == rhs.contentDigest
            && Set(lhs.nativeRoutes) == Set(rhs.nativeRoutes)
    }

    private static func marketplaceKindMatches(_ kind: ArtifactKind, components: Set<ComponentKind>) -> Bool {
        guard components.isEmpty == false,
              components.isSubset(of: [.skill, .plugin, .mcpServer]) else { return false }
        if kind == .package { return true }
        if components.contains(.plugin) { return kind == .package || kind == .nativePlugin }
        if components == [.skill] { return kind == .skill }
        if components == [.mcpServer] { return kind == .mcpServer }
        return kind == .package
    }

    private static func nativeRouteIsObserved(_ route: NativePackageRoute, snapshot: WorkspaceSnapshot) -> Bool {
        snapshot.targetObservations.contains { observation in
            observation.surface.client == route.client
                && observation.discoveredPlugins.contains(route.externalPluginID)
                && observation.pluginMetadata[route.externalPluginID] != nil
        }
    }

    private static func order(_ lhs: LegacyReferenceKey, _ rhs: LegacyReferenceKey) -> Bool {
        lhs.domain == rhs.domain ? lhs.identifier < rhs.identifier : lhs.domain.rawValue < rhs.domain.rawValue
    }
}
