import AgentToolingCore
import Foundation
import Observation

/// How a reviewed apply ended (`WorkspaceDeploymentSession.applyReviewed`).
enum ReviewedApplyOutcome: Equatable {
    /// The reviewed steps ran, each to its own end.
    case applied(DeploymentOutcome)
    /// The library moved after the plan was read, so the plan may no longer
    /// say what would happen: nothing ran.
    case stale
    /// Nothing ran, and why.
    case notRun(String)
}

/// Where one reviewed step is while an apply runs it.
enum ReviewedStepProgress: Equatable, Sendable {
    case started
    case succeeded
    case failed(String)
    /// The apply stopped before this step ran.
    case notRun
}

/// What runs a plan's commands, and where each app's own tool is found. Live
/// by default; a test scripts both, so nothing it applies reaches this Mac's
/// own apps.
struct DeploymentCommandServices: Sendable {
    var runner: @Sendable () -> any CommandRunning
    var locate: @Sendable (ClientKind, URL) -> URL?

    static let live = DeploymentCommandServices(
        runner: { ProcessCommandRunner() }, locate: { ClientExecutableLocator.locate($0, homeURL: $1) })
}

/// Prepares read-only plans and applies approved changes through verified operations.
/// Preparation and all apply paths share one FIFO queue. Jobs invoke work directly
/// rather than enqueueing nested jobs. Assignment intent counts as installed only
/// after a step succeeds.
@MainActor @Observable
final class WorkspaceDeploymentSession {
    struct Result: Identifiable {
        let id = UUID()
        let title: String
        /// The apps this operation wrote to. One operation is one app, so an
        /// outcome can be attributed to the app it belongs to.
        var surfaces: [TargetSurface] = []
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
    /// The library revision `plan` was read at: a review built on the plan
    /// installs only while the library is still there.
    private(set) var planRevision: WorkspaceObjectID?
    /// Destinations the last plan proved this app installed. Kept so the
    /// install picker can tell an update of our own copy from somebody else's
    /// files without measuring the disk a second time.
    private(set) var provenInstalls: Set<WorkspaceDeploymentInstallKey> = []
    /// Proven installs whose files no longer match the fingerprint recorded
    /// when they were installed: somebody edited them. Replacing one without
    /// asking would lose that work, so the direct paths leave these alone.
    private(set) var editedInstalls: Set<WorkspaceDeploymentInstallKey> = []
    /// The connections a receipt shows Agent Tooling set up, and has not
    /// taken out since, by app surface, read when the last plan could hold a
    /// step that decides on them: one replacing a registration, or one
    /// taking Agent Tooling's own connection out of an app. It is the proof
    /// that lets the registration under that name be replaced, or removed
    /// (D10, D30). Without it the registration is left alone.
    private(set) var provenConnections: [TargetSurface: Set<String>] = [:]
    private(set) var results: [Result] = []
    private(set) var isBusy = false
    private(set) var errorMessage: String?
    /// What runs the plan's commands and finds each app's tool.
    @ObservationIgnored var commandServices = DeploymentCommandServices.live

    /// The last job asked for, which the next one waits for.
    @ObservationIgnored private var lastJob: Task<Void, Never>?
    /// A preparation asked for that has not begun yet. A second prepare
    /// joins it, since it will read whatever the library holds when it
    /// begins.
    @ObservationIgnored private var waitingPreparation: Task<Void, Never>?
    /// The preparation reading now, with the library revision it began at.
    /// A prepare asked for while it reads joins it while the library is
    /// still at that revision, since a second read would read the same
    /// thing; once the library has moved, the read under way may have read
    /// too early, so the new one waits its turn and reads again.
    @ObservationIgnored private var runningPreparation: (task: Task<Void, Never>, head: WorkspaceObjectID?)?

    // Internal, not private, so this session's extensions in their own
    // files (a what-if plan, the connections an app reports) plan from the
    // same parts.
    let service: WorkspaceApplicationService
    let library: WorkspaceLibrarySession
    let store: WorkspaceRevisionStore
    let homeRoot: URL
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

    /// The prepared plan's steps that would run: every step but the ones a
    /// direct path must leave alone, which never count as waiting (D6). Home,
    /// Apps and the status other Macs read count these.
    var pendingItems: [WorkspaceDeploymentItem] {
        guard let plan else { return [] }
        let held = Set(heldBack(in: plan).map(Self.installKey))
        return plan.items.filter { !held.contains(Self.installKey($0)) }
    }

    /// How many of the prepared plan's steps would run (`pendingItems`).
    var pendingCount: Int { pendingItems.count }

    // MARK: The queue

    /// Runs `job` once every job asked for before it has finished. The job
    /// is the session's own task, so the caller's task being cancelled (a
    /// screen SwiftUI restarts) neither cancels it nor loses its answer.
    private func enqueue<Value: Sendable>(_ job: @escaping @MainActor () async -> Value) -> Task<Value, Never> {
        let previous = lastJob
        let task = Task { @MainActor in
            await previous?.value
            return await job()
        }
        lastJob = Task { _ = await task.value }
        return task
    }

    /// Points one destination at a folder of the person's choosing.
    ///
    /// Nothing moves: this records where a later install would write. What is
    /// already in that folder stays exactly as it is, and an install refuses
    /// rather than replacing it.
    func linkDestination(
        surface: TargetSurface, scope: ToolingScope,
        projectID: ArtifactID?, to folder: URL
    ) async {
        await enqueue { await self.linkNow(surface: surface, scope: scope, projectID: projectID, to: folder) }.value
    }

    private func linkNow(surface: TargetSurface, scope: ToolingScope, projectID: ArtifactID?, to folder: URL) async {
        guard !isBusy, library.access == .writable,
            let head = library.state?.snapshot.document.revision.id
        else { return }
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
        await enqueue { await self.unlinkNow(id) }.value
    }

