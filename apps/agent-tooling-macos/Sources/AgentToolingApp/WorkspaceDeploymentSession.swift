import AgentToolingCore
import Foundation
import Observation

/// What would change in this Mac's apps, and applying it once the person says so.
///
/// Preparing reads only. Applying goes through the same reviewed operation path
/// the rest of the app uses, so each destination is approved and verified on its
/// own. A saved assignment is never reported as installed until a step actually
/// succeeded.
@MainActor @Observable
final class WorkspaceDeploymentSession {
    struct Result: Identifiable {
        let id = UUID()
        let title: String
        let succeeded: Int
        let failed: Int
        let outputs: [String]
    }

    /// Destinations this Mac writes somewhere other than the default.
    struct LinkedDestination: Identifiable {
        let id: WorkspaceObjectID
        let surface: TargetSurface
        let scope: ToolingScope
        let projectName: String?
        let path: String
    }

    private(set) var linkedDestinations: [LinkedDestination] = []
    private(set) var plan: WorkspaceDeploymentPlan?
    private(set) var results: [Result] = []
    private(set) var isBusy = false
    private(set) var errorMessage: String?

    private let service: WorkspaceApplicationService
    private let library: WorkspaceLibrarySession
    private let store: WorkspaceRevisionStore
    private let homeRoot: URL
    private let contentStore: CentralPackageContentStore?

    init(
        service: WorkspaceApplicationService,
        library: WorkspaceLibrarySession,
        store: WorkspaceRevisionStore,
        homeRoot: URL,
        contentStore: CentralPackageContentStore?
    ) {
        self.service = service
        self.library = library
        self.store = store
        self.homeRoot = homeRoot
        self.contentStore = contentStore
    }

    var canApply: Bool {
        !isBusy && library.access == .writable && plan?.items.isEmpty == false
    }

    /// Reads current intent and this Mac's real destinations. Nothing is written.
    /// Points one destination at a folder of the person's choosing.
    ///
    /// Nothing moves: this records where a later install would write. What is
    /// already in that folder stays exactly as it is, and an install refuses
    /// rather than replacing it.
    func linkDestination(surface: TargetSurface, scope: ToolingScope,
                         projectID: ArtifactID?, to folder: URL) async {
        guard !isBusy, library.access == .writable,
              let head = library.state?.snapshot.document.revision.id else { return }
        isBusy = true
        errorMessage = nil
        defer { isBusy = false }
        let library = self.store.libraryURL
        do {
            _ = try await service.commitDeviceChange(expectedRevisionID: head) { device in
                try WorkspaceLinkedDestinations.register(
                    selector: .init(surface: surface, scope: scope, logicalProjectID: projectID),
                    path: folder.standardizedFileURL.path,
                    in: &device, managedLibraryRoot: library)
            }
        } catch WorkspaceLinkedDestinationError.pathInUseAsSource {
            errorMessage = "That folder is already where one of your tools is written from. One folder cannot be both."
        } catch WorkspaceLinkedDestinationError.pathInsideManagedLibrary {
            errorMessage = "That folder is inside Agent Tooling's own library. Choose a folder of your own."
        } catch WorkspaceLinkedDestinationError.duplicateSelector {
            errorMessage = "That destination already writes somewhere you chose. Remove it first."
        } catch WorkspaceLinkedDestinationError.duplicatePath {
            errorMessage = "Another destination already writes into that folder."
        } catch {
            errorMessage = "That folder could not be used. Nothing was changed."
        }
        await self.library.refresh()
        await performPrepare()
    }

    /// Goes back to the app's own folder. Nothing at the old path is touched.
    func unlinkDestination(_ id: WorkspaceObjectID) async {
        guard !isBusy, library.access == .writable,
              let head = library.state?.snapshot.document.revision.id else { return }
        isBusy = true
        errorMessage = nil
        defer { isBusy = false }
        do {
            _ = try await service.commitDeviceChange(expectedRevisionID: head) { device in
                WorkspaceLinkedDestinations.unregister(id, in: &device)
            }
        } catch {
            errorMessage = "That could not be changed. Nothing was moved."
        }
        await self.library.refresh()
        await performPrepare()
    }

