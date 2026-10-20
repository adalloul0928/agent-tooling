import AgentToolingCore
import Foundation

/// The connections each app on this Mac reports, as the planner is given
/// them, so a connection an app already has is not planned again.
extension WorkspaceDeploymentSession {
    /// Observes user-scoped registrations in checked clients. Plugin and project
    /// registrations cannot satisfy them; a different command is a replacement.
    /// Unscanned clients remain unobserved. Agent Tooling's own connection is also
    /// observed without an assignment so owned registrations can be removed safely.
    nonisolated static func reportedManagedConnections(
        snapshot: WorkspaceApplicationSnapshot, targets: [CapturedSkillAssignmentTarget]
    ) -> [WorkspaceDeploymentObservation] {
        let artifacts = Dictionary(
            snapshot.document.artifacts.map { ($0.identity.id, $0) }, uniquingKeysWith: { first, _ in first })
        let reports = Dictionary(
            snapshot.device.observations.map { ($0.surface, $0) }, uniquingKeysWith: { first, _ in first })
        let bindings = Dictionary(
            (snapshot.device.mcpBindings ?? []).map { ($0.artifactID, $0) }, uniquingKeysWith: { first, _ in first })
        // Each app's files are read once, however many connections it is
        // asked for.
        var registrations: [TargetSurface: [String: UserScopeMCPRegistration]] = [:]
        var results: [WorkspaceDeploymentObservation] = []
        var seen = Set<WorkspaceDeploymentInstallKey>()
        for assignment in snapshot.document.assignments {
            let selector = ResolvedAssignmentSelector(destination: assignment.destination)
            guard let captured = targets.first(where: { $0.target.selector == selector }),
                let artifact = artifacts[assignment.artifactID],
                artifact.identity.kind == .mcpServer, artifact.identity.parentPackageID == nil,
                let name = artifact.declaredName, !name.isEmpty,
                let report = reports[selector.surface]
            else { continue }
            let key = WorkspaceDeploymentInstallKey(
                artifactID: artifact.identity.id, physicalDestinationID: captured.target.physicalDestinationID)
            guard seen.insert(key).inserted else { continue }
            if selector.scope == .user, registrations[selector.surface] == nil {
                registrations[selector.surface] = report.userScopeMCPRegistrations()
            }
            if let observation = reportedConnection(
                key, named: name, scope: selector.scope, registrations: registrations[selector.surface] ?? [:],
                binding: bindings[artifact.identity.id])
            {
                results.append(observation)
            }
        }
        if let own = AgentToolingConnection.ownConnection(in: snapshot.document) {
            for captured in targets {
                let selector = captured.target.selector
                let key = WorkspaceDeploymentInstallKey(
                    artifactID: own.identity.id, physicalDestinationID: captured.target.physicalDestinationID)
                guard selector.scope == .user, selector.logicalProjectID == nil, !seen.contains(key),
                    let report = reports[selector.surface]
                else { continue }
                // One the assignments above already read is read from what
                // they read; any other app is read for this name alone.
                let registration =
                    registrations[selector.surface].map { $0[AgentToolingConnection.declaredName] }
                    ?? report.userScopeMCPRegistration(ofServer: AgentToolingConnection.declaredName)
                guard let registration else { continue }
                seen.insert(key)
                if let observation = reportedConnection(
                    key, named: AgentToolingConnection.declaredName, scope: .user,
                    registrations: [AgentToolingConnection.declaredName: registration], binding: bindings[own.identity.id])
                {
                    results.append(observation)
                }
            }
        }
        return results
    }

    /// What the planner is told about the connection `name`, asked for at
    /// `scope` at one destination, in an app that registers `registrations`
    /// for the person: nothing at all for a scope other than the person's own,
    /// which those registrations say nothing about; otherwise whether it is
    /// there, on, and started the way `binding` says.
    nonisolated static func reportedConnection(
        _ key: WorkspaceDeploymentInstallKey, named name: String, scope: ToolingScope,
        registrations: [String: UserScopeMCPRegistration], binding: DeviceMCPDefinitionBinding?
    ) -> WorkspaceDeploymentObservation? {
        guard scope == .user else { return nil }
        let registration = registrations[name]
        return WorkspaceDeploymentObservation(
            artifactID: key.artifactID, physicalDestinationID: key.physicalDestinationID, isPresent: registration != nil,
            isEnabled: registration?.isEnabled, connectionMatches: registration.flatMap { matches($0, binding: binding) })
    }

    /// Whether the app starts a registration with this Mac's bound command:
    /// for a binding that is a command, an entry that names no command is not
    /// it. Nil for a binding that is an address, which a registration's
    /// command says nothing about.
    private nonisolated static func matches(
        _ registration: UserScopeMCPRegistration, binding: DeviceMCPDefinitionBinding?
    ) -> Bool? {
        guard case .stdio(let executable, let arguments) = binding?.destination else { return nil }
        guard let configured = registration.command else { return false }
        guard let configuredArguments = registration.arguments else { return nil }
        return AgentToolingConnection.sameCommand(configured, executable) && configuredArguments == arguments
    }

    /// Previews this connection command with the same destinations, observations,
    /// reachability checks, and ownership receipts as a prepared plan. It changes
    /// neither disk nor session state and returns nil when planning is unavailable.
    func helperSteps(assuming command: ConnectAgentToolingCommand) async -> HelperSteps? {
        guard let current = try? store.snapshot(), let preview = try? command.preview(of: current, deviceID: store.deviceID)
        else { return nil }
        guard let connection = preview.connection else { return HelperSteps(adds: [], removals: []) }
        let candidate = preview.snapshot
        guard let captured = try? await Self.captureTargets(snapshot: candidate, homeRoot: homeRoot) else { return nil }
        let plan = WorkspaceDeploymentPlanner.plan(
            document: candidate.document, device: candidate.device, targets: captured.targets.map(\.target),
            observations: Self.reportedManagedConnections(snapshot: candidate, targets: captured.targets),
            unavailableDestinations: Self.unavailableDestinations(snapshot: candidate, skipped: captured.skipped),
            provenConnections: await Self.provenConnections(in: store))
        let steps = plan.items.filter { $0.artifactID == connection }
        return HelperSteps(
            adds: Set(steps.filter { !$0.action.isRemoval }.map(\.surface)),
            removals: Set(steps.filter(\.action.isRemoval).map(\.surface)))
    }
}

/// Where a plan would add Agent Tooling's own connection, and where it would
/// take it out (`WorkspaceDeploymentSession.helperSteps(assuming:)`).
struct HelperSteps: Equatable, Sendable {
    let adds: Set<TargetSurface>
    let removals: Set<TargetSurface>
}