    private func unlinkNow(_ id: WorkspaceObjectID) async {
        guard !isBusy, library.access == .writable,
            let head = library.state?.snapshot.document.revision.id
        else { return }
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

    /// Reads current intent and this Mac's real destinations, after whatever
    /// the session is doing now. Nothing is written.
    ///
    /// A second call while one is still waiting its turn joins it, and so
    /// does one while a read is under way over the library as it still is.
    /// The read is the session's own task, so a screen whose task is
    /// cancelled and restarted meanwhile (SwiftUI does that to the Apps
    /// screen's task at launch) neither cancels the read nor loses the plan,
    /// nor reads it twice.
    func prepare() async {
        if let waitingPreparation {
            await waitingPreparation.value
            return
        }
        if let running = runningPreparation, running.head == library.state?.snapshot.document.revision.id {
            await running.task.value
            return
        }
        let preparation = enqueue {
            if let begun = self.waitingPreparation {
                self.runningPreparation = (begun, self.library.state?.snapshot.document.revision.id)
            }
            self.waitingPreparation = nil
            await self.prepareNow()
            self.runningPreparation = nil
        }
        waitingPreparation = preparation
        await preparation.value
    }

    private func prepareNow() async {
        isBusy = true
        errorMessage = nil
        results = []
        defer { isBusy = false }
        await performPrepare()
    }

    /// The read itself, so applying can refresh without fighting its own busy
    /// flag and leaving a stale plan on screen.
    ///
    /// Split into small steps so each one is legible: gather the selectors this
    /// Mac could hold something for, capture the ones that resolve to a real
    /// destination, turn the ones that do not into plain-words reasons, measure
    /// what is already there, and plan over all of it. A per-selector problem
    /// (a project with no folder, a client not installed, an unsupported app)
    /// is carried through as a reason rather than aborting the whole read.
    private func performPrepare() async {
        do {
            // A plan is over the library as read. With no read yet, which is
            // what a cold launch landing here looks like, read first rather
            // than planning over nothing and calling that a checked plan.
            if library.state == nil { await library.refresh() }
            guard let snapshot = library.state?.snapshot else {
                plan = nil
                planRevision = nil
                errorMessage = library.errorMessage ?? "The library could not be read. Nothing was changed."
                return
            }
            let captured = try await Self.captureTargets(snapshot: snapshot, homeRoot: homeRoot)
            // A selector that resolved to no destination is not a failure of the
            // whole read: it becomes a named reason the plan can show, so the
            // items that did resolve still install.
            let unavailable = Self.unavailableDestinations(
                snapshot: snapshot, skipped: captured.skipped)
            plan = await buildPlan(
                snapshot: snapshot, captured: captured.targets, unavailable: unavailable)
            planRevision = snapshot.document.revision.id
            linkedDestinations = Self.linkedDestinations(snapshot: snapshot)
        } catch is CancellationError {
            errorMessage = "Checking your apps was cancelled. Nothing was changed."
        } catch let error as WorkspaceSkillTargetCaptureError {
            plan = nil
            planRevision = nil
            errorMessage = Self.message(for: error)
        } catch let error as WorkspaceRevisionStoreError {
            plan = nil
            planRevision = nil
            errorMessage = Self.message(for: error)
        } catch {
            plan = nil
            planRevision = nil
            errorMessage = "This Mac's apps could not be checked. Nothing was changed."
        }
    }

    /// Every place this Mac could hold something — where things are asked for
    /// now, and where this app may have put something before — captured into
    /// real destinations, with the selectors it could not reach reported
    /// alongside. Without the second half, withdrawing an assignment would
    /// leave the old copy installed with nothing offering to remove it.
    nonisolated static func captureTargets(
        snapshot: WorkspaceApplicationSnapshot, homeRoot: URL
    ) async throws -> WorkspaceSkillTargetCaptureResult {
        var selectors = Set(
            snapshot.document.assignments.map {
                ResolvedAssignmentSelector(destination: $0.destination)
            })
        // Only surfaces the skill capture can actually place into are worth a
        // removal selector; an unsupported surface would only ever be skipped.
        for observation in snapshot.device.observations
        where observation.installed
            && TargetSurfaceCapability.skillClient(for: observation.surface) != nil
        {
            selectors.insert(.init(surface: observation.surface, scope: .user, logicalProjectID: nil))
            for root in snapshot.device.projectRoots ?? [] {
                selectors.insert(
                    .init(
                        surface: observation.surface, scope: .project,
                        logicalProjectID: root.projectID))
            }
        }
        let ordered = selectors.sorted {
            [$0.surface.rawValue, $0.scope.rawValue, $0.logicalProjectID?.rawValue.uuidString ?? ""]
                .lexicographicallyPrecedes(
                    [$1.surface.rawValue, $1.scope.rawValue, $1.logicalProjectID?.rawValue.uuidString ?? ""])
        }
        return try await WorkspaceSkillTargetCapture.capture(
            homeURL: homeRoot, deviceID: snapshot.device.deviceID, selectors: ordered,
            projectRoots: snapshot.device.projectRoots ?? [],
            observations: snapshot.device.observations,
            capabilityEvidence: snapshot.device.capabilityEvidence)
    }

    /// Measures what is at each destination now, then plans over the captured
    /// targets and the named destinations this Mac could not reach.
    private func buildPlan(
        snapshot: WorkspaceApplicationSnapshot,
        captured: [CapturedSkillAssignmentTarget],
        unavailable: [ResolvedAssignmentSelector: String]
    ) async -> WorkspaceDeploymentPlan {
        // Only destinations this app can prove it installed may be offered for
        // removal; anything else is somebody else's.
        let (proven, edited) = Self.provenInstalls(snapshot: snapshot, targets: captured, store: store)
        provenInstalls = proven
        editedInstalls = edited
        // Measure what is actually at each destination now, so "already there"
        // is an observation rather than an assumption.
        let observations = await Self.planObservations(snapshot: snapshot, captured: captured, proven: proven)
        // Whether Agent Tooling's own connection may come out of an app is
        // the planner's to say, from the receipts, so they are read first
        // whenever it might (D10).
        let removalProof =
            Self.mayRemoveOwnConnection(snapshot: snapshot, captured: captured, observations: observations)
            ? await Self.provenConnections(in: store) : nil
        // The service reads the held content itself and forwards everything to
        // the planner, so the unavailable-destination reasons this screen built
        // reach the plan without the screen re-reading the content store.
        let plan: WorkspaceDeploymentPlan
        do {
            plan = try await service.deploymentPlan(
                targets: captured.map(\.target),
                observations: observations, provenInstalls: proven,
                nativeInstallRoutes: Self.reviewedNativeRoutes(snapshot: snapshot),
                unavailableDestinations: unavailable, provenConnections: removalProof ?? [:])
        } catch {
            // The snapshot was read a moment ago; a plan over an empty library
            // is a truthful "nothing to do" rather than a fabricated one.
            plan = WorkspaceDeploymentPlanner.plan(
                document: snapshot.document, device: snapshot.device,
                targets: captured.map(\.target), observations: observations,
                provenInstalls: proven,
                nativeInstallRoutes: Self.reviewedNativeRoutes(snapshot: snapshot),
                unavailableDestinations: unavailable, provenConnections: removalProof ?? [:])
        }
        if let removalProof {
            provenConnections = removalProof
        } else {
            provenConnections = await Self.provenConnections(for: plan, store: store)
        }
        return plan
    }

    /// The connections a receipt shows Agent Tooling set up, by app surface,
    /// read only when `plan` holds a step that would replace a registration:
    /// the one step this proof decides once a plan is made (D30). Receipts
    /// that cannot be read prove nothing.
    nonisolated static func provenConnections(
        for plan: WorkspaceDeploymentPlan, store: WorkspaceRevisionStore
    ) async -> [TargetSurface: Set<String>] {
        guard plan.items.contains(where: replacesRegistration) else { return [:] }
        return await provenConnections(in: store)
    }

    /// The connections the receipts `store` keeps show Agent Tooling set up
    /// and has not taken out since, by app surface, read from as many
    /// receipts as the store keeps: the one reading every screen that
    /// decides on a registration shares (S11, a prepared plan, a what-if
    /// one), so none of them proves what another does not. Receipts that
    /// cannot be read prove nothing.
    nonisolated static func provenConnections(in store: WorkspaceRevisionStore) async -> [TargetSurface: Set<String>] {
        let receipts = await Task.detached {
            (try? store.operationReceipts(limit: WorkspaceRevisionStore.maximumReceipts)) ?? []
        }.value
        return WorkspaceDeploymentOperations.provenConnections(in: receipts)
    }

    /// Whether a plan over `snapshot` could take Agent Tooling's own
    /// connection out of an app: an app whose user-scope destination this
    /// Mac's contributions do not name holds it, started the way this Mac's
    /// binding says. Only then do the receipts have to be read before
    /// planning. A yes the planner then turns down costs one read; a no can
    /// only leave a registration where it is.
    nonisolated static func mayRemoveOwnConnection(
        snapshot: WorkspaceApplicationSnapshot, captured: [CapturedSkillAssignmentTarget],
        observations: [WorkspaceDeploymentObservation]
    ) -> Bool {
        guard let own = AgentToolingConnection.ownConnection(in: snapshot.document) else { return false }
        let recorded = AgentToolingConnection.apps(on: snapshot.device.deviceID, in: snapshot.document)
        let surfaces = Dictionary(
            captured.map { ($0.target.physicalDestinationID, $0.target.selector.surface) }, uniquingKeysWith: { first, _ in first })
        return observations.contains { observation in
            guard observation.artifactID == own.identity.id, observation.isPresent, observation.connectionMatches == true,
                let client = surfaces[observation.physicalDestinationID]?.client
            else { return false }
            return !recorded.contains(client)
        }
    }

    /// Whether `item` would change a connection its app already holds under
    /// the connection's name (the planner's `replacesExisting`).
    nonisolated static func replacesRegistration(_ item: WorkspaceDeploymentItem) -> Bool {
        if case .configureManagedConnection(_, replacesExisting: true) = item.action { true } else { false }
    }

    /// Whether `item` replaces a registration Agent Tooling cannot prove it
    /// made: no receipt in `proven` shows it set up the connection named
    /// `declaredName` in that app. Such a registration is the person's own,
    /// or another tool's, and is left alone (D10, D30): nothing removes it
    /// or points it somewhere else.
    nonisolated static func leavesRegistrationAlone(
        _ item: WorkspaceDeploymentItem, declaredName: String?, proven: [TargetSurface: Set<String>]
    ) -> Bool {
        guard replacesRegistration(item) else { return false }
        guard let declaredName, !declaredName.isEmpty else { return true }
        return proven[item.surface]?.contains(declaredName) != true
    }

    /// The steps of `plan` that would replace a registration Agent Tooling
    /// cannot prove it made, by the names `snapshot` declares and the
    /// connections `proven` shows it set up: what a what-if plan leaves
    /// alone, as a prepared one does.
    nonisolated static func unprovenReplacements(
        in plan: WorkspaceDeploymentPlan, snapshot: WorkspaceApplicationSnapshot, proven: [TargetSurface: Set<String>]
    ) -> Set<WorkspaceDeploymentInstallKey> {
        let replacing = plan.items.filter(replacesRegistration)
        guard !replacing.isEmpty else { return [] }
        let names = Dictionary(
            snapshot.document.artifacts.map { ($0.identity.id, $0.declaredName) }, uniquingKeysWith: { first, _ in first })
        return Set(
            replacing.filter { leavesRegistrationAlone($0, declaredName: names[$0.artifactID] ?? nil, proven: proven) }
                .map(installKey))
    }

    /// What is at each destination now, as the planner is given it: the
    /// folders measured on disk, the packages each app reports, and the
    /// connections each app reports. One function, so a plan built anywhere
    /// else (a what-if plan for setup's placement grid) observes exactly what
    /// a prepared one does.
    nonisolated static func planObservations(
        snapshot: WorkspaceApplicationSnapshot, captured: [CapturedSkillAssignmentTarget],
        proven: Set<WorkspaceDeploymentInstallKey>
    ) async -> [WorkspaceDeploymentObservation] {
        await measure(snapshot: snapshot, targets: captured, alsoMeasuring: proven)
            + reportedNativePackages(snapshot: snapshot, targets: captured)
            + reportedManagedConnections(snapshot: snapshot, targets: captured)
    }

    /// Turns each skipped selector into a reason in a person's words, naming
    /// the project or the app so the plan says what to do rather than showing a
    /// code word. A project's name comes from the document's own logical
    /// projects; a surface names itself.
    nonisolated static func unavailableDestinations(
        snapshot: WorkspaceApplicationSnapshot,
        skipped: [SkippedSkillAssignmentSelector]
    ) -> [ResolvedAssignmentSelector: String] {
        let projectNames = Dictionary(
            snapshot.document.logicalProjects.map { ($0.id, $0.name) },
            uniquingKeysWith: { first, _ in first })
        var result: [ResolvedAssignmentSelector: String] = [:]
        for entry in skipped {
            let detail: String
            switch entry.reason {
            case .missingProject(let id):
                let name = projectNames[id] ?? "This project"
                detail = "\(name) has no folder on this Mac yet. Choose one on the Projects screen."
            case .unavailableClient(let surface):
                detail = "\(surface.displayName) is not installed on this Mac."
            case .unsupportedSurface(let surface):
                detail = "Agent Tooling cannot install into \(surface.displayName) yet."
            case .notChecked(let surface):
                detail = notCheckedDetail(surface)
            case .invalidSelectors, .invalidProjectBindings,
                .ambiguousObservation, .invalidRoot, .unreadableDirectory,
                .changedDuringCapture:
                // These are structural and are thrown, not skipped; if one ever
                // arrives here, a neutral sentence is safer than a code word.
                detail = "This destination could not be checked on this Mac."
            }
            result[entry.selector] = detail
        }
        return result
    }

    /// Where this Mac writes something other than the client's default folder.
    private nonisolated static func linkedDestinations(
        snapshot: WorkspaceApplicationSnapshot
    ) -> [LinkedDestination] {
        let projects = Dictionary(
            snapshot.document.logicalProjects.map { ($0.id, $0.name) },
            uniquingKeysWith: { first, _ in first })
        return snapshot.device.destinations.map {
            .init(
                id: $0.id, surface: $0.selector.surface, scope: $0.selector.scope,
                projectName: $0.selector.logicalProjectID.flatMap { projects[$0] },
                path: $0.resolvedPath)
        }.sorted { $0.path < $1.path }
    }

    /// A typed capture error in a person's words, naming the surface or project.
    private nonisolated static func message(for error: WorkspaceSkillTargetCaptureError) -> String {
        switch error {
        case .ambiguousObservation(let surface):
            return "This Mac has more than one record for \(surface.displayName), so its apps could not be checked. Check your apps again."
        case .unsupportedSurface(let surface):
            return "Agent Tooling cannot install into \(surface.displayName) yet."
        case .unavailableClient(let surface):
            return "\(surface.displayName) is not installed on this Mac."
        case .notChecked(let surface):
            // Capture reports this as a skip and never throws it; the arm
            // only keeps the switch exhaustive.
            return notCheckedDetail(surface)
        case .missingProject:
            return "One of these needs its project folder on this Mac. Choose one on the Projects screen."
        case .invalidRoot, .unreadableDirectory:
            return "A destination folder on this Mac could not be read. Nothing was changed."
        case .changedDuringCapture:
            return "This Mac's folders changed while they were being checked. Check your apps again."
        case .invalidSelectors, .invalidProjectBindings:
            return "This Mac's apps could not be checked. Nothing was changed."
        }
    }

    /// Why an assignment to an app this Mac has not checked yet is held back,
    /// naming the app as a person knows it.
    private nonisolated static func notCheckedDetail(_ surface: TargetSurface) -> String {
        "\(surface.client?.rawValue ?? surface.displayName) has not been checked on this Mac yet. Check your apps again."
    }

    /// A revision-store error in plain words rather than a generic banner.
    private nonisolated static func message(for error: WorkspaceRevisionStoreError) -> String {
        switch error {
        case .notInitialized:
            return "The library has not been set up yet, so there is nothing to check."
        default:
            return "The library could not be read on this Mac. Nothing was changed."
        }
    }

    /// Reads each destination folder that exists and records its content, so a
    /// destination that already holds the approved version is reported as such
    /// instead of being installed again. A folder that cannot be read is simply
    /// not observed, which is different from observing it as absent.
    nonisolated static func measure(
        snapshot: WorkspaceApplicationSnapshot,
        targets: [CapturedSkillAssignmentTarget],
        alsoMeasuring proven: Set<WorkspaceDeploymentInstallKey>
    ) async -> [WorkspaceDeploymentObservation] {
        let artifacts = Dictionary(
            snapshot.document.artifacts.map { ($0.identity.id, $0) },
            uniquingKeysWith: { first, _ in first })
        let byDestination = Dictionary(
            targets.map { ($0.target.physicalDestinationID, $0) },
            uniquingKeysWith: { first, _ in first })
        // Where things are asked for, plus where this app already put them, so
        // a withdrawn item is still measured and can be offered for removal.
        var pairs = Set(
            snapshot.document.assignments.compactMap { assignment -> WorkspaceDeploymentInstallKey? in
                let selector = ResolvedAssignmentSelector(destination: assignment.destination)
                guard let captured = targets.first(where: { $0.target.selector == selector }) else { return nil }
                return .init(
                    artifactID: assignment.artifactID,
                    physicalDestinationID: captured.target.physicalDestinationID)
            })
        pairs.formUnion(proven)
        var results: [WorkspaceDeploymentObservation] = []
        for pair in pairs.sorted(by: { $0.artifactID.rawValue.uuidString < $1.artifactID.rawValue.uuidString }) {
            guard let captured = byDestination[pair.physicalDestinationID],
                let artifact = artifacts[pair.artifactID],
                // A client's own package is not a folder under a skill root;
                // the client reports it, in `reportedNativePackages`. Nor is a
                // connection: the app reports it, in
                // `reportedManagedConnections`.
                artifact.identity.kind != .nativePlugin, artifact.identity.kind != .mcpServer,
                let name = artifact.declaredName, !name.isEmpty
            else { continue }
            let folder = captured.plannedDirectory.appending(path: name, directoryHint: .isDirectory)
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: folder.path, isDirectory: &isDirectory),
                isDirectory.boolValue
            else {
                results.append(
                    .init(
                        artifactID: pair.artifactID,
                        physicalDestinationID: pair.physicalDestinationID,
                        isPresent: false))
                continue
            }
            let digest = try? await PackageTreeCapture().capture(directory: folder).digest
            results.append(
                .init(
                    artifactID: pair.artifactID,
                    physicalDestinationID: pair.physicalDestinationID,
                    isPresent: true, contentDigest: digest))
        }
        return results
    }

