import Foundation

public enum WorkspaceDeploymentOperationError: Error, Equatable, Sendable {
    case missingContent
    case unsupportedSurface
    case unsupportedScope
    case missingProjectRoot
    case invalidStagingRoot
    case stagingFailed
    /// An apply-once linked destination already holds something this app did
    /// not put there. Nothing was written.
    case destinationOccupied(path: String)
}

/// A reviewed content deployment, staged and ready for the existing executor.
public struct StagedDeployment: Hashable, Sendable {
    public let artifactID: ArtifactID
    public let deploymentName: String
    /// Empty for a removal: nothing is staged to put there.
    public let stagingPath: String
    /// The staged tree for an install, or the installed tree for a removal.
    public let fingerprint: String
    public let destinationPath: String
    public let client: ClientKind
    public let scope: ToolingScope
    public let isRemoval: Bool

    public init(
        artifactID: ArtifactID, deploymentName: String, stagingPath: String, fingerprint: String,
        destinationPath: String, client: ClientKind, scope: ToolingScope, isRemoval: Bool = false
    ) {
        self.artifactID = artifactID
        self.deploymentName = deploymentName
        self.stagingPath = stagingPath
        self.fingerprint = fingerprint
        self.destinationPath = destinationPath
        self.client = client
        self.scope = scope
        self.isRemoval = isRemoval
    }
}