    func prepare() async {
        guard !isBusy else { return }
        isBusy = true
        errorMessage = nil
        results = []
        defer { isBusy = false }
        await performPrepare()
    }

    /// The read itself, so applying can refresh without fighting its own busy
    /// flag and leaving a stale plan on screen.
    private func performPrepare() async {
        do {
            guard let snapshot = library.state?.snapshot else {
                plan = nil
                return
            }
            // Every place this Mac could hold something: where things are asked
            // for now, and where this app may have put something before. Without
            // the second half, withdrawing an assignment would leave the old copy
            // installed with nothing offering to remove it.
            var selectors = Set(snapshot.document.assignments.map {
                ResolvedAssignmentSelector(destination: $0.destination)
            })
            for observation in snapshot.device.observations where observation.installed {
                selectors.insert(.init(surface: observation.surface, scope: .user, logicalProjectID: nil))
                for root in snapshot.device.projectRoots ?? [] {
                    selectors.insert(.init(surface: observation.surface, scope: .project,
                                           logicalProjectID: root.projectID))
                }
            }
            let ordered = selectors.sorted {
                [$0.surface.rawValue, $0.scope.rawValue, $0.logicalProjectID?.rawValue.uuidString ?? ""]
                    .lexicographicallyPrecedes(
                        [$1.surface.rawValue, $1.scope.rawValue, $1.logicalProjectID?.rawValue.uuidString ?? ""])
            }
            let captured = try await WorkspaceSkillTargetCapture.capture(
                homeURL: homeRoot, deviceID: snapshot.device.deviceID, selectors: ordered,
                projectRoots: snapshot.device.projectRoots ?? [],
                observations: snapshot.device.observations,
                capabilityEvidence: snapshot.device.capabilityEvidence)
            // Measure what is actually at each destination now, so "already
            // there" is an observation rather than an assumption.
            // Only destinations this app can prove it installed may be offered
            // for removal; anything else is somebody else's.
            let proven = Self.provenInstalls(snapshot: snapshot, targets: captured,
                                             store: store)
            let observations = await Self.measure(
                snapshot: snapshot, targets: captured, alsoMeasuring: proven)
            // A native package is only offered where the person's own retained
            // record holds an install command for that exact client and package.
            // Without one there is nothing to run, and offering it anyway would
            // be an install claim with no command behind it.
            plan = try await service.deploymentPlan(
                targets: captured.map(\.target), observations: observations,
                provenInstalls: proven,
                nativeInstallRoutes: Self.reviewedNativeRoutes(snapshot: snapshot))
            let projects = Dictionary(snapshot.document.logicalProjects.map { ($0.id, $0.name) },
                                      uniquingKeysWith: { first, _ in first })
            linkedDestinations = snapshot.device.destinations.map {
                .init(id: $0.id, surface: $0.selector.surface, scope: $0.selector.scope,
                      projectName: $0.selector.logicalProjectID.flatMap { projects[$0] },
                      path: $0.resolvedPath)
            }.sorted { $0.path < $1.path }
        } catch is CancellationError {
            errorMessage = "Checking your apps was cancelled. Nothing was changed."
        } catch {
            plan = nil
            errorMessage = "This Mac's apps could not be checked. Nothing was changed."
        }
    }

