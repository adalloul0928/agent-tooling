import Foundation
import Testing

@testable import AgentToolingCore

struct WorkspaceNativePluginCommandPlanningTests {
    @Test(arguments: [TargetSurface.claudeCode, .codexCLI])
    func reviewedCatalogInstallMatchesTheNativeCommandContract(_ surface: TargetSurface) throws {
        let fixture = try Fixture(surface: surface)
        let plan = try fixture.plan()

        #expect(plan.arguments == fixture.install.arguments)
        #expect(plan.executable == fixture.install.executable)
        #expect(plan.externalPluginID == fixture.pluginID)
        #expect(plan.scope == .user)
    }

    @MainActor
    @Test(arguments: [ClientKind.claude, .codex])
    func commandExactlyMatchesExistingAppModelMarketplacePlan(_ client: ClientKind) throws {
        let surface: TargetSurface = client == .claude ? .claudeCode : .codexCLI
        let fixture = try Fixture(surface: surface)
        let root = FileManager.default.temporaryDirectory
            .appending(path: "native-command-parity-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try WorkspaceStore(rootURL: root.appending(path: "workspace"))
        try store.saveWorkspaceSnapshot(.init(preferences: .init(enabledClients: [client])))
        let model = try AppModel(store: store, homeURL: root.appending(path: "home"), marketplaceProviders: [])
        let package = MarketplacePackage(
            id: "\(client == .claude ? "claude" : "codex"):\(fixture.pluginID)",
            name: "Review", publisher: "Fixture", summary: "Fixture", sourceName: "Fixture",
            components: [.plugin], supportedClients: [client], location: fixture.pluginID,
            nativeInstalls: [fixture.install])
        model.marketplacePackages = [package]
        model.planMarketplaceInstall(packageID: package.id, client: client)

        let old = try #require(model.pendingPlan?.steps.first(where: { $0.kind == .command }))
        let new = try fixture.plan()
        #expect(new.executable == old.executable)
        #expect(new.arguments == old.arguments)
    }

    @Test func ownershipRouteCannotSynthesizeOrSubstituteCurrentCatalogEvidence() throws {
        let fixture = try Fixture(surface: .claudeCode)
        var wrongID = fixture.install
        wrongID.arguments[2] = "another@marketplace"
        #expect(throws: WorkspaceNativePluginCommandPlanningError.invalidReviewedInstall) {
            _ = try fixture.plan(install: wrongID)
        }

        var wrongScope = fixture.install
        wrongScope.scope = .project
        #expect(throws: WorkspaceNativePluginCommandPlanningError.invalidReviewedInstall) {
            _ = try fixture.plan(install: wrongScope)
        }

