import Foundation

public enum WorkspaceMigrationInventoryChoiceKind: String, Equatable, Sendable {
    case centralPersonal, centralUpstream, attachedAuthoring, trackedOnly, nativePackage
}

public struct WorkspaceMigrationNativeChildChoice: Sendable {
    public let legacy: LegacyReferenceKey
    public let packageRelativePath: String?

    public init(legacy: LegacyReferenceKey, packageRelativePath: String? = nil) {
        self.legacy = legacy
        self.packageRelativePath = packageRelativePath
    }
}

public enum WorkspaceMigrationInventoryStrategy: Sendable {
    case centralPersonal
    case centralUpstream(
        installedDirectory: URL,
        sourceID: WorkspaceObjectID,
        subscriptionID: WorkspaceObjectID
    )
    case attachedAuthoring(directory: URL, sourceID: WorkspaceObjectID)
    case trackedOnly
    case nativePackage(routes: [NativePackageRoute], children: [WorkspaceMigrationNativeChildChoice])

    public var kind: WorkspaceMigrationInventoryChoiceKind {
        switch self {
        case .centralPersonal: .centralPersonal
        case .centralUpstream: .centralUpstream
        case .attachedAuthoring: .attachedAuthoring
        case .trackedOnly: .trackedOnly
        case .nativePackage: .nativePackage
        }
    }
}

public struct WorkspaceMigrationInventoryChoice: Sendable {
    public let legacy: LegacyReferenceKey
    public let strategy: WorkspaceMigrationInventoryStrategy

    public init(legacy: LegacyReferenceKey, strategy: WorkspaceMigrationInventoryStrategy) {
        self.legacy = legacy
        self.strategy = strategy
    }
}

public struct WorkspaceMigrationCandidatePreparationRequest: Sendable {
    public let attemptID: WorkspaceObjectID
    public let checkpoint: WorkspaceLegacyCheckpoint
    public let legacyDatabaseURL: URL
    public let context: WorkspaceMigrationContext
    public let choices: [WorkspaceMigrationInventoryChoice]
    public let preservingIdentities: [WorkspaceMigrationIdentityEntry]
    public let marketplaceResolutions: [WorkspaceMarketplaceMigrationResolution]
    public let preservingMarketplaceBindings: [String: ArtifactID]
    public let managedMCPResolutions: [WorkspaceManagedMCPMigrationResolution]
    public let projects: [WorkspaceMCPMigrationProject]
    public let configurationProjects: [LegacyReferenceKey: ArtifactID]
    public let projectIDsBySkillID: [ArtifactID: ArtifactID]
    public let nativePluginPlacements: [WorkspaceNativePluginMigrationPlacement]

    public init(
        attemptID: WorkspaceObjectID,
        checkpoint: WorkspaceLegacyCheckpoint,
        legacyDatabaseURL: URL,
        context: WorkspaceMigrationContext,
        choices: [WorkspaceMigrationInventoryChoice],
        preservingIdentities: [WorkspaceMigrationIdentityEntry] = [],
        marketplaceResolutions: [WorkspaceMarketplaceMigrationResolution] = [],
        preservingMarketplaceBindings: [String: ArtifactID] = [:],
        managedMCPResolutions: [WorkspaceManagedMCPMigrationResolution] = [],
        projects: [WorkspaceMCPMigrationProject] = [],
        configurationProjects: [LegacyReferenceKey: ArtifactID] = [:],
        projectIDsBySkillID: [ArtifactID: ArtifactID] = [:],
        nativePluginPlacements: [WorkspaceNativePluginMigrationPlacement] = []
    ) {
        self.attemptID = attemptID
        self.checkpoint = checkpoint
        self.legacyDatabaseURL = legacyDatabaseURL
        self.context = context
        self.choices = choices
        self.preservingIdentities = preservingIdentities
        self.marketplaceResolutions = marketplaceResolutions
        self.preservingMarketplaceBindings = preservingMarketplaceBindings
        self.managedMCPResolutions = managedMCPResolutions
        self.projects = projects
        self.configurationProjects = configurationProjects
        self.projectIDsBySkillID = projectIDsBySkillID
        self.nativePluginPlacements = nativePluginPlacements
    }
}

