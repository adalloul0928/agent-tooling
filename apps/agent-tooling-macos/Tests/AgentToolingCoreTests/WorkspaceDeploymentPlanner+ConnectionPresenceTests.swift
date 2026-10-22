import AgentToolingTestSupport
import Foundation
import Testing

@testable import AgentToolingCore

/// A managed connection an app already has is not planned again: present and
/// started the way this Mac's binding says, it is already there; present but
/// started another way, the step replaces it, and says so.
@Suite("Deployment planner · connection presence")
struct WorkspaceDeploymentPlannerConnectionPresenceTests {
    @Test func aConnectionNobodyObservedIsAddedAsNew() throws {
        let plan = try Self.plan(observation: nil)
        #expect(plan.items.map(\.action) == [.configureManagedConnection(transport: .stdio, replacesExisting: false)])
    }

    @Test func aConnectionObservedAbsentIsAddedAsNew() throws {
        let plan = try Self.plan(observation: Self.observed(isPresent: false))
        #expect(plan.items.map(\.action) == [.configureManagedConnection(transport: .stdio, replacesExisting: false)])
    }

    /// Nothing asked about on or off is satisfied either way: the app's own
    /// enablement does not make an installed connection look missing.
    @Test func aConnectionPresentAndMatchingIsAlreadyThere() throws {
        for enabled in [true, false, nil] as [Bool?] {
            let plan = try Self.plan(observation: Self.observed(isPresent: true, isEnabled: enabled, matches: true))
            #expect(plan.items.isEmpty, "enabled \(String(describing: enabled))")
            #expect(plan.exclusions.map(\.reason) == [.alreadyPresent])
        }
    }

    @Test func aConnectionPresentButStartedAnotherWayIsReplaced() throws {
        let plan = try Self.plan(observation: Self.observed(isPresent: true, isEnabled: true, matches: false))
        #expect(plan.items.map(\.action) == [.configureManagedConnection(transport: .stdio, replacesExisting: true)])
    }

    /// When how the app starts it could not be read, that is not taken as a
    /// difference: replacing what may well be right is the worse mistake.
    @Test func aConnectionPresentWithAnUnknownCommandIsAlreadyThere() throws {
        let plan = try Self.plan(observation: Self.observed(isPresent: true, isEnabled: true, matches: nil))
        #expect(plan.items.isEmpty)
        #expect(plan.exclusions.map(\.reason) == [.alreadyPresent])
    }

    @Test func aConnectionAskedToBeOffButOnIsReconfigured() throws {
        let plan = try Self.plan(
            observation: Self.observed(isPresent: true, isEnabled: true, matches: true), desiredEnabled: false)
        #expect(plan.items.map(\.action) == [.configureManagedConnection(transport: .stdio, replacesExisting: true)])
    }

    // MARK: - One connection, one app

    private static let connectionID = ArtifactID(fixtureUUID("00000000-0000-0000-0000-0000000000f1"))
    private static let deviceID = WorkspaceObjectID(fixtureUUID("00000000-0000-0000-0000-0000000000f2"))
    private static let workspaceID = WorkspaceObjectID(fixtureUUID("00000000-0000-0000-0000-0000000000f3"))
    private static let destinationID = WorkspaceObjectID(fixtureUUID("00000000-0000-0000-0000-0000000000f4"))

    private static func observed(isPresent: Bool, isEnabled: Bool? = nil, matches: Bool? = nil) -> WorkspaceDeploymentObservation {
        .init(
            artifactID: connectionID, physicalDestinationID: destinationID, isPresent: isPresent, isEnabled: isEnabled,
            connectionMatches: matches)
    }

    private static func plan(
        observation: WorkspaceDeploymentObservation?, desiredEnabled: Bool? = nil
    ) throws -> WorkspaceDeploymentPlan {
        let artifact = ArtifactRecord(
            identity: .init(id: connectionID, kind: .mcpServer, displayName: "Agent Tooling"), authority: .centralPersonal,
            declaredName: "agent-tooling")
        var document = PortableWorkspaceDocument(
            workspaceID: workspaceID, revision: .init(writerID: deviceID), artifacts: [artifact],
            assignments: [
                .init(
                    artifactID: connectionID, destination: .init(surface: .codexCLI, scope: .user, deviceIDs: [deviceID]),
                    reason: .manual, desiredEnabled: desiredEnabled)
            ])
        document.mcpDefinitions = [.init(artifactID: connectionID, connection: .deviceBound(transport: .stdio))]
        document = try WorkspaceDocumentCoding.seal(document)
        var device = DeviceWorkspaceState(workspaceID: workspaceID, deviceID: deviceID)
        device.mcpBindings = [
            .init(
                artifactID: connectionID,
                destination: .stdio(executable: "/Applications/Agent Tooling.app/Contents/Helpers/agent-tooling-mcp", arguments: []))
        ]
        device.capabilityEvidence = [
            TargetCapabilityEvidence(
                surface: .codexCLI, installedClientVersion: "0.164.0", adapterContractVersion: 1, component: .mcpServer,
                transport: "stdio", scopes: [.user], support: .supported, observedAt: Date(timeIntervalSince1970: 1_700_000_000))
        ]
        let target = ResolvedAssignmentTarget(
            selector: .init(surface: .codexCLI, scope: .user, logicalProjectID: nil), physicalDestinationID: destinationID,
            installedClientVersion: "0.164.0", adapterContractVersion: 1,
            componentContexts: [.init(component: .mcpServer, transport: "stdio")])
        return WorkspaceDeploymentPlanner.plan(
            document: document, device: device, targets: [target], observations: observation.map { [$0] } ?? [])
    }
}