    /// Uses native package observations rather than checking skill folders.
    /// Scope must match: a project install cannot satisfy a user-wide request.
    /// An unscanned client remains unobserved, not absent.
    nonisolated static func reportedNativePackages(
        snapshot: WorkspaceApplicationSnapshot,
        targets: [CapturedSkillAssignmentTarget]
    ) -> [WorkspaceDeploymentObservation] {
        let artifacts = Dictionary(
            snapshot.document.artifacts.map { ($0.identity.id, $0) },
            uniquingKeysWith: { first, _ in first })
        let reports = Dictionary(
            snapshot.device.observations.map { ($0.surface, $0) },
            uniquingKeysWith: { first, _ in first })
        var results: [WorkspaceDeploymentObservation] = []
        var seen = Set<WorkspaceDeploymentInstallKey>()
        for assignment in snapshot.document.assignments {
            let selector = ResolvedAssignmentSelector(destination: assignment.destination)
            guard let captured = targets.first(where: { $0.target.selector == selector }),
                let artifact = artifacts[assignment.artifactID],
                artifact.identity.kind == .nativePlugin,
                let client = selector.surface.client,
                let route = artifact.nativeRoutes.first(where: { $0.client == client }),
                let report = reports[selector.surface]
            else { continue }
            let key = WorkspaceDeploymentInstallKey(
                artifactID: artifact.identity.id,
                physicalDestinationID: captured.target.physicalDestinationID)
            guard seen.insert(key).inserted else { continue }
            let metadata = report.pluginMetadata[route.externalPluginID]
            let present = metadata.map { Self.reportedScope($0.scope, covers: selector.scope) } ?? false
            results.append(
                .init(
                    artifactID: key.artifactID, physicalDestinationID: key.physicalDestinationID,
                    isPresent: present, isEnabled: metadata?.enabled))
        }
        return results
    }