public struct WorkspaceMigrationCandidatePreparationItem: Sendable, Equatable {
    public let legacy: LegacyReferenceKey
    public let artifactID: ArtifactID
    public let displayName: String
    public let kind: ArtifactKind
    public let selectedChoice: WorkspaceMigrationInventoryChoiceKind?
    public let parentLegacy: LegacyReferenceKey?
    public let bundledChildCount: Int

    public init(
        legacy: LegacyReferenceKey,
        artifactID: ArtifactID,
        displayName: String,
        kind: ArtifactKind,
        selectedChoice: WorkspaceMigrationInventoryChoiceKind?,
        parentLegacy: LegacyReferenceKey? = nil,
        bundledChildCount: Int = 0
    ) {
        self.legacy = legacy
        self.artifactID = artifactID
        self.displayName = displayName
        self.kind = kind
        self.selectedChoice = selectedChoice
        self.parentLegacy = parentLegacy
        self.bundledChildCount = bundledChildCount
    }
}

public enum WorkspaceMigrationCandidatePreparationIssueKind: String, Equatable, Sendable {
    case invalidCheckpoint, duplicateChoice, unknownItem, invalidChoice
    case missingPersonalContent, invalidUpstream, changedUpstreamContent
    case invalidAttachment, invalidNativePackage, inventoryNeedsReview
    case assemblyRejected, invalidPreparation
}

public struct WorkspaceMigrationCandidatePreparationIssue: Sendable, Equatable {
    public let kind: WorkspaceMigrationCandidatePreparationIssueKind
    public let legacy: LegacyReferenceKey?
    public let detail: String
    public let marketplacePackageID: String?

    public init(
        kind: WorkspaceMigrationCandidatePreparationIssueKind,
        legacy: LegacyReferenceKey? = nil,
        detail: String,
        marketplacePackageID: String? = nil
    ) {
        self.kind = kind
        self.legacy = legacy
        self.detail = detail
        self.marketplacePackageID = marketplacePackageID
    }
}

public struct WorkspaceMigrationCandidatePreparationPreview: Sendable {
    public let preparation: WorkspaceMigrationPreparation?
    public let items: [WorkspaceMigrationCandidatePreparationItem]
    public let issues: [WorkspaceMigrationCandidatePreparationIssue]
    public var canPrepare: Bool { preparation != nil && issues.isEmpty }

    public init(
        preparation: WorkspaceMigrationPreparation?,
        items: [WorkspaceMigrationCandidatePreparationItem],
        issues: [WorkspaceMigrationCandidatePreparationIssue]
    ) {
        self.preparation = preparation
        self.items = items
        self.issues = issues
    }
}

