import Foundation

/// Explicit decisions gathered by review, not inferred from matching labels.
/// Complete trees are transient reviewed bytes and never part of portable JSON.
public struct WorkspaceMigrationDecisions: Sendable {
    public var artifacts: [WorkspaceInventoryMigrationResolution] = []
    public var sources: [PortableSourceDescriptor] = []
    public var subscriptions: [UpstreamSubscription] = []
    public var identities: [WorkspaceMigrationIdentityEntry] = []
    public var marketplace: [WorkspaceMarketplaceMigrationResolution] = []
    public var marketplaceBindings: [String: ArtifactID] = [:]
    public var managedMCP: [WorkspaceManagedMCPMigrationResolution] = []
    public var projects: [WorkspaceMCPMigrationProject] = []
    public var configurationProjects: [LegacyReferenceKey: ArtifactID] = [:]
    public var sourceLocations: [SourceRootBinding] = []
    public var rootContent: [ArtifactID: CapturedPackageTree] = [:]

    public init() {}
}

/// Retain this context across a review retry. Timestamps do not allocate identities.
public struct WorkspaceMigrationContext: Sendable {
    public let workspaceID: WorkspaceObjectID
    public let deviceID: WorkspaceObjectID
    public let revision: WorkspaceRevision

    public init(workspaceID: WorkspaceObjectID, deviceID: WorkspaceObjectID, revision: WorkspaceRevision) {
        self.workspaceID = workspaceID
        self.deviceID = deviceID
        self.revision = revision
    }
}

public enum WorkspaceMigrationAssemblyIssue: String, Hashable, Sendable {
    case invalidLegacySnapshot, invalidIdentity, inventoryNeedsReview, configurationNeedsReview
    case invalidProjectMapping, missingProjectMapping, projectRootMismatch, wrongDevice
    case missingContent, contentMismatch, invalidSourceBinding, invalidCombinedDocument
}

/// Sealed in-memory candidate, not an initialized store or migration receipt.
/// Raw checkpoint fidelity, assignment parity and reviewed commit remain gates.
public struct WorkspaceMigrationCandidate: Sendable {
    public let document: PortableWorkspaceDocument
    public let device: DeviceWorkspaceState
    public let content: [ArtifactID: CapturedPackageTree]
    public let legacySnapshot: WorkspaceSnapshot
}

public struct WorkspaceMigrationAssemblyPreview: Sendable {
    public let candidate: WorkspaceMigrationCandidate?
    public let inventory: WorkspaceInventoryMigrationPreview?
    public let configurations: WorkspaceConfigurationMigrationPreview?
    public let issues: [WorkspaceMigrationAssemblyIssue]

    public var canAssemble: Bool { candidate != nil && issues.isEmpty }
}

