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
    /// Which kind of content change a staged copy represents, so an operation
    /// title can tell a first install from a replacement rather than calling
    /// every non-removal an "update".
    public enum Change: Hashable, Sendable {
        /// Nothing is at the destination; this creates it.
        case install
        /// Something is there and differs; this replaces it.
        case update
        /// The installed copy is being removed.
        case remove
    }

    public let artifactID: ArtifactID
    public let deploymentName: String
    /// Empty for a removal: nothing is staged to put there.
    public let stagingPath: String
    /// The staged tree for an install, or the installed tree for a removal.
    public let fingerprint: String
    public let destinationPath: String
    /// The installed content the person reviewed, before staging began.
    public let reviewedDestinationDigest: ContentDigest?
    public let client: ClientKind
    public let scope: ToolingScope
    public let change: Change
    /// The project folder a project-scoped copy lands under, so the executor
    /// can admit that folder's own client directory. Absent for user scope.
    public let projectRootPath: String?
    /// The plan destination this copy was staged for, so the step that
    /// carries it out can be told apart from another destination's.
    let physicalDestinationID: WorkspaceObjectID?
    public var isRemoval: Bool { change == .remove }

    public init(
        artifactID: ArtifactID, deploymentName: String, stagingPath: String, fingerprint: String,
        destinationPath: String, client: ClientKind, scope: ToolingScope, change: Change = .install,
        projectRootPath: String? = nil, physicalDestinationID: WorkspaceObjectID? = nil,
        reviewedDestinationDigest: ContentDigest? = nil
    ) {
        self.projectRootPath = projectRootPath
        self.artifactID = artifactID
        self.deploymentName = deploymentName
        self.stagingPath = stagingPath
        self.fingerprint = fingerprint
        self.destinationPath = destinationPath
        self.reviewedDestinationDigest = reviewedDestinationDigest
        self.client = client
        self.scope = scope
        self.change = change
        self.physicalDestinationID = physicalDestinationID
    }

    /// The reviewed step this copy carries out, when it was staged from one.
    var installKey: WorkspaceDeploymentInstallKey? {
        physicalDestinationID.map { .init(artifactID: artifactID, physicalDestinationID: $0) }
    }
}

/// One apply's reviewed operations, in the order they run, and the reviewed
/// step each operation step carries out.
public struct WorkspaceDeploymentRun: Sendable {
    public let operations: [OperationPlan]
    /// The reviewed step each operation step carries out, by the operation
    /// step's identifier. A connection that replaces a registration is two
    /// operation steps, its removal and then its add, for one reviewed step.
    public let installKeys: [UUID: WorkspaceDeploymentInstallKey]
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
            stagingRoot.standardizedFileURL.path == stagingRoot.path
        else {
            throw WorkspaceDeploymentOperationError.invalidStagingRoot
        }
        let byID = Dictionary(artifacts.map { ($0.identity.id, $0) }, uniquingKeysWith: { first, _ in first })
        var staged: [StagedDeployment] = []
        for item in plan.items {
            let digest: ContentDigest
            let reviewedDestinationDigest: ContentDigest?
            var removing = false
            let change: StagedDeployment.Change
            switch item.action {
            case .installContent(let value):
                digest = value
                reviewedDestinationDigest = nil
                change = .install
            case .updateContent(let installed, let value):
                digest = value
                reviewedDestinationDigest = installed
                change = .update
            case .removeContent(let value):
                digest = value
                reviewedDestinationDigest = value
                removing = true
                change = .remove
            // These are the command bridges' work, not a folder copy.
            case .installNativePackage, .configureManagedConnection, .removeManagedConnection: continue
            }
            // A removal needs no staged tree; the installed copy is the subject.
            let tree = removing ? nil : content[digest]
            if !removing, tree == nil { throw WorkspaceDeploymentOperationError.missingContent }
            guard let artifact = byID[item.artifactID],
                let deploymentName = artifact.declaredName, !deploymentName.isEmpty
            else {
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
                    for: .init(
                        surface: item.surface, scope: item.scope,
                        logicalProjectID: item.logicalProjectID),
                    in: $0)
            }
            let destination: URL
            if let linked {
                // The person pointed this destination somewhere. The item's own
                // folder name is still theirs to keep, so it lands inside that
                // folder rather than becoming it.
                destination =
                    URL(fileURLWithPath: linked.resolvedPath)
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
                    provenInstall: provenInstalls.contains(destination.path))
            {
                // Something is already there that this app did not put there.
                // It is left exactly as it is; the caller reports it rather than
                // this deciding someone else's files are disposable.
                throw WorkspaceDeploymentOperationError.destinationOccupied(path: destination.path)
            }

