import Foundation
import Testing

@testable import AgentToolingCore

struct WorkspaceConfigurationMigrationTests {
    private let workspaceID = WorkspaceObjectID(UUID(uuidString: "00000000-0000-0000-0000-000000000001")!)

    @Test func translatesLogicalConfigurationReferencesAndKeepsDeviceFactsLocal() throws {
        let parent = profile("parent", skills: ["skill"], plugins: ["plugin"], mcps: ["mcp"], collections: ["shelf"], bindings: nil)
        let child = profile("child", parent: "parent", scope: .project, root: "/work/project", checks: [check("ready")], bindings: [binding(.codex, enabled: false)])
        let sourceID = UUID(uuidString: "00000000-0000-0000-0000-000000000010")!
        let snapshot = WorkspaceSnapshot(
            skills: [skill("skill", bundle: "plugin")], mcpServers: [mcp("mcp")],
            plugins: [plugin("plugin", skills: ["skill"], profiles: ["child"])], profiles: [parent, child],
            sources: [.init(id: sourceID, name: "Catalog", kind: .gitRepository, location: "https://example.com/catalog.git")], activeProfileID: "child",
            collections: [.init(id: "shelf", name: "Shelf", items: [.init(kind: .skill, identifier: "skill")])]
        )
        let bindings: [LegacyReferenceKey: ArtifactID] = [
            .init(domain: .skill, identifier: "skill"): artifact("00000000-0000-0000-0000-000000000101"),
            .init(domain: .plugin, identifier: "plugin"): artifact("00000000-0000-0000-0000-000000000102"),
            .init(domain: .mcpServer, identifier: "mcp"): artifact("00000000-0000-0000-0000-000000000103"),
        ]
        let projectID = artifact("00000000-0000-0000-0000-000000000104")
        let before = try AgentToolingCoding.encoder().encode(snapshot)
        let preview = try WorkspaceConfigurationMigration.preview(
            snapshot: snapshot, workspaceID: workspaceID, artifactBindings: bindings,
            projectBindings: [.init(domain: .configuration, identifier: "child"): projectID]
        )

        #expect(preview.canMigrateConfigurations)
        #expect(preview.state.defaultConfigurationID == nil)
        let childID = try #require(preview.state.identityMap.first { $0.legacy == .init(domain: .configuration, identifier: "child") }?.objectID)
        let translated = try #require(preview.state.configurations.first { $0.id == childID })
        #expect(translated.logicalProjectID == projectID)
        #expect(translated.targetBindings?.first?.enabled == false)
        #expect(translated.inheritedFrom?.legacy.identifier == "parent")
        #expect(preview.deviceState.activeConfigurationOverrideID == childID)
        #expect(preview.deviceState.configurationBindings == [.init(configurationID: childID, projectRoot: "/work/project")])
        #expect(preview.deviceState.checkObservations == [.init(configurationID: childID, checkID: "ready", detail: "ready", state: .healthy)])
        #expect(preview.state.catalogSources.first?.remoteLocation == "https://example.com/catalog.git")
        #expect(preview.deviceState.catalogSources.first?.localLocation == nil)
        #expect(Set(preview.coverage.map(\.position)).count == preview.coverage.count)
        #expect(preview.state.legacyRelationships.contains { $0.kind == .skillBundle })
        #expect(try AgentToolingCoding.encoder().encode(snapshot) == before)

        // Translate the new references back to the legacy strings once. This
        // checks logical round-trip fidelity without using the migrator again.
        let parentRecord = try #require(preview.state.configurations.first { $0.name == "parent" })
        #expect(parentRecord.requiredSkills.map(\.legacy.identifier) == ["skill"])
        #expect(parentRecord.enabledPlugins.map(\.legacy.identifier) == ["plugin"])
        #expect(parentRecord.requiredMCPs.map(\.legacy.identifier) == ["mcp"])
        #expect(parentRecord.includedCollections.map(\.legacy.identifier) == ["shelf"])
    }

    @Test func retainsUnresolvedReferencesAndReportsConfigurationBlockers() throws {
        let snapshot = WorkspaceSnapshot(
            profiles: [profile("project", parent: "missing", scope: .project, root: "relative", checks: [check("same"), check("same")],
                               skills: ["absent"], collections: ["missing-shelf"], bindings: [binding(.codex, enabled: true), binding(.codex, enabled: false)])],
            sources: [.init(name: "Unsafe", kind: .gitRepository, location: "https://token@example.com/private")],
            activeProfileID: "project",
            tagAssignments: [.init(item: .init(kind: .plugin, identifier: "absent-plugin"), tags: ["keep"])]
        )
        let preview = try WorkspaceConfigurationMigration.preview(snapshot: snapshot, workspaceID: workspaceID, artifactBindings: [:])

        #expect(!preview.canMigrateConfigurations)
        #expect(preview.blockers.contains { $0.kind == .missingParent })
        #expect(preview.blockers.contains { $0.kind == .missingCollection })
        #expect(preview.blockers.contains { $0.kind == .invalidPath })
        #expect(preview.blockers.contains { $0.kind == .invalidCatalogLocation })
        #expect(preview.blockers.contains { $0.kind == .structuralValidation })
        #expect(preview.coverage.contains { $0.reference.legacy == .init(domain: .skill, identifier: "absent") && $0.reference.resolution == .unresolved })
        #expect(preview.state.tagAssignments.first?.item.resolution == .unresolved)
    }