/// Turns a deployment plan into work the existing reviewed operation path can
/// run, and stages the exact approved bytes first.
///
/// Staging is deliberate: the executor copies from a folder and re-checks its
/// fingerprint before committing, so the thing that lands is the revision that
/// was reviewed rather than whatever the library held at copy time. Nothing here
/// executes anything, and producing a plan is not evidence of installation.
///
/// Only content deployments to a supported CLI surface are built here. Native
/// package installs and managed connections have their own command bridges,
/// which carry their own evidence requirements.
public enum WorkspaceDeploymentOperations {
    /// Writes the approved trees into a staging root.
    ///
    /// The root must be inside this app's own managed library: the executor
    /// refuses to copy content from anywhere else, which is what keeps a
    /// deployment from installing whatever happens to be lying around.
    /// `device` supplies this Mac's own linked destinations. A destination the
    /// person redirected writes where they pointed it instead of the client's
    /// default folder, and an apply-once one that already holds something is
    /// left alone rather than replaced.
    public static func stage(
        _ plan: WorkspaceDeploymentPlan,
        artifacts: [ArtifactRecord],
        content: [ContentDigest: CapturedPackageTree],
        stagingRoot: URL,
        homeURL: URL,
        projectRoots: [ArtifactID: URL] = [:],
        device: DeviceWorkspaceState? = nil,
        provenInstalls: Set<String> = []
    ) throws -> [StagedDeployment] {
        guard stagingRoot.isFileURL, stagingRoot.path.hasPrefix("/"),
              !stagingRoot.path.contains("\0"),
              stagingRoot.standardizedFileURL.path == stagingRoot.path else {
            throw WorkspaceDeploymentOperationError.invalidStagingRoot
        }
        let byID = Dictionary(artifacts.map { ($0.identity.id, $0) }, uniquingKeysWith: { first, _ in first })
        var staged: [StagedDeployment] = []
        for item in plan.items {
            let digest: ContentDigest
            var removing = false
            switch item.action {
            case .installContent(let value): digest = value
            case .updateContent(_, let value): digest = value
            case .removeContent(let value): digest = value; removing = true
            // These are the command bridges' work, not a folder copy.
            case .installNativePackage, .configureManagedConnection: continue
            }
            // A removal needs no staged tree; the installed copy is the subject.
            let tree = removing ? nil : content[digest]
            if !removing, tree == nil { throw WorkspaceDeploymentOperationError.missingContent }
            guard let artifact = byID[item.artifactID],
                  let deploymentName = artifact.declaredName, !deploymentName.isEmpty else {
                throw WorkspaceDeploymentOperationError.missingContent
            }
            guard let client = item.surface.client else {
                throw WorkspaceDeploymentOperationError.unsupportedSurface
            }
            let projectRoot = item.logicalProjectID.flatMap { projectRoots[$0] }
            if item.scope == .project, projectRoot == nil {
                throw WorkspaceDeploymentOperationError.missingProjectRoot
            }
            let linked = device.flatMap {
                WorkspaceLinkedDestinations.binding(
                    for: .init(surface: item.surface, scope: item.scope,
                               logicalProjectID: item.logicalProjectID),
                    in: $0)
            }
            let destination: URL
            if let linked {
                // The person pointed this destination somewhere. The item's own
                // folder name is still theirs to keep, so it lands inside that
                // folder rather than becoming it.
                destination = URL(fileURLWithPath: linked.resolvedPath)
                    .appending(path: deploymentName).standardizedFileURL
            } else {
                do {
                    destination = try NativeSkillDestination.skillURL(
                        client: client, skillID: deploymentName, homeURL: homeURL,
                        scope: item.scope, projectRoot: projectRoot)
                } catch NativeSkillDestinationError.unsupportedScope {
                    throw WorkspaceDeploymentOperationError.unsupportedScope
                } catch {
                    throw WorkspaceDeploymentOperationError.unsupportedSurface
                }
            }
            if !removing, let linked,
               !WorkspaceLinkedDestinations.mayWrite(
                   into: destination, policy: linked.writePolicy,
                   provenInstall: provenInstalls.contains(destination.path)) {
                // Something is already there that this app did not put there.
                // It is left exactly as it is; the caller reports it rather than
                // this deciding someone else's files are disposable.
                throw WorkspaceDeploymentOperationError.destinationOccupied(path: destination.path)
            }

            if removing {
                // The removal is bound to the exact installed tree that was
                // measured, so an edited folder is refused at apply time.
                let installed = (try? DirectoryFingerprint.sha256(of: destination)) ?? ""
                staged.append(.init(
                    artifactID: item.artifactID, deploymentName: deploymentName,
                    stagingPath: "", fingerprint: installed,
                    destinationPath: destination.path, client: client, scope: item.scope,
                    isRemoval: true))
                continue
            }
            guard let tree else { throw WorkspaceDeploymentOperationError.missingContent }
            let folder = stagingRoot.appending(path: item.artifactID.rawValue.uuidString.lowercased()
                + "-" + item.physicalDestinationID.rawValue.uuidString.lowercased())
            do { try WorkspacePackageExporter.write(tree: tree, to: folder) }
            catch { throw WorkspaceDeploymentOperationError.stagingFailed }
            let fingerprint: String
            do { fingerprint = try DirectoryFingerprint.sha256(of: folder) }
            catch { throw WorkspaceDeploymentOperationError.stagingFailed }

            staged.append(.init(
                artifactID: item.artifactID, deploymentName: deploymentName,
                stagingPath: folder.path, fingerprint: fingerprint,
                destinationPath: destination.path, client: client, scope: item.scope))
        }
        return staged
    }

