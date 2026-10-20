import AgentToolingCore
import Foundation

/// Applies incoming assignments using this Mac's per-kind update policy.
/// Automatic installs use the normal planning and risk-review pipeline; other
/// assignments wait for review. Received intent does not prove installation,
/// and the planner excludes assignments outside this device's scope.
@MainActor @Observable
final class WorkspaceIncomingSession {
    struct Arrival: Identifiable, Equatable {
        let artifactID: ArtifactID
        let displayName: String
        let kind: ToolingItemKind
        /// The apps on this Mac the plan would put it in.
        let clients: [ClientKind]
        var id: ArtifactID { artifactID }
    }

    /// Items other Macs asked for here that this Mac has not installed yet.
    private(set) var waiting: [Arrival] = []
    /// What the last pass installed on its own, under the automatic policy.
    private(set) var installedAutomatically: [String] = []
    /// Items whose install was held for a look (the classifier said review).
    private(set) var heldForReview: [Arrival] = []
    private(set) var isWorking = false
    private(set) var errorMessage: String?
    private(set) var lastChecked: Date?

    private let library: WorkspaceLibrarySession
    private let deployment: WorkspaceDeploymentSession
    private let device: WorkspaceDeviceSession
    private let service: WorkspaceApplicationService
    private let sync: WorkspaceSyncSession?
    /// Assignments this Mac's own setup made, as they stand at each look.
    /// They are never arrivals, even those that name every Mac: what a person
    /// placed here did not come from another Mac. Asked at every review,
    /// because setup keeps adding them while the workspace is open.
    private let excludedContributionIDs: @MainActor () -> Set<WorkspaceObjectID>

    init(
        library: WorkspaceLibrarySession, deployment: WorkspaceDeploymentSession,
        device: WorkspaceDeviceSession, service: WorkspaceApplicationService, sync: WorkspaceSyncSession?,
        excludedContributionIDs: @escaping @MainActor () -> Set<WorkspaceObjectID> = { [] }
    ) {
        self.library = library
        self.deployment = deployment
        self.device = device
        self.service = service
        self.sync = sync
        self.excludedContributionIDs = excludedContributionIDs
    }

    var hasWork: Bool { !waiting.isEmpty || !heldForReview.isEmpty }

    /// Looks at what the plan would do for assignments that did not come from
    /// this Mac, and installs by policy. Called after a sync pass that brought
    /// anything in, and from Home.
    func review(installingAutomatically: Bool = true) async {
        guard !isWorking else { return }
        isWorking = true
        errorMessage = nil
        installedAutomatically = []
        defer { isWorking = false }

        await library.refresh()
        await deployment.prepare()
        guard let plan = deployment.plan, let state = library.state else {
            errorMessage = deployment.errorMessage
            return
        }
        let arrivals = Self.arrivals(
            in: plan, library: state.library, thisDevice: library.deviceID, excluding: excludedContributionIDs())
        lastChecked = .now
        guard installingAutomatically else {
            waiting = arrivals
            heldForReview = []
            return
        }

        let policy = device.updatePolicy
        var remaining: [Arrival] = []
        var held: [Arrival] = []
        for arrival in arrivals {
            guard policy.policy(for: arrival.kind) == .automatic else {
                remaining.append(arrival)
                continue
            }
            // The install everything else uses, with no picker: the assignment
            // is already saved; only the plan and the executor run.
            switch deployment.risk(for: [arrival.artifactID]) ?? .direct {
            case .direct:
                await deployment.applyDirect([arrival.artifactID])
                if let message = deployment.errorMessage {
                    // Every failure is kept, not just the last one.
                    errorMessage = [errorMessage, message].compactMap { $0 }.joined(separator: " ")
                    remaining.append(arrival)
                } else {
                    installedAutomatically.append(arrival.displayName)
                }
            case .needsReview:
                held.append(arrival)
            }
        }
        waiting = remaining
        heldForReview = held
    }

    /// Installs one waiting item now: the press that "ask me first" waits for.
    func install(_ artifactID: ArtifactID) async {
        guard !isWorking, waiting.contains(where: { $0.artifactID == artifactID }) else { return }
        isWorking = true
        errorMessage = nil
        defer { isWorking = false }
        await deployment.prepare()
        switch deployment.risk(for: [artifactID]) ?? .direct {
        case .direct:
            await deployment.applyDirect([artifactID])
            if let message = deployment.errorMessage {
                errorMessage = message
                return
            }
            waiting.removeAll { $0.artifactID == artifactID }
        case .needsReview:
            if let arrival = waiting.first(where: { $0.artifactID == artifactID }) {
                waiting.removeAll { $0.artifactID == artifactID }
                heldForReview.append(arrival)
            }
        }
    }

    func installAll() async {
        for arrival in waiting { await install(arrival.artifactID) }
    }

    /// Finds plan items from shared assignments applicable to this Mac. Assignments
    /// only for this Mac and contributions in `excluding` are local intent. Those
    /// only for other Macs are irrelevant. Arrival apps retain the standard order.
    static func arrivals(
        in plan: WorkspaceDeploymentPlan, library: WorkspaceLibraryReadModel, thisDevice: WorkspaceObjectID,
        excluding: Set<WorkspaceObjectID> = []
    ) -> [Arrival] {
        let rows = Dictionary(library.rows.map { ($0.artifactID, $0) }, uniquingKeysWith: { first, _ in first })
        var byArtifact: [ArtifactID: Set<ClientKind>] = [:]
        for item in plan.items {
            // Only first installs are arrivals. Replacing a copy is an update
            // and removal is its own review; neither is "from your other Macs".
            switch item.action {
            case .installContent, .installNativePackage, .configureManagedConnection: break
            case .updateContent, .removeContent, .removeManagedConnection: continue
            }
            guard let row = rows[item.artifactID] else { continue }
            let fromElsewhere = row.requestedAssignments.contains { assignment in
                !excluding.contains(assignment.id)
                    && assignment.destination.surface == item.surface
                    && assignment.destination.scope == item.scope
                    && Self.isShared(assignment.destination.deviceIDs, with: thisDevice)
            }
            guard fromElsewhere, let client = item.surface.client else { continue }
            byArtifact[item.artifactID, default: []].insert(client)
        }
        return byArtifact.compactMap { id, clients in
            guard let row = rows[id], let kind = Self.kind(of: row.kind) else { return nil }
            return Arrival(
                artifactID: id, displayName: row.displayName, kind: kind,
                clients: ClientKind.allCases.filter(clients.contains))
        }.sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
    }

    /// Whether an assignment to `devices` reaches this Mac from the shared
    /// document: every Mac (nil), or several naming this one.
    static func isShared(_ devices: [WorkspaceObjectID]?, with thisDevice: WorkspaceObjectID) -> Bool {
        guard let devices else { return true }
        return devices.contains(thisDevice) && devices != [thisDevice]
    }

    private static func kind(of kind: ArtifactKind) -> ToolingItemKind? {
        switch kind {
        case .mcpServer: .mcpServer
        case .nativePlugin, .package: .plugin
        case .skill: .skill
        case .preset, .logicalProject: nil
        }
    }
}