/// Converts reviewed legacy ownership choices into one immutable preparation.
/// It does not stage, initialize, select authority, fetch a repository, or touch
/// a native client. The only snapshot read is from the supplied checkpoint.
public actor WorkspaceMigrationCandidatePreparationService {
    public init() {}

    public func preview(
        _ request: WorkspaceMigrationCandidatePreparationRequest
    ) async throws -> WorkspaceMigrationCandidatePreparationPreview {
        do {
            try Task.checkCancellation()
            guard let snapshot = try request.checkpoint.workspaceSnapshot() else {
                return failure(.invalidCheckpoint, "The checkpoint does not contain a workspace snapshot.")
            }
            try WorkspaceSnapshotValidator.validate(snapshot, mode: .localState)
            return try await prepare(snapshot: snapshot, request: request)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            return failure(.invalidCheckpoint, "The checkpoint could not be read as a supported workspace.")
        }
    }

    private func prepare(
        snapshot: WorkspaceSnapshot,
        request: WorkspaceMigrationCandidatePreparationRequest
    ) async throws -> WorkspaceMigrationCandidatePreparationPreview {
        let inventory = Inventory(snapshot)
        let keys = Set(inventory.values.keys)
        let identities: [WorkspaceMigrationIdentityEntry]
        do {
            identities = try WorkspaceMigrationIdentity.mapping(
                keys: keys,
                workspaceID: request.context.workspaceID,
                preserving: request.preservingIdentities
            )
        } catch {
            return failure(.invalidChoice, "The preserved migration identities are inconsistent.")
        }
        let ids = Dictionary(uniqueKeysWithValues: identities.compactMap { entry in
            entry.legacy.domain.isArtifact ? (entry.legacy, ArtifactID(entry.objectID.rawValue)) : nil
        })
        let choiceGroups = Dictionary(grouping: request.choices, by: \.legacy)
        var issues: [WorkspaceMigrationCandidatePreparationIssue] = []
        var decisions = WorkspaceMigrationDecisions()
        var sourceDirectories: [ArtifactID: URL] = [:]
        decisions.identities = identities
        decisions.marketplace = request.marketplaceResolutions
        decisions.marketplaceBindings = request.preservingMarketplaceBindings
        decisions.managedMCP = request.managedMCPResolutions
        decisions.projects = request.projects
        decisions.configurationProjects = request.configurationProjects
        var selectedKinds: [LegacyReferenceKey: WorkspaceMigrationInventoryChoiceKind] = [:]
        var parents: [LegacyReferenceKey: LegacyReferenceKey] = [:]

        let nestedNativeChildren = request.choices.flatMap { choice -> [LegacyReferenceKey] in
            guard case .nativePackage(_, let children) = choice.strategy else { return [] }
            return children.map(\.legacy)
        }
        let nestedGroups = Dictionary(grouping: nestedNativeChildren, by: { $0 })
        for (legacy, values) in nestedGroups where values.count != 1 || choiceGroups[legacy] != nil {
            issues.append(issue(.invalidNativePackage, legacy, "A bundled child must belong to exactly one selected native package."))
        }

        for resolution in request.managedMCPResolutions {
            let legacy = LegacyReferenceKey(domain: .mcpServer, identifier: resolution.legacyServerID)
            guard choiceGroups[legacy] == nil,
                  case .mcp(let server)? = inventory.values[legacy],
                  let artifactID = ids[legacy],
                  resolution.definition.artifactID == artifactID else {
                issues.append(issue(.invalidChoice, legacy, "The managed MCP definition does not match its reserved inventory identity."))
                continue
            }
            selectedKinds[legacy] = .centralPersonal
            decisions.artifacts.append(.init(legacy: legacy, artifact: .init(
                identity: Self.identity(id: artifactID, kind: .mcpServer, name: server.name),
                authority: .centralPersonal,
                declaredName: server.id
            )))
        }

        for legacy in choiceGroups.keys.sorted(by: Self.keyOrder) {
            guard let group = choiceGroups[legacy], group.count == 1 else {
                issues.append(issue(.duplicateChoice, legacy, "Choose one ownership mode for each inventory item."))
                continue
            }
            guard let value = inventory.values[legacy], let artifactID = ids[legacy] else {
                issues.append(issue(.unknownItem, legacy, "The selected item is absent from the reviewed checkpoint."))
                continue
            }
            guard nestedGroups[legacy] == nil else { continue }
            let choice = group[0]
            selectedKinds[legacy] = choice.strategy.kind
            do {
                switch choice.strategy {
                case .centralPersonal:
                    guard case .skill(let skill) = value, skill.owned, skill.repositoryBinding == nil else {
                        throw CandidateError.invalidChoice
                    }
                    let source = try Self.personalDirectory(skill: skill, databaseURL: request.legacyDatabaseURL)
                    let prepared = try await WorkspaceSkillPreparation.capturePersonal(directory: source)
                    guard prepared.frontmatter.name == skill.name else { throw CandidateError.invalidChoice }
                    decisions.artifacts.append(.init(legacy: legacy, artifact: .init(
                        identity: Self.identity(id: artifactID, kind: .skill, name: skill.displayName),
                        authority: .centralPersonal,
                        declaredName: prepared.frontmatter.name,
                        contentDigest: prepared.tree.digest
                    )))
                    decisions.rootContent[artifactID] = prepared.tree
                    sourceDirectories[artifactID] = source

                case .centralUpstream(let directory, let sourceID, let subscriptionID):
                    guard case .skill(let skill) = value,
                          let binding = skill.repositoryBinding else { throw CandidateError.invalidUpstream }
                    let facts = try Self.upstreamFacts(binding: binding, directory: directory)
                    let before: String
                    do { before = try DirectoryFingerprint.sha256(of: directory) }
                    catch is CancellationError { throw CancellationError() }
                    catch { throw CandidateError.invalidUpstream }
                    guard before == facts.fingerprint else { throw CandidateError.changedUpstream }
                    let prepared = try await WorkspaceSkillPreparation.capturePersonal(directory: directory)
                    let after: String
                    do { after = try DirectoryFingerprint.sha256(of: directory) }
                    catch is CancellationError { throw CancellationError() }
                    catch { throw CandidateError.invalidUpstream }
                    guard after == facts.fingerprint, prepared.frontmatter.name == skill.name else {
                        throw CandidateError.changedUpstream
                    }
                    let path = binding.subdirectory.isEmpty ? "." : binding.subdirectory
                    decisions.artifacts.append(.init(legacy: legacy, artifact: .init(
                        identity: Self.identity(id: artifactID, kind: .skill, name: skill.displayName),
                        authority: .centralUpstream(subscriptionID: subscriptionID),
                        declaredName: prepared.frontmatter.name,
                        contentDigest: prepared.tree.digest
                    )))
                    decisions.sources.append(.init(
                        id: sourceID,
                        role: .publisherRepository,
                        repositoryURL: binding.repositoryURL,
                        requestedRef: binding.ref,
                        packageRelativePaths: [path]
                    ))
                    decisions.subscriptions.append(.init(
                        id: subscriptionID,
                        artifactID: artifactID,
                        sourceID: sourceID,
                        lock: .init(
                            publisherID: facts.publisherID,
                            sourceRootID: sourceID,
                            requestedRef: binding.ref,
                            approvedRevision: facts.revision,
                            approvedContent: prepared.tree.digest,
                            packageRelativePath: path
                        )
                    ))
                    decisions.rootContent[artifactID] = prepared.tree
                    sourceDirectories[artifactID] = directory

                case .attachedAuthoring(let directory, let sourceID):
                    guard case .skill(let skill) = value, skill.repositoryBinding == nil else {
                        throw CandidateError.invalidAttachment
                    }
                    let prepared: PreparedStandaloneSkill
                    do { prepared = try await WorkspaceSkillPreparation.capturePersonal(directory: directory) }
                    catch is CancellationError { throw CancellationError() }
                    catch { throw CandidateError.invalidAttachment }
                    guard prepared.frontmatter.name == skill.name else { throw CandidateError.invalidAttachment }
                    decisions.artifacts.append(.init(legacy: legacy, artifact: .init(
                        identity: Self.identity(id: artifactID, kind: .skill, name: skill.displayName),
                        authority: .attachedAuthoring(sourceRootID: sourceID),
                        declaredName: prepared.frontmatter.name
                    )))
                    decisions.sources.append(.init(
                        id: sourceID,
                        role: .attachedAuthoring,
                        packageRelativePaths: ["."]
                    ))
                    decisions.sourceLocations.append(.init(sourceRootID: sourceID, checkoutPath: directory.path))

                case .trackedOnly:
                    guard Self.canTrack(value, legacy: legacy, inventory: inventory) else {
                        throw CandidateError.invalidChoice
                    }
                    decisions.artifacts.append(.init(legacy: legacy, artifact: .init(
                        identity: Self.identity(id: artifactID, kind: Self.kind(legacy.domain), name: inventory.name(value)),
                        authority: .trackedOnly
                    )))

                case .nativePackage(let routes, let children):
                    guard case .plugin(let plugin) = value else { throw CandidateError.invalidNative }
                    do { try Self.validateNative(plugin: plugin, routes: routes, children: children, inventory: inventory) }
                    catch { throw CandidateError.invalidNative }
                    decisions.artifacts.append(.init(legacy: legacy, artifact: .init(
                        identity: Self.identity(id: artifactID, kind: .nativePlugin, name: plugin.name),
                        authority: .nativeOwned,
                        declaredName: plugin.id,
                        nativeRoutes: routes
                    )))
                    for child in children {
                        guard let childValue = inventory.values[child.legacy], let childID = ids[child.legacy] else {
                            throw CandidateError.invalidNative
                        }
                        parents[child.legacy] = legacy
                        selectedKinds[child.legacy] = .nativePackage
                        decisions.artifacts.append(.init(legacy: child.legacy, artifact: .init(
                            identity: .init(
                                id: childID,
                                kind: Self.kind(child.legacy.domain),
                                displayName: inventory.name(childValue),
                                parentPackageID: artifactID
                            ),
                            authority: .nativeOwned,
                            declaredName: child.legacy.identifier,
                            packageRelativePath: child.packageRelativePath
                        )))
                    }
                }
            } catch is CancellationError {
                throw CancellationError()
            } catch CandidateError.changedUpstream {
                issues.append(issue(.changedUpstreamContent, legacy, "The installed upstream folder differs from its saved fingerprint."))
            } catch CandidateError.invalidUpstream {
                issues.append(issue(.invalidUpstream, legacy, "The upstream installation lacks an exact saved source, revision, path, or fingerprint."))
            } catch CandidateError.invalidAttachment {
                issues.append(issue(.invalidAttachment, legacy, "The attached authoring folder is not a matching standalone skill."))
            } catch CandidateError.invalidNative {
                issues.append(issue(.invalidNativePackage, legacy, "The native plugin routes or whole child graph do not match captured client evidence."))
            } catch {
                let kind: WorkspaceMigrationCandidatePreparationIssueKind = choice.strategy.kind == .centralPersonal
                    ? .missingPersonalContent : .invalidChoice
                issues.append(issue(kind, legacy, "The selected ownership mode cannot preserve this item's reviewed content and identity."))
            }
        }

        let items = Self.items(
            inventory: inventory,
            ids: ids,
            selectedKinds: selectedKinds,
            parents: parents
        )
        guard issues.isEmpty else { return .init(preparation: nil, items: items, issues: Self.sorted(issues)) }

        let assembly = WorkspaceMigrationAssembly.preview(
            snapshot: snapshot,
            context: request.context,
            decisions: decisions
        )
        guard assembly.canAssemble else {
            var blockers: [WorkspaceMigrationCandidatePreparationIssue] = []
            if let inventoryPreview = assembly.inventory {
                blockers += inventoryPreview.issues.map {
                    .init(kind: .inventoryNeedsReview, legacy: $0.legacy, detail: $0.detail,
                        marketplacePackageID: $0.marketplacePackageID)
                }
            }
            if blockers.isEmpty {
                blockers = assembly.issues.map {
                    issue(.assemblyRejected, nil, "Migration assembly requires review: \($0.rawValue).")
                }
            }
            return .init(preparation: nil, items: items, issues: Self.sorted(blockers))
        }
        do {
            let preparation = try WorkspaceMigrationPreparation.build(
                attemptID: request.attemptID,
                checkpoint: request.checkpoint,
                legacyDatabaseURL: request.legacyDatabaseURL,
                context: request.context,
                decisions: decisions,
                sourceDirectories: sourceDirectories,
                projectIDsBySkillID: request.projectIDsBySkillID,
                nativePluginPlacements: request.nativePluginPlacements
            )
            return .init(preparation: preparation, items: items, issues: [])
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            return .init(preparation: nil, items: items, issues: [
                issue(.invalidPreparation, nil, "The reviewed candidate did not pass final migration preparation checks.")
            ])
        }
    }

    private func failure(
        _ kind: WorkspaceMigrationCandidatePreparationIssueKind,
        _ detail: String
    ) -> WorkspaceMigrationCandidatePreparationPreview {
        .init(preparation: nil, items: [], issues: [.init(kind: kind, detail: detail)])
    }

    private func issue(
        _ kind: WorkspaceMigrationCandidatePreparationIssueKind,
        _ legacy: LegacyReferenceKey?,
        _ detail: String
    ) -> WorkspaceMigrationCandidatePreparationIssue {
        .init(kind: kind, legacy: legacy, detail: detail)
    }
}