    /// Whether a client's record of an installed package covers a destination's
    /// scope. Claude Code writes "User", "Project" or "Local"; Codex keeps no
    /// scope of its own and the scan writes "This Mac", which is the account.
    /// A word this build does not know is taken as covering: re-installing what
    /// a client already reports is the wrong direction to be wrong in.
    private nonisolated static func reportedScope(_ scope: String, covers destination: ToolingScope) -> Bool {
        switch scope.lowercased() {
        case "user", "this mac": destination == .user
        case "project", "local": destination == .project
        default: true
        }
    }

    /// Destinations this app's own ledger or receipts show it installed.
    nonisolated static func provenInstalls(
        snapshot: WorkspaceApplicationSnapshot,
        targets: [CapturedSkillAssignmentTarget],
        store: WorkspaceRevisionStore
    ) -> (proven: Set<WorkspaceDeploymentInstallKey>, edited: Set<WorkspaceDeploymentInstallKey>) {
        let authority = ManagedInstallAuthority.fromStore(store)
        var keys = Set<WorkspaceDeploymentInstallKey>()
        var edited = Set<WorkspaceDeploymentInstallKey>()
        for artifact in snapshot.document.artifacts {
            guard artifact.identity.parentPackageID == nil,
                let name = artifact.declaredName, !name.isEmpty
            else { continue }
            for captured in targets {
                let folder = captured.plannedDirectory.appending(path: name, directoryHint: .isDirectory)
                guard let proof = authority.proof(forDestination: folder.path) else { continue }
                let key = WorkspaceDeploymentInstallKey(
                    artifactID: artifact.identity.id, physicalDestinationID: captured.target.physicalDestinationID)
                keys.insert(key)
                // The same comparison the setup check makes: the tree on disk
                // against the fingerprint approved at install.
                if case .modifiedSinceReview = InstalledPackageDriftInspector.drift(for: proof.record).state {
                    edited.insert(key)
                }
            }
        }
        return (keys, edited)
    }