            if removing {
                // The earlier reviewed digest, not this new fingerprint,
                // decides which content execution is allowed to remove.
                let installed = (try? DirectoryFingerprint.sha256(of: destination)) ?? ""
                staged.append(
                    .init(
                        artifactID: item.artifactID, deploymentName: deploymentName,
                        stagingPath: "", fingerprint: installed,
                        destinationPath: destination.path, client: client, scope: item.scope,
                        change: .remove, projectRootPath: projectRoot?.path,
                        physicalDestinationID: item.physicalDestinationID,
                        reviewedDestinationDigest: reviewedDestinationDigest))
                continue
            }
            guard let tree else { throw WorkspaceDeploymentOperationError.missingContent }
            let folder = stagingRoot.appending(
                path: item.artifactID.rawValue.uuidString.lowercased()
                    + "-" + item.physicalDestinationID.rawValue.uuidString.lowercased())
            // The staging folder is named after the item and its destination,
            // so a second attempt at the same install finds the last attempt's
            // copy still there and the exporter refuses a non-empty folder.
            // What is staged is always rebuilt from the library, so the old copy
            // is disposable; anything else under the staging root is left alone.
            if FileManager.default.fileExists(atPath: folder.path) {
                do { try FileManager.default.removeItem(at: folder) } catch { throw WorkspaceDeploymentOperationError.stagingFailed }
            }
            do { try WorkspacePackageExporter.write(tree: tree, to: folder) } catch {
                throw WorkspaceDeploymentOperationError.stagingFailed
            }
            let fingerprint: String
            do { fingerprint = try DirectoryFingerprint.sha256(of: folder) } catch { throw WorkspaceDeploymentOperationError.stagingFailed }

