import Foundation
import Testing

@testable import AgentToolingCore

struct WorkspaceMigrationAssemblyTests {
    @Test func assemblesOwnedStandaloneAndConfigurationFromOneSnapshot() throws {
        let context = fixedContext()
        let tree = try skillTree("personal")
        let skillID = try migratedID(.skill, "mine", workspaceID: context.workspaceID)
        let snapshot = WorkspaceSnapshot(
            skills: [legacySkill("mine", owned: true)],
            profiles: [profile("personal", requiredSkills: ["mine"])],
            activeProfileID: "personal")
        var decisions = WorkspaceMigrationDecisions()
        decisions.artifacts = [.init(
            legacy: key(.skill, "mine"),
            artifact: .init(
                identity: .init(id: skillID, kind: .skill, displayName: "Mine"),
                authority: .centralPersonal,
                declaredName: "mine",
                contentDigest: tree.digest))]
        decisions.rootContent = [skillID: tree]

        let output = WorkspaceMigrationAssembly.preview(
            snapshot: snapshot, context: context, decisions: decisions)
        let candidate = try #require(output.candidate)

        #expect(output.canAssemble)
        #expect(candidate.document.artifacts.first?.identity.id == skillID)
        #expect(candidate.document.configurationState?.configurations.count == 1)
        #expect(candidate.document.configurationState?.configurations[0].requiredSkills.first?.resolution == .artifact(skillID))
        #expect(candidate.device.configurationState?.activeConfigurationOverrideID
            == candidate.document.configurationState?.configurations[0].id)
        #expect(candidate.content[skillID] == tree)
        #expect(candidate.device.applicationState?.preferences.workspacePreferences == snapshot.preferences)
        #expect(candidate.device.inventoryState?.records.first?.captured == .skill(snapshot.skills[0]))
        try candidate.document.validateStructure()
        try candidate.device.validateStructure(against: candidate.document)
    }

    @Test func stableContextAndDecisionsProduceIdenticalCanonicalBytes() throws {
        let context = fixedContext()
        let tree = try skillTree("stable")
        let skillID = try migratedID(.skill, "mine", workspaceID: context.workspaceID)
        let snapshot = WorkspaceSnapshot(skills: [legacySkill("mine", owned: true)], activeProfileID: "")
        var decisions = WorkspaceMigrationDecisions()
        decisions.artifacts = [.init(legacy: key(.skill, "mine"), artifact: .init(
            identity: .init(id: skillID, kind: .skill, displayName: "Mine"),
            authority: .centralPersonal, contentDigest: tree.digest))]
        decisions.rootContent = [skillID: tree]

        let first = try #require(WorkspaceMigrationAssembly.preview(
            snapshot: snapshot, context: context, decisions: decisions).candidate)
        let second = try #require(WorkspaceMigrationAssembly.preview(
            snapshot: snapshot, context: context, decisions: decisions).candidate)

        let firstDocument = try WorkspaceDocumentCoding.encode(first.document)
        let secondDocument = try WorkspaceDocumentCoding.encode(second.document)
        let firstDevice = try WorkspaceDocumentCoding.encodeDeviceState(first.device)
        let secondDevice = try WorkspaceDocumentCoding.encodeDeviceState(second.device)
        #expect(firstDocument == secondDocument)
        #expect(firstDevice == secondDevice)
    }

    @Test func twoProjectConfigurationsShareOneExplicitProjectAndRoot() throws {
        let context = fixedContext()
        let projectID = artifactID("00000000-0000-0000-0000-000000000099")
        let root = "/private/tmp/shared-project"
        let firstKey = key(.configuration, "first")
        let secondKey = key(.configuration, "second")
        let snapshot = WorkspaceSnapshot(
            profiles: [
                profile("first", scope: .project, projectRoot: root),
                profile("second", scope: .localProject, projectRoot: root),
            ],
            activeProfileID: "first")
        var decisions = WorkspaceMigrationDecisions()
        decisions.configurationProjects = [firstKey: projectID, secondKey: projectID]
        decisions.projects = [.init(
            project: .init(id: projectID, name: "Shared project", repositoryHints: ["https://github.com/example/project"]),
            rootPath: root)]

        let output = WorkspaceMigrationAssembly.preview(
            snapshot: snapshot, context: context, decisions: decisions)
        let candidate = try #require(output.candidate)

        #expect(output.canAssemble)
        #expect(candidate.document.logicalProjects == [
            .init(id: projectID, name: "Shared project", repositoryHints: ["https://github.com/example/project"]),
        ])
        #expect(candidate.document.configurationState?.configurations.allSatisfy {
            $0.logicalProjectID == projectID
        } == true)
        #expect(candidate.device.projectRoots == [.init(projectID: projectID, rootPath: root)])
        #expect(candidate.device.configurationState?.configurationBindings.map(\.projectRoot) == [root, root])
    }

    @Test func projectRootDisagreementBlocksCandidate() {
        let context = fixedContext()
        let projectID = artifactID("00000000-0000-0000-0000-000000000099")
        let snapshot = WorkspaceSnapshot(
            profiles: [profile("project", scope: .project, projectRoot: "/private/tmp/actual")],
            activeProfileID: "project")
        var decisions = WorkspaceMigrationDecisions()
        decisions.configurationProjects = [key(.configuration, "project"): projectID]
        decisions.projects = [.init(
            project: .init(id: projectID, name: "Project"),
            rootPath: "/private/tmp/different")]

        let output = WorkspaceMigrationAssembly.preview(
            snapshot: snapshot, context: context, decisions: decisions)

        #expect(output.candidate == nil)
        #expect(output.issues == [.projectRootMismatch])
    }

    @Test func centralContentMustBePresentAndMatchTheReviewedArtifactDigest() throws {
        let context = fixedContext()
        let expected = try skillTree("expected")
        let different = try skillTree("different")
        let skillID = try migratedID(.skill, "mine", workspaceID: context.workspaceID)
        let snapshot = WorkspaceSnapshot(skills: [legacySkill("mine", owned: true)], activeProfileID: "")
        var decisions = WorkspaceMigrationDecisions()
        decisions.artifacts = [.init(legacy: key(.skill, "mine"), artifact: .init(
            identity: .init(id: skillID, kind: .skill, displayName: "Mine"),
            authority: .centralPersonal, contentDigest: expected.digest))]

        let missing = WorkspaceMigrationAssembly.preview(
            snapshot: snapshot, context: context, decisions: decisions)
        #expect(missing.candidate == nil)
        #expect(missing.issues == [.missingContent])

        decisions.rootContent = [skillID: different]
        let mismatch = WorkspaceMigrationAssembly.preview(
            snapshot: snapshot, context: context, decisions: decisions)
        #expect(mismatch.candidate == nil)
        #expect(mismatch.issues == [.contentMismatch])
    }

    @Test func nativeParentAndChildRemainOneGraphWithoutCentralContent() throws {
        let context = fixedContext()
        let pluginID = try migratedID(.plugin, "browser", workspaceID: context.workspaceID)
        let childID = try migratedID(.skill, "browse", workspaceID: context.workspaceID)
        let snapshot = WorkspaceSnapshot(
            skills: [legacySkill("browse")],
            plugins: [legacyPlugin("browser", skills: ["browse"])],
            profiles: [profile("native", requiredSkills: ["browse"])],
            targetObservations: [nativeObservation(pluginID: "browser", skillID: "browse")],
            activeProfileID: "native")
        var parent = ArtifactRecord(
            identity: .init(id: pluginID, kind: .nativePlugin, displayName: "Browser"),
            authority: .nativeOwned,
            nativeRoutes: [.init(client: .codex, externalPluginID: "browser")])
        parent.declaredName = "browser"
        let child = ArtifactRecord(
            identity: .init(id: childID, kind: .skill, displayName: "Browse", parentPackageID: pluginID),
            authority: .nativeOwned,
            declaredName: "browse",
            packageRelativePath: "skills/browse")
        var decisions = WorkspaceMigrationDecisions()
        decisions.artifacts = [
            .init(legacy: key(.plugin, "browser"), artifact: parent),
            .init(legacy: key(.skill, "browse"), artifact: child),
        ]

        let output = WorkspaceMigrationAssembly.preview(
            snapshot: snapshot, context: context, decisions: decisions)
        let candidate = try #require(output.candidate)

        #expect(output.canAssemble)
        #expect(candidate.content.isEmpty)
        #expect(candidate.device.inventoryState?.records.count == 2)
        #expect(candidate.document.artifacts.first(where: { $0.identity.id == childID })?.identity.parentPackageID == pluginID)
        #expect(candidate.document.configurationState?.configurations[0].requiredSkills[0].resolution == .artifact(childID))
    }

    @Test func invalidLegacyAndDivergentIdentityInputsNeverReturnCandidates() throws {
        let context = fixedContext()
        let duplicate = legacySkill("same")
        let invalidLegacy = WorkspaceMigrationAssembly.preview(
            snapshot: .init(skills: [duplicate, duplicate], activeProfileID: ""),
            context: context,
            decisions: .init())
        #expect(invalidLegacy.candidate == nil)
        #expect(invalidLegacy.issues == [.invalidLegacySnapshot])

        let snapshot = WorkspaceSnapshot(skills: [legacySkill("mine")], activeProfileID: "")
        var decisions = WorkspaceMigrationDecisions()
        let legacy = key(.skill, "mine")
        decisions.identities = [
            .init(legacy: legacy, objectID: objectID("00000000-0000-0000-0000-000000000080")),
            .init(legacy: legacy, objectID: objectID("00000000-0000-0000-0000-000000000081")),
        ]
        let invalidIdentity = WorkspaceMigrationAssembly.preview(
            snapshot: snapshot, context: context, decisions: decisions)
        #expect(invalidIdentity.candidate == nil)
        #expect(invalidIdentity.issues == [.invalidIdentity])
    }

    @Test func packageChildrenAreVerifiedFromTheirOwningUpstreamTree() throws {
        let context = fixedContext()
        let parentID = try migratedID(.plugin, "package", workspaceID: context.workspaceID)
        let childID = try migratedID(.skill, "mine", workspaceID: context.workspaceID)
        let child = try skillTree("upstream")
        let root = try CapturedPackageTree(entries: [
            .init(relativePath: "skills", kind: .directory),
            .init(relativePath: "skills/mine", kind: .directory),
            .init(relativePath: "LICENSE", kind: .file(bytes: Data("License text".utf8), executable: false)),
        ] + child.entries.map { .init(relativePath: "skills/mine/" + $0.relativePath, kind: $0.kind) })
        let sourceID = WorkspaceObjectID()
        let subscriptionID = WorkspaceObjectID()
        let authority = ContentAuthority.centralUpstream(subscriptionID: subscriptionID)
        var decisions = WorkspaceMigrationDecisions()
        decisions.artifacts = [
            .init(legacy: key(.plugin, "package"), artifact: .init(
                identity: .init(id: parentID, kind: .package, displayName: "Package"), authority: authority, contentDigest: root.digest)),
            .init(legacy: key(.skill, "mine"), artifact: .init(
                identity: .init(id: childID, kind: .skill, displayName: "Mine", parentPackageID: parentID),
                authority: authority, packageRelativePath: "skills/mine", contentDigest: child.digest)),
        ]
        decisions.sources = [.init(id: sourceID, role: .publisherRepository,
            repositoryURL: "https://github.com/example/tools", requestedRef: "main", packageRelativePaths: ["."])]
        decisions.subscriptions = [.init(id: subscriptionID, artifactID: parentID, sourceID: sourceID,
            lock: .init(publisherID: "example", sourceRootID: sourceID, requestedRef: "main",
                approvedRevision: .init(kind: .gitCommitSHA1, value: String(repeating: "a", count: 40)),
                approvedContent: root.digest, packageRelativePath: "."))]
        decisions.rootContent = [parentID: root]
        let snapshot = WorkspaceSnapshot(skills: [legacySkill("mine")],
            plugins: [legacyPlugin("package", skills: ["mine"])], activeProfileID: "")
        let preview = WorkspaceMigrationAssembly.preview(snapshot: snapshot, context: context, decisions: decisions)
        let candidate = try #require(preview.candidate)
        #expect(candidate.content[parentID] == root)
        #expect(candidate.content[childID] == child)
        #expect(candidate.document.subscriptions.count == 1)
        decisions.rootContent[childID] = child
        #expect(WorkspaceMigrationAssembly.preview(snapshot: snapshot, context: context, decisions: decisions).issues == [.contentMismatch])
    }

    @Test func configurationProjectRequiresActualEnrolledMapping() {
        let context = fixedContext()
        let snapshot = WorkspaceSnapshot(profiles: [profile("project", scope: .project, projectRoot: "/work/project")],
            activeProfileID: "project")
        var decisions = WorkspaceMigrationDecisions()
        decisions.configurationProjects = [key(.configuration, "project"): ArtifactID()]
        let result = WorkspaceMigrationAssembly.preview(snapshot: snapshot, context: context, decisions: decisions)
        #expect(result.configurations?.canMigrateConfigurations == true)
        #expect(result.candidate == nil)
        #expect(result.issues == [.missingProjectMapping])
    }

    private func fixedContext() -> WorkspaceMigrationContext {
        let workspace = objectID("00000000-0000-0000-0000-000000000001")
        return .init(
            workspaceID: workspace,
            deviceID: objectID("00000000-0000-0000-0000-000000000002"),
            revision: .init(
                id: objectID("00000000-0000-0000-0000-000000000003"),
                writerID: objectID("00000000-0000-0000-0000-000000000004"),
                createdAt: Date(timeIntervalSince1970: 1_700_000_000.123)))
    }

    private func skillTree(_ body: String) throws -> CapturedPackageTree {
        try CapturedPackageTree(entries: [
            .init(relativePath: "SKILL.md", kind: .file(bytes: Data("""
                ---
                name: mine
                description: A migrated skill
                ---
                \(body)
                """.utf8), executable: false)),
            .init(relativePath: "scripts", kind: .directory),
            .init(relativePath: "scripts/run", kind: .file(bytes: Data(body.utf8), executable: true)),
        ])
    }

    private func legacySkill(_ id: String, owned: Bool = false) -> Skill {
        .init(
            id: id, name: id, displayName: id.capitalized, summary: "Summary",
            bundle: "standalone", scope: "This Mac", owned: owned,
            triggers: [], negativeTrigger: "", files: ["SKILL.md"], clients: [], validationCount: 1)
    }

    private func profile(
        _ id: String,
        scope: ToolingScope = .user,
        projectRoot: String? = nil,
        requiredSkills: [String] = []
    ) -> ToolingProfile {
        .init(
            id: id, name: id.capitalized, summary: "Configuration", scope: scope,
            projectRoot: projectRoot, checks: [], enabledPlugins: [], requiredMCPs: [],
            requiredSkills: requiredSkills)
    }

    private func legacyPlugin(_ id: String, skills: [String]) -> Plugin {
        .init(
            id: id, name: id.capitalized, summary: "Native package", source: "Codex",
            scope: "This Mac", revision: "current", skills: skills, profiles: [],
            clients: [.init(client: .codex, state: .healthy, detail: "Found", isInstalled: true)],
            installed: true)
    }

    private func nativeObservation(pluginID: String, skillID: String) -> TargetObservation {
        .init(
            surface: .codexCLI,
            installed: true,
            commandAvailable: true,
            discoveredSkills: [skillID],
            discoveredPlugins: [pluginID],
            skillMetadata: [
                skillID: .init(
                    path: "/private/native/skills/\(skillID)", source: "Native", providerPluginID: pluginID),
            ],
            pluginMetadata: [
                pluginID: .init(
                    name: pluginID, source: "/private/native", scope: "This Mac", enabled: true,
                    skillIDs: [skillID]),
            ],
            capabilities: .init(
                supportsPluginInstall: true, supportsProjectScope: true, supportsLocalMarketplace: true,
                supportsMCPAuthentication: false, supportsConnectorDiscovery: false,
                requiresNewSession: true, requiresRestart: false, supportsMachineReadableOutput: true),
            lastScannedAt: Date(timeIntervalSince1970: 1_700_000_000))
    }

    private func migratedID(
        _ domain: LegacyReferenceDomain,
        _ identifier: String,
        workspaceID: WorkspaceObjectID
    ) throws -> ArtifactID {
        let entry = try WorkspaceMigrationIdentity.mapping(
            keys: [key(domain, identifier)], workspaceID: workspaceID)[0]
        return ArtifactID(entry.objectID.rawValue)
    }

    private func key(_ domain: LegacyReferenceDomain, _ identifier: String) -> LegacyReferenceKey {
        .init(domain: domain, identifier: identifier)
    }

    private func artifactID(_ value: String) -> ArtifactID {
        ArtifactID(UUID(uuidString: value)!)
    }

    private func objectID(_ value: String) -> WorkspaceObjectID {
        WorkspaceObjectID(UUID(uuidString: value)!)
    }
}