    /// Routes whose install command this build has recorded, with the client
    /// release it was checked against.
    ///
    /// A route with no recorded command is not offered. Gemini has none, so a
    /// Gemini package is excluded by name rather than attempted with a command
    /// nobody wrote down.
    nonisolated static func reviewedNativeRoutes(
        snapshot: WorkspaceApplicationSnapshot
    ) -> Set<NativePackageRoute> {
        let routes = snapshot.document.artifacts
            .filter { $0.identity.parentPackageID == nil }
            .flatMap(\.nativeRoutes)
        return Set(
            routes.filter {
                NativePluginInstallRegister.command(
                    for: $0.client, externalPluginID: $0.externalPluginID) != nil
            })
    }

    /// What `commandPlans` found: the commands it could build, and the steps
    /// it could not build one for, with the reason in a person's words.
    struct CommandPlans {
        var plugins: [WorkspaceNativePluginCommandPlan] = []
        var connections: [WorkspaceManagedMCPCommandPlan] = []
        /// A step the plan lists that no command could be built for. It stays
        /// a step on the sheet, and the sheet says it will not run. Leaving it
        /// out would let "Install 59 changes" mean seven.
        var withoutCommand: [WorkspaceDeploymentInstallKey: String] = [:]
    }

    /// Builds reviewed native-command plans after re-resolving requirements,
    /// matching registered command shapes and locating runnable client tools.
    /// Failed checks populate `withoutCommand`; no command is guessed from a
    /// route. Plugin installs must come from `NativePluginInstallRegister`.
    /// Replacing a connection requires a receipt proving this app created it;
    /// unowned registrations remain untouched, including overwrite-capable routes.
    nonisolated static func commandPlans(
        plan: WorkspaceDeploymentPlan,
        snapshot: WorkspaceApplicationSnapshot,
        homeRoot: URL,
        locate: (ClientKind, URL) -> URL? = { ClientExecutableLocator.locate($0, homeURL: $1) },
        provenConnections: [TargetSurface: Set<String>] = [:]
    ) -> CommandPlans {
        var executables: [ClientKind: URL] = [:]
        func executable(_ client: ClientKind) -> URL? {
            if let found = executables[client] { return found }
            guard let found = locate(client, homeRoot) else { return nil }
            executables[client] = found
            return found
        }

        let targetsByID = Dictionary(
            plan.resolvedTargets.map { ($0.physicalDestinationID, $0) },
            uniquingKeysWith: { first, _ in first })
        var result = CommandPlans()
        for item in plan.items {
            switch item.action {
            case .installContent, .updateContent, .removeContent: continue
            case .installNativePackage, .configureManagedConnection, .removeManagedConnection: break
            }
            let key = WorkspaceDeploymentInstallKey(
                artifactID: item.artifactID, physicalDestinationID: item.physicalDestinationID)
            if case .removeManagedConnection = item.action {
                switch Self.removalCommand(
                    for: item, targets: targetsByID, snapshot: snapshot, executable: executable,
                    provenConnections: provenConnections)
                {
                case .command(let command): result.connections.append(command)
                case .none(let reason): result.withoutCommand[key] = reason
                }
                continue
            }
            guard
                let requirement = plan.requirements.first(where: {
                    $0.artifactID == item.artifactID
                        && $0.physicalDestinationID == item.physicalDestinationID
                }),
                let target = targetsByID[item.physicalDestinationID],
                let client = target.selector.surface.client
            else {
                result.withoutCommand[key] = "This step no longer matches a destination on this Mac."
                continue
            }
            guard let executableURL = executable(client) else {
                result.withoutCommand[key] =
                    "\(client.rawValue)'s command-line tool was not found in any place this app looks, "
                    + "so it cannot be asked to do this."
                continue
            }
            let capabilities = snapshot.device.capabilityEvidence.filter { $0.surface == target.selector.surface }
            var built = false
            var refusal: (any Error)?
            switch item.action {
            case .installNativePackage(let route):
                guard
                    let install = NativePluginInstallRegister.reviewedInstall(
                        for: route.client, externalPluginID: route.externalPluginID)
                else {
                    result.withoutCommand[key] =
                        "No install command is recorded for \(client.rawValue), so nothing will run."
                    continue
                }
                for capability in capabilities where capability.component == .plugin {
                    do {
                        result.plugins.append(
                            try WorkspaceNativePluginCommandPlanning.plan(
                                document: snapshot.document, device: snapshot.device,
                                requirement: requirement, resolvedTargets: plan.resolvedTargets,
                                target: target, capability: capability, reviewedInstall: install,
                                executableURL: executableURL))
                        built = true
                        break
                    } catch {
                        refusal = error
                    }
                }
            case .configureManagedConnection(_, let replacesExisting):
                // The name the connection goes by in the client's own config is
                // the one the workspace already declared for it. Inventing a
                // second name would leave two records of one connection.
                guard
                    let name = snapshot.document.artifacts.first(where: {
                        $0.identity.id == item.artifactID
                    })?.declaredName, !name.isEmpty
                else {
                    result.withoutCommand[key] =
                        "This connection has no name in the library, so \(client.rawValue) cannot be asked to set it up."
                    continue
                }
                if Self.leavesRegistrationAlone(item, declaredName: name, proven: provenConnections) {
                    result.withoutCommand[key] =
                        "\(client.rawValue) already has a registration named \(name) that Agent Tooling did not add, "
                        + "so it is left alone."
                    continue
                }
                let replaced =
                    replacesExisting
                    ? snapshot.device.observations.first { $0.surface == target.selector.surface }.flatMap {
                        WorkspaceManagedMCPCommandPlanning.registeredCommand(named: name, in: $0)
                    } : nil
                for capability in capabilities where capability.component == .mcpServer {
                    do {
                        result.connections.append(
                            try WorkspaceManagedMCPCommandPlanning.plan(
                                document: snapshot.document, device: snapshot.device,
                                requirement: requirement, resolvedTargets: plan.resolvedTargets,
                                target: target, capability: capability,
                                nativeServerIdentifier: name,
                                executableURL: executableURL, replacing: replacesExisting, replacedCommand: replaced))
                        built = true
                        break
                    } catch {
                        refusal = error
                    }
                }
            case .installContent, .updateContent, .removeContent, .removeManagedConnection:
                continue
            }
            if !built { result.withoutCommand[key] = Self.describe(refusal, client: client) }
        }
        return result
    }

