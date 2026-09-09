import Foundation
import Testing

@testable import AgentToolingCore

struct WorkspaceSkillAssignmentMigrationTests {
    @Test func nilBindingsUseTheOwnedSkillsProjectScopeEvenWhenUnlisted() throws {
        let root = "/private/tmp/skill-project"
        let snapshot = WorkspaceSnapshot(
            skills: [skill("owned", scope: "Project", projectRoot: root, clients: [.codex])],
            profiles: [profile("active")],
            activeProfileID: "active"
        )
        let projectID = ArtifactID()
        let candidate = try candidate(snapshot, project: .init(
            project: .init(id: projectID, name: "Project"), rootPath: root
        ))
        let artifactID = try #require(candidate.document.artifacts.first { $0.identity.kind == .skill }?.identity.id)

        let preview = try WorkspaceSkillAssignmentMigration.preview(
            candidate: candidate, projectIDsBySkillID: [artifactID: projectID]
        )

        #expect(preview.canMigrate)
        #expect(preview.assignments.count == 1)
        #expect(preview.assignments[0].destination == .init(
            surface: .codexCLI, scope: .project, logicalProjectID: projectID, deviceIDs: [candidate.device.deviceID]
        ))
        #expect(preview.assignments[0].desiredEnabled == nil)
        #expect(preview.assignments[0].reason == .manual)
        #expect(preview.deploymentNames == [artifactID: "owned"])
    }

    @Test func nearestExplicitBindingsRetainTrueFalseAndUnknownButDeployOnlyTrue() throws {
        let snapshot = WorkspaceSnapshot(
            skills: [skill("owned", clients: [.claude, .codex, .gemini])],
            profiles: [
                profile("parent", skills: ["owned"], bindings: [binding(.claude, true)]),
                profile("child", parent: "parent", skills: ["owned"], bindings: [
                    binding(.claude, nil), binding(.codex, false), binding(.gemini, true),
                ]),
            ],
            activeProfileID: "child",
            preferences: .init(enabledClients: [.claude, .codex, .gemini])
        )
        let candidate = try candidate(snapshot)
        let preview = try WorkspaceSkillAssignmentMigration.preview(candidate: candidate)

        #expect(preview.canMigrate)
        #expect(preview.assignments.map(\.destination.surface) == [.geminiCLI])
        #expect(preview.assignments.map(\.desiredEnabled) == [true])
        let activeID = try #require(candidate.device.configurationState?.activeConfigurationOverrideID)
        #expect(preview.assignments.map(\.reason) == [.onboarding(configurationID: activeID)])
    }

    @Test func explicitEmptyBindingsSuppressTheLegacyFallback() throws {
        let snapshot = WorkspaceSnapshot(
            skills: [skill("owned", clients: [.codex])],
            profiles: [profile("active", bindings: [])],
            activeProfileID: "active"
        )
        let candidate = try candidate(snapshot)
        let preview = try WorkspaceSkillAssignmentMigration.preview(candidate: candidate)

        #expect(preview.canMigrate)
        #expect(preview.assignments.isEmpty)
    }

    @Test func projectScopeRequiresAnExplicitLogicalProjectMapping() throws {
        let root = "/private/tmp/mapping-required"
        let snapshot = WorkspaceSnapshot(
            skills: [skill("owned", scope: "Project", projectRoot: root, clients: [.codex])],
            profiles: [profile("active")], activeProfileID: "active"
        )
        let candidate = try candidate(snapshot)
        let preview = try WorkspaceSkillAssignmentMigration.preview(candidate: candidate)

        #expect(preview.assignments.isEmpty)
        #expect(preview.issues == [.init(legacySkillID: "owned", kind: .missingProjectMapping)])
    }

    @Test func nonOwnedTrackedSkillDoesNotBecomeACentralAssignment() throws {
        let snapshot = WorkspaceSnapshot(
            skills: [skill("upstream", owned: false, clients: [.codex])],
            profiles: [profile("active")], activeProfileID: "active"
        )
        let candidate = try candidate(snapshot, owned: false)
        let before = try AgentToolingCoding.encoder().encode(candidate.legacySnapshot)
        let first = try WorkspaceSkillAssignmentMigration.preview(candidate: candidate)
        let second = try WorkspaceSkillAssignmentMigration.preview(candidate: candidate)

        #expect(first.assignments.isEmpty)
        #expect(first.assignments == second.assignments)
        #expect(first.deploymentNames == second.deploymentNames)
        #expect(first.issues == second.issues)
        #expect(try AgentToolingCoding.encoder().encode(candidate.legacySnapshot) == before)
    }

    @Test func retriesAreStableAndExistingAssignmentsAreNotProposedAgain() throws {
        let original = try candidate(.init(skills: [skill("owned", clients: [.codex])], activeProfileID: ""))
        let first = try WorkspaceSkillAssignmentMigration.preview(candidate: original)
        #expect(first.assignments.count == 1)
        #expect(try WorkspaceSkillAssignmentMigration.preview(candidate: original).assignments == first.assignments)
        var document = original.document
        document.assignments = first.assignments
        document = try WorkspaceDocumentCoding.seal(document)
        let replay = WorkspaceMigrationCandidate(document: document, device: original.device,
            content: original.content, legacySnapshot: original.legacySnapshot)
        let second = try WorkspaceSkillAssignmentMigration.preview(candidate: replay)
        #expect(second.canMigrate)
        #expect(second.assignments.isEmpty)

        document.assignments[0].desiredEnabled = false
        document = try WorkspaceDocumentCoding.seal(document)
        let changed = WorkspaceMigrationCandidate(document: document, device: original.device,
            content: original.content, legacySnapshot: original.legacySnapshot)
        let conflict = try WorkspaceSkillAssignmentMigration.preview(candidate: changed)
        #expect(!conflict.canMigrate)
        #expect(conflict.assignments.isEmpty)
        #expect(conflict.issues.map(\.kind) == [.existingAssignmentConflict])
    }

    @Test func oldOwnedFlagCannotExtractANativePluginChild() throws {
        let context = WorkspaceMigrationContext(workspaceID: WorkspaceObjectID(), deviceID: WorkspaceObjectID(),
            revision: .init(writerID: WorkspaceObjectID()))
        let keys: Set<LegacyReferenceKey> = [.init(domain: .skill, identifier: "owned"), .init(domain: .plugin, identifier: "native")]
        let mapping = try WorkspaceMigrationIdentity.mapping(keys: keys, workspaceID: context.workspaceID)
        let skillID = ArtifactID(try #require(mapping.first { $0.legacy.domain == .skill }?.objectID.rawValue))
        let pluginID = ArtifactID(try #require(mapping.first { $0.legacy.domain == .plugin }?.objectID.rawValue))
        let plugin = Plugin(id: "native", name: "Native", summary: "Whole native plugin", source: "Codex",
            scope: "This Mac", revision: "current", skills: ["owned"], profiles: [],
            clients: [.init(client: .codex, state: .healthy, detail: "Found", isInstalled: true)], installed: true)
        let observation = TargetObservation(surface: .codexCLI, installed: true,
            discoveredSkills: ["owned"], discoveredPlugins: ["native"],
            skillMetadata: ["owned": .init(path: "/private/native/skills/owned", source: "Native", providerPluginID: "native")],
            pluginMetadata: ["native": .init(name: "Native", source: "/private/native", scope: "This Mac", enabled: true, skillIDs: ["owned"])],
            capabilities: .init(supportsPluginInstall: true, supportsProjectScope: true, supportsLocalMarketplace: true,
                supportsMCPAuthentication: false, supportsConnectorDiscovery: false, requiresNewSession: true,
                requiresRestart: false, supportsMachineReadableOutput: true))
        let snapshot = WorkspaceSnapshot(skills: [skill("owned", clients: [.codex])], plugins: [plugin],
            targetObservations: [observation], activeProfileID: "")
        var decisions = WorkspaceMigrationDecisions()
        decisions.artifacts = [
            .init(legacy: .init(domain: .plugin, identifier: "native"), artifact: .init(
                identity: .init(id: pluginID, kind: .nativePlugin, displayName: "Native"), authority: .nativeOwned,
                nativeRoutes: [.init(client: .codex, externalPluginID: "native")])),
            .init(legacy: .init(domain: .skill, identifier: "owned"), artifact: .init(
                identity: .init(id: skillID, kind: .skill, displayName: "Owned", parentPackageID: pluginID),
                authority: .nativeOwned, packageRelativePath: "skills/owned")),
        ]
        let assembly = WorkspaceMigrationAssembly.preview(snapshot: snapshot, context: context, decisions: decisions)
        let migrated = try #require(assembly.candidate)
        let preview = try WorkspaceSkillAssignmentMigration.preview(candidate: migrated)
        #expect(preview.assignments.isEmpty)
        #expect(preview.deploymentNames.isEmpty)
        #expect(preview.issues.map(\.kind) == [.packageChildRequiresReview])
        #expect(migrated.content.isEmpty)
    }

    @MainActor @Test(arguments: [ToolingScope.user, .project], ["fallback", "empty", "explicit"])
    func migratedRequirementsMatchActualLegacySyncDestinations(_ scope: ToolingScope, _ selection: String) async throws {
        let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
            .appending(path: "assignment-parity-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let home = root.appending(path: "home")
        let project = root.appending(path: "project")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        let store = try WorkspaceStore(rootURL: root.appending(path: "store"))
        let model = try AppModel(store: store, runner: NoCommands(), homeURL: home)
        var draft = SkillDraft()
        draft.name = "owned"
        draft.purpose = "Review documents."
        draft.triggers = ["Review a document"]
        draft.negativeTrigger = "Do not use for unrelated work."
        draft.selectedTargets = Set(ClientKind.allCases)
        draft.scope = scope
        draft.projectRoot = scope == .project ? project.path : ""
        draft.syncClients = false
        let created = try model.library.createSkill(from: draft)
        let bindings: [OnboardingTargetBinding]?
        switch selection {
        case "empty": bindings = []
        case "explicit": bindings = [binding(.claude, false), binding(.codex, true), binding(.gemini, nil)]
        default: bindings = nil
        }
        let snapshot = WorkspaceSnapshot(skills: [created.skill],
            profiles: [profile("active", skills: selection == "fallback" ? [] : ["owned"], bindings: bindings)],
            activeProfileID: "active", preferences: .init(enabledClients: Set(ClientKind.allCases)))
        model.skills = snapshot.skills
        model.profiles = snapshot.profiles
        model.activeProfileID = snapshot.activeProfileID
        model.enabledClients = snapshot.preferences.enabledClients
        await model.runSync()
        let old = try #require(model.pendingPlan)
        let oldDestinations = Set(old.steps.compactMap { $0.kind == .copyDirectory ? $0.destinationPath : nil }
            .map { URL(fileURLWithPath: $0).path })
        let projectID = ArtifactID()
        let tree = try await PackageTreeCapture().capture(directory: model.library.skillURL(for: created.skill))
        let candidate = try candidate(snapshot, project: scope == .project ? .init(
            project: .init(id: projectID, name: "Project"), rootPath: project.path) : nil, content: tree)
        let skillID = try #require(candidate.document.artifacts.first { $0.identity.kind == .skill }?.identity.id)
        let preview = try WorkspaceSkillAssignmentMigration.preview(candidate: candidate,
            projectIDsBySkillID: scope == .project ? [skillID: projectID] : [:])
        #expect(preview.canMigrate)
        let capabilities = TargetCapabilities(supportsPluginInstall: false, supportsProjectScope: false,
            supportsLocalMarketplace: false, supportsMCPAuthentication: false, supportsConnectorDiscovery: false,
            requiresNewSession: false, requiresRestart: false, supportsMachineReadableOutput: false)
        let surfaces: [TargetSurface] = [.claudeCode, .codexCLI, .geminiCLI]
        let captured = try await WorkspaceSkillTargetCapture.capture(homeURL: home, deviceID: candidate.device.deviceID,
            selectors: Array(Set(preview.assignments.map { ResolvedAssignmentSelector(destination: $0.destination) })),
            projectRoots: candidate.device.projectRoots ?? [],
            observations: surfaces.map { .init(surface: $0, installed: true, version: "fixture-1", capabilities: capabilities) })
        let resolved = WorkspaceAssignmentResolver.resolve(artifacts: candidate.document.artifacts,
            contributions: preview.assignments, currentDeviceID: candidate.device.deviceID,
            targets: captured.map(\.target), capabilityEvidence: surfaces.map {
                .init(surface: $0, installedClientVersion: "fixture-1",
                    adapterContractVersion: WorkspaceSkillTargetCapture.adapterContractVersion,
                    component: .skill, scopes: [.user, .project], support: .supported, observedAt: .now)
            }, contentEvidence: candidate.content.map { .init(artifactID: $0.key, digest: $0.value.digest) })
        #expect(resolved.issues.isEmpty)
        let newDestinations = try Set(resolved.requirements.map { requirement in
            let target = try #require(captured.first { $0.target.physicalDestinationID == requirement.physicalDestinationID })
            let name = try #require(preview.deploymentNames[requirement.artifactID])
            return target.plannedDirectory.appending(path: name).path
        })
        #expect(newDestinations == oldDestinations)
        #expect(oldDestinations.count == (selection == "empty" ? 0 : selection == "explicit" ? 1 : 3))
        for path in newDestinations { #expect(!FileManager.default.fileExists(atPath: path)) }
    }

    private struct NoCommands: CommandRunning {
        func run(executable: String, arguments: [String], currentDirectory: URL?) async throws -> CommandOutput {
            Issue.record("Migration preview must not run a native command")
            return .init(status: 1, standardOutput: "", standardError: "Unexpected command")
        }
    }

    private func candidate(
        _ snapshot: WorkspaceSnapshot,
        owned: Bool = true,
        project: WorkspaceMCPMigrationProject? = nil,
        content: CapturedPackageTree? = nil
    ) throws -> WorkspaceMigrationCandidate {
        let context = WorkspaceMigrationContext(
            workspaceID: WorkspaceObjectID(UUID(uuidString: "00000000-0000-0000-0000-000000000001")!),
            deviceID: WorkspaceObjectID(UUID(uuidString: "00000000-0000-0000-0000-000000000002")!),
            revision: .init(writerID: WorkspaceObjectID(UUID(uuidString: "00000000-0000-0000-0000-000000000003")!))
        )
        let tree = try content ?? CapturedPackageTree(entries: [
            .init(relativePath: "SKILL.md", kind: .file(bytes: Data("skill".utf8), executable: false)),
        ])
        let id = ArtifactID(try #require(WorkspaceMigrationIdentity.mapping(
            keys: [.init(domain: .skill, identifier: snapshot.skills[0].id)], workspaceID: context.workspaceID
        ).first?.objectID.rawValue))
        var decisions = WorkspaceMigrationDecisions()
        decisions.artifacts = [.init(
            legacy: .init(domain: .skill, identifier: snapshot.skills[0].id),
            artifact: .init(identity: .init(id: id, kind: .skill, displayName: "Owned"),
                authority: owned ? .centralPersonal : .trackedOnly,
                contentDigest: owned ? tree.digest : nil)
        )]
        if owned { decisions.rootContent = [id: tree] }
        if let project { decisions.projects = [project] }
        return try #require(WorkspaceMigrationAssembly.preview(
            snapshot: snapshot, context: context, decisions: decisions
        ).candidate)
    }

    private func skill(_ id: String, owned: Bool = true, scope: String = "This Mac", projectRoot: String? = nil, clients: Set<ClientKind>) -> Skill {
        .init(id: id, name: id, displayName: id, summary: "", bundle: "standalone", scope: scope,
            owned: owned, triggers: [], negativeTrigger: "", files: ["SKILL.md"],
            clients: clients.map { .init(client: $0, state: .healthy, detail: "Found", isInstalled: true) },
            validationCount: 0, projectRoot: projectRoot)
    }

    private func profile(_ id: String, parent: String? = nil, skills: [String] = [], bindings: [OnboardingTargetBinding]? = nil) -> ToolingProfile {
        .init(id: id, name: id, summary: "", inheritedFrom: parent, scope: .user, checks: [], enabledPlugins: [],
            requiredMCPs: [], requiredSkills: skills, targetBindings: bindings)
    }

    private func binding(_ client: ClientKind, _ enabled: Bool?) -> OnboardingTargetBinding {
        .init(item: .init(kind: .skill, identifier: "owned"), client: client, enabled: enabled)
    }
}