    /// One reviewable operation per destination folder, so a person approves
    /// what happens to each place rather than one undifferentiated batch.
    public static func operations(
        for staged: [StagedDeployment],
        identifiers: () -> UUID = { UUID() }
    ) -> [OperationPlan] {
        Dictionary(grouping: staged) { DestinationKey(client: $0.client, scope: $0.scope) }
            .sorted { left, right in
                [left.key.client.rawValue, left.key.scope.rawValue]
                    .lexicographicallyPrecedes([right.key.client.rawValue, right.key.scope.rawValue])
            }
            .map { key, deployments in
                let sorted = deployments.sorted { $0.deploymentName < $1.deploymentName }
                let steps = sorted.map { deployment in
                    deployment.isRemoval
                        ? OperationStep(
                            id: identifiers(),
                            kind: .removeManagedDirectory,
                            title: "Remove \(deployment.deploymentName)",
                            detail: "Remove the copy this app installed in \(key.client.rawValue).",
                            destinationPath: deployment.destinationPath,
                            // Bound to the installed tree; an edited folder is
                            // left alone rather than deleted.
                            destinationFingerprint: deployment.fingerprint)
                        : OperationStep(
                            id: identifiers(),
                            kind: .copyDirectory,
                            title: "Install \(deployment.deploymentName)",
                            detail: "Copy the approved version into \(key.client.rawValue).",
                            sourcePath: deployment.stagingPath,
                            // The executor recomputes this before committing, so a
                            // staged folder that changed cannot slip past review.
                            sourceFingerprint: deployment.fingerprint,
                            destinationPath: deployment.destinationPath)
                }
                let removals = sorted.filter(\.isRemoval).count
                return OperationPlan(
                    id: identifiers(),
                    kind: .installSkill,
                    title: removals == sorted.count
                        ? "Remove \(sorted.count == 1 ? "1 tool" : "\(sorted.count) tools") from \(key.client.rawValue)"
                        : "Update \(sorted.count == 1 ? "1 tool" : "\(sorted.count) tools") in \(key.client.rawValue)",
                    summary: "Only what you reviewed changes. Nothing else in that folder is touched.",
                    targetSurfaces: [key.client.primarySurface],
                    scope: key.scope,
                    steps: steps)
            }
    }

    /// Turns already-reviewed command plans into operation steps.
    ///
    /// Every check that admits one of these lives in its own bridge, which
    /// requires exact routes, capability evidence and scope support before it
    /// will produce a plan at all. This only carries the result across; it adds
    /// no permission of its own, and running a command is not evidence that the
    /// package or connection is usable afterwards.
    public static func operations(
        nativePlugins: [WorkspaceNativePluginCommandPlan] = [],
        managedConnections: [WorkspaceManagedMCPCommandPlan] = [],
        identifiers: () -> UUID = { UUID() }
    ) -> [OperationPlan] {
        var plans: [OperationPlan] = []
        let pluginGroups = Dictionary(grouping: nativePlugins, by: \.surface)
        for surface in pluginGroups.keys.sorted(by: { $0.rawValue < $1.rawValue }) {
            let group = (pluginGroups[surface] ?? []).sorted { $0.externalPluginID < $1.externalPluginID }
            plans.append(OperationPlan(
                id: identifiers(), kind: .installPlugin,
                title: "Install \(group.count == 1 ? "1 package" : "\(group.count) packages") in \(surface.displayName)",
                summary: "Asks the app to install these itself. It owns them afterwards, including updates.",
                targetSurfaces: [surface], scope: group[0].scope,
                steps: group.map { plan in
                    OperationStep(
                        id: identifiers(), kind: .command,
                        title: "Install \(plan.externalPluginID)",
                        detail: "Runs the app's own install command.",
                        executable: plan.executableURL.path, arguments: plan.arguments)
                }))
        }
        let connectionGroups = Dictionary(grouping: managedConnections, by: \.surface)
        for surface in connectionGroups.keys.sorted(by: { $0.rawValue < $1.rawValue }) {
            let group = (connectionGroups[surface] ?? [])
                .sorted { $0.nativeServerIdentifier < $1.nativeServerIdentifier }
            plans.append(OperationPlan(
                id: identifiers(), kind: .configureMCP,
                title: "Set up \(group.count == 1 ? "1 connection" : "\(group.count) connections") in \(surface.displayName)",
                summary: "Adds these connections to the app. Signing in, if needed, stays with you.",
                targetSurfaces: [surface], scope: group[0].scope,
                steps: group.map { plan in
                    OperationStep(
                        id: identifiers(), kind: .command,
                        title: "Set up \(plan.nativeServerIdentifier)",
                        detail: "Runs the app's own command to add this connection.",
                        executable: plan.executableURL.path, arguments: plan.arguments,
                        projectRootPath: plan.workingDirectoryPath)
                }))
        }
        return plans
    }

    private struct DestinationKey: Hashable {
        let client: ClientKind
        let scope: ToolingScope
    }
}

private extension ClientKind {
    var primarySurface: TargetSurface {
        switch self {
        case .claude: .claudeCode
        case .codex: .codexCLI
        case .gemini: .geminiCLI
        }
    }
}