    /// What one removal of a connection runs, or why it runs nothing.
    private enum RemovalCommand {
        case command(WorkspaceManagedMCPCommandPlan)
        case none(String)
    }

    /// The command that takes the connection `item` names out of its app:
    /// the app's own tool, removing it by its declared name at the person's
    /// scope. Built only while a receipt in `provenConnections` shows Agent
    /// Tooling set that connection up in that app (D10), as a replacement's
    /// removal is (D30); without the proof the registration is left alone.
    private nonisolated static func removalCommand(
        for item: WorkspaceDeploymentItem, targets: [WorkspaceObjectID: ResolvedAssignmentTarget],
        snapshot: WorkspaceApplicationSnapshot, executable: (ClientKind) -> URL?,
        provenConnections: [TargetSurface: Set<String>]
    ) -> RemovalCommand {
        guard let target = targets[item.physicalDestinationID], let client = target.selector.surface.client else {
            return .none("This step no longer matches a destination on this Mac.")
        }
        guard
            let name = snapshot.document.artifacts.first(where: { $0.identity.id == item.artifactID })?.declaredName,
            !name.isEmpty
        else {
            return .none("This connection has no name in the library, so \(client.rawValue) cannot be asked to remove it.")
        }
        guard provenConnections[target.selector.surface]?.contains(name) == true else {
            return .none(
                "\(client.rawValue) already has a registration named \(name) that Agent Tooling did not add, so it is left alone.")
        }
        guard let executableURL = executable(client) else {
            return .none(
                "\(client.rawValue)'s command-line tool was not found in any place this app looks, so it cannot be asked to do this.")
        }
        do {
            return .command(
                try WorkspaceManagedMCPCommandPlanning.removal(
                    artifactID: item.artifactID, physicalDestinationID: item.physicalDestinationID,
                    surface: target.selector.surface, scope: target.selector.scope, nativeServerIdentifier: name,
                    executableURL: executableURL))
        } catch {
            return .none(describe(error, client: client))
        }
    }