private extension WorkspaceMigrationCandidatePreparationService {
    enum CandidateError: Error { case invalidChoice, invalidUpstream, changedUpstream, invalidAttachment, invalidNative }

    enum InventoryValue {
        case skill(Skill), plugin(Plugin), mcp(MCPServer)
    }

    struct Inventory {
        let snapshot: WorkspaceSnapshot
        let values: [LegacyReferenceKey: InventoryValue]

        init(_ snapshot: WorkspaceSnapshot) {
            self.snapshot = snapshot
            var result: [LegacyReferenceKey: InventoryValue] = [:]
            for value in snapshot.skills { result[.init(domain: .skill, identifier: value.id)] = .skill(value) }
            for value in snapshot.plugins { result[.init(domain: .plugin, identifier: value.id)] = .plugin(value) }
            for value in snapshot.mcpServers { result[.init(domain: .mcpServer, identifier: value.id)] = .mcp(value) }
            values = result
        }

        func name(_ value: InventoryValue) -> String {
            switch value {
            case .skill(let value): value.displayName
            case .plugin(let value): value.name
            case .mcp(let value): value.name
            }
        }
    }

    struct UpstreamFacts {
        let fingerprint: String
        let revision: SourceRevision
        let publisherID: String
    }

    static func personalDirectory(skill: Skill, databaseURL: URL) throws -> URL {
        guard safeComponent(skill.bundle), safeComponent(skill.id) else { throw CandidateError.invalidChoice }
        return databaseURL.deletingLastPathComponent()
            .appending(path: "library", directoryHint: .isDirectory)
            .appending(path: "packages", directoryHint: .isDirectory)
            .appending(path: skill.bundle, directoryHint: .isDirectory)
            .appending(path: "skills", directoryHint: .isDirectory)
            .appending(path: skill.id, directoryHint: .isDirectory)
    }

