import Foundation
import Testing
@testable import AgentToolingCore

struct WorkspaceMigrationNativePlacementIntakeTests {
    @Test(arguments: ["user", "User", "This Mac"])
    func legacyNativeUserTokensRemainAutomatic(token: String) throws {
        let result = try review(fixture(scope: token))
        #expect(result.placements.map(\.scope) == [.user])
        #expect(result.requirements.isEmpty)
    }

    @Test(arguments: ["local", "Local", "localProject", "This project only"])
    func legacyNativeLocalTokensRequireProjectConfirmation(token: String) throws {
        let project = projectFixture(id: "00000000-0000-0000-0000-000000000201", name: "Local", root: "/private/project")
        let result = try review(fixture(scope: token), projects: [project])
        #expect(result.placements.isEmpty)
        #expect(result.requirements.first?.observedScope == .localProject)
        #expect(result.requirements.first?.candidates.first?.scope == .localProject)
    }

    @Test func uniquelyObservedUserPlacementIsAcceptedAutomatically() throws {
        let result = try review(fixture(scope: "This Mac"))

        let placement = try #require(result.placements.first)
        #expect(result.requirements.isEmpty)
        #expect(placement.client == .claude)
        #expect(placement.scope == .user)
        #expect(placement.logicalProjectID == nil)
        #expect(result.selections.isEmpty)
        #expect(result.selectedProjectIDs.isEmpty)
    }

