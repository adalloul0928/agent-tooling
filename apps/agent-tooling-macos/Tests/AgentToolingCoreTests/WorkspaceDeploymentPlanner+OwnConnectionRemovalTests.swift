import AgentToolingTestSupport
import Foundation
import Testing

@testable import AgentToolingCore

/// Agent Tooling's own connection comes out of an app this Mac no longer asks
/// to have it (D10), and only when everything says it is Agent Tooling's to
/// take out: nothing on this Mac asks for it there, the app starts it the way
/// this Mac's binding says, and a receipt proves Agent Tooling set it up in
/// that app. Anything else under the name is left alone (rule 15).
@Suite("Deployment planner · taking Agent Tooling's own connection out")
struct WorkspaceDeploymentPlannerOwnConnectionRemovalTests {
    @Test func aWithdrawnConnectionAgentToolingSetUpIsTakenOut() throws {
        let plan = try Self.plan(asking: [], observation: Self.observed(matches: true), proven: Self.proof)

        let item = try #require(plan.items.first)
        #expect(plan.items.count == 1)
        #expect(item.action == .removeManagedConnection)
        #expect(item.action.isRemoval)
        #expect(item.artifactID == Self.connectionID)
        #expect(item.physicalDestinationID == Self.destinationID)
        #expect(item.surface == .codexCLI)
        #expect(item.scope == .user)
        #expect(item.displayName == "Agent Tooling")
    }

    @Test func withoutAReceiptNothingIsTakenOut() throws {
        for proven in [[:], [TargetSurface.claudeCode: Set([AgentToolingConnection.declaredName])], [.codexCLI: ["sentry"]]] {
            let plan = try Self.plan(asking: [], observation: Self.observed(matches: true), proven: proven)
            #expect(plan.items.isEmpty, "\(proven)")
        }
    }

    /// A registration the app now starts some other way, or one whose command
    /// could not be read, is not the one Agent Tooling set up.
    @Test func aRegistrationThatStartsSomethingElseIsLeftAlone() throws {
        for matches in [false, nil] as [Bool?] {
            let plan = try Self.plan(asking: [], observation: Self.observed(matches: matches), proven: Self.proof)
            #expect(plan.items.isEmpty, "matches \(String(describing: matches))")
        }
        let absent = try Self.plan(asking: [], observation: Self.observed(isPresent: false, matches: nil), proven: Self.proof)
        #expect(absent.items.isEmpty)
    }

    /// This Mac still asks for it in Codex: nothing comes out, even while the
    /// request cannot be resolved because Codex has not said its version.
    @Test func aConnectionThisMacStillAsksForIsNeverTakenOut() throws {
        for version in ["0.164.0", nil] as [String?] {
            let plan = try Self.plan(
                asking: [Self.deviceID], observation: Self.observed(matches: true), proven: Self.proof, version: version)
            #expect(!plan.items.contains { $0.action == .removeManagedConnection }, "version \(String(describing: version))")
        }
    }

    /// Another Mac asking for it in its own Codex does not keep it in this
    /// one's.
    @Test func anotherMacsChoiceDoesNotKeepItHere() throws {
        let plan = try Self.plan(asking: [Self.otherDeviceID], observation: Self.observed(matches: true), proven: Self.proof)
        #expect(plan.items.map(\.action) == [.removeManagedConnection])
    }

    /// Only Agent Tooling's own connection is ever taken out: a withdrawn
    /// connection of the person's own, started the same way and set up by
    /// Agent Tooling, stays.
    @Test func noOtherConnectionIsTakenOut() throws {
        let plan = try Self.plan(
            asking: [], observation: Self.observed(matches: true), proven: [.codexCLI: ["agent-tooling", "local-helper"]],
            declaredName: "local-helper")
        #expect(plan.items.isEmpty)
    }

    // MARK: - One connection, one app

    private static let connectionID = ArtifactID(fixtureUUID("00000000-0000-0000-0000-0000000000e1"))
    private static let deviceID = WorkspaceObjectID(fixtureUUID("00000000-0000-0000-0000-0000000000e2"))
    private static let otherDeviceID = WorkspaceObjectID(fixtureUUID("00000000-0000-0000-0000-0000000000e5"))
    private static let workspaceID = WorkspaceObjectID(fixtureUUID("00000000-0000-0000-0000-0000000000e3"))
    private static let destinationID = WorkspaceObjectID(fixtureUUID("00000000-0000-0000-0000-0000000000e4"))
    private static let helper = "/Applications/Agent Tooling.app/Contents/Helpers/agent-tooling-mcp"
    private static let proof: [TargetSurface: Set<String>] = [.codexCLI: [AgentToolingConnection.declaredName]]

    private static func observed(isPresent: Bool = true, matches: Bool?) -> WorkspaceDeploymentObservation {
        .init(
            artifactID: connectionID, physicalDestinationID: destinationID, isPresent: isPresent, isEnabled: true,
            connectionMatches: matches)
    }

    /// The library's connection, asked for in Codex by the Macs `asking`
    /// (none: this Mac withdrew it), with this Mac's binding of the helper,
    /// Codex at `version`, and what Codex was observed to hold.
    private static func plan(
        asking devices: [WorkspaceObjectID], observation: WorkspaceDeploymentObservation,
        proven: [TargetSurface: Set<String>], version: String? = "0.164.0",
        declaredName: String = AgentToolingConnection.declaredName
    ) throws -> WorkspaceDeploymentPlan {
        let artifact = ArtifactRecord(
            identity: .init(id: connectionID, kind: .mcpServer, displayName: "Agent Tooling"), authority: .centralPersonal,
            declaredName: declaredName)
        var document = PortableWorkspaceDocument(
            workspaceID: workspaceID, revision: .init(writerID: deviceID), artifacts: [artifact],
            assignments: devices.map { device in
                .init(
                    artifactID: connectionID, destination: .init(surface: .codexCLI, scope: .user, deviceIDs: [device]),
                    reason: .manual)
            })
        document.mcpDefinitions = [.init(artifactID: connectionID, connection: .deviceBound(transport: .stdio))]
        document = try WorkspaceDocumentCoding.seal(document)
        var device = DeviceWorkspaceState(workspaceID: workspaceID, deviceID: deviceID)
        device.mcpBindings = [.init(artifactID: connectionID, destination: .stdio(executable: helper, arguments: []))]
        device.capabilityEvidence = [
            TargetCapabilityEvidence(
                surface: .codexCLI, installedClientVersion: "0.164.0", adapterContractVersion: 1, component: .mcpServer,
                transport: "stdio", scopes: [.user], support: .supported, observedAt: Date(timeIntervalSince1970: 1_700_000_000))
        ]
        let target = ResolvedAssignmentTarget(
            selector: .init(surface: .codexCLI, scope: .user, logicalProjectID: nil), physicalDestinationID: destinationID,
            installedClientVersion: version, adapterContractVersion: 1,
            componentContexts: [.init(component: .mcpServer, transport: "stdio")])
        return WorkspaceDeploymentPlanner.plan(
            document: document, device: device, targets: [target], observations: [observation], provenConnections: proven)
    }
}