    @Test func remoteCatalogObservationsAndReferenceOwnersSurviveRepeatedPreviews() throws {
        let sourceID = UUID()
        let refreshed = Date(timeIntervalSince1970: 1_000)
        let snapshot = WorkspaceSnapshot(
            profiles: [profile("one", skills: ["missing"]), profile("two", skills: ["missing"])],
            sources: [.init(id: sourceID, name: "Publisher catalog", kind: .agentPlugins,
                            location: "https://example.com/catalog", lastRefreshedAt: refreshed,
                            lastRevision: "release-7", trustSummary: "Reviewed here")],
            activeProfileID: "one")
        let preview = try WorkspaceConfigurationMigration.preview(snapshot: snapshot, workspaceID: workspaceID, artifactBindings: [:])
        #expect(preview.canMigrateConfigurations)
        let observed = try #require(preview.deviceState.catalogSources.first)
        #expect(observed.lastRefreshedAt == refreshed)
        #expect(observed.lastRevision == "release-7")
        #expect(observed.trustSummary == "Reviewed here")
        #expect(observed.localLocation == nil)
        let references = preview.coverage.filter { $0.reference.legacy == .init(domain: .skill, identifier: "missing") }
        #expect(Set(references.compactMap(\.owner)) == [.init(domain: .configuration, identifier: "one"), .init(domain: .configuration, identifier: "two")])
        #expect(Set(preview.coverage.map(\.position)).count == preview.coverage.count)
        let repeatPreview = try WorkspaceConfigurationMigration.preview(
            snapshot: snapshot, workspaceID: workspaceID, artifactBindings: [:], preserving: preview.state.identityMap)
        #expect(repeatPreview == preview)
    }

    @Test func absentCatalogReferenceIsUnresolvedAndCannotPassReview() throws {
        let missingCatalog = UUID()
        let snapshot = WorkspaceSnapshot(
            profiles: [profile("local")],
            marketplacePackages: [.init(id: "package", name: "Package", publisher: "Publisher", summary: "",
                                        sourceID: missingCatalog, sourceName: "Missing", components: [.skill],
                                        supportedClients: [.codex], location: "https://example.com/package")],
            activeProfileID: "local")
        let preview = try WorkspaceConfigurationMigration.preview(snapshot: snapshot, workspaceID: workspaceID, artifactBindings: [:])
        #expect(!preview.canMigrateConfigurations)
        let source = try #require(preview.coverage.first { $0.position.contains("marketplace[package].sourceID") })
        #expect(source.reference.resolution == .unresolved)
        #expect(preview.state.identityMap.contains { $0.legacy.identifier == missingCatalog.uuidString.lowercased() })
    }

    @Test func duplicatedChecksAndBindingsArePreservedAsBlockedInput() throws {
        let invalid = profile("local", checks: [check("same"), check("same")], bindings: [binding(.codex, enabled: true), binding(.codex, enabled: false)])
        let preview = try WorkspaceConfigurationMigration.preview(
            snapshot: WorkspaceSnapshot(profiles: [invalid], activeProfileID: "local"), workspaceID: workspaceID, artifactBindings: [:])
        #expect(!preview.canMigrateConfigurations)
        #expect(preview.blockers.contains { $0.kind == .structuralValidation })
        #expect(preview.state.configurations[0].checkDefinitions.count == 2)
        #expect(preview.state.configurations[0].targetBindings?.map(\.enabled) == [true, false])
    }

    @Test func policyTemplateCannotSilentlyBecomeTheActivePersonalConfiguration() throws {
        let snapshot = WorkspaceSnapshot(activeProfileID: "template", managedPolicies: [
            .init(id: "company", name: "Company", sourcePath: "/private/policy.json", importedAt: Date(timeIntervalSince1970: 1),
                  profiles: [profile("template")])])
        let preview = try WorkspaceConfigurationMigration.preview(snapshot: snapshot, workspaceID: workspaceID, artifactBindings: [:])
        #expect(!preview.canMigrateConfigurations)
        #expect(preview.deviceState.activeConfigurationOverrideID == nil)
        #expect(preview.state.managedPolicies.count == 1)
        #expect(preview.state.configurations.count == 1)
    }

