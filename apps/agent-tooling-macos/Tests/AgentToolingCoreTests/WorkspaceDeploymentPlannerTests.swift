import Foundation
import Testing

@testable import AgentToolingCore

/// The planner says what would change on this device and, by name, what would
/// not. It proves nothing about installation: an item here is a request for the
/// reviewed operation path.
@Suite("Workspace deployment planner")
struct WorkspaceDeploymentPlannerTests {
    @Test func approvedContentBecomesOneInstallPerDestination() throws {
        let document = try Self.document(
            artifacts: [Self.personal],
            assignments: [Self.assignment(Self.personalID, surface: .codexCLI),
                          Self.assignment(Self.personalID, surface: .claudeCode)])

        let plan = WorkspaceDeploymentPlanner.plan(document: document, device: Self.device,
            targets: [Self.target(.codexCLI), Self.target(.claudeCode)],
            availableContent: [Self.held(Self.personalID, "a")])

        #expect(plan.items.count == 2)
        #expect(plan.exclusions.isEmpty, "\(plan.exclusions)")
        #expect(plan.items.allSatisfy { $0.action == .installContent(digest: Self.digest("a")) })
        #expect(Set(plan.items.map(\.surface)) == [.codexCLI, .claudeCode])
        #expect(plan.items.allSatisfy { $0.reasons == [.manual] })
    }

    @Test func anObservedMatchIsExcludedWhileDifferentContentBecomesAnUpdate() throws {
        let document = try Self.document(artifacts: [Self.personal],
            assignments: [Self.assignment(Self.personalID, surface: .codexCLI)])
        let destination = Self.target(.codexCLI).physicalDestinationID

        let unchanged = WorkspaceDeploymentPlanner.plan(document: document, device: Self.device,
            targets: [Self.target(.codexCLI)], availableContent: [Self.held(Self.personalID, "a")],
            observations: [.init(artifactID: Self.personalID, physicalDestinationID: destination,
                                 isPresent: true, contentDigest: Self.digest("a"))])
        #expect(unchanged.items.isEmpty)
        #expect(unchanged.exclusions.map(\.reason) == [.alreadyPresent])

        let stale = WorkspaceDeploymentPlanner.plan(document: document, device: Self.device,
            targets: [Self.target(.codexCLI)], availableContent: [Self.held(Self.personalID, "a")],
            observations: [.init(artifactID: Self.personalID, physicalDestinationID: destination,
                                 isPresent: true, contentDigest: Self.digest("b"))])
        #expect(stale.items.first?.action == .updateContent(from: Self.digest("b"), to: Self.digest("a")))

        // Present but unmeasured is not proof the destination is correct.
        let unmeasured = WorkspaceDeploymentPlanner.plan(document: document, device: Self.device,
            targets: [Self.target(.codexCLI)], availableContent: [Self.held(Self.personalID, "a")],
            observations: [.init(artifactID: Self.personalID, physicalDestinationID: destination,
                                 isPresent: true, contentDigest: nil)])
        #expect(unmeasured.items.first?.action == .updateContent(from: nil, to: Self.digest("a")))
    }

    @Test func trackedAndContentlessItemsAreExcludedByNameRatherThanAttempted() throws {
        let contentless = ArtifactRecord(
            identity: .init(id: Self.otherID, kind: .skill, displayName: "No content"),
            authority: .centralPersonal, declaredName: "no-content")
        let document = try Self.document(
            artifacts: [Self.tracked, contentless],
            assignments: [Self.assignment(Self.trackedID, surface: .codexCLI),
                          Self.assignment(Self.otherID, surface: .codexCLI)])

        let plan = WorkspaceDeploymentPlanner.plan(document: document, device: Self.device,
            targets: [Self.target(.codexCLI)])

        #expect(plan.items.isEmpty)
        #expect(plan.exclusions.contains { $0.reason == .trackedOwnership && $0.artifactID == Self.trackedID })
        #expect(plan.exclusions.contains { $0.reason == .missingContent && $0.artifactID == Self.otherID })
    }