public enum WorkspaceMigrationAssembly {
    /// Both converters always consume this same snapshot/context. Accepting two
    /// independently mutable previews would allow a stale configuration packet
    /// to be joined to unrelated inventory without any shared origin evidence.
    public static func preview(
        snapshot: WorkspaceSnapshot, context: WorkspaceMigrationContext, decisions: WorkspaceMigrationDecisions
    ) -> WorkspaceMigrationAssemblyPreview {
        var inventory: WorkspaceInventoryMigrationPreview?
        var configurations: WorkspaceConfigurationMigrationPreview?
        func blocked(_ issue: WorkspaceMigrationAssemblyIssue) -> WorkspaceMigrationAssemblyPreview {
            .init(candidate: nil, inventory: inventory, configurations: configurations, issues: [issue])
        }
        do { try WorkspaceSnapshotValidator.validate(snapshot, mode: .localState) }
        catch { return blocked(.invalidLegacySnapshot) }
        guard context.revision.parentIDs.isEmpty else { return blocked(.invalidCombinedDocument) }
        do {
            inventory = try WorkspaceInventoryMigration.preview(snapshot: snapshot, workspaceID: context.workspaceID,
                resolutions: decisions.artifacts, sources: decisions.sources, subscriptions: decisions.subscriptions,
                preserving: decisions.identities, marketplaceResolutions: decisions.marketplace,
                preservingMarketplaceBindings: decisions.marketplaceBindings, deviceID: context.deviceID,
                managedMCPResolutions: decisions.managedMCP, preservingMCPProjectMappings: decisions.projects)
        } catch { return blocked(.invalidIdentity) }
        guard let inventoryValue = inventory, inventoryValue.canMigrateInventory else { return blocked(.inventoryNeedsReview) }
        do {
            configurations = try WorkspaceConfigurationMigration.preview(snapshot: snapshot, workspaceID: context.workspaceID,
                artifactBindings: inventoryValue.artifactBindings, projectBindings: decisions.configurationProjects,
                preserving: inventoryValue.identityMap)
        } catch { return blocked(.invalidIdentity) }
        guard let config = configurations, config.canMigrateConfigurations else { return blocked(.configurationNeedsReview) }

        // Every inventory reservation, including absent legacy targets retained
        // by a prior preview, must survive configuration allocation unchanged.
        let combinedMap = Dictionary(grouping: config.state.identityMap, by: \.legacy)
        guard inventoryValue.identityMap.allSatisfy({ combinedMap[$0.legacy] == [$0] }) else { return blocked(.invalidIdentity) }

        var artifacts = inventoryValue.artifacts
        var projects: [ArtifactID: WorkspaceMCPMigrationProject] = [:]
        var roots: [String: ArtifactID] = [:]
        for mapping in decisions.projects + inventoryValue.mcpProjectMappings {
            do { try WorkspaceDomainValidation.requireAbsolutePath(mapping.rootPath, field: "migration project root") }
            catch { return blocked(.invalidProjectMapping) }
            if let previous = projects[mapping.project.id], previous.project != mapping.project || previous.rootPath != mapping.rootPath {
                return blocked(.invalidProjectMapping)
            }
            if let previous = roots[mapping.rootPath], previous != mapping.project.id { return blocked(.invalidProjectMapping) }
            projects[mapping.project.id] = mapping
            roots[mapping.rootPath] = mapping.project.id
        }
        for mapping in projects.values {
            if let artifact = artifacts.first(where: { $0.identity.id == mapping.project.id }) {
                guard artifact.identity.kind == .logicalProject, artifact.identity.displayName == mapping.project.name,
                      artifact.identity.parentPackageID == nil else { return blocked(.invalidProjectMapping) }
            } else {
                artifacts.append(.init(identity: .init(id: mapping.project.id, kind: .logicalProject,
                    displayName: mapping.project.name), authority: .trackedOnly))
            }
        }
        for configuration in config.state.configurations {
            guard let projectID = configuration.logicalProjectID else { continue }
            guard let project = projects[projectID],
                  let binding = config.deviceState.configurationBindings.first(where: { $0.configurationID == configuration.id }) else {
                return blocked(.missingProjectMapping)
            }
            guard binding.projectRoot == project.rootPath else { return blocked(.projectRootMismatch) }
        }
        for assignment in inventoryValue.managedMCPAssignments {
            guard assignment.destination.deviceIDs == [context.deviceID] else { return blocked(.wrongDevice) }
            if let projectID = assignment.destination.logicalProjectID, projects[projectID] == nil {
                return blocked(.missingProjectMapping)
            }
        }
        let content: [ArtifactID: CapturedPackageTree]
        do { content = try materialize(artifacts: artifacts, roots: decisions.rootContent,
            managedMCP: Set(inventoryValue.mcpDefinitions.map(\.artifactID))) }
        catch let issue as WorkspaceMigrationAssemblyIssue { return blocked(issue) }
        catch { return blocked(.contentMismatch) }
        for source in inventoryValue.sources where source.role == .attachedAuthoring {
            guard decisions.sourceLocations.filter({ $0.sourceRootID == source.id }).count == 1 else {
                return blocked(.invalidSourceBinding)
            }
        }
        do {
            let document = try WorkspaceDocumentCoding.seal(.init(workspaceID: context.workspaceID, revision: context.revision,
                artifacts: artifacts, sources: inventoryValue.sources, subscriptions: inventoryValue.subscriptions,
                logicalProjects: projects.values.map(\.project), assignments: inventoryValue.managedMCPAssignments,
                configurationState: config.state, mcpDefinitions: inventoryValue.mcpDefinitions))
            let device = DeviceWorkspaceState(workspaceID: context.workspaceID, deviceID: context.deviceID,
                sourceLocations: decisions.sourceLocations, observations: inventoryValue.observations,
                configurationState: config.deviceState, mcpBindings: inventoryValue.mcpBindings,
                applicationState: DeviceApplicationState(snapshot: snapshot),
                projectRoots: projects.values.map { .init(projectID: $0.project.id, rootPath: $0.rootPath) },
                inventoryState: try DeviceInventoryState(snapshot: snapshot, artifactBindings: inventoryValue.artifactBindings))
            try device.validateStructure(against: document)
            // Run canonical encoding now, not only at later store initialization.
            // This catches size/serialization constraints before displaying ready.
            _ = try WorkspaceDocumentCoding.encode(document)
            let bytes = try WorkspaceDocumentCoding.encodeDeviceState(device)
            let canonicalDevice = try WorkspaceDocumentCoding.decodeDeviceState(bytes, against: document)
            return .init(candidate: .init(document: document, device: canonicalDevice, content: content,
                legacySnapshot: snapshot), inventory: inventoryValue, configurations: config, issues: [])
        } catch { return blocked(.invalidCombinedDocument) }
    }