    /// Reads each destination folder that exists and records its content, so a
    /// destination that already holds the approved version is reported as such
    /// instead of being installed again. A folder that cannot be read is simply
    /// not observed, which is different from observing it as absent.
    private nonisolated static func measure(
        snapshot: WorkspaceApplicationSnapshot,
        targets: [CapturedSkillAssignmentTarget],
        alsoMeasuring proven: Set<WorkspaceDeploymentInstallKey>
    ) async -> [WorkspaceDeploymentObservation] {
        let artifacts = Dictionary(snapshot.document.artifacts.map { ($0.identity.id, $0) },
                                   uniquingKeysWith: { first, _ in first })
        let byDestination = Dictionary(targets.map { ($0.target.physicalDestinationID, $0) },
                                       uniquingKeysWith: { first, _ in first })
        // Where things are asked for, plus where this app already put them, so
        // a withdrawn item is still measured and can be offered for removal.
        var pairs = Set(snapshot.document.assignments.compactMap { assignment -> WorkspaceDeploymentInstallKey? in
            let selector = ResolvedAssignmentSelector(destination: assignment.destination)
            guard let captured = targets.first(where: { $0.target.selector == selector }) else { return nil }
            return .init(artifactID: assignment.artifactID,
                         physicalDestinationID: captured.target.physicalDestinationID)
        })
        pairs.formUnion(proven)
        var results: [WorkspaceDeploymentObservation] = []
        for pair in pairs.sorted(by: { $0.artifactID.rawValue.uuidString < $1.artifactID.rawValue.uuidString }) {
            guard let captured = byDestination[pair.physicalDestinationID],
                  let artifact = artifacts[pair.artifactID],
                  let name = artifact.declaredName, !name.isEmpty else { continue }
            let folder = captured.plannedDirectory.appending(path: name, directoryHint: .isDirectory)
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: folder.path, isDirectory: &isDirectory),
                  isDirectory.boolValue else {
                results.append(.init(artifactID: pair.artifactID,
                                     physicalDestinationID: pair.physicalDestinationID,
                                     isPresent: false))
                continue
            }
            let digest = try? await PackageTreeCapture().capture(directory: folder).digest
            results.append(.init(artifactID: pair.artifactID,
                                 physicalDestinationID: pair.physicalDestinationID,
                                 isPresent: true, contentDigest: digest))
        }
        return results
    }

    /// Destinations this app's own ledger or receipts show it installed.
    private nonisolated static func provenInstalls(
        snapshot: WorkspaceApplicationSnapshot,
        targets: [CapturedSkillAssignmentTarget],
        store: WorkspaceRevisionStore
    ) -> Set<WorkspaceDeploymentInstallKey> {
        let authority = ManagedInstallAuthority.fromStore(store)
        var keys = Set<WorkspaceDeploymentInstallKey>()
        for artifact in snapshot.document.artifacts {
            guard artifact.identity.parentPackageID == nil,
                  let name = artifact.declaredName, !name.isEmpty else { continue }
            for captured in targets {
                let folder = captured.plannedDirectory.appending(path: name, directoryHint: .isDirectory)
                guard authority.proof(forDestination: folder.path) != nil else { continue }
                keys.insert(.init(artifactID: artifact.identity.id,
                                  physicalDestinationID: captured.target.physicalDestinationID))
            }
        }
        return keys
    }

    /// Routes whose install command this build has recorded, with the client
    /// release it was checked against.
    ///
    /// A route with no recorded command is not offered. Gemini has none, so a
    /// Gemini package is excluded by name rather than attempted with a command
    /// nobody wrote down.
    private nonisolated static func reviewedNativeRoutes(
        snapshot: WorkspaceApplicationSnapshot
    ) -> Set<NativePackageRoute> {
        let routes = snapshot.document.artifacts
            .filter { $0.identity.parentPackageID == nil }
            .flatMap(\.nativeRoutes)
        return Set(routes.filter {
            NativePluginInstallRegister.command(
                for: $0.client, externalPluginID: $0.externalPluginID) != nil
        })
    }

    /// The reviewed command plans for the two routes that are not folder copies.
    ///
    /// Each bridge does its own checking and refuses far more than it accepts —
    /// it re-resolves the requirement against the document, insists the recorded
    /// install command matches the exact command it expects, and requires the
    /// client's own tool to be a runnable file at a path it can name. Anything
    /// that does not pass is simply absent from the result, because a command a
    /// person is asked to approve must be one that can actually run.
    ///
    /// The install command itself is read from `NativePluginInstallRegister`,
    /// which is the one place a client's install command is written down, with
    /// the release it was checked against and where it was read. It is never
    /// constructed from a route: `<client> plugin install <id>` is exactly the
    /// inference the route contract forbids, and a client with no recorded
    /// command yields nothing here rather than a plausible guess.
    nonisolated static func commandPlans(
        plan: WorkspaceDeploymentPlan,
        snapshot: WorkspaceApplicationSnapshot,
        homeRoot: URL
    ) -> (plugins: [WorkspaceNativePluginCommandPlan], connections: [WorkspaceManagedMCPCommandPlan]) {
        var executables: [ClientKind: URL] = [:]
        func executable(_ client: ClientKind) -> URL? {
            if let found = executables[client] { return found }
            guard let found = ClientExecutableLocator.locate(client, homeURL: homeRoot) else { return nil }
            executables[client] = found
            return found
        }

        let targetsByID = Dictionary(plan.resolvedTargets.map { ($0.physicalDestinationID, $0) },
                                     uniquingKeysWith: { first, _ in first })
        var plugins: [WorkspaceNativePluginCommandPlan] = []
        var connections: [WorkspaceManagedMCPCommandPlan] = []
        for item in plan.items {
            guard let requirement = plan.requirements.first(where: {
                      $0.artifactID == item.artifactID
                          && $0.physicalDestinationID == item.physicalDestinationID
                  }),
                  let target = targetsByID[item.physicalDestinationID],
                  let client = target.selector.surface.client,
                  let executableURL = executable(client) else { continue }
            switch item.action {
            case .installNativePackage(let route):
                guard let install = NativePluginInstallRegister.reviewedInstall(
                    for: route.client, externalPluginID: route.externalPluginID) else { continue }
                for capability in snapshot.device.capabilityEvidence
                where capability.surface == target.selector.surface && capability.component == .plugin {
                    guard let built = try? WorkspaceNativePluginCommandPlanning.plan(
                        document: snapshot.document, device: snapshot.device,
                        requirement: requirement, resolvedTargets: plan.resolvedTargets,
                        target: target, capability: capability, reviewedInstall: install,
                        executableURL: executableURL) else { continue }
                    plugins.append(built)
                    break
                }
            case .configureManagedConnection:
                // The name the connection goes by in the client's own config is
                // the one the workspace already declared for it. Inventing a
                // second name would leave two records of one connection.
                guard let name = snapshot.document.artifacts.first(where: {
                    $0.identity.id == item.artifactID
                })?.declaredName, !name.isEmpty else { continue }
                for capability in snapshot.device.capabilityEvidence
                where capability.surface == target.selector.surface && capability.component == .mcpServer {
                    guard let built = try? WorkspaceManagedMCPCommandPlanning.plan(
                        document: snapshot.document, device: snapshot.device,
                        requirement: requirement, resolvedTargets: plan.resolvedTargets,
                        target: target, capability: capability,
                        nativeServerIdentifier: name,
                        executableURL: executableURL) else { continue }
                    connections.append(built)
                    break
                }
            case .installContent, .updateContent, .removeContent:
                continue
            }
        }
        return (plugins, connections)
    }

    /// Folders at redirected destinations that this app's own ledger proves it
    /// installed.
    ///
    /// Without this an apply-once destination that this app filled last time
    /// would refuse to be updated, because a folder being there is exactly what
    /// the no-clobber rule looks for. The ledger is what tells the two apart.
    private nonisolated static func provenLinkedPaths(
        plan: WorkspaceDeploymentPlan,
        snapshot: WorkspaceApplicationSnapshot,
        store: WorkspaceRevisionStore
    ) -> Set<String> {
        let authority = ManagedInstallAuthority.fromStore(store)
        let names = Dictionary(
            snapshot.document.artifacts.compactMap { artifact -> (ArtifactID, String)? in
                guard let name = artifact.declaredName, !name.isEmpty else { return nil }
                return (artifact.identity.id, name)
            }, uniquingKeysWith: { first, _ in first })
        var paths = Set<String>()
        for item in plan.items {
            guard let name = names[item.artifactID],
                  let binding = WorkspaceLinkedDestinations.binding(
                      for: .init(surface: item.surface, scope: item.scope,
                                 logicalProjectID: item.logicalProjectID),
                      in: snapshot.device) else { continue }
            let folder = URL(fileURLWithPath: binding.resolvedPath)
                .appending(path: name, directoryHint: .isDirectory).standardizedFileURL
            guard authority.proof(forDestination: folder.path) != nil else { continue }
            paths.insert(folder.path)
        }
        return paths
    }

    /// Applies the prepared plan through the reviewed operation path.
    func apply() async {
        guard canApply, let plan, let contentStore else { return }
        isBusy = true
        errorMessage = nil
        defer { isBusy = false }
        do {
            guard let snapshot = library.state?.snapshot else { return }
            var content: [ContentDigest: CapturedPackageTree] = [:]
            for artifact in snapshot.document.artifacts {
                guard let digest = artifact.contentDigest, content[digest] == nil,
                      plan.items.contains(where: {
                          if case .removeContent = $0.action { return false }
                          return $0.artifactID == artifact.identity.id
                      }) else { continue }
                content[digest] = try await contentStore.read(digest)
            }
            // Staging lives inside the app's managed library; the executor
            // refuses to copy from anywhere else.
            try store.prepareManagedDirectories()
            let staging = store.libraryURL.appending(path: "staged-deployments")
            try? FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true,
                                                     attributes: [.posixPermissions: 0o700])
            let projectRoots = Dictionary(
                (snapshot.device.projectRoots ?? []).map { ($0.projectID, URL(fileURLWithPath: $0.rootPath)) },
                uniquingKeysWith: { first, _ in first })
            let commandPlans = Self.commandPlans(plan: plan, snapshot: snapshot, homeRoot: homeRoot)
            let staged = try WorkspaceDeploymentOperations.stage(
                plan, artifacts: snapshot.document.artifacts, content: content,
                stagingRoot: staging, homeURL: homeRoot, projectRoots: projectRoots,
                device: snapshot.device,
                provenInstalls: Self.provenLinkedPaths(plan: plan, snapshot: snapshot,
                                                       store: store))
            // Only the folders this device registered, and only those. The
            // executor still applies every other rule inside them.
            let executor = OperationExecutor(
                store: store, homeURL: homeRoot,
                linkedDestinationRoots: snapshot.device.destinations.map {
                    URL(fileURLWithPath: $0.resolvedPath)
                })
            var collected: [Result] = []
            let operations = WorkspaceDeploymentOperations.operations(for: staged)
                + WorkspaceDeploymentOperations.operations(
                    nativePlugins: commandPlans.plugins, managedConnections: commandPlans.connections)
            for operation in operations {
                let receipt = await executor.execute(operation)
                collected.append(.init(
                    title: operation.title,
                    succeeded: receipt.results.filter { $0.status == .succeeded }.count,
                    failed: receipt.results.filter { $0.status == .failed }.count,
                    outputs: receipt.results.filter { $0.status == .failed }.map(\.output)))
            }
            results = collected
            // Re-read, so what is shown next reflects what actually happened.
            await performPrepare()
        } catch WorkspaceDeploymentOperationError.missingProjectRoot {
            errorMessage = "One of these needs its project folder on this Mac. Nothing was changed."
        } catch WorkspaceDeploymentOperationError.destinationOccupied {
            errorMessage = "A folder you pointed a destination at already holds something Agent Tooling did not put there. It was left exactly as it is, and nothing was installed."
        } catch {
            errorMessage = "These tools could not be installed. Your apps were left as they are."
        }
    }
}