    static func upstreamFacts(binding: SkillRepositoryBinding, directory: URL) throws -> UpstreamFacts {
        try binding.validate()
        guard directory.isFileURL,
              let fingerprint = binding.installedFingerprints[directory.path],
              let revisionValue = binding.installedRevision,
              SkillRepositoryBinding.isHash(revisionValue, lengths: [40, 64]),
              let components = URLComponents(string: binding.repositoryURL),
              components.host?.lowercased() == "github.com" else {
            throw CandidateError.invalidUpstream
        }
        let parts = components.path.split(separator: "/")
        guard parts.count == 2 else { throw CandidateError.invalidUpstream }
        return .init(
            fingerprint: fingerprint,
            revision: .init(
                kind: revisionValue.count == 40 ? .gitCommitSHA1 : .gitCommitSHA256,
                value: revisionValue
            ),
            publisherID: "github:\(parts[0].lowercased())"
        )
    }

    static func validateNative(
        plugin: Plugin,
        routes: [NativePackageRoute],
        children: [WorkspaceMigrationNativeChildChoice],
        inventory: Inventory
    ) throws {
        guard !routes.isEmpty,
              Set(routes.map(\.client)).count == routes.count,
              Set(children.map(\.legacy)).count == children.count else { throw CandidateError.invalidNative }
        for route in routes {
            guard inventory.snapshot.targetObservations.contains(where: {
                $0.surface.client == route.client
                    && $0.discoveredPlugins.contains(route.externalPluginID)
                    && $0.pluginMetadata[route.externalPluginID] != nil
            }) else { throw CandidateError.invalidNative }
        }
        var expected = Set(plugin.skills.map { LegacyReferenceKey(domain: .skill, identifier: $0) })
        for observation in inventory.snapshot.targetObservations {
            guard let client = observation.surface.client else { continue }
            let routeIDs = Set(routes.filter { $0.client == client }.map(\.externalPluginID))
            for (id, metadata) in observation.skillMetadata {
                if let provider = metadata.providerPluginID, routeIDs.contains(provider) {
                    expected.insert(.init(domain: .skill, identifier: id))
                }
            }
            for (parent, metadata) in observation.pluginMetadata where
                routeIDs.contains(parent)
            {
                expected.formUnion(metadata.skillIDs.map { .init(domain: .skill, identifier: $0) })
                expected.formUnion(metadata.mcpServerIDs.map { .init(domain: .mcpServer, identifier: $0) })
            }
        }
        guard expected == Set(children.map(\.legacy)),
              expected.allSatisfy({ inventory.values[$0] != nil }) else { throw CandidateError.invalidNative }
        for child in children {
            switch child.legacy.domain {
            case .skill:
                guard let path = child.packageRelativePath else { throw CandidateError.invalidNative }
                try WorkspaceDomainValidation.requirePortablePath(path, field: "native skill package path")
            case .mcpServer:
                guard child.packageRelativePath == nil else { throw CandidateError.invalidNative }
            default:
                throw CandidateError.invalidNative
            }
        }
    }