    /// Why no command could be built, in a person's words. The bridges' own
    /// reasons are about records lining up; a person needs to know what to do.
    private nonisolated static func describe(_ refusal: (any Error)?, client: ClientKind) -> String {
        guard let refusal else {
            return "This Mac has no record of what \(client.rawValue) can be asked to carry. Check your apps again."
        }
        if let refusal = refusal as? WorkspaceNativePluginCommandPlanningError {
            switch refusal {
            case .blockedByManagedPolicy, .unresolvedManagedPolicy:
                return "A managed policy on this Mac blocks this plugin in \(client.rawValue)."
            case .unsupportedScope, .unsupportedSurface, .unsupportedEnablement:
                return "\(client.rawValue) cannot be asked to do this here."
            default:
                break
            }
        }
        return "\(client.rawValue) could not be asked to do this: its record on this Mac does not line up with the library's."
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
                    for: .init(
                        surface: item.surface, scope: item.scope,
                        logicalProjectID: item.logicalProjectID),
                    in: snapshot.device)
            else { continue }
            let folder = URL(fileURLWithPath: binding.resolvedPath)
                .appending(path: name, directoryHint: .isDirectory).standardizedFileURL
            guard authority.proof(forDestination: folder.path) != nil else { continue }
            paths.insert(folder.path)
        }
        return paths
    }

    /// The prepared plan narrowed to some items: what installing just those
    /// would do on this Mac. Exclusions that name one of the items are kept, so
    /// "cannot be carried out" still shows for the thing somebody just chose;
    /// removals and other items' work are left out, because they are not what
    /// the button said. A caller whose button did say it names the items
    /// whose removals it takes in `includingRemovalsOf`: Let your apps ask
    /// does, for Agent Tooling's own connection (D10).
    func plan(
        for artifactIDs: Set<ArtifactID>, includingRemovals: Bool = false,
        excluding heldBack: Set<WorkspaceDeploymentInstallKey> = [],
        onlyRemovalKeys: Set<WorkspaceDeploymentInstallKey>? = nil,
        includingRemovalsOf removable: Set<ArtifactID> = []
    ) -> WorkspaceDeploymentPlan? {
        guard let plan else { return nil }
        return WorkspaceDeploymentPlan(
            items: plan.items.filter { item in
                if item.action.isRemoval, !removable.contains(item.artifactID) {
                    if !includingRemovals { return false }
                    // Scoping by artifact alone sweeps up every removal the
                    // planner offers for that artifact, including one pending at
                    // a destination this caller never touched. When a caller
                    // knows the exact places it wrote, it narrows removals to
                    // those keys so an unrelated pending removal is left alone.
                    if let onlyRemovalKeys, !onlyRemovalKeys.contains(Self.installKey(item)) { return false }
                }
                if heldBack.contains(Self.installKey(item)) { return false }
                return artifactIDs.contains(item.artifactID)
            },
            exclusions: plan.exclusions.filter { $0.artifactID.map(artifactIDs.contains) ?? false },
            requirements: plan.requirements, resolvedTargets: plan.resolvedTargets)
    }

    /// Whether installing just these items can run from the button that asked
    /// for it, and if not, why a person should look first.
    func risk(for artifactIDs: Set<ArtifactID>, requestedByAgent: Bool = false) -> OperationPlanRiskClassifier.Verdict? {
        guard let scoped = plan(for: artifactIDs) else { return nil }
        return OperationPlanRiskClassifier.classify(
            scoped,
            context: .init(provenInstalls: provenInstalls, editedInstalls: editedInstalls, requestedByAgent: requestedByAgent))
    }

    /// Applies only the items for these artifacts, through the same staged,
    /// receipted path `apply()` uses. The caller has already decided, from
    /// `risk(for:)`, that nobody needs to look first. The items are read from
    /// the plan as it stands when the apply's turn comes.
    func apply(
        only artifactIDs: Set<ArtifactID>, includingRemovals: Bool = false,
        excluding heldBack: Set<WorkspaceDeploymentInstallKey> = [],
        onlyRemovalKeys: Set<WorkspaceDeploymentInstallKey>? = nil
    ) async {
        await enqueue {
            guard
                let scoped = self.plan(
                    for: artifactIDs, includingRemovals: includingRemovals,
                    excluding: heldBack, onlyRemovalKeys: onlyRemovalKeys),
                !scoped.items.isEmpty
            else { return }
            await self.applyNow(scoped)
        }.value
    }

    /// The steps a direct path must leave alone: copies this app cannot prove
    /// it installed, copies somebody edited since, and registrations this app
    /// cannot prove it made. One rule, so the install, update and arrival
    /// paths and every review cannot disagree about it.
    func heldBack(in plan: WorkspaceDeploymentPlan) -> [WorkspaceDeploymentItem] {
        plan.items.filter { cannotOverwrite($0) || editedSinceInstall($0) || cannotReplace($0) }
    }

    /// Whether this step would replace a registration its app holds under the
    /// connection's name that Agent Tooling cannot prove it made: no receipt
    /// shows it set that connection up in that app (`provenConnections`).
    /// The registration is left exactly as it is (D10, D30); no command is
    /// built for the step either (`commandPlans`).
    func cannotReplace(_ item: WorkspaceDeploymentItem) -> Bool {
        guard Self.replacesRegistration(item) else { return false }
        let name = library.state?.snapshot.document.artifacts.first { $0.identity.id == item.artifactID }?.declaredName
        return Self.leavesRegistrationAlone(item, declaredName: name, proven: provenConnections)
    }

    /// Applies only these artifacts' steps that a direct path may run, and
    /// returns the steps it left alone. The one call every direct path makes.
    @discardableResult
    func applyDirect(_ artifactIDs: Set<ArtifactID>) async -> [WorkspaceDeploymentItem] {
        await enqueue {
            guard let scoped = self.plan(for: artifactIDs) else { return [] }
            let leftAlone = self.heldBack(in: scoped)
            if let running = self.plan(for: artifactIDs, excluding: Set(leftAlone.map(Self.installKey))),
                !running.items.isEmpty
            {
                await self.applyNow(running)
            }
            return leftAlone
        }.value
    }

    /// Replaces the copies of these artifacts this app proved it installed
    /// and nobody edited since. The path an update takes after the library has
    /// new content. Returns the steps it left alone, which wait on the Apps
    /// screen's review.
    @discardableResult
    func replaceProvenCopies(of artifactIDs: Set<ArtifactID>) async -> [WorkspaceDeploymentItem] {
        await applyDirect(artifactIDs)
    }

    /// Whether this step would replace a copy of ours that was edited since.
    func editedSinceInstall(_ item: WorkspaceDeploymentItem) -> Bool {
        guard case .updateContent = item.action else { return false }
        return editedInstalls.contains(Self.installKey(item))
    }

    /// Whether the executor will refuse this step no matter who approves it:
    /// it would replace files at a place Agent Tooling cannot prove it
    /// installed (somebody's hand-made skill folder, for example). The engine
    /// checks the same thing again right before writing; this lets a caller
    /// say so up front and leave the step out instead of watching it fail.
    func cannotOverwrite(_ item: WorkspaceDeploymentItem) -> Bool {
        guard case .updateContent = item.action else { return false }
        return !provenInstalls.contains(Self.installKey(item))
    }

    nonisolated static func installKey(_ item: WorkspaceDeploymentItem) -> WorkspaceDeploymentInstallKey {
        .init(artifactID: item.artifactID, physicalDestinationID: item.physicalDestinationID)
    }

    /// The order a plan's steps run in, and the order a review lists them in:
    /// each app in the app order; in an app, what is copied into it first,
    /// then what it installs itself, then its connections, then the
    /// connections taken out of it; then by scope, by name and by
    /// destination, so no two steps tie. The operations are built
    /// in this order, so a review drawn in it sees its steps run in it.
    nonisolated static func runsBefore(_ left: WorkspaceDeploymentItem, _ right: WorkspaceDeploymentItem) -> Bool {
        runPlace(left) < runPlace(right)
    }

    private nonisolated static func runPlace(_ item: WorkspaceDeploymentItem) -> (Int, Int, Int, String, String) {
        let app = item.surface.client.flatMap { ClientKind.allCases.firstIndex(of: $0) } ?? ClientKind.allCases.count
        let part =
            switch item.action {
            case .installContent, .updateContent, .removeContent: 0
            case .installNativePackage: 1
            case .configureManagedConnection: 2
            case .removeManagedConnection: 3
            }
        let scope = ToolingScope.allCases.firstIndex(of: item.scope) ?? ToolingScope.allCases.count
        return (app, part, scope, item.displayName, item.physicalDestinationID.rawValue.uuidString)
    }

    /// Applies only the reviewed plan after queued work finishes and the library
    /// revision still matches. Ownership and command checks use that revision;
    /// `onStep` reports execution order. Cancellation finishes and receipts the current
    /// step, then marks later steps not run. The caller rechecks affected clients
    /// before preparing another plan.
    func applyReviewed(
        _ plan: WorkspaceDeploymentPlan, basedOn revision: WorkspaceObjectID,
        onStep: (@MainActor (WorkspaceDeploymentInstallKey, ReviewedStepProgress) -> Void)? = nil
    ) async -> ReviewedApplyOutcome {
        let job = enqueue { await self.applyReviewedNow(plan, basedOn: revision, onStep: onStep) }
        return await withTaskCancellationHandler {
            await job.value
        } onCancel: {
            job.cancel()
        }
    }

    private func applyReviewedNow(
        _ plan: WorkspaceDeploymentPlan, basedOn revision: WorkspaceObjectID,
        onStep: (@MainActor (WorkspaceDeploymentInstallKey, ReviewedStepProgress) -> Void)?
    ) async -> ReviewedApplyOutcome {
        guard !Task.isCancelled else { return .notRun(Self.stoppedBeforeStarting) }
        guard library.access == .writable, let contentStore else {
            return .notRun("This library cannot be changed on this Mac, so nothing was installed.")
        }
        // The library as the store holds it now, not as a screen last read it:
        // a write made anywhere since the review moves this. A library that
        // cannot be read at all did not move: that is said as it is.
        guard let snapshot = try? store.snapshot() else { return .notRun("The library could not be read. Nothing was changed.") }
        guard snapshot.document.revision.id == revision else { return .stale }
        guard !plan.items.isEmpty else { return .notRun("There is nothing in this plan to install.") }
        isBusy = true
        errorMessage = nil
        defer { isBusy = false }
        do {
            let ran = try await run(plan, snapshot: snapshot, contentStore: contentStore, onStep: onStep)
            results = ran.results
            let steps = plan.items.compactMap { item -> (client: ClientKind, end: ReviewedStepProgress)? in
                item.surface.client.map { ($0, ran.ends[Self.installKey(item)] ?? .notRun) }
            }
            return .applied(DeploymentOutcome.from(steps: steps, finishedAt: .now))
        } catch {
            let message = Self.applyFailure(error)
            errorMessage = message
            return .notRun(message)
        }
    }

    /// Every failure caught here is raised before anything is written, so each
    /// one says nothing was changed: a plan can remove as well as install, and
    /// "nothing was installed" would answer for only half of it.
    private func applyNow(_ plan: WorkspaceDeploymentPlan) async {
        guard canApply, let contentStore else { return }
        isBusy = true
        errorMessage = nil
        defer { isBusy = false }
        guard let snapshot = library.state?.snapshot else { return }
        do {
            results = try await run(plan, snapshot: snapshot, contentStore: contentStore, onStep: nil).results
            // Re-read, so what is shown next reflects what actually happened.
            await performPrepare()
        } catch {
            errorMessage = Self.applyFailure(error)
        }
    }

    /// What one run did: each operation's result, and how each reviewed step
    /// ended.
    private struct Ran {
        var results: [Result]
        var ends: [WorkspaceDeploymentInstallKey: ReviewedStepProgress]
    }

    /// Stages what `plan` copies, builds every command it runs from
    /// `snapshot`, and runs the operations in the order a review lists them,
    /// telling `onStep` as each reviewed step starts and ends. Stopping the
    /// calling task stops it between steps.
    private func run(
        _ plan: WorkspaceDeploymentPlan, snapshot: WorkspaceApplicationSnapshot, contentStore: CentralPackageContentStore,
        onStep: (@MainActor (WorkspaceDeploymentInstallKey, ReviewedStepProgress) -> Void)?
    ) async throws -> Ran {
        var content: [ContentDigest: CapturedPackageTree] = [:]
        for artifact in snapshot.document.artifacts {
            guard let digest = artifact.contentDigest, content[digest] == nil,
                plan.items.contains(where: { !$0.action.isRemoval && $0.artifactID == artifact.identity.id })
            else { continue }
            content[digest] = try await contentStore.read(digest)
        }
        // Staging lives inside the app's managed library; the executor
        // refuses to copy from anywhere else.
        try store.prepareManagedDirectories()
        let staging = store.libraryURL.appending(path: "staged-deployments")
        try? FileManager.default.createDirectory(
            at: staging, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        let projectRoots = Dictionary(
            (snapshot.device.projectRoots ?? []).map { ($0.projectID, URL(fileURLWithPath: $0.rootPath)) },
            uniquingKeysWith: { first, _ in first })
        // The proof the review was read with, so a replacement runs exactly
        // the two commands it showed.
        let commandPlans = Self.commandPlans(
            plan: plan, snapshot: snapshot, homeRoot: homeRoot, locate: commandServices.locate,
            provenConnections: provenConnections)
        let staged = try WorkspaceDeploymentOperations.stage(
            plan, artifacts: snapshot.document.artifacts, content: content,
            stagingRoot: staging, homeURL: homeRoot, projectRoots: projectRoots,
            device: snapshot.device,
            provenInstalls: Self.provenLinkedPaths(
                plan: plan, snapshot: snapshot,
                store: store))
        // Only the folders this device registered, and only those. The
        // executor still applies every other rule inside them.
        let executor = OperationExecutor(
            store: store, runner: commandServices.runner(), homeURL: homeRoot,
            linkedDestinationRoots: snapshot.device.destinations.map {
                URL(fileURLWithPath: $0.resolvedPath)
            })
        let order = plan.items.sorted(by: Self.runsBefore).map(Self.installKey)
        let operations = WorkspaceDeploymentOperations.run(
            staged: staged, nativePlugins: commandPlans.plugins, managedConnections: commandPlans.connections, order: order)
        let progress = ReviewedStepTracker(installKeys: operations.installKeys, onStep: onStep)
        var collected: [Result] = []
        for operation in operations.operations {
            // Stopped: the operations not begun do not begin.
            guard !Task.isCancelled else { break }
            let receipt = await executor.execute(operation) { event in await progress.take(event) }
            collected.append(
                .init(
                    title: operation.title,
                    surfaces: operation.targetSurfaces,
                    succeeded: receipt.results.filter { $0.status == .succeeded }.count,
                    failed: receipt.results.filter { $0.status == .failed }.count,
                    outputs: receipt.results.filter { $0.status == .failed }.map(\.output)))
        }
        progress.endTheRest(in: order)
        return Ran(results: collected, ends: progress.ends)
    }

    /// What a reviewed apply says when it was stopped before it began.
    private nonisolated static let stoppedBeforeStarting = "The install was stopped before it began. Nothing was changed."

    /// A failure raised before anything was written, in a person's words.
    private nonisolated static func applyFailure(_ error: any Error) -> String {
        switch error {
        case WorkspaceDeploymentOperationError.missingProjectRoot:
            "One of these needs its project folder on this Mac. Nothing was changed."
        case WorkspaceDeploymentOperationError.destinationOccupied:
            "A folder you pointed a destination at already holds something Agent Tooling did not put there. It was left exactly as it is, and nothing was changed."
        case WorkspaceDeploymentOperationError.missingContent:
            "The library has no verified copy of one of these tools, so nothing was changed."
        case WorkspaceDeploymentOperationError.stagingFailed, WorkspaceDeploymentOperationError.invalidStagingRoot:
            "The approved copy could not be prepared inside Agent Tooling's own library, so nothing was changed."
        case WorkspaceDeploymentOperationError.unsupportedSurface, WorkspaceDeploymentOperationError.unsupportedScope:
            "One of these asks for a place Agent Tooling cannot install into yet, so nothing was changed."
        default:
            // Anything else is named, because a sentence with no cause sends a
            // person hunting through logs for what this screen already knew.
            "These changes could not be made. Your apps were left as they are. (\(error.localizedDescription))"
        }
    }
}