        var extraConsent = fixture.install
        extraConsent.arguments.append("--yes")
        #expect(throws: WorkspaceNativePluginCommandPlanningError.invalidReviewedInstall) {
            _ = try fixture.plan(install: extraConsent)
        }
    }

    @Test func unsupportedSurfacesAndScopesNeverBecomeNativeCommands() throws {
        let project = try Fixture(surface: .claudeCode, scope: .project)
        #expect(throws: WorkspaceNativePluginCommandPlanningError.unsupportedScope(.project, .claude)) {
            _ = try project.plan()
        }

        let gemini = try Fixture(surface: .geminiCLI)
        #expect(throws: WorkspaceNativePluginCommandPlanningError.unsupportedSurface(.geminiCLI)) {
            _ = try gemini.plan()
        }

        let desktop = try Fixture(surface: .claudeDesktop)
        #expect(throws: WorkspaceNativePluginCommandPlanningError.unsupportedSurface(.claudeDesktop)) {
            _ = try desktop.plan()
        }
    }

    @Test(arguments: [true, false])
    func installDoesNotClaimToApplyExplicitEnablement(_ enabled: Bool) throws {
        var fixture = try Fixture(surface: .claudeCode)
        fixture.document.assignments[0].desiredEnabled = enabled
        fixture.document = try WorkspaceDocumentCoding.seal(fixture.document)
        fixture.requirement.desiredEnabled = enabled
        fixture.requirement.contributions[0].desiredEnabled = enabled

        #expect(throws: WorkspaceNativePluginCommandPlanningError.unsupportedEnablement) {
            _ = try fixture.plan()
        }
    }

    @Test func anotherDevicesEnablementDoesNotBlockCurrentDevicePresence() throws {
        var fixture = try Fixture(surface: .claudeCode)
        var remote = fixture.document.assignments[0]
        remote.id = WorkspaceObjectID(UUID(uuidString: "00000000-0000-0000-0000-000000000111")!)
        remote.destination.deviceIDs = [WorkspaceObjectID(
            UUID(uuidString: "00000000-0000-0000-0000-000000000112")!)]
        remote.desiredEnabled = false
        fixture.document.assignments.append(remote)
        fixture.document = try WorkspaceDocumentCoding.seal(fixture.document)

        #expect(throws: Never.self) { _ = try fixture.plan() }
    }

    @Test func omittedApplicableAssignmentAndUnassignedAliasedTargetAreRejected() throws {
        var omitted = try Fixture(surface: .claudeCode)
        var contribution = omitted.document.assignments[0]
        contribution.id = WorkspaceObjectID(UUID(uuidString: "00000000-0000-0000-0000-000000000113")!)
        contribution.destination.surface = .codexCLI
        omitted.document.assignments.append(contribution)
        omitted.document = try WorkspaceDocumentCoding.seal(omitted.document)
        #expect(throws: WorkspaceNativePluginCommandPlanningError.invalidRequirement) {
            _ = try omitted.plan()
        }

        var aliased = try Fixture(surface: .claudeCode)
        let unrelated = ResolvedAssignmentTarget(
            selector: .init(surface: .codexCLI, scope: .user),
            physicalDestinationID: aliased.target.physicalDestinationID,
            installedClientVersion: "1.0.0", adapterContractVersion: 1,
            componentContexts: [.init(component: .plugin)])
        aliased.target = unrelated
        aliased.resolvedTargets.append(unrelated)
        #expect(throws: WorkspaceNativePluginCommandPlanningError.invalidRequirement) {
            _ = try aliased.plan()
        }
    }

    @Test func exactSupportedCapabilityAndCLIIdentityAreRequired() throws {
        var missing = try Fixture(surface: .claudeCode)
        missing.device.capabilityEvidence = []
        #expect(throws: WorkspaceNativePluginCommandPlanningError.invalidCapability) {
            _ = try missing.plan()
        }

        var unknown = try Fixture(surface: .claudeCode)
        unknown.capability.support = .unknown(reason: "adapter has not checked this route")
        unknown.device.capabilityEvidence = [unknown.capability]
        #expect(throws: WorkspaceNativePluginCommandPlanningError.unsupportedCapability) {
            _ = try unknown.plan()
        }

        let fixture = try Fixture(surface: .claudeCode)
        #expect(throws: WorkspaceNativePluginCommandPlanningError.invalidCLIURL) {
            _ = try fixture.plan(executableURL: URL(fileURLWithPath: "/usr/local/bin/codex"))
        }
    }

    @Test func managedPolicyBlocksAndUnresolvedPolicyStateFailClosed() throws {
        var blocked = try Fixture(surface: .claudeCode)
        let policyID = WorkspaceObjectID(UUID(uuidString: "00000000-0000-0000-0000-000000000114")!)
        let pluginLegacy = LegacyReferenceKey(domain: .plugin, identifier: blocked.pluginID)
        let policyLegacy = LegacyReferenceKey(domain: .policy, identifier: "managed")
        blocked.document.configurationState = .init(
            managedPolicies: [.init(
                id: policyID, name: "Managed",
                blockedPlugins: [.init(legacy: pluginLegacy, resolution: .artifact(Fixture.artifactID))])],
            identityMap: [
                .init(legacy: pluginLegacy, objectID: WorkspaceObjectID(Fixture.artifactID.rawValue)),
                .init(legacy: policyLegacy, objectID: policyID),
            ])
        blocked.document = try WorkspaceDocumentCoding.seal(blocked.document)
        #expect(throws: WorkspaceNativePluginCommandPlanningError.blockedByManagedPolicy) {
            _ = try blocked.plan()
        }

        var unresolved = try Fixture(surface: .claudeCode)
        let missingID = WorkspaceObjectID(UUID(uuidString: "00000000-0000-0000-0000-000000000115")!)
        let missingLegacy = LegacyReferenceKey(domain: .plugin, identifier: "blocked-but-missing")
        unresolved.document.configurationState = .init(
            managedPolicies: [.init(
                id: policyID, name: "Managed",
                blockedPlugins: [.init(legacy: missingLegacy, resolution: .unresolved)])],
            identityMap: [
                .init(legacy: missingLegacy, objectID: missingID),
                .init(legacy: policyLegacy, objectID: policyID),
            ])
        unresolved.document = try WorkspaceDocumentCoding.seal(unresolved.document)
        #expect(throws: WorkspaceNativePluginCommandPlanningError.unresolvedManagedPolicy) {
            _ = try unresolved.plan()
        }
    }

    private struct Fixture {
        static let artifactID = ArtifactID(UUID(uuidString: "00000000-0000-0000-0000-000000000101")!)
        static let deviceID = WorkspaceObjectID(UUID(uuidString: "00000000-0000-0000-0000-000000000102")!)
        static let physicalID = WorkspaceObjectID(UUID(uuidString: "00000000-0000-0000-0000-000000000103")!)
        static let projectID = ArtifactID(UUID(uuidString: "00000000-0000-0000-0000-000000000108")!)

        let pluginID = "review@marketplace"
        var document: PortableWorkspaceDocument
        var device: DeviceWorkspaceState
        var requirement: EffectiveAssignmentRequirement
        var target: ResolvedAssignmentTarget
        var resolvedTargets: [ResolvedAssignmentTarget]
        var capability: TargetCapabilityEvidence
        var install: NativeInstall
        var executableURL: URL

        init(surface: TargetSurface, scope: ToolingScope = .user) throws {
            let client = try #require(surface.client)
            let logicalProjectID: ArtifactID? = scope == .project || scope == .localProject
                ? Self.projectID : nil
            let destination = PortableDestination(
                surface: surface, scope: scope, logicalProjectID: logicalProjectID,
                deviceIDs: [Self.deviceID])
            let contribution = AssignmentContribution(
                id: WorkspaceObjectID(UUID(uuidString: "00000000-0000-0000-0000-000000000104")!),
                artifactID: Self.artifactID, destination: destination, reason: .manual)
            let route = NativePackageRoute(client: client, externalPluginID: pluginID)
            var artifacts: [ArtifactRecord] = [.init(
                identity: .init(id: Self.artifactID, kind: .nativePlugin, displayName: "Review"),
                authority: .nativeOwned, nativeRoutes: [route])]
            var projects: [LogicalProjectRecord] = []
            if logicalProjectID != nil {
                artifacts.append(.init(
                    identity: .init(id: Self.projectID, kind: .logicalProject, displayName: "Project"),
                    authority: .trackedOnly))
                projects = [.init(id: Self.projectID, name: "Project")]
            }
            document = try WorkspaceDocumentCoding.seal(.init(
                workspaceID: WorkspaceObjectID(UUID(uuidString: "00000000-0000-0000-0000-000000000105")!),
                revision: .init(
                    id: WorkspaceObjectID(UUID(uuidString: "00000000-0000-0000-0000-000000000106")!),
                    writerID: WorkspaceObjectID(UUID(uuidString: "00000000-0000-0000-0000-000000000107")!),
                    createdAt: Date(timeIntervalSince1970: 1_700_000_000)),
                artifacts: artifacts,
                logicalProjects: projects,
                assignments: [contribution]))
            capability = .init(
                surface: surface, installedClientVersion: "1.0.0", adapterContractVersion: 1,
                component: .plugin, scopes: [scope], support: .supported,
                observedAt: Date(timeIntervalSince1970: 1_700_000_000))
            device = .init(
                workspaceID: document.workspaceID, deviceID: Self.deviceID,
                capabilityEvidence: [capability],
                projectRoots: logicalProjectID.map { [.init(projectID: $0, rootPath: "/work/project")] } ?? [])
            target = .init(
                selector: .init(destination: destination), physicalDestinationID: Self.physicalID,
                installedClientVersion: "1.0.0", adapterContractVersion: 1,
                componentContexts: [.init(component: .plugin)])
            resolvedTargets = [target]
            let resolved = WorkspaceAssignmentResolver.resolve(
                artifacts: document.artifacts, contributions: document.assignments,
                currentDeviceID: device.deviceID, targets: resolvedTargets,
                capabilityEvidence: device.capabilityEvidence)
            requirement = try #require(resolved.requirements.first)
            let executable = client == .claude ? "claude" : client == .codex ? "codex" : "gemini"
            let arguments = client == .claude
                ? ["plugin", "install", pluginID, "--scope", "user"]
                : ["plugin", "add", pluginID]
            install = .init(
                client: client, executable: executable, arguments: arguments,
                detail: "Reviewed current catalog route")
            executableURL = URL(fileURLWithPath: "/usr/local/bin/\(executable)")
        }

        func plan(
            install: NativeInstall? = nil,
            executableURL: URL? = nil
        ) throws -> WorkspaceNativePluginCommandPlan {
            try WorkspaceNativePluginCommandPlanning.plan(
                document: document, device: device, requirement: requirement,
                resolvedTargets: resolvedTargets, target: target, capability: capability,
                reviewedInstall: install ?? self.install,
                executableURL: executableURL ?? self.executableURL)
        }
    }
}