    @Test func aNativePackageNeedsAReviewedRouteAndNeverCarriesAnOnOffRequest() throws {
        let route = NativePackageRoute(client: .codex, externalPluginID: "browser")
        let plugin = ArtifactRecord(
            identity: .init(id: Self.otherID, kind: .nativePlugin, displayName: "Browser"),
            authority: .nativeOwned, declaredName: "browser", nativeRoutes: [route])
        let document = try Self.document(artifacts: [plugin],
            assignments: [Self.assignment(Self.otherID, surface: .codexCLI)])

        let withoutRoute = WorkspaceDeploymentPlanner.plan(document: document, device: Self.device,
            targets: [Self.target(.codexCLI)])
        #expect(withoutRoute.items.isEmpty)
        #expect(withoutRoute.exclusions.map(\.reason) == [.missingNativeRoute])

        let withRoute = WorkspaceDeploymentPlanner.plan(document: document, device: Self.device,
            targets: [Self.target(.codexCLI)], nativeInstallRoutes: [route])
        #expect(withRoute.items.map(\.action) == [.installNativePackage(route: route)])

        var enabled = try Self.document(artifacts: [plugin],
            assignments: [Self.assignment(Self.otherID, surface: .codexCLI, enabled: true)])
        enabled = enabled.canonicalized()
        let requested = WorkspaceDeploymentPlanner.plan(document: enabled, device: Self.device,
            targets: [Self.target(.codexCLI)], nativeInstallRoutes: [route])
        #expect(requested.items.isEmpty)
        #expect(requested.exclusions.map(\.reason) == [.unsupportedByAdapter])
    }

    @Test func aBundledMemberIsNeverPlannedOnItsOwn() throws {
        let parentID = Self.otherID
        let childID = ArtifactID(UUID(uuidString: "00000000-0000-0000-0000-0000000000c9")!)
        let route = NativePackageRoute(client: .codex, externalPluginID: "browser")
        let parent = ArtifactRecord(
            identity: .init(id: parentID, kind: .nativePlugin, displayName: "Browser"),
            authority: .nativeOwned, declaredName: "browser", nativeRoutes: [route])
        let child = ArtifactRecord(
            identity: .init(id: childID, kind: .skill, displayName: "Browse", parentPackageID: parentID),
            authority: .nativeOwned, declaredName: "browse", packageRelativePath: "skills/browse")
        // The document contract already refuses a native child assignment, so
        // the planner must not need one to keep members bundled.
        let document = try Self.document(artifacts: [parent, child],
            assignments: [Self.assignment(parentID, surface: .codexCLI)])

        let plan = WorkspaceDeploymentPlanner.plan(document: document, device: Self.device,
            targets: [Self.target(.codexCLI)], nativeInstallRoutes: [route])

        #expect(plan.items.count == 1)
        #expect(plan.items.first?.artifactID == parentID)
        #expect(!plan.items.contains { $0.artifactID == childID })
    }

