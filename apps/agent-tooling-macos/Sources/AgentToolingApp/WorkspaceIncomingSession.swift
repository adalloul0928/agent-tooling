import AgentToolingCore
import Foundation

/// What other Macs asked for on this one, and what this Mac does about it.
///
/// A sync pass that brings the document forward may leave assignments this Mac
/// has not satisfied: an install made on another Mac as "every Mac", or one
/// that names this Mac. That is the same situation as a found update and is
/// handled by the same rule — `UpdatePolicy` per kind: install automatically,
/// or ask. The install itself is the ordinary one-step path: plan, classify,
/// direct apply (or hold for review), receipts. Arriving intent is never
/// evidence that a file changed.
///
/// A Mac set to take only what names it is never asked about items that do not
/// apply to it; the planner already leaves those out.
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

    init(
        library: WorkspaceLibrarySession, deployment: WorkspaceDeploymentSession,
        device: WorkspaceDeviceSession, service: WorkspaceApplicationService, sync: WorkspaceSyncSession?
    ) {
        self.library = library
        self.deployment = deployment
        self.device = device
        self.service = service
        self.sync = sync
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
        let arrivals = Self.arrivals(in: plan, library: state.library, thisDevice: library.deviceID)
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
            if let message = deployment.errorMessage { errorMessage = message; return }
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

    /// Plan items for assignments that did not originate on this Mac. An
    /// assignment that names only this Mac was made here (or for here, by
    /// name, which is the same decision); a shared one or one naming several
    /// Macs came from the shared document.
    static func arrivals(
        in plan: WorkspaceDeploymentPlan, library: WorkspaceLibraryReadModel, thisDevice: WorkspaceObjectID
    ) -> [Arrival] {
        let rows = Dictionary(library.rows.map { ($0.artifactID, $0) }, uniquingKeysWith: { first, _ in first })
        var byArtifact: [ArtifactID: Set<ClientKind>] = [:]
        for item in plan.items {
            // Only first installs are arrivals. Replacing a copy is an update
            // and removal is its own review; neither is "from your other Macs".
            switch item.action {
            case .installContent, .installNativePackage, .configureManagedConnection: break
            case .updateContent, .removeContent: continue
            }
            guard let row = rows[item.artifactID] else { continue }
            let fromElsewhere = row.requestedAssignments.contains { assignment in
                assignment.destination.surface == item.surface
                    && assignment.destination.scope == item.scope
                    && assignment.destination.deviceIDs != [thisDevice]
            }
            guard fromElsewhere, let client = item.surface.client else { continue }
            byArtifact[item.artifactID, default: []].insert(client)
        }
        return byArtifact.compactMap { id, clients in
            guard let row = rows[id], let kind = Self.kind(of: row.kind) else { return nil }
            return Arrival(
                artifactID: id, displayName: row.displayName, kind: kind,
                clients: clients.sorted { $0.rawValue < $1.rawValue })
        }.sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
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