    @Test func scopedConfigurationsWithoutLocalRootsCannotPassMigration() throws {
        for scope: ToolingScope in [.project, .localProject, .workspace] {
            let key = LegacyReferenceKey(domain: .configuration, identifier: "scoped")
            let preview = try WorkspaceConfigurationMigration.preview(
                snapshot: .init(profiles: [profile("scoped", scope: scope)], activeProfileID: "scoped"),
                workspaceID: workspaceID, artifactBindings: [:], projectBindings: [key: ArtifactID()])
            #expect(!preview.canMigrateConfigurations)
            #expect(preview.blockers.contains { $0.kind == .invalidPath && $0.reference == key })
        }
    }

    @Test func twoProjectConfigurationsCanShareOneExplicitLogicalProjectBinding() throws {
        let firstKey = LegacyReferenceKey(domain: .configuration, identifier: "first")
        let secondKey = LegacyReferenceKey(domain: .configuration, identifier: "second")
        let projectID = artifact("00000000-0000-0000-0000-000000000201")
        let snapshot = WorkspaceSnapshot(
            profiles: [
                profile("first", scope: .project, root: "/work/project"),
                profile("second", scope: .localProject, root: "/work/project"),
            ],
            activeProfileID: "first")

        let preview = try WorkspaceConfigurationMigration.preview(
            snapshot: snapshot,
            workspaceID: workspaceID,
            artifactBindings: [:],
            projectBindings: [firstKey: projectID, secondKey: projectID])

        #expect(preview.canMigrateConfigurations)
        #expect(preview.state.configurations.map(\.logicalProjectID) == [projectID, projectID])
        #expect(!preview.blockers.contains { $0.kind == .structuralValidation })
    }

    @Test func projectBindingCannotReuseAnArtifactIdentity() throws {
        let configurationKey = LegacyReferenceKey(domain: .configuration, identifier: "project")
        let collidingID = artifact("00000000-0000-0000-0000-000000000202")
        let preview = try WorkspaceConfigurationMigration.preview(
            snapshot: .init(
                profiles: [profile("project", scope: .project, root: "/work/project")],
                activeProfileID: "project"),
            workspaceID: workspaceID,
            artifactBindings: [.init(domain: .skill, identifier: "unrelated"): collidingID],
            projectBindings: [configurationKey: collidingID])

        #expect(!preview.canMigrateConfigurations)
        #expect(preview.blockers.contains { $0.kind == .duplicateIdentity && $0.reference == configurationKey })
    }

    @Test func pluginProfileReferencesCannotChooseBetweenPersonalAndPolicyNames() throws {
        let pluginID = ArtifactID()
        let snapshot = WorkspaceSnapshot(
            plugins: [plugin("bundle", profiles: ["shared"])], profiles: [profile("active"), profile("shared")],
            activeProfileID: "active", managedPolicies: [.init(id: "company", name: "Company", sourcePath: "/private/policy.json", profiles: [profile("shared")])])
        let preview = try WorkspaceConfigurationMigration.preview(
            snapshot: snapshot, workspaceID: workspaceID, artifactBindings: [.init(domain: .plugin, identifier: "bundle"): pluginID])
        #expect(!preview.canMigrateConfigurations)
        #expect(preview.blockers.contains { $0.kind == .ambiguousReference })
        #expect(preview.state.legacyRelationships.first { $0.kind == .pluginProfile }?.destination.resolution == .unresolved)
        #expect(preview.coverage.first { $0.position.contains("relationship.pluginProfile") }?.reference.resolution == .unresolved)
    }

    private func profile(_ id: String, parent: String? = nil, scope: ToolingScope = .user, root: String? = nil,
                         checks: [ProfileCheck] = [], skills: [String] = [], plugins: [String] = [], mcps: [String] = [],
                         collections: [String] = [], bindings: [OnboardingTargetBinding]? = nil) -> ToolingProfile {
        .init(id: id, name: id, summary: "", inheritedFrom: parent, scope: scope, projectRoot: root, checks: checks,
              enabledPlugins: plugins, requiredMCPs: mcps, requiredSkills: skills, includedCollections: collections, targetBindings: bindings)
    }
    private func skill(_ id: String, bundle: String = "") -> Skill { .init(id: id, name: id, displayName: id, summary: "", bundle: bundle, scope: "", owned: false, triggers: [], negativeTrigger: "", files: [], clients: [], validationCount: 0) }
    private func plugin(_ id: String, skills: [String] = [], profiles: [String] = []) -> Plugin { .init(id: id, name: id, summary: "", source: "", scope: "", revision: "", skills: skills, profiles: profiles, clients: [], installed: false) }
    private func mcp(_ id: String) -> MCPServer { .init(id: id, name: id, summary: "", endpoint: "", transport: .stdio, authentication: "", scope: "", clients: []) }
    private func check(_ id: String) -> ProfileCheck { .init(id: id, name: id, detail: id, state: .healthy) }
    private func binding(_ client: ClientKind, enabled: Bool?) -> OnboardingTargetBinding { .init(item: .init(kind: .skill, identifier: "skill"), client: client, enabled: enabled) }
    private func artifact(_ value: String) -> ArtifactID { ArtifactID(UUID(uuidString: value)!) }
}
