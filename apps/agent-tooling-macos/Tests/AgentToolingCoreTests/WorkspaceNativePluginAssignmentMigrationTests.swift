import Foundation
import Testing

@testable import AgentToolingCore

struct WorkspaceNativePluginAssignmentMigrationTests {
    @Test func explicitBindingsPreserveTrueFalseAndUnknownWithoutUsingObservations() throws {
        let fixture = try Fixture(bindings: [(.claude, true), (.codex, false), (.gemini, nil)])
        let output = try WorkspaceNativePluginAssignmentMigration.preview(candidate: fixture.candidate, placements: [
            fixture.placement(.claude), fixture.placement(.codex), fixture.placement(.gemini),
        ])

        #expect(output.issues.isEmpty)
        #expect(Dictionary(uniqueKeysWithValues: output.proposals.map { ($0.destination.surface, $0.desiredEnabled) }) == [
            .claudeCode: true, .codexCLI: false, .geminiCLI: nil,
        ])
        #expect(output.proposals.map(\.reason) == Array(repeating: .onboarding(configurationID: fixture.configurationID), count: 3))
        #expect(output.proposals.allSatisfy { $0.destination.deviceIDs == [fixture.deviceID] })
    }

    @Test func nilAndExplicitEmptyBindingsNeverExpandObservationOrRouteIntoDesiredState() throws {
        for bindings: [(ClientKind, Bool?)]? in [nil, []] {
            let fixture = try Fixture(bindings: bindings)
            let withoutPlacement = try WorkspaceNativePluginAssignmentMigration.preview(candidate: fixture.candidate, placements: [])
            #expect(withoutPlacement.proposals.isEmpty)
            #expect(withoutPlacement.issues.isEmpty)
            let output = try WorkspaceNativePluginAssignmentMigration.preview(
                candidate: fixture.candidate, placements: [fixture.placement(.claude)])
            #expect(output.proposals.isEmpty)
        }
    }

    @Test func exactRetryIsOmittedWhileChangedExistingIntentConflicts() throws {
        let fixture = try Fixture(bindings: [(.claude, true)])
        let first = try WorkspaceNativePluginAssignmentMigration.preview(
            candidate: fixture.candidate, placements: [fixture.placement(.claude)])
        var matchingDocument = fixture.candidate.document
        matchingDocument.assignments = first.proposals
        matchingDocument = try WorkspaceDocumentCoding.seal(matchingDocument)
        let matching = WorkspaceMigrationCandidate(document: matchingDocument, device: fixture.candidate.device,
            content: [:], legacySnapshot: fixture.candidate.legacySnapshot)
        let replay = try WorkspaceNativePluginAssignmentMigration.preview(candidate: matching, placements: [fixture.placement(.claude)])
        #expect(replay.proposals.isEmpty)
        #expect(replay.issues.isEmpty)

        var changedDocument = matchingDocument
        changedDocument.assignments[0].desiredEnabled = false
        changedDocument = try WorkspaceDocumentCoding.seal(changedDocument)
        let changed = WorkspaceMigrationCandidate(document: changedDocument, device: fixture.candidate.device,
            content: [:], legacySnapshot: fixture.candidate.legacySnapshot)
        let conflict = try WorkspaceNativePluginAssignmentMigration.preview(candidate: changed, placements: [fixture.placement(.claude)])
        #expect(conflict.proposals.isEmpty)
        #expect(conflict.issues.map(\.kind) == [.existingAssignmentConflict])
    }

    @Test func missingDuplicateAndUnusedPlacementsAreReviewable() throws {
        let fixture = try Fixture(bindings: [(.claude, true)])
        let missing = try WorkspaceNativePluginAssignmentMigration.preview(candidate: fixture.candidate, placements: [])
        #expect(missing.issues.map(\.kind) == [.missingPlacement])
        let duplicate = try WorkspaceNativePluginAssignmentMigration.preview(candidate: fixture.candidate,
            placements: [fixture.placement(.claude), fixture.placement(.claude)])
        #expect(duplicate.issues.map(\.kind) == [.duplicatePlacement])
        let unused = try WorkspaceNativePluginAssignmentMigration.preview(candidate: fixture.candidate,
            placements: [fixture.placement(.claude), fixture.placement(.codex)])
        #expect(unused.proposals.count == 1)
        #expect(unused.issues.map(\.kind) == [.unusedPlacement])
    }

    @Test func noActiveConfigurationIsOnlyAnIssueWhenCallerSuppliesAPlacement() throws {
        let fixture = try Fixture(bindings: [(.claude, true)])
        var document = fixture.candidate.document
        document.configurationState?.defaultConfigurationID = nil
        document = try WorkspaceDocumentCoding.seal(document)
        let device = DeviceWorkspaceState(workspaceID: fixture.workspaceID, deviceID: fixture.deviceID,
            configurationState: .init(), applicationState: .init(preferences: .init(enabledClients: ClientKind.allCases)), projectRoots: [])
        let candidate = WorkspaceMigrationCandidate(document: document, device: device, content: [:], legacySnapshot: fixture.candidate.legacySnapshot)
        #expect(try WorkspaceNativePluginAssignmentMigration.preview(candidate: candidate, placements: []).issues.isEmpty)
        #expect(try WorkspaceNativePluginAssignmentMigration.preview(candidate: candidate,
            placements: [fixture.placement(.claude)]).issues.map(\.kind) == [.missingActiveConfiguration])
    }

    @Test func disabledRootOutsideEnabledPluginsStillRetainsItsExplicitFalsePlacement() throws {
        let fixture = try Fixture(bindings: [(.codex, false)], enabledPlugin: false)
        let output = try WorkspaceNativePluginAssignmentMigration.preview(
            candidate: fixture.candidate, placements: [fixture.placement(.codex)])

        #expect(output.issues.isEmpty)
        #expect(output.proposals.count == 1)
        #expect(output.proposals[0].desiredEnabled == false)
    }

    @Test func disabledClientBindingsRemainPortableButDoNotCreateCurrentDeviceAssignments() throws {
        for enabled: Bool? in [true, false, nil] {
            let fixture = try Fixture(bindings: [(.claude, enabled)], enabledClients: [.codex])
            let output = try WorkspaceNativePluginAssignmentMigration.preview(candidate: fixture.candidate, placements: [])
            #expect(output.proposals.isEmpty)
            #expect(output.issues.isEmpty)
            #expect(fixture.candidate.document.configurationState?.configurations[0].targetBindings?.first?.enabled == enabled)

            let supplied = try WorkspaceNativePluginAssignmentMigration.preview(
                candidate: fixture.candidate, placements: [fixture.placement(.claude)])
            #expect(supplied.proposals.isEmpty)
            #expect(supplied.issues.map(\.kind) == [.unusedPlacement])
        }
    }

    @Test func placementMustSupplyScopeProjectAndExactClientRoute() throws {
        let fixture = try Fixture(bindings: [(.claude, true)])
        let invalidScope = try WorkspaceNativePluginAssignmentMigration.preview(
            candidate: fixture.candidate, placements: [.init(artifactID: fixture.pluginID, client: .claude, scope: .workspace)])
        #expect(invalidScope.proposals.isEmpty)
        #expect(invalidScope.issues.map(\.kind) == [.invalidScope])

        let project = try Fixture(bindings: [(.claude, true)], includeProject: true)
        let missingProject = try WorkspaceNativePluginAssignmentMigration.preview(
            candidate: project.candidate, placements: [.init(artifactID: project.pluginID, client: .claude, scope: .project)])
        #expect(missingProject.issues.map(\.kind) == [.invalidProject])
        let validProject = try WorkspaceNativePluginAssignmentMigration.preview(
            candidate: project.candidate, placements: [project.placement(.claude, scope: .project, projectID: project.projectID)])
        #expect(validProject.issues.isEmpty)
        #expect(validProject.proposals.first?.destination.logicalProjectID == project.projectID)

        let noRouteFixture = try Fixture(bindings: [(.codex, true)], routeClients: [.claude])
        let noCodexRoute = try WorkspaceNativePluginAssignmentMigration.preview(
            candidate: noRouteFixture.candidate, placements: [noRouteFixture.placement(.codex)])
        #expect(noCodexRoute.proposals.isEmpty)
        #expect(noCodexRoute.issues.map(\.kind) == [.missingNativeRoute])
    }

    @Test func unresolvedPluginReferencesDoNotCreateNativeAssignments() throws {
        let fixture = try Fixture(bindings: [(.claude, true)])
        var state = try #require(fixture.candidate.document.configurationState)
        state.configurations[0].targetBindings = [
            .init(item: .init(legacy: .init(domain: .plugin, identifier: "unknown"), resolution: .unresolved), client: .claude, enabled: true),
        ]
        state.identityMap.append(.init(legacy: .init(domain: .plugin, identifier: "unknown"),
            objectID: Self.object("00000000-0000-0000-0000-000000000108")))
        var document = fixture.candidate.document
        document.configurationState = state
        document = try WorkspaceDocumentCoding.seal(document)
        let candidate = WorkspaceMigrationCandidate(document: document, device: fixture.candidate.device,
            content: [:], legacySnapshot: fixture.candidate.legacySnapshot)

        let output = try WorkspaceNativePluginAssignmentMigration.preview(candidate: candidate, placements: [])
        #expect(output.proposals.isEmpty)
        #expect(output.issues.map(\.kind) == [.unresolvedPluginBinding])
    }

    @Test func nativeChildBindingDoesNotBecomeAnIndependentAssignment() throws {
        let fixture = try Fixture(bindings: [(.claude, true)])
        let childID = Self.artifact("00000000-0000-0000-0000-000000000107")
        let childReference = WorkspaceReference(
            legacy: .init(domain: .plugin, identifier: "browser-child"), resolution: .artifact(childID))
        var document = fixture.candidate.document
        var child = ArtifactRecord(identity: .init(id: childID, kind: .nativePlugin, displayName: "Child",
            parentPackageID: fixture.pluginID), authority: .nativeOwned, packageRelativePath: "children/browser")
        child.declaredName = "browser-child"
        document.artifacts.append(child)
        document.configurationState?.configurations[0].targetBindings = [
            .init(item: childReference, client: .claude, enabled: true),
        ]
        document.configurationState?.identityMap.append(.init(
            legacy: childReference.legacy, objectID: WorkspaceObjectID(childID.rawValue)))
        document = try WorkspaceDocumentCoding.seal(document)
        let candidate = WorkspaceMigrationCandidate(document: document, device: fixture.candidate.device,
            content: [:], legacySnapshot: fixture.candidate.legacySnapshot)
        let output = try WorkspaceNativePluginAssignmentMigration.preview(candidate: candidate,
            placements: [.init(artifactID: childID, client: .claude, scope: .user)])
        #expect(output.proposals.isEmpty)
        #expect(output.issues.map(\.kind) == [.nativeChild, .unusedPlacement])
    }

    private struct Fixture {
        let workspaceID = WorkspaceNativePluginAssignmentMigrationTests.object("00000000-0000-0000-0000-000000000101")
        let deviceID = WorkspaceNativePluginAssignmentMigrationTests.object("00000000-0000-0000-0000-000000000102")
        let configurationID = WorkspaceNativePluginAssignmentMigrationTests.object("00000000-0000-0000-0000-000000000103")
        let pluginID = WorkspaceNativePluginAssignmentMigrationTests.artifact("00000000-0000-0000-0000-000000000104")
        let projectID = WorkspaceNativePluginAssignmentMigrationTests.artifact("00000000-0000-0000-0000-000000000105")
        let candidate: WorkspaceMigrationCandidate

        init(
            bindings: [(ClientKind, Bool?)]?, enabledPlugin: Bool = true, includeProject: Bool = false,
            routeClients: Set<ClientKind> = Set(ClientKind.allCases), enabledClients: Set<ClientKind> = Set(ClientKind.allCases)
        ) throws {
            let pluginReference = WorkspaceReference(
                legacy: .init(domain: .plugin, identifier: "browser"), resolution: .artifact(pluginID))
            let configurationReference = WorkspaceReference(
                legacy: .init(domain: .configuration, identifier: "active"), resolution: .object(configurationID))
            let configuredBindings: [WorkspaceConfigurationTargetBinding]? = bindings.map { values in
                values.map { .init(item: pluginReference, client: $0.0, enabled: $0.1) }
            }
            let configuration = WorkspaceConfigurationRecord(id: configurationID, name: "Active",
                enabledPlugins: enabledPlugin ? [pluginReference] : [], targetBindings: configuredBindings)
            let state = WorkspaceConfigurationState(configurations: [configuration], identityMap: [
                .init(legacy: configurationReference.legacy, objectID: configurationID),
                .init(legacy: pluginReference.legacy, objectID: WorkspaceObjectID(pluginID.rawValue)),
            ], defaultConfigurationID: configurationID)
            let native = ArtifactRecord(identity: .init(id: pluginID, kind: .nativePlugin, displayName: "Browser"),
                authority: .nativeOwned, nativeRoutes: ClientKind.allCases.filter(routeClients.contains).map {
                    .init(client: $0, externalPluginID: "browser-\($0.rawValue)")
                })
            let projects = includeProject ? [LogicalProjectRecord(id: projectID, name: "Project")] : []
            let projectArtifacts = includeProject ? [ArtifactRecord(
                identity: .init(id: projectID, kind: .logicalProject, displayName: "Project"), authority: .trackedOnly
            )] : []
            var document = PortableWorkspaceDocument(workspaceID: workspaceID,
                revision: .init(writerID: WorkspaceNativePluginAssignmentMigrationTests.object("00000000-0000-0000-0000-000000000106")), artifacts: [native] + projectArtifacts,
                logicalProjects: projects, configurationState: state)
            document = try WorkspaceDocumentCoding.seal(document)
            let device = DeviceWorkspaceState(workspaceID: workspaceID, deviceID: deviceID,
                configurationState: .init(activeConfigurationOverrideID: configurationID),
                applicationState: .init(preferences: .init(enabledClients: Array(enabledClients))),
                projectRoots: includeProject ? [.init(projectID: projectID, rootPath: "/private/project")] : [])
            try device.validateStructure(against: document)
            candidate = .init(document: document, device: device, content: [:],
                legacySnapshot: .init(activeProfileID: "", preferences: .init(enabledClients: enabledClients)))
        }

        func placement(_ client: ClientKind, scope: ToolingScope = .user, projectID: ArtifactID? = nil) -> WorkspaceNativePluginMigrationPlacement {
            .init(artifactID: pluginID, client: client, scope: scope, logicalProjectID: projectID)
        }
    }

    private static func object(_ value: String) -> WorkspaceObjectID { WorkspaceObjectID(UUID(uuidString: value)!) }
    private static func artifact(_ value: String) -> ArtifactID { ArtifactID(UUID(uuidString: value)!) }
}