    static func canTrack(_ value: InventoryValue, legacy: LegacyReferenceKey, inventory: Inventory) -> Bool {
        switch value {
        case .skill(let skill):
            guard !skill.owned, skill.repositoryBinding == nil else { return false }
        case .mcp(let server):
            guard !server.isManagedDefinition else { return false }
        case .plugin:
            return false
        }
        if legacy.domain == .skill,
           inventory.snapshot.plugins.contains(where: { $0.skills.contains(legacy.identifier) }) {
            return false
        }
        return !inventory.snapshot.targetObservations.contains { observation in
            switch legacy.domain {
            case .skill:
                observation.skillMetadata[legacy.identifier]?.providerPluginID != nil
                    || observation.pluginMetadata.values.contains { $0.skillIDs.contains(legacy.identifier) }
            case .mcpServer:
                observation.pluginMetadata.values.contains { $0.mcpServerIDs.contains(legacy.identifier) }
            case .plugin, .configuration, .collection, .catalogSource, .policy:
                false
            }
        }
    }

    static func items(
        inventory: Inventory,
        ids: [LegacyReferenceKey: ArtifactID],
        selectedKinds: [LegacyReferenceKey: WorkspaceMigrationInventoryChoiceKind],
        parents: [LegacyReferenceKey: LegacyReferenceKey]
    ) -> [WorkspaceMigrationCandidatePreparationItem] {
        let childCounts = Dictionary(grouping: parents.values, by: { $0 }).mapValues(\.count)
        return inventory.values.keys.sorted(by: keyOrder).compactMap { legacy in
            guard let value = inventory.values[legacy], let id = ids[legacy] else { return nil }
            let implicitTracked = selectedKinds[legacy] == nil && canTrack(value, legacy: legacy, inventory: inventory)
            return .init(
                legacy: legacy,
                artifactID: id,
                displayName: inventory.name(value),
                kind: kind(legacy.domain),
                selectedChoice: selectedKinds[legacy] ?? (implicitTracked ? .trackedOnly : nil),
                parentLegacy: parents[legacy],
                bundledChildCount: childCounts[legacy] ?? 0
            )
        }
    }