    @Test func forcedUserReviewRequiresTheCurrentExplicitCandidate() throws {
        let project = try review(fixture(scope: "project"))
        let requirementID = try #require(project.requirements.first?.id)

        let pending = try review(fixture(scope: "This Mac"), requiringReview: [requirementID])
        let requirement = try #require(pending.requirements.first)
        #expect(pending.placements.isEmpty)

        let selected = try review(
            fixture(scope: "This Mac"),
            selections: [requirement.id: try #require(pending.requirements.first?.candidates.first?.id)],
            requiringReview: [requirement.id]
        )
        #expect(selected.placements.map(\.scope) == [.user])
    }

    @Test(arguments: [ToolingScope.project, .localProject])
    func projectScopesRequireOneReviewedProjectSelection(scope: ToolingScope) throws {
        let project = projectFixture(id: "00000000-0000-0000-0000-000000000201", name: "Alpha", root: "/private/projects/alpha")
        let pending = try review(fixture(scope: scope.rawValue), projects: [project])
        let requirement = try #require(pending.requirements.first)
        let candidate = try #require(requirement.candidates.first)

        #expect(pending.placements.isEmpty)
        #expect(candidate.scope == scope)
        #expect(candidate.projectID == project.project.id)
        #expect(candidate.rootPath == project.rootPath)

        let selected = try review(fixture(scope: scope.rawValue), projects: [project], selections: [requirement.id: candidate.id])
        let placement = try #require(selected.placements.first)
        #expect(placement.scope == scope)
        #expect(placement.logicalProjectID == project.project.id)
        #expect(selected.selectedProjectIDs == [project.project.id])
    }

    @Test func noIntentAndDisabledClientCreateNoRequirement() throws {
        var noBinding = fixture(scope: "This Mac")
        noBinding.snapshot.profiles[0].targetBindings = nil
        #expect(try review(noBinding).requirements.isEmpty)

        var excluded = fixture(scope: "This Mac")
        excluded.snapshot.preferences.enabledClients = []
        #expect(try review(excluded).requirements.isEmpty)
    }

    @Test func unknownConflictingAndMissingEvidenceRemainNamedWithoutCandidates() throws {
        var unknown = fixture(scope: "mystery")
        var result = try review(unknown)
        #expect(result.requirements.count == 1)
        #expect(result.requirements[0].displayName == "Browser")
        #expect(result.requirements[0].observedScope == nil)
        #expect(result.requirements[0].candidates.isEmpty)
        #expect(result.placements.isEmpty)

        unknown.snapshot.targetObservations.append(observation(scope: "Project", source: "/private/other"))
        result = try review(unknown)
        #expect(result.requirements[0].candidates.isEmpty)

        var missingRoute = fixture(scope: "This Mac")
        missingRoute.choices = [.init(legacy: Self.pluginKey, strategy: .nativePackage(routes: [], children: []))]
        result = try review(missingRoute)
        #expect(result.requirements[0].candidates.isEmpty)

        var wrongRoute = fixture(scope: "This Mac")
        wrongRoute.choices = [.init(legacy: Self.pluginKey, strategy: .nativePackage(
            routes: [.init(client: .claude, externalPluginID: "different")], children: []
        ))]
        result = try review(wrongRoute)
        #expect(result.requirements[0].candidates.isEmpty)

        var missingMetadata = fixture(scope: "This Mac")
        missingMetadata.snapshot.targetObservations[0].pluginMetadata = [:]
        result = try review(missingMetadata)
        #expect(result.requirements[0].candidates.isEmpty)
        missingMetadata.snapshot.targetObservations.append(observation(scope: "This Mac", source: "/private/native/browser"))
        result = try review(missingMetadata)
        #expect(result.requirements[0].candidates.isEmpty)
        #expect(result.placements.isEmpty)
    }

    @Test func staleSelectionCannotSurviveChangedEvidenceProjectOrDesiredFlag() throws {
        let firstProject = projectFixture(id: "00000000-0000-0000-0000-000000000201", name: "Alpha", root: "/private/projects/alpha")
        let initial = try review(fixture(scope: "project"), projects: [firstProject])
        let requirement = try #require(initial.requirements.first)
        let selection = try #require(requirement.candidates.first?.id)

        var changedEvidence = fixture(scope: "project")
        changedEvidence.snapshot.targetObservations[0].pluginMetadata["browser"]?.revision = "new-revision"
        #expect(try review(changedEvidence, projects: [firstProject], selections: [requirement.id: selection]).placements.isEmpty)

        let renamed = projectFixture(id: "00000000-0000-0000-0000-000000000201", name: "Renamed", root: "/private/projects/renamed")
        #expect(try review(fixture(scope: "project"), projects: [renamed], selections: [requirement.id: selection]).placements.isEmpty)

        var changedIntent = fixture(scope: "project")
        changedIntent.snapshot.profiles[0].targetBindings = [binding(enabled: false)]
        #expect(try review(changedIntent, projects: [firstProject], selections: [requirement.id: selection]).placements.isEmpty)
    }

    @Test func activeConfigurationRootChangeInvalidatesAnOtherwiseAvailableCandidate() throws {
        let project = projectFixture(id: "00000000-0000-0000-0000-000000000201", name: "Alpha",
                                     root: "/private/projects/alpha")
        var initialFixture = fixture(scope: "project")
        initialFixture.snapshot.profiles[0].scope = .project
        initialFixture.snapshot.profiles[0].projectRoot = "/private/projects/alpha"
        let initial = try review(initialFixture, projects: [project])
        let requirement = try #require(initial.requirements.first)
        let oldCandidate = try #require(requirement.candidates.first?.id)

        var changed = initialFixture
        changed.snapshot.profiles[0].projectRoot = "/private/projects/beta"
        let refreshed = try review(changed, projects: [project], selections: [requirement.id: oldCandidate])

        #expect(refreshed.requirements.first?.candidates.count == 1)
        #expect(refreshed.requirements.first?.candidates.first?.projectID == project.project.id)
        #expect(refreshed.requirements.first?.candidates.first?.id != oldCandidate)
        #expect(refreshed.placements.isEmpty)
        #expect(refreshed.selections.isEmpty)
    }

    @Test func changingInheritedBindingOriginInvalidatesTheSameEffectiveBinding() throws {
        let project = projectFixture(id: "00000000-0000-0000-0000-000000000201", name: "Alpha",
                                     root: "/private/projects/alpha")
        var initialFixture = fixture(scope: "project")
        let inheritedBinding = binding(enabled: true)
        initialFixture.snapshot.profiles = [
            .init(id: "base-a", name: "Base A", summary: "", checks: [], enabledPlugins: [], requiredMCPs: [],
                  targetBindings: [inheritedBinding]),
            .init(id: "base-b", name: "Base B", summary: "", checks: [], enabledPlugins: [], requiredMCPs: [],
                  targetBindings: [inheritedBinding]),
            .init(id: "active", name: "Active", summary: "", inheritedFrom: "base-a", scope: .project,
                  projectRoot: "/private/projects/alpha", checks: [], enabledPlugins: [], requiredMCPs: [],
                  targetBindings: nil),
        ]
        let initial = try review(initialFixture, projects: [project])
        let requirement = try #require(initial.requirements.first)
        let oldCandidate = try #require(requirement.candidates.first?.id)

        var changed = initialFixture
        changed.snapshot.profiles[2].inheritedFrom = "base-b"
        let refreshed = try review(changed, projects: [project], selections: [requirement.id: oldCandidate])

        #expect(refreshed.requirements.first?.candidates.first?.id != oldCandidate)
        #expect(refreshed.placements.isEmpty)
        #expect(refreshed.selections.isEmpty)
    }

    @Test func observedProjectChangingToUserDoesNotAutoAcceptWhenReviewPersists() throws {
        let project = projectFixture(id: "00000000-0000-0000-0000-000000000201", name: "Alpha", root: "/private/projects/alpha")
        let old = try review(fixture(scope: "project"), projects: [project])
        let requirementID = try #require(old.requirements.first?.id)
        let oldCandidate = try #require(old.requirements.first?.candidates.first?.id)

        let changed = try review(
            fixture(scope: "This Mac"), projects: [project],
            selections: [requirementID: oldCandidate], requiringReview: [requirementID]
        )
        #expect(changed.placements.isEmpty)
        #expect(changed.requirements[0].observedScope == .user)
        #expect(changed.requirements[0].candidates[0].id != oldCandidate)
    }

    @Test func requirementIdentityIsStableAndSourcePathNeverBecomesProjectRoot() throws {
        let first = try review(fixture(scope: "project", source: "/native/package/not-a-project"))
        let second = try review(fixture(scope: "project", source: "/different/native/package"))
        #expect(first.requirements[0].id == second.requirements[0].id)
        #expect(first.requirements[0].candidates.isEmpty)
        #expect(second.requirements[0].candidates.isEmpty)
    }

    @Test func duplicateOrInvalidReviewedProjectsAreRejected() throws {
        let first = projectFixture(id: "00000000-0000-0000-0000-000000000201", name: "Alpha", root: "/private/projects/alpha")
        let sameID = projectFixture(id: "00000000-0000-0000-0000-000000000201", name: "Beta", root: "/private/projects/beta")
        #expect(throws: WorkspaceMigrationNativePlacementIntakeError.duplicateProjectID) {
            try review(fixture(scope: "project"), projects: [first, sameID])
        }

        let sameRoot = projectFixture(id: "00000000-0000-0000-0000-000000000202", name: "Beta", root: first.rootPath)
        #expect(throws: WorkspaceMigrationNativePlacementIntakeError.duplicateProjectRoot) {
            try review(fixture(scope: "project"), projects: [first, sameRoot])
        }
        let sameName = projectFixture(id: "00000000-0000-0000-0000-000000000204", name: first.project.name,
                                      root: "/private/projects/gamma")
        let equalNames = try review(fixture(scope: "project"), projects: [first, sameName])
        #expect(Set(equalNames.requirements.first?.candidates.compactMap(\.projectID) ?? [])
            == [first.project.id, sameName.project.id])
        let relative = projectFixture(id: "00000000-0000-0000-0000-000000000203", name: "Bad", root: "relative")
        #expect(throws: WorkspaceMigrationNativePlacementIntakeError.invalidProject) {
            try review(fixture(scope: "project"), projects: [relative])
        }
    }
}