    private static func materialize(
        artifacts: [ArtifactRecord], roots: [ArtifactID: CapturedPackageTree], managedMCP: Set<ArtifactID>
    ) throws -> [ArtifactID: CapturedPackageTree] {
        guard Set(artifacts.map(\.identity.id)).count == artifacts.count else { throw WorkspaceMigrationAssemblyIssue.invalidIdentity }
        let records = Dictionary(uniqueKeysWithValues: artifacts.map { ($0.identity.id, $0) })
        var result: [ArtifactID: CapturedPackageTree] = [:]
        var visiting = Set<ArtifactID>()
        func tree(for artifact: ArtifactRecord) throws -> CapturedPackageTree {
            if let previous = result[artifact.identity.id] { return previous }
            guard visiting.insert(artifact.identity.id).inserted else { throw WorkspaceMigrationAssemblyIssue.contentMismatch }
            defer { visiting.remove(artifact.identity.id) }
            guard let digest = artifact.contentDigest else { throw WorkspaceMigrationAssemblyIssue.missingContent }
            let content: CapturedPackageTree
            if let parentID = artifact.identity.parentPackageID {
                guard let parent = records[parentID], parent.authority == artifact.authority,
                      let relativePath = artifact.packageRelativePath else { throw WorkspaceMigrationAssemblyIssue.contentMismatch }
                content = try tree(for: parent).subtree(at: relativePath)
                guard roots[artifact.identity.id] == nil else { throw WorkspaceMigrationAssemblyIssue.contentMismatch }
            } else {
                guard let root = roots[artifact.identity.id] else { throw WorkspaceMigrationAssemblyIssue.missingContent }
                content = root
            }
            guard content.digest == digest else { throw WorkspaceMigrationAssemblyIssue.contentMismatch }
            result[artifact.identity.id] = content
            return content
        }
        for artifact in artifacts {
            switch artifact.authority {
            case .centralPersonal, .centralUpstream:
                // Only typed standalone MCP definitions have no package bytes.
                // A package-owned MCP component still requires its full tree.
                if !managedMCP.contains(artifact.identity.id) { _ = try tree(for: artifact) }
            case .nativeOwned, .attachedAuthoring, .trackedOnly:
                guard roots[artifact.identity.id] == nil else { throw WorkspaceMigrationAssemblyIssue.contentMismatch }
            }
        }
        guard Set(roots.keys).isSubset(of: Set(result.keys)) else { throw WorkspaceMigrationAssemblyIssue.contentMismatch }
        return result
    }
}

extension WorkspaceMigrationAssemblyIssue: Error {}
