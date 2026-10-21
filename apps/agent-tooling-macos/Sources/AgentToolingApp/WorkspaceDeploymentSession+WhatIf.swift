import AgentToolingCore
import Foundation

/// What saving some intent would do on this Mac, before it is saved: the
/// plan a prepared plan would be once those contributions were in the
/// library, and which of its steps a direct path would leave alone. Setup's
/// placement grid draws every cell from one, so the review after it cannot
/// say anything the grid did not.
struct PlacementPreview: Sendable {
    let plan: WorkspaceDeploymentPlan
    /// Steps that would replace a copy, or a connection's registration,
    /// Agent Tooling cannot prove it put there, which a direct path leaves
    /// alone.
    let unproven: Set<WorkspaceDeploymentInstallKey>
    /// Steps that would replace a copy of Agent Tooling's that was edited
    /// since it was installed, which a direct path leaves alone too.
    let edited: Set<WorkspaceDeploymentInstallKey>

    /// From `plan`, the installs Agent Tooling proved it made, and the steps
    /// that would replace a registration it cannot prove it made
    /// (`unprovenReplacements`): the same rule
    /// `WorkspaceDeploymentSession.heldBack(in:)` applies to a prepared plan.
    init(
        plan: WorkspaceDeploymentPlan, proven: Set<WorkspaceDeploymentInstallKey>,
        edited: Set<WorkspaceDeploymentInstallKey>, unprovenReplacements: Set<WorkspaceDeploymentInstallKey> = []
    ) {
        self.plan = plan
        let updates = plan.items.compactMap { item -> WorkspaceDeploymentInstallKey? in
            guard case .updateContent = item.action else { return nil }
            return WorkspaceDeploymentInstallKey(artifactID: item.artifactID, physicalDestinationID: item.physicalDestinationID)
        }
        unproven = Set(updates.filter { !proven.contains($0) }).union(unprovenReplacements)
        self.edited = Set(updates.filter { proven.contains($0) && edited.contains($0) })
    }
}

extension WorkspaceDeploymentSession {
    /// Previews additions using the same destinations, observations, and ownership
    /// proofs as normal planning. Writes nothing and leaves session state untouched.
    /// Returns nil if app checks are unavailable or the batch rejects the additions.
    func previewPlan(assuming additions: [AssignmentContribution]) async -> PlacementPreview? {
        guard let current = try? store.snapshot() else { return nil }
        var document = current.document
        document.assignments += additions
        let candidate = WorkspaceApplicationSnapshot(document: document, device: current.device)
        do {
            let captured = try await Self.captureTargets(snapshot: candidate, homeRoot: homeRoot)
            let unavailable = Self.unavailableDestinations(snapshot: candidate, skipped: captured.skipped)
            let (proven, edited) = Self.provenInstalls(snapshot: candidate, targets: captured.targets, store: store)
            let observations = await Self.planObservations(snapshot: candidate, captured: captured.targets, proven: proven)
            let plan = try await service.deploymentPlan(
                targets: captured.targets.map(\.target), observations: observations, provenInstalls: proven,
                nativeInstallRoutes: Self.reviewedNativeRoutes(snapshot: candidate), unavailableDestinations: unavailable,
                assuming: additions)
            let connections = await Self.provenConnections(for: plan, store: store)
            return PlacementPreview(
                plan: plan, proven: proven, edited: edited,
                unprovenReplacements: Self.unprovenReplacements(in: plan, snapshot: candidate, proven: connections))
        } catch {
            return nil
        }
    }
}