private extension WorkspaceMigrationNativePlacementIntakeTests {
    static let workspaceID = WorkspaceObjectID(UUID(uuidString: "00000000-0000-0000-0000-000000000101")!)
    static let pluginKey = LegacyReferenceKey(domain: .plugin, identifier: "browser")

    struct Fixture {
        var snapshot: WorkspaceSnapshot
        var choices: [WorkspaceMigrationInventoryChoice]
    }

    func fixture(scope: String, source: String = "/private/native/browser") -> Fixture {
        let snapshot = WorkspaceSnapshot(
            plugins: [.init(id: "browser", name: "Browser", summary: "Native package", source: "Catalog",
                            scope: "This Mac", revision: "current", skills: [], profiles: [], clients: [], installed: true)],
            profiles: [.init(id: "active", name: "Active", summary: "", checks: [], enabledPlugins: [],
                             requiredMCPs: [], targetBindings: [binding(enabled: true)])],
            targetObservations: [observation(scope: scope, source: source)],
            activeProfileID: "active",
            preferences: .init(enabledClients: [.claude])
        )
        return .init(snapshot: snapshot, choices: [.init(
            legacy: Self.pluginKey,
            strategy: .nativePackage(routes: [.init(client: .claude, externalPluginID: "browser")], children: [])
        )])
    }

    func review(
        _ fixture: Fixture,
        projects: [WorkspaceMCPMigrationProject] = [],
        selections: [String: String] = [:],
        requiringReview: Set<String> = []
    ) throws -> WorkspaceMigrationNativePlacementIntake {
        try .review(
            intake: .init(choices: fixture.choices, issues: [], snapshot: fixture.snapshot),
            workspaceID: Self.workspaceID,
            projects: projects,
            selections: selections,
            requiringReview: requiringReview
        )
    }

    func binding(enabled: Bool?) -> OnboardingTargetBinding {
        .init(item: .init(kind: .plugin, identifier: "browser"), client: .claude, enabled: enabled)
    }

    func observation(scope: String, source: String) -> TargetObservation {
        .init(
            surface: .claudeCode,
            installed: true,
            commandAvailable: true,
            discoveredPlugins: ["browser"],
            pluginMetadata: ["browser": .init(name: "Browser", source: source, scope: scope,
                                                revision: "revision", enabled: true)],
            capabilities: .init(supportsPluginInstall: true, supportsProjectScope: true,
                                supportsLocalMarketplace: true, supportsMCPAuthentication: false,
                                supportsConnectorDiscovery: false, requiresNewSession: false,
                                requiresRestart: false, supportsMachineReadableOutput: true),
            lastScannedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
    }

    func projectFixture(id: String, name: String, root: String) -> WorkspaceMCPMigrationProject {
        .init(project: .init(id: ArtifactID(UUID(uuidString: id)!), name: name), rootPath: root)
    }
}
