import Darwin
import Foundation
import Testing
@testable import AgentToolingCore
@testable import AgentToolingApp

@MainActor
struct WorkspaceMigrationNativePlacementSetupTests {
    @Test func projectPluginNeedsExplicitPlacementAfterProjectConfirmationAndRetainsDisabledBinding() async throws {
        let fixture = try Fixture(projectScoped: true)
        defer { fixture.remove() }
        let session = WorkspaceMigrationSetupSession(location: fixture.location)
        await session.inspect()
        let projectRequirement = try #require(session.projectIntake?.requirements.first)
        session.setProjectName("Fixture project", for: projectRequirement.id)
        await session.confirmProject(projectRequirement.id)
        #expect(session.nativePlacementIntake?.requirements.count == 1)
        #expect(session.preview?.canPrepare == false)
        let requirement = try #require(session.nativePlacementIntake?.requirements.first)
        let candidate = try #require(requirement.candidates.first { $0.rootPath == fixture.projectRoot.path })
        await session.selectNativePlacement(candidate.id, for: requirement.id)
        #expect(session.nativePlacementIntake?.selections[requirement.id] == candidate.id)
        let preparation = try #require(session.preview?.preparation)
        #expect(preparation.content.isEmpty)
        #expect(preparation.record.manifest.sourceCaptures.isEmpty)
        let assignment = try #require(preparation.record.document.assignments.first)
        #expect(assignment.destination.logicalProjectID == candidate.projectID)
        #expect(assignment.destination.scope == .project && assignment.desiredEnabled == false)
        #expect(preparation.record.document.artifacts.contains { $0.identity.kind == .nativePlugin && $0.identity.parentPackageID == nil })
        #expect(preparation.record.document.artifacts.contains { $0.identity.kind == .skill && $0.identity.parentPackageID != nil })
        await session.inspect()
        #expect(session.nativePlacementIntake?.selections[requirement.id] == candidate.id)
        await session.stage()
        #expect(session.reviewSession?.state?.journalEntry.phase == .prepared)
        #expect(try String(contentsOf: fixture.nativeRoot.appending(path: "SENTINEL"), encoding: .utf8)
            == "native package sentinel\n")
    }

    @Test func changedObservationScopeOrBindingClearsNativeSelection() async throws {
        let fixture = try Fixture(projectScoped: true)
        defer { fixture.remove() }
        let session = WorkspaceMigrationSetupSession(location: fixture.location)
        await session.inspect()
        let project = try #require(session.projectIntake?.requirements.first)
        session.setProjectName("Project", for: project.id); await session.confirmProject(project.id)
        let requirement = try #require(session.nativePlacementIntake?.requirements.first)
        let candidate = try #require(requirement.candidates.first)
        await session.selectNativePlacement(candidate.id, for: requirement.id)
        #expect(session.preview?.canPrepare == true)
        try fixture.rewrite(observedScope: "This Mac", enabled: nil, root: nil)
        await session.inspect()
        #expect(session.nativePlacementIntake?.selections[requirement.id] == nil)
        #expect(session.preview?.canPrepare == false)
        let userCandidate = try #require(session.nativePlacementIntake?.requirements.first?.candidates.first)
        await session.selectNativePlacement(userCandidate.id, for: requirement.id)
        try fixture.rewrite(observedScope: nil, enabled: true, root: fixture.projectRoot.path)
        await session.inspect()
        #expect(session.nativePlacementIntake?.selections[requirement.id] == nil)
    }

    @Test func changedProjectFolderRequiresProjectAndNativeConfirmationAgain() async throws {
        let fixture = try Fixture(projectScoped: true)
        defer { fixture.remove() }
        let session = WorkspaceMigrationSetupSession(location: fixture.location)
        await session.inspect()
        let project = try #require(session.projectIntake?.requirements.first)
        session.setProjectName("Project", for: project.id)
        await session.confirmProject(project.id)
        let requirement = try #require(session.nativePlacementIntake?.requirements.first)
        let candidate = try #require(requirement.candidates.first)
        await session.selectNativePlacement(candidate.id, for: requirement.id)
        let newRoot = fixture.root.appending(path: "new-project")
        try FileManager.default.createDirectory(at: newRoot, withIntermediateDirectories: false)
        try fixture.rewrite(observedScope: nil, enabled: nil, root: newRoot.path)
        await session.inspect()
        #expect(session.nativePlacementIntake?.selections[requirement.id] == nil)
        #expect(session.nativePlacementIntake?.requirements.first?.candidates.isEmpty == true)
        #expect(session.preview?.canPrepare == false)
        let newProject = try #require(session.projectIntake?.requirements.first)
        session.setProjectName("New project", for: newProject.id)
        await session.confirmProject(newProject.id)
        let newCandidate = try #require(session.nativePlacementIntake?.requirements.first?.candidates.first)
        #expect(newCandidate.rootPath == newRoot.path)
        #expect(session.hasUnresolvedNativePlacements)
        await session.selectNativePlacement(newCandidate.id, for: requirement.id)
        #expect(session.preview?.canPrepare == true)
    }

    @Test func addNativeProjectAddsCandidateButRequiresASeparateSelection() async throws {
        let fixture = try Fixture(projectScoped: false)
        defer { fixture.remove() }
        let session = WorkspaceMigrationSetupSession(location: fixture.location)
        await session.inspect()
        let requirement = try #require(session.nativePlacementIntake?.requirements.first)
        #expect(requirement.candidates.isEmpty)
        await session.addNativeProject(root: fixture.projectRoot, for: requirement.id)
        let refreshed = try #require(session.nativePlacementIntake?.requirements.first)
        #expect(session.nativePlacementIntake?.selections[refreshed.id] == nil)
        let candidate = try #require(refreshed.candidates.first { $0.rootPath == fixture.projectRoot.path })
        await session.selectNativePlacement(candidate.id, for: refreshed.id)
        #expect(session.preview?.canPrepare == true, "\(session.preview?.issues ?? [])")
    }

    @Test func deletedOrReplacedExtraNativeProjectClearsSelectionOnInspect() async throws {
        let fixture = try Fixture(projectScoped: false)
        defer { fixture.remove() }
        let session = WorkspaceMigrationSetupSession(location: fixture.location)
        await session.inspect()
        let requirement = try #require(session.nativePlacementIntake?.requirements.first)
        await session.addNativeProject(root: fixture.projectRoot, for: requirement.id)
        let candidate = try #require(session.nativePlacementIntake?.requirements.first?.candidates.first)
        await session.selectNativePlacement(candidate.id, for: requirement.id)
        try FileManager.default.removeItem(at: fixture.projectRoot)
        await session.inspect()
        #expect(session.nativePlacementIntake?.selections[requirement.id] == nil)
        #expect(session.nativePlacementIntake?.requirements.first?.candidates.contains(where: { $0.rootPath == fixture.projectRoot.path }) == false)
        try Data("not a directory".utf8).write(to: fixture.projectRoot)
        await session.addNativeProject(root: fixture.projectRoot, for: requirement.id)
        #expect(session.nativePlacementIntake?.requirements.first?.candidates.contains(where: { $0.rootPath == fixture.projectRoot.path }) == false)
    }

    @Test func directStageAfterExtraNativeProjectDeletionDoesNotCreateReview() async throws {
        let fixture = try Fixture(projectScoped: false)
        defer { fixture.remove() }
        let session = WorkspaceMigrationSetupSession(location: fixture.location)
        await session.inspect()
        let requirement = try #require(session.nativePlacementIntake?.requirements.first)
        await session.addNativeProject(root: fixture.projectRoot, for: requirement.id)
        let candidate = try #require(session.nativePlacementIntake?.requirements.first?.candidates.first)
        await session.selectNativePlacement(candidate.id, for: requirement.id)
        #expect(session.preview?.canPrepare == true)
        try FileManager.default.removeItem(at: fixture.projectRoot)
        await session.stage()
        #expect(session.reviewSession == nil)
        #expect(session.nativeProjectErrors[requirement.id] != nil)
        #expect(session.preview?.canPrepare != true || session.hasUnresolvedNativePlacements)
    }

    @Test func exportsUnmigratedNativeProjectFixtureWhenRequested() throws {
        guard let output = ProcessInfo.processInfo.environment["WORKSPACE_MIGRATION_NATIVE_PROJECT_FIXTURE"] else { return }
        let fixture = try Fixture(projectScoped: true)
        let payload: [String: Any] = ["workspace": fixture.store.rootURL.path, "home": fixture.location.homeRoot.path,
            "project": fixture.projectRoot.path, "nativeRoot": fixture.nativeRoot.path]
        do { try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]).write(to: URL(fileURLWithPath: output), options: .withoutOverwriting) }
        catch { fixture.remove(); throw error }
    }

    private struct Fixture {
        let root: URL; let store: WorkspaceStore; let location: WorkspaceMigrationLegacyLocation
        let projectRoot: URL; let nativeRoot: URL
        init(projectScoped: Bool) throws {
            root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appending(path: "native-placement-\(UUID().uuidString)")
            store = try WorkspaceStore(rootURL: root.appending(path: "legacy"))
            let home = root.appending(path: "home"); try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            location = .init(legacyRoot: store.rootURL, homeRoot: home)
            projectRoot = root.appending(path: "project").resolvingSymlinksInPath(); nativeRoot = root.appending(path: "native-package").resolvingSymlinksInPath()
            try FileManager.default.createDirectory(at: projectRoot, withIntermediateDirectories: true); try FileManager.default.createDirectory(at: nativeRoot, withIntermediateDirectories: true)
            try Data("native package sentinel\n".utf8).write(to: nativeRoot.appending(path: "SENTINEL"))
            let skill = Skill(id: "child", name: "child", displayName: "Child", summary: "", bundle: "plugin", scope: "This Mac", owned: false, triggers: [], negativeTrigger: "", files: ["SKILL.md"], clients: [], validationCount: 0)
            let plugin = Plugin(id: "plugin", name: "Plugin", summary: "", source: "", scope: "Project", revision: "", skills: [skill.id], profiles: [], clients: [], installed: true)
            let scope: ToolingScope = projectScoped ? .project : .user
            let profile = ToolingProfile(id: "profile", name: "Profile", summary: "", scope: scope, projectRoot: projectScoped ? projectRoot.path : nil, checks: [], enabledPlugins: [plugin.id], requiredMCPs: [], targetBindings: [.init(item: .init(kind: .plugin, identifier: plugin.id), client: .claude, enabled: false)])
            let observation = TargetObservation(surface: .claudeCode, installed: true, commandAvailable: true, discoveredSkills: [skill.id], discoveredPlugins: [plugin.id], skillMetadata: [skill.id: .init(path: nativeRoot.appending(path: "skills/child/SKILL.md").path, source: "", providerPluginID: plugin.id)], pluginMetadata: [plugin.id: .init(name: "Plugin", source: nativeRoot.path, scope: "Project", enabled: false, skillIDs: [skill.id])], capabilities: .init(supportsPluginInstall: true, supportsProjectScope: true, supportsLocalMarketplace: true, supportsMCPAuthentication: false, supportsConnectorDiscovery: false, requiresNewSession: false, requiresRestart: false, supportsMachineReadableOutput: true), lastScannedAt: .now)
            var preferences = WorkspacePreferences(enabledClients: [.claude]); preferences.automaticallyCheckHealth = false
            try store.saveWorkspaceSnapshot(.init(skills: [skill], plugins: [plugin], profiles: [profile], targetObservations: [observation], activeProfileID: profile.id, preferences: preferences))
        }
        func rewrite(observedScope: String?, enabled: Bool?, root: String?) throws {
            guard var snapshot = try store.loadWorkspaceSnapshot() else { throw CocoaError(.fileNoSuchFile) }
            if let observedScope, var metadata = snapshot.targetObservations[0].pluginMetadata["plugin"] {
                metadata.scope = observedScope
                snapshot.targetObservations[0].pluginMetadata["plugin"] = metadata
            }
            if let enabled, var bindings = snapshot.profiles[0].targetBindings {
                bindings[0] = .init(item: bindings[0].item, client: bindings[0].client, enabled: enabled)
                snapshot.profiles[0].targetBindings = bindings
            }
            if let root { snapshot.profiles[0].projectRoot = root }
            try store.saveWorkspaceSnapshot(snapshot)
        }
        func remove() {
            func unlock(_ url: URL) {
                var info = stat()
                guard lstat(url.path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR else { return }
                _ = chmod(url.path, 0o700)
                for child in (try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil)) ?? [] {
                    unlock(child)
                }
            }
            unlock(root)
            try? FileManager.default.removeItem(at: root)
        }
    }
}