            staged.append(
                .init(
                    artifactID: item.artifactID, deploymentName: deploymentName,
                    stagingPath: folder.path, fingerprint: fingerprint,
                    destinationPath: destination.path, client: client, scope: item.scope,
                    change: change, projectRootPath: projectRoot?.path,
                    physicalDestinationID: item.physicalDestinationID,
                    reviewedDestinationDigest: reviewedDestinationDigest))
        }
        return staged
    }

    /// Orders operations by client: file copies, native installs, connections, then
    /// disconnections. Reviewed `order` controls steps within each operation; unlisted
    /// steps follow by name. Each replacement connection gets its own removal/add
    /// operation: removal failure skips only that add. Disconnections run in separate
    /// operations, preserving approval for each destination.
    public static func run(
        staged: [StagedDeployment],
        nativePlugins: [WorkspaceNativePluginCommandPlan] = [],
        managedConnections: [WorkspaceManagedMCPCommandPlan] = [],
        order: [WorkspaceDeploymentInstallKey] = [],
        identifiers: () -> UUID = { UUID() }
    ) -> WorkspaceDeploymentRun {
        var rank: [WorkspaceDeploymentInstallKey: Int] = [:]
        for (index, key) in order.enumerated() where rank[key] == nil { rank[key] = index }
        func place(_ key: WorkspaceDeploymentInstallKey?) -> Int { key.flatMap { rank[$0] } ?? order.count }
        var installKeys: [UUID: WorkspaceDeploymentInstallKey] = [:]
        var built: [(sort: OperationSort, plan: OperationPlan)] = []

        for (key, deployments) in Dictionary(grouping: staged, by: { DestinationKey(client: $0.client, scope: $0.scope) }) {
            let sorted = deployments.sorted {
                (place($0.installKey), $0.deploymentName) < (place($1.installKey), $1.deploymentName)
            }
            let steps = sorted.map { deployment in
                let step = contentStep(deployment, client: key.client, id: identifiers())
                if let installKey = deployment.installKey { installKeys[step.id] = installKey }
                return step
            }
            built.append(
                (
                    OperationSort(
                        app: appPlace(key.client), part: 0, first: sorted.map { place($0.installKey) }.min() ?? order.count,
                        tiebreak: key.scope.rawValue),
                    contentOperation(steps: steps, deployments: sorted, key: key, id: identifiers())
                ))
        }
        for (surface, group) in Dictionary(grouping: nativePlugins, by: \.surface) {
            let sorted = group.sorted {
                (place(.init(artifactID: $0.artifactID, physicalDestinationID: $0.physicalDestinationID)), $0.externalPluginID)
                    < (place(.init(artifactID: $1.artifactID, physicalDestinationID: $1.physicalDestinationID)), $1.externalPluginID)
            }
            let steps = sorted.map { plan in
                let step = OperationStep(
                    id: identifiers(), kind: .command,
                    title: "Install \(plan.externalPluginID)",
                    detail: "Runs the app's own install command.",
                    executable: plan.executableURL.path, arguments: plan.arguments)
                installKeys[step.id] = .init(artifactID: plan.artifactID, physicalDestinationID: plan.physicalDestinationID)
                return step
            }
            built.append(
                (
                    OperationSort(
                        app: appPlace(surface.client), part: 1, first: place(installKeys[steps[0].id]), tiebreak: surface.rawValue),
                    OperationPlan(
                        id: identifiers(), kind: .installPlugin,
                        title: "Install \(group.count == 1 ? "1 package" : "\(group.count) packages") in \(appName(surface))",
                        summary: "Asks the app to install these itself. It owns them afterwards, including updates.",
                        targetSurfaces: [surface], scope: sorted[0].scope, steps: steps)
                ))
        }
        for (surface, group) in Dictionary(grouping: managedConnections, by: \.surface) {
            let sorted = group.sorted {
                (place(.init(artifactID: $0.artifactID, physicalDestinationID: $0.physicalDestinationID)), $0.nativeServerIdentifier)
                    < (place(.init(artifactID: $1.artifactID, physicalDestinationID: $1.physicalDestinationID)), $1.nativeServerIdentifier)
            }
            // Plain adds share an operation; each replacement is one of its
            // own, so what its removal stops is its own add alone. Removals
            // share one of their own, after the adds.
            var runs: [[WorkspaceManagedMCPCommandPlan]] = []
            for plan in sorted where !plan.isRemoval {
                if plan.preArguments == nil, let last = runs.last, last.allSatisfy({ $0.preArguments == nil }) {
                    runs[runs.count - 1].append(plan)
                } else {
                    runs.append([plan])
                }
            }
            let removals = sorted.filter(\.isRemoval)
            if !removals.isEmpty {
                let steps = removals.map { plan in
                    let step = OperationStep(
                        id: identifiers(), kind: .command, title: disconnectionStepTitle(plan.nativeServerIdentifier),
                        detail: "Runs the app's own command to remove this connection.",
                        executable: plan.executableURL.path, arguments: plan.arguments,
                        currentDirectoryPath: plan.workingDirectoryPath,
                        projectRootPath: plan.workingDirectoryPath)
                    installKeys[step.id] = .init(artifactID: plan.artifactID, physicalDestinationID: plan.physicalDestinationID)
                    return step
                }
                let connections = removals.count == 1 ? "1 connection" : "\(removals.count) connections"
                built.append(
                    (
                        OperationSort(
                            app: appPlace(surface.client), part: 3, first: place(installKeys[steps[0].id]),
                            tiebreak: surface.rawValue),
                        OperationPlan(
                            id: identifiers(), kind: .configureMCP,
                            title: "Remove \(connections) from \(appName(surface))",
                            summary: "Removes these connections from the app. Nothing else in its configuration changes.",
                            targetSurfaces: [surface], scope: removals[0].scope, steps: steps)
                    ))
            }
            for run in runs {
                let steps = run.flatMap { plan in
                    let key = WorkspaceDeploymentInstallKey(artifactID: plan.artifactID, physicalDestinationID: plan.physicalDestinationID)
                    var steps: [OperationStep] = []
                    if let preArguments = plan.preArguments {
                        // The old registration goes first; if it cannot be
                        // removed, the add would only fail on the name, so it
                        // does not run.
                        steps.append(
                            OperationStep(
                                id: identifiers(), kind: .command,
                                title: removalStepTitle(plan.nativeServerIdentifier),
                                detail: "Runs the app's own command to remove the registration this one replaces.",
                                executable: plan.executableURL.path, arguments: preArguments,
                                currentDirectoryPath: plan.workingDirectoryPath,
                                projectRootPath: plan.workingDirectoryPath, stopsOnFailure: true))
                    }
                    steps.append(
                        OperationStep(
                            id: identifiers(), kind: .command,
                            title: connectionStepTitle(plan.nativeServerIdentifier),
                            detail: "Runs the app's own command to add this connection.",
                            executable: plan.executableURL.path, arguments: plan.arguments,
                            currentDirectoryPath: plan.workingDirectoryPath,
                            projectRootPath: plan.workingDirectoryPath))
                    for step in steps { installKeys[step.id] = key }
                    return steps
                }
                let replacing = run.count == 1 && run[0].preArguments != nil
                built.append(
                    (
                        OperationSort(
                            app: appPlace(surface.client), part: 2, first: place(installKeys[steps[0].id]),
                            tiebreak: surface.rawValue),
                        OperationPlan(
                            id: identifiers(), kind: .configureMCP,
                            title: replacing
                                ? "Replace \(run[0].nativeServerIdentifier) in \(appName(surface))"
                                : "Set up \(run.count == 1 ? "1 connection" : "\(run.count) connections") in \(appName(surface))",
                            summary: replacing
                                ? "Removes the registration this connection replaces, then adds it. Signing in, if needed, stays with you."
                                : "Adds these connections to the app. Signing in, if needed, stays with you.",
                            targetSurfaces: [surface], scope: run[0].scope, steps: steps)
                    ))
            }
        }
        return WorkspaceDeploymentRun(
            operations: built.sorted { $0.sort < $1.sort }.map(\.plan), installKeys: installKeys)
    }

    /// The title of the step that adds the connection `name`, as its receipt
    /// keeps it. A receipt holding it, succeeded, is Agent Tooling's proof it
    /// set that connection up (`provenConnections(in:)`).
    static func connectionStepTitle(_ name: String) -> String {
        "Set up \(name)"
    }

    /// The title of the step that removes the registration a connection
    /// replaces. It proves nothing: it takes a registration out, and the add
    /// after it puts one back.
    static func removalStepTitle(_ name: String) -> String {
        "Remove the old \(name)"
    }

    /// The title of the step that takes the connection `name` out of its
    /// app for good (`.removeManagedConnection`). Succeeded, it ends the
    /// proof an earlier "Set up <name>" gave (`provenConnections(in:)`).
    static func disconnectionStepTitle(_ name: String) -> String {
        "Remove \(name)"
    }

    /// Derives connection ownership from successful add/remove receipts in time
    /// order. A later permanent removal revokes ownership; failed adds, replacement
    /// pre-removals and configuration edits prove nothing. This permits replacement
    /// or withdrawal of registrations we created while preserving later manual ones.
    public static func provenConnections(in receipts: [OperationReceipt]) -> [TargetSurface: Set<String>] {
        // Oldest first; the store lists the newest first, so receipts made at
        // the same moment keep that order reversed.
        let ordered = receipts.indices
            .sorted {
                receipts[$0].createdAt != receipts[$1].createdAt ? receipts[$0].createdAt < receipts[$1].createdAt : $0 > $1
            }
            .map { receipts[$0] }
        var proven: [TargetSurface: Set<String>] = [:]
        for receipt in ordered where receipt.kind == .configureMCP {
            for outcome in receipt.itemOutcomes where outcome.status == .succeeded {
                if let name = connectionName(in: outcome.title, after: connectionStepTitle("")) {
                    for surface in receipt.targetSurfaces { proven[surface, default: []].insert(name) }
                } else if let name = connectionName(in: outcome.title, after: disconnectionStepTitle("")) {
                    for surface in receipt.targetSurfaces { proven[surface]?.remove(name) }
                }
            }
        }
        return proven.filter { !$0.value.isEmpty }
    }

    /// The connection's name in a step title that is `prefix` followed by
    /// one name: none when the rest is empty or is more than one word ("Remove
    /// the old agent-tooling" names no connection after "Remove ").
    private static func connectionName(in title: String, after prefix: String) -> String? {
        guard title.hasPrefix(prefix) else { return nil }
        let name = String(title.dropFirst(prefix.count))
        return name.isEmpty || name.contains(where: \.isWhitespace) ? nil : name
    }

    /// One reviewable operation per destination folder, so a person approves
    /// what happens to each place rather than one undifferentiated batch.
    static func operations(
        for staged: [StagedDeployment],
        identifiers: () -> UUID = { UUID() }
    ) -> [OperationPlan] {
        run(staged: staged, identifiers: identifiers).operations
    }

    /// Turns already-reviewed command plans into operation steps.
    ///
    /// Every check that admits one of these lives in its own bridge, which
    /// requires exact routes, capability evidence and scope support before it
    /// will produce a plan at all. This only carries the result across; it adds
    /// no permission of its own, and running a command is not evidence that the
    /// package or connection is usable afterwards.
    static func operations(
        nativePlugins: [WorkspaceNativePluginCommandPlan] = [],
        managedConnections: [WorkspaceManagedMCPCommandPlan] = [],
        identifiers: () -> UUID = { UUID() }
    ) -> [OperationPlan] {
        run(staged: [], nativePlugins: nativePlugins, managedConnections: managedConnections, identifiers: identifiers)
            .operations
    }

    private static func contentStep(_ deployment: StagedDeployment, client: ClientKind, id: UUID) -> OperationStep {
        deployment.isRemoval
            ? OperationStep(
                id: id,
                kind: .removeManagedDirectory,
                title: "Remove \(deployment.deploymentName)",
                detail: "Remove the copy Agent Tooling installed in \(client.rawValue).",
                destinationPath: deployment.destinationPath,
                // Legacy callers supply a linked-install fingerprint. New
                // deployment reviews bind content separately from ownership.
                destinationFingerprint: deployment.reviewedDestinationDigest == nil ? deployment.fingerprint : nil,
                reviewedDestinationDigest: deployment.reviewedDestinationDigest,
                projectRootPath: deployment.projectRootPath)
            : OperationStep(
                id: id,
                kind: .copyDirectory,
                title: "Install \(deployment.deploymentName)",
                detail: "Copy the approved version into \(client.rawValue).",
                sourcePath: deployment.stagingPath,
                // The executor recomputes this before committing, so a
                // staged folder that changed cannot slip past review.
                sourceFingerprint: deployment.fingerprint,
                destinationPath: deployment.destinationPath,
                reviewedDestinationDigest: deployment.reviewedDestinationDigest,
                // Names the project folder the copy lands under, so the
                // executor admits that folder's client directory and
                // nothing outside it.
                projectRootPath: deployment.projectRootPath)
    }

    private static func contentOperation(
        steps: [OperationStep], deployments: [StagedDeployment], key: DestinationKey, id: UUID
    ) -> OperationPlan {
        let removals = deployments.filter(\.isRemoval).count
        let installs = deployments.filter { $0.change == .install }.count
        let updates = deployments.filter { $0.change == .update }.count
        let count = deployments.count
        let tools = count == 1 ? "1 tool" : "\(count) tools"
        let title: String
        if removals == count {
            title = "Remove \(tools) from \(key.client.rawValue)"
        } else if installs == count {
            title = "Install \(tools) in \(key.client.rawValue)"
        } else if updates == count {
            title = "Update \(tools) in \(key.client.rawValue)"
        } else {
            // A folder that gets some first installs and some
            // replacements at once is neither, so it is a change.
            title = "Change \(tools) in \(key.client.rawValue)"
        }
        return OperationPlan(
            id: id,
            // A plan that only replaces what an app already has is an
            // update, and history says so.
            kind: updates == count && removals == 0 ? .updateSkill : .installSkill,
            title: title,
            summary: "Only what you reviewed changes. Nothing else in that folder is touched.",
            targetSurfaces: [key.client.defaultSurface],
            scope: key.scope,
            steps: steps)
    }

    /// An app as a person knows it: "Codex", never its surface's "Codex CLI".
    private static func appName(_ surface: TargetSurface) -> String {
        surface.client?.rawValue ?? surface.displayName
    }

    /// Where an app falls in the app order; a surface no app owns, last.
    private static func appPlace(_ client: ClientKind?) -> Int {
        client.flatMap { ClientKind.allCases.firstIndex(of: $0) } ?? ClientKind.allCases.count
    }

    /// Where an operation falls in the run: its app, then copies before what
    /// the app installs before connections before connections taken out,
    /// then the first reviewed step it carries out, then its folder or
    /// surface, so no two tie.
    private struct OperationSort: Comparable {
        let app: Int
        let part: Int
        let first: Int
        let tiebreak: String

        static func < (left: Self, right: Self) -> Bool {
            (left.app, left.part, left.first, left.tiebreak) < (right.app, right.part, right.first, right.tiebreak)
        }
    }

    private struct DestinationKey: Hashable {
        let client: ClientKind
        let scope: ToolingScope
    }
}