    static func identity(id: ArtifactID, kind: ArtifactKind, name: String) -> ArtifactIdentity {
        .init(id: id, kind: kind, displayName: name)
    }

    static func kind(_ domain: LegacyReferenceDomain) -> ArtifactKind {
        switch domain {
        case .skill: .skill
        case .plugin: .nativePlugin
        case .mcpServer: .mcpServer
        case .configuration, .collection, .catalogSource, .policy: .logicalProject
        }
    }

    static func safeComponent(_ value: String) -> Bool {
        !value.isEmpty && value != "." && value != ".." && !value.contains("/") && !value.contains("\\")
            && value.precomposedStringWithCanonicalMapping == value
            && !value.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
    }

    static func keyOrder(_ lhs: LegacyReferenceKey, _ rhs: LegacyReferenceKey) -> Bool {
        if lhs.domain != rhs.domain { return lhs.domain.rawValue < rhs.domain.rawValue }
        return lhs.identifier < rhs.identifier
    }

    static func sorted(
        _ issues: [WorkspaceMigrationCandidatePreparationIssue]
    ) -> [WorkspaceMigrationCandidatePreparationIssue] {
        issues.sorted {
            let left = [$0.kind.rawValue, $0.legacy?.domain.rawValue ?? "", $0.legacy?.identifier ?? ""]
            let right = [$1.kind.rawValue, $1.legacy?.domain.rawValue ?? "", $1.legacy?.identifier ?? ""]
            return left.lexicographicallyPrecedes(right)
        }
    }
}