/// Follows a run's operation steps and tells a review how each of its steps
/// is doing: a reviewed step starts with its first operation step and ends
/// with its last. A connection that replaces a registration is two operation
/// steps for one reviewed step, and ends failed if either failed.
@MainActor
private final class ReviewedStepTracker {
    private let installKeys: [UUID: WorkspaceDeploymentInstallKey]
    private let onStep: (@MainActor (WorkspaceDeploymentInstallKey, ReviewedStepProgress) -> Void)?
    private var remaining: [WorkspaceDeploymentInstallKey: Int] = [:]
    private var started: Set<WorkspaceDeploymentInstallKey> = []
    private var failure: [WorkspaceDeploymentInstallKey: String] = [:]
    private var incomplete: Set<WorkspaceDeploymentInstallKey> = []
    /// How each reviewed step ended.
    private(set) var ends: [WorkspaceDeploymentInstallKey: ReviewedStepProgress] = [:]

    init(
        installKeys: [UUID: WorkspaceDeploymentInstallKey],
        onStep: (@MainActor (WorkspaceDeploymentInstallKey, ReviewedStepProgress) -> Void)?
    ) {
        self.installKeys = installKeys
        self.onStep = onStep
        for key in installKeys.values { remaining[key, default: 0] += 1 }
    }

    func take(_ event: OperationStepEvent) {
        switch event {
        case .started(let id):
            guard let key = installKeys[id], started.insert(key).inserted else { return }
            onStep?(key, .started)
        case .finished(let result):
            guard let key = installKeys[result.stepID], ends[key] == nil else { return }
            switch result.status {
            case .succeeded: break
            case .failed: failure[key] = failure[key] ?? result.output
            case .skipped, .pending, .manual: incomplete.insert(key)
            }
            remaining[key, default: 1] -= 1
            guard remaining[key, default: 0] <= 0 else { return }
            let end: ReviewedStepProgress =
                if let failed = failure[key] {
                    .failed(failed)
                } else if incomplete.contains(key) || !started.contains(key) {
                    .notRun
                } else {
                    .succeeded
                }
            ends[key] = end
            onStep?(key, end)
        }
    }

    /// Every reviewed step in `order` that has not ended ends now, not run:
    /// the run stopped before it, or there was no command to run it with.
    func endTheRest(in order: [WorkspaceDeploymentInstallKey]) {
        for key in order where ends[key] == nil {
            ends[key] = .notRun
            onStep?(key, .notRun)
        }
    }
}