    @Test func independentReasonsForOneDestinationAllSurvive() throws {
        let presetID = ArtifactID(UUID(uuidString: "00000000-0000-0000-0000-0000000000e1")!)
        let document = try Self.document(
            artifacts: [Self.personal,
                        .init(identity: .init(id: presetID, kind: .preset, displayName: "Starter"),
                              authority: .centralPersonal)],
            assignments: [
                Self.assignment(Self.personalID, surface: .codexCLI),
                Self.assignment(Self.personalID, surface: .codexCLI, reason: .preset(presetID: presetID),
                                id: "00000000-0000-0000-0000-0000000000f2"),
            ],
            presets: [.init(id: presetID, name: "Starter", revision: 1,
                            memberArtifactIDs: [Self.personalID])])

        let plan = WorkspaceDeploymentPlanner.plan(document: document, device: Self.device,
            targets: [Self.target(.codexCLI)], availableContent: [Self.held(Self.personalID, "a")])

        #expect(plan.items.count == 1)
        #expect(Set(plan.items.first?.reasons ?? []) == [.manual, .preset(presetID: presetID)],
                "\(plan.items.first?.reasons ?? []) \(plan.exclusions)")
    }

    private static let personalID = ArtifactID(UUID(uuidString: "00000000-0000-0000-0000-0000000000a1")!)
    private static let trackedID = ArtifactID(UUID(uuidString: "00000000-0000-0000-0000-0000000000b2")!)
    private static let otherID = ArtifactID(UUID(uuidString: "00000000-0000-0000-0000-0000000000c3")!)
    private static let deviceID = WorkspaceObjectID(UUID(uuidString: "00000000-0000-0000-0000-0000000000d4")!)
    private static let workspaceID = WorkspaceObjectID(UUID(uuidString: "00000000-0000-0000-0000-0000000000e5")!)

    private static var personal: ArtifactRecord {
        .init(identity: .init(id: personalID, kind: .skill, displayName: "Personal"),
              authority: .centralPersonal, declaredName: "personal", contentDigest: digest("a"))
    }
    private static var tracked: ArtifactRecord {
        .init(identity: .init(id: trackedID, kind: .skill, displayName: "Tracked"), authority: .trackedOnly)
    }

    private static var device: DeviceWorkspaceState {
        var state = DeviceWorkspaceState(workspaceID: workspaceID, deviceID: deviceID)
        state.capabilityEvidence = [TargetSurface.codexCLI, .claudeCode].flatMap { surface in
            [ComponentKind.skill, .plugin, .mcpServer].map { component in
                TargetCapabilityEvidence(surface: surface, installedClientVersion: "1.0.0",
                    adapterContractVersion: 1, component: component,
                    transport: component == .mcpServer ? "stdio" : nil,
                    scopes: [.user, .project], support: .supported,
                    observedAt: Date(timeIntervalSince1970: 1_700_000_000))
            }
        }
        return state
    }

    private static func target(_ surface: TargetSurface) -> ResolvedAssignmentTarget {
        .init(selector: .init(surface: surface, scope: .user, logicalProjectID: nil),
              physicalDestinationID: WorkspaceObjectID(UUID(uuidString:
                  surface == .codexCLI ? "00000000-0000-0000-0000-000000000101"
                                       : "00000000-0000-0000-0000-000000000102")!),
              installedClientVersion: "1.0.0", adapterContractVersion: 1,
              componentContexts: [.init(component: .skill, transport: nil),
                                  .init(component: .plugin, transport: nil),
                                  .init(component: .mcpServer, transport: "stdio")])
    }

    private static func digest(_ character: Character) -> ContentDigest {
        .init(algorithm: .sha256TreeV1, value: String(repeating: String(character), count: 64))
    }

    private static func assignment(
        _ artifactID: ArtifactID,
        surface: TargetSurface,
        enabled: Bool? = nil,
        reason: AssignmentReason = .manual,
        id: String? = nil
    ) -> AssignmentContribution {
        // Twelve hex digits in the final group: nine zeros, the item's own last
        // two, and one for the surface.
        let identifier = id ?? ("00000000-0000-0000-0000-000000000"
            + String(artifactID.rawValue.uuidString.suffix(2))
            + (surface == .codexCLI ? "1" : "2"))
        return .init(id: WorkspaceObjectID(UUID(uuidString: identifier)!),
                     artifactID: artifactID,
                     destination: .init(surface: surface, scope: .user),
                     reason: reason, desiredPresence: true, desiredEnabled: enabled)
    }

    private static func held(_ artifactID: ArtifactID, _ character: Character) -> AssignmentContentEvidence {
        .init(artifactID: artifactID, digest: digest(character))
    }

    private static func document(
        artifacts: [ArtifactRecord],
        assignments: [AssignmentContribution],
        presets: [PresetRecord] = []
    ) throws -> PortableWorkspaceDocument {
        try WorkspaceDocumentCoding.seal(.init(
            workspaceID: workspaceID, revision: .init(writerID: deviceID),
            artifacts: artifacts, assignments: assignments, presets: presets))
    }
}
