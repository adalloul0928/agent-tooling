import Foundation
import Testing
@testable import AgentToolingCore

struct WorkspaceInventoryMigrationTests {
    private let workspaceID = WorkspaceObjectID(UUID(uuidString: "00000000-0000-0000-0000-000000000111")!)

    @Test func tracksUnknownStandaloneWithoutInventingContentOrSource() throws {
        var snapshot = WorkspaceSnapshot(skills: [skill("docs")])
        snapshot.importedRepositoryPath = "/private/authoring"
        snapshot.preferences.enabledClients = [.claude]
        snapshot.backupConfiguration = .init(isEnabled: true, location: "/private/backup")
        let preview = try WorkspaceInventoryMigration.preview(snapshot: snapshot, workspaceID: workspaceID)
        #expect(preview.canMigrateInventory)
        #expect(preview.artifacts.count == 1)
        #expect(preview.artifacts[0].authority == .trackedOnly)
        #expect(preview.sources.isEmpty && preview.subscriptions.isEmpty)
        #expect(preview.coverage.count == WorkspaceInventoryMigrationFieldGroup.allCases.count)
        #expect(preview.retainedLegacySnapshot.skills == snapshot.skills)
        #expect(preview.retainedLegacySnapshot.importedRepositoryPath == snapshot.importedRepositoryPath)
        #expect(preview.retainedLegacySnapshot.preferences == snapshot.preferences)
        #expect(preview.retainedLegacySnapshot.backupConfiguration == snapshot.backupConfiguration)
        let document = try WorkspaceDocumentCoding.seal(.init(
            workspaceID: workspaceID, revision: .init(writerID: workspaceID), artifacts: preview.artifacts))
        let encoded = String(decoding: try WorkspaceDocumentCoding.encode(document), as: UTF8.self)
        #expect(!encoded.contains("/private/"))
    }

    @Test func knownManagementAndUpstreamLinksCannotBecomeUnmanagedOnMigration() throws {
        let owned = skill("mine", owned: true)
        var linked = skill("third-party")
        linked.repositoryBinding = try .init(repositoryURL: "https://github.com/owner/skills", subdirectory: "skills/third-party")
        let snapshot = WorkspaceSnapshot(skills: [owned, linked])
        let first = try WorkspaceInventoryMigration.preview(snapshot: snapshot, workspaceID: workspaceID)
        #expect(!first.canMigrateInventory)
        #expect(Set(first.issues.compactMap(\.legacy)) == Set([key(.skill, "mine"), key(.skill, "third-party")]))
        let resolutions = first.artifacts.map { artifact in
            WorkspaceInventoryMigrationResolution(
                legacy: artifact.identity.aliases.first!.value == "mine" ? key(.skill, "mine") : key(.skill, "third-party"), artifact: artifact)
        }
        let explicitTracking = try WorkspaceInventoryMigration.preview(
            snapshot: snapshot, workspaceID: workspaceID, resolutions: resolutions)
        #expect(!explicitTracking.canMigrateInventory)
        #expect(explicitTracking.retainedLegacySnapshot.skills[1].repositoryBinding == linked.repositoryBinding)
    }

    @Test func personalResolutionRequiresExistingOwnershipAndVerifiedDigest() throws {
        let snapshot = WorkspaceSnapshot(skills: [skill("mine", owned: true)])
        var personal = try record(.skill, "mine", authority: .centralPersonal)
        let noBytes = try WorkspaceInventoryMigration.preview(
            snapshot: snapshot, workspaceID: workspaceID, resolutions: [.init(legacy: key(.skill, "mine"), artifact: personal)])
        #expect(noBytes.issues.contains { $0.kind == .missingMaterialization })
        personal.contentDigest = digest
        let valid = try WorkspaceInventoryMigration.preview(
            snapshot: snapshot, workspaceID: workspaceID, resolutions: [.init(legacy: key(.skill, "mine"), artifact: personal)])
        #expect(valid.canMigrateInventory)
        #expect(valid.artifactBindings[key(.skill, "mine")] == personal.identity.id)
        let unowned = try WorkspaceInventoryMigration.preview(
            snapshot: .init(skills: [skill("mine")]), workspaceID: workspaceID,
            resolutions: [.init(legacy: key(.skill, "mine"), artifact: personal)])
        #expect(unowned.issues.contains { $0.kind == .upstreamOwnershipLost })
    }

    @Test func upstreamResolutionPreservesLocatorAndTypedLock() throws {
        var linked = skill("remote")
        linked.repositoryBinding = try .init(repositoryURL: "https://github.com/owner/repo", ref: "main", subdirectory: "skills/remote")
        linked.repositoryBinding?.installedFingerprints = ["/private/deployment": String(repeating: "b", count: 64)]
        linked.repositoryBinding?.installedRevision = String(repeating: "c", count: 40)
        let sourceID = WorkspaceObjectID()
        let subscriptionID = WorkspaceObjectID()
        var artifact = try record(.skill, "remote", authority: .centralUpstream(subscriptionID: subscriptionID))
        artifact.contentDigest = digest
        let source = PortableSourceDescriptor(
            id: sourceID, role: .publisherRepository, repositoryURL: "https://github.com/owner/repo", requestedRef: "main",
            packageRelativePaths: ["skills/remote"])
        let subscription = UpstreamSubscription(
            id: subscriptionID, artifactID: artifact.identity.id, sourceID: sourceID,
            lock: .init(publisherID: "owner", sourceRootID: sourceID, requestedRef: "main",
                        approvedRevision: .init(kind: .gitCommitSHA1, value: String(repeating: "d", count: 40)),
                        approvedContent: digest, packageRelativePath: "skills/remote"))
        let preview = try WorkspaceInventoryMigration.preview(
            snapshot: .init(skills: [linked]), workspaceID: workspaceID,
            resolutions: [.init(legacy: key(.skill, "remote"), artifact: artifact)], sources: [source], subscriptions: [subscription])
        #expect(preview.canMigrateInventory)
        #expect(preview.subscriptions[0].lock.approvedContent == digest)
        #expect(preview.retainedLegacySnapshot.skills[0].repositoryBinding == linked.repositoryBinding)
        var changedSource = source
        changedSource.requestedRef = "other"
        let changed = try WorkspaceInventoryMigration.preview(
            snapshot: .init(skills: [linked]), workspaceID: workspaceID,
            resolutions: [.init(legacy: key(.skill, "remote"), artifact: artifact)], sources: [changedSource], subscriptions: [subscription])
        #expect(changed.issues.contains { $0.kind == .upstreamOwnershipLost })
        var mismatchedLock = subscription
        mismatchedLock.lock.approvedContent = .init(value: String(repeating: "f", count: 64))
        let mismatch = try WorkspaceInventoryMigration.preview(
            snapshot: .init(skills: [linked]), workspaceID: workspaceID,
            resolutions: [.init(legacy: key(.skill, "remote"), artifact: artifact)], sources: [source], subscriptions: [mismatchedLock])
        #expect(mismatch.issues.contains { $0.kind == .structuralValidation })
    }

    @Test func preservesWholeNativePackageAndChildReferencesInConfiguration() throws {
        var nativeRoot = try record(.plugin, "browser", authority: .nativeOwned)
        nativeRoot.nativeRoutes = [.init(client: .codex, externalPluginID: "browser")]
        var child = try record(.skill, "browse", authority: .nativeOwned)
        child.identity.parentPackageID = nativeRoot.identity.id
        child.packageRelativePath = "skills/browse"
        let observation = nativeObservation(pluginID: "browser", skillID: "browse")
        let snapshot = WorkspaceSnapshot(
            skills: [skill("browse")], plugins: [plugin("browser", skills: ["browse"])],
            profiles: [.init(id: "setup", name: "Setup", summary: "", checks: [], enabledPlugins: ["browser"], requiredMCPs: [], requiredSkills: ["browse"])],
            targetObservations: [observation], activeProfileID: "setup")
        let inventory = try WorkspaceInventoryMigration.preview(
            snapshot: snapshot, workspaceID: workspaceID, resolutions: [
                .init(legacy: key(.plugin, "browser"), artifact: nativeRoot), .init(legacy: key(.skill, "browse"), artifact: child),
            ])
        #expect(inventory.canMigrateInventory)
        #expect(inventory.observations == [observation])
        let configuration = try WorkspaceConfigurationMigration.preview(
            snapshot: snapshot, workspaceID: workspaceID, artifactBindings: inventory.artifactBindings, preserving: inventory.identityMap)
        #expect(configuration.canMigrateConfigurations)
        let document = try WorkspaceDocumentCoding.seal(.init(
            workspaceID: workspaceID, revision: .init(writerID: workspaceID), artifacts: inventory.artifacts,
            configurationState: configuration.state))
        #expect(try WorkspaceDocumentCoding.decode(WorkspaceDocumentCoding.encode(document)) == document)
        #expect(document.assignments.isEmpty)
    }

    @Test func nativeLabelsAndInstalledFlagsAreInsufficient() throws {
        var allegedRoot = try record(.plugin, "official", authority: .nativeOwned)
        allegedRoot.nativeRoutes = [.init(client: .claude, externalPluginID: "official")]
        let snapshot = WorkspaceSnapshot(plugins: [plugin("official", skills: [])])
        let noDecision = try WorkspaceInventoryMigration.preview(snapshot: snapshot, workspaceID: workspaceID)
        #expect(!noDecision.canMigrateInventory)
        #expect(noDecision.artifacts[0].authority == .trackedOnly)
        let unobserved = try WorkspaceInventoryMigration.preview(
            snapshot: snapshot, workspaceID: workspaceID,
            resolutions: [.init(legacy: key(.plugin, "official"), artifact: allegedRoot)])
        #expect(unobserved.issues.contains { $0.kind == .missingNativeEvidence })
    }

    @Test func parentConflictsMissingChildrenAndStandaloneConversionsAreBlocked() throws {
        var nativeRoot = try record(.plugin, "browser", authority: .nativeOwned)
        nativeRoot.nativeRoutes = [.init(client: .codex, externalPluginID: "browser")]
        var snapshot = WorkspaceSnapshot(
            skills: [skill("browse")], plugins: [plugin("browser", skills: ["browse"])],
            targetObservations: [nativeObservation(pluginID: "browser", skillID: "browse")])
        let standalone = try WorkspaceInventoryMigration.preview(
            snapshot: snapshot, workspaceID: workspaceID, resolutions: [
                .init(legacy: key(.plugin, "browser"), artifact: nativeRoot),
                .init(legacy: key(.skill, "browse"), artifact: try record(.skill, "browse", authority: .trackedOnly)),
            ])
        #expect(standalone.issues.contains { $0.kind == .conflictingParentage })
        snapshot.skills = []
        let missing = try WorkspaceInventoryMigration.preview(
            snapshot: snapshot, workspaceID: workspaceID, resolutions: [.init(legacy: key(.plugin, "browser"), artifact: nativeRoot)])
        #expect(missing.issues.contains { $0.kind == .conflictingParentage && $0.legacy == key(.skill, "browse") })
    }

    @Test func wrongIdentityAndDuplicateInputsFailWithoutTrapping() throws {
        let snapshot = WorkspaceSnapshot(skills: [skill("docs")])
        var wrong = try record(.skill, "docs", authority: .trackedOnly)
        wrong.identity.id = ArtifactID()
        let decision = WorkspaceInventoryMigrationResolution(legacy: key(.skill, "docs"), artifact: wrong)
        let invalid = try WorkspaceInventoryMigration.preview(snapshot: snapshot, workspaceID: workspaceID, resolutions: [decision])
        #expect(!invalid.canMigrateInventory)
        #expect(invalid.issues.contains { $0.kind == .invalidResolution })
        #expect(throws: WorkspaceInventoryMigrationError.duplicateResolution) {
            try WorkspaceInventoryMigration.preview(snapshot: snapshot, workspaceID: workspaceID, resolutions: [decision, decision])
        }
        #expect(throws: WorkspaceInventoryMigrationError.duplicateInventoryIdentity) {
            try WorkspaceInventoryMigration.preview(snapshot: .init(skills: [skill("docs"), skill("docs")]), workspaceID: workspaceID)
        }
    }

    @Test func declaredMembershipCannotBeDiscardedWhenObservationIsMissing() throws {
        let parent = try record(.plugin, "package", authority: .trackedOnly)
        let standalone = try record(.skill, "child", authority: .trackedOnly)
        let snapshot = WorkspaceSnapshot(skills: [skill("child")], plugins: [plugin("package", skills: ["child"])])
        let output = try WorkspaceInventoryMigration.preview(snapshot: snapshot, workspaceID: workspaceID, resolutions: [
            .init(legacy: key(.plugin, "package"), artifact: parent), .init(legacy: key(.skill, "child"), artifact: standalone),
        ])
        #expect(!output.canMigrateInventory)
        #expect(output.issues.contains { $0.kind == .conflictingParentage })
    }

    @Test func managedMCPDefinitionStaysRetainedAndBlockingUntilRepresented() throws {
        let server = MCPServer(id: "api", name: "API", summary: "Managed", endpoint: "node server.js", transport: .stdio,
                               authentication: "Environment", scope: "This Mac", clients: [], secretNames: ["API_TOKEN"], definitionOrigin: .managed)
        let output = try WorkspaceInventoryMigration.preview(snapshot: .init(mcpServers: [server]), workspaceID: workspaceID)
        #expect(!output.canMigrateInventory)
        #expect(output.retainedLegacySnapshot.mcpServers == [server])
        #expect(output.issues.contains { $0.kind == .unresolvedAuthority })
        #expect(output.artifacts[0].authority == .trackedOnly)
    }

    @Test func malformedSourceGraphCannotReturnSuccessfulInventory() throws {
        let source = PortableSourceDescriptor(role: .publisherRepository, repositoryURL: "https://secret@example.test/repo", requestedRef: "main")
        let output = try WorkspaceInventoryMigration.preview(snapshot: .init(skills: [skill("docs")]), workspaceID: workspaceID, sources: [source])
        #expect(!output.canMigrateInventory)
        #expect(output.issues.contains { $0.kind == .structuralValidation })
        #expect(!output.issues.map(\.detail).joined().contains("secret"))
    }

    @Test func identitiesSurviveRenameAndInputReordering() throws {
        let snapshot = WorkspaceSnapshot(skills: [skill("first"), skill("second")])
        let first = try WorkspaceInventoryMigration.preview(snapshot: snapshot, workspaceID: workspaceID)
        var changed = snapshot
        changed.skills.reverse()
        changed.skills[0].displayName = "Renamed"
        let second = try WorkspaceInventoryMigration.preview(snapshot: changed, workspaceID: workspaceID, preserving: first.identityMap)
        #expect(first.artifactBindings == second.artifactBindings)
        #expect(first.coverage == second.coverage)
        #expect(second.artifacts.contains { $0.identity.displayName == "Renamed" })
    }

    @Test func installedMarketplaceOnlyInventoryCannotDisappearIntoArchive() throws {
        let package = MarketplacePackage(
            id: "catalog:browser", name: "Browser", publisher: "Publisher", summary: "Package", sourceName: "Catalog",
            components: [.plugin], supportedClients: [.codex], location: "catalog/browser", nativeInstalls: [
                .init(client: .codex, executable: "codex", arguments: ["plugin", "install", "browser"], detail: "Found", isInstalled: true),
            ], ownership: .nativeClient)
        let snapshot = WorkspaceSnapshot(marketplacePackages: [package])
        let output = try WorkspaceInventoryMigration.preview(snapshot: snapshot, workspaceID: workspaceID)
        #expect(!output.canMigrateInventory)
        #expect(output.artifacts.isEmpty)
        #expect(output.marketplaceCoverage == [.init(packageID: package.id, disposition: .needsReview)])
        #expect(output.issues.contains { $0.kind == .unmappedMarketplacePackage && $0.marketplacePackageID == package.id })
        #expect(output.retainedLegacySnapshot.marketplacePackages == [package])
        var catalogOnly = package
        catalogOnly.nativeInstalls[0].isInstalled = false
        catalogOnly.ownership = nil
        let catalog = try WorkspaceInventoryMigration.preview(snapshot: .init(marketplacePackages: [catalogOnly]), workspaceID: workspaceID)
        #expect(catalog.canMigrateInventory)
        #expect(catalog.artifacts.isEmpty)
        #expect(catalog.marketplaceCoverage == [.init(packageID: package.id, disposition: .retainedLocally)])
    }

    @Test func nativeMarketplaceLinkReusesOneObservedPluginRoot() throws {
        var root = try record(.plugin, "browser", authority: .nativeOwned)
        root.nativeRoutes = [.init(client: .codex, externalPluginID: "browser")]
        let package = marketplacePackage(
            "catalog:browser", components: [.plugin], ownership: .nativeClient,
            nativeInstalls: [.init(
                client: .codex, executable: "codex", arguments: ["plugin", "install", "browser"],
                detail: "Found", isInstalled: true)])
        let snapshot = WorkspaceSnapshot(
            plugins: [plugin("browser", skills: [])],
            targetObservations: [nativePluginObservation(pluginID: "browser")],
            marketplacePackages: [package])
        let output = try WorkspaceInventoryMigration.preview(
            snapshot: snapshot, workspaceID: workspaceID,
            resolutions: [.init(legacy: key(.plugin, "browser"), artifact: root)],
            marketplaceResolutions: [.init(
                packageID: package.id, artifact: root, linkedLegacy: key(.plugin, "browser"))])

        #expect(output.canMigrateInventory)
        #expect(output.artifacts.count == 1)
        #expect(output.marketplaceArtifactBindings[package.id] == root.identity.id)
        #expect(output.artifacts[0].identity.aliases.contains(
            .init(namespace: "legacy.marketplacePackage", value: package.id)))
        #expect(output.marketplaceCoverage == [.init(packageID: package.id, disposition: .mapped)])
    }

    @Test func uninstalledRegistryOwnershipLabelDoesNotRequireImportingTheEntireCatalog() throws {
        var package = marketplacePackage("mcp-registry:example", components: [.mcpServer], ownership: .managed)
        package.isInstalled = false
        let preview = try WorkspaceInventoryMigration.preview(
            snapshot: .init(marketplacePackages: [package]), workspaceID: workspaceID)
        #expect(preview.canMigrateInventory)
        #expect(preview.artifacts.isEmpty)
        #expect(preview.marketplaceCoverage == [.init(packageID: package.id, disposition: .retainedLocally)])
    }

    @Test func nativeMarketplaceRouteNeedsCapturedPluginEvidence() throws {
        var root = ArtifactRecord(
            identity: .init(kind: .nativePlugin, displayName: "Browser"),
            authority: .nativeOwned)
        root.nativeRoutes = [.init(client: .codex, externalPluginID: "browser")]
        let package = marketplacePackage("catalog:browser", components: [.plugin], ownership: .nativeClient)
        let output = try WorkspaceInventoryMigration.preview(
            snapshot: .init(marketplacePackages: [package]), workspaceID: workspaceID,
            marketplaceResolutions: [.init(packageID: package.id, artifact: root)])
        #expect(!output.canMigrateInventory)
        #expect(output.artifacts.isEmpty)
        #expect(output.issues.contains { $0.marketplacePackageID == package.id && $0.kind == .invalidResolution })
    }

    @Test func managedMarketplaceRequiresTypedUpstreamGraphInsteadOfCatalogLock() throws {
        let package = MarketplacePackage(
            id: "catalog:tools", name: "Tools", publisher: "Publisher", summary: "Package", sourceName: "Catalog",
            revision: "v1", components: [.plugin], supportedClients: [.codex], location: "https://github.com/owner/tools",
            isInstalled: true,
            provenance: .init(
                source: .init(kind: .gitRepository, location: "https://github.com/owner/tools"),
                lock: .init(revision: "v1", digest: String(repeating: "f", count: 64))),
            ownership: .managed)
        let sourceID = WorkspaceObjectID()
        let subscriptionID = WorkspaceObjectID()
        let artifactID = ArtifactID()
        let artifact = ArtifactRecord(
            identity: .init(id: artifactID, kind: .package, displayName: "Tools"),
            authority: .centralUpstream(subscriptionID: subscriptionID), contentDigest: digest)
        let source = PortableSourceDescriptor(
            id: sourceID, role: .publisherRepository, repositoryURL: "https://github.com/owner/tools",
            requestedRef: "v1", packageRelativePaths: ["."])
        let subscription = UpstreamSubscription(
            id: subscriptionID, artifactID: artifactID, sourceID: sourceID,
            lock: .init(
                publisherID: "owner", sourceRootID: sourceID, requestedRef: "v1",
                approvedRevision: .init(kind: .gitCommitSHA1, value: String(repeating: "d", count: 40)),
                approvedContent: digest, packageRelativePath: "."))
        let valid = try WorkspaceInventoryMigration.preview(
            snapshot: .init(marketplacePackages: [package]), workspaceID: workspaceID,
            sources: [source], subscriptions: [subscription],
            marketplaceResolutions: [.init(packageID: package.id, artifact: artifact)])
        #expect(valid.canMigrateInventory)
        #expect(valid.marketplaceArtifactBindings[package.id] == artifactID)
        var differentRepository = source
        differentRepository.repositoryURL = "https://github.com/another/publisher"
        let sourceChanged = try WorkspaceInventoryMigration.preview(
            snapshot: .init(marketplacePackages: [package]), workspaceID: workspaceID,
            sources: [differentRepository], subscriptions: [subscription],
            marketplaceResolutions: [.init(packageID: package.id, artifact: artifact)])
        #expect(!sourceChanged.canMigrateInventory)
        #expect(sourceChanged.issues.contains { $0.marketplacePackageID == package.id && $0.kind == .invalidResolution })

        let catalogEvidenceOnly = try WorkspaceInventoryMigration.preview(
            snapshot: .init(marketplacePackages: [package]), workspaceID: workspaceID,
            marketplaceResolutions: [.init(
                packageID: package.id,
                artifact: .init(identity: artifact.identity, authority: .trackedOnly))])
        #expect(!catalogEvidenceOnly.canMigrateInventory)
        #expect(catalogEvidenceOnly.issues.contains { $0.marketplacePackageID == package.id })
    }

    @Test func standaloneTrackedMarketplaceIdentityIsStableAcrossRetry() throws {
        let package = marketplacePackage("local:utility", components: [.skill], ownership: .unmanaged)
        let artifact = ArtifactRecord(
            identity: .init(kind: .skill, displayName: "Utility"), authority: .trackedOnly)
        let first = try WorkspaceInventoryMigration.preview(
            snapshot: .init(marketplacePackages: [package]), workspaceID: workspaceID,
            marketplaceResolutions: [.init(packageID: package.id, artifact: artifact)])
        #expect(first.canMigrateInventory)

        let second = try WorkspaceInventoryMigration.preview(
            snapshot: .init(marketplacePackages: [package]), workspaceID: workspaceID,
            marketplaceResolutions: [.init(packageID: package.id, artifact: artifact)],
            preservingMarketplaceBindings: first.marketplaceArtifactBindings)
        #expect(second.canMigrateInventory)
        var changed = artifact
        changed.identity.id = ArtifactID()
        let mismatch = try WorkspaceInventoryMigration.preview(
            snapshot: .init(marketplacePackages: [package]), workspaceID: workspaceID,
            marketplaceResolutions: [.init(packageID: package.id, artifact: changed)],
            preservingMarketplaceBindings: first.marketplaceArtifactBindings)
        #expect(!mismatch.canMigrateInventory)
        #expect(mismatch.artifacts.isEmpty)
    }

    @Test func marketplaceLinksRejectUnknownDuplicateAndMismatchedLegacyInputs() throws {
        let package = marketplacePackage("local:utility", components: [.skill], ownership: .unmanaged)
        let artifact = ArtifactRecord(identity: .init(kind: .skill, displayName: "Utility"), authority: .trackedOnly)
        let resolution = WorkspaceMarketplaceMigrationResolution(packageID: package.id, artifact: artifact)
        #expect(throws: WorkspaceInventoryMigrationError.duplicateResolution) {
            try WorkspaceInventoryMigration.preview(
                snapshot: .init(marketplacePackages: [package]), workspaceID: workspaceID,
                marketplaceResolutions: [resolution, resolution])
        }
        #expect(throws: WorkspaceInventoryMigrationError.unknownResolution) {
            try WorkspaceInventoryMigration.preview(
                snapshot: .init(), workspaceID: workspaceID,
                marketplaceResolutions: [resolution])
        }
        #expect(throws: WorkspaceInventoryMigrationError.duplicateResolution) {
            try WorkspaceInventoryMigration.preview(
                snapshot: .init(), workspaceID: workspaceID,
                preservingMarketplaceBindings: ["first": artifact.identity.id, "second": artifact.identity.id])
        }

        let snapshot = WorkspaceSnapshot(skills: [skill("docs")], marketplacePackages: [package])
        let legacy = try record(.skill, "docs", authority: .trackedOnly)
        let mismatched = try WorkspaceInventoryMigration.preview(
            snapshot: snapshot, workspaceID: workspaceID,
            resolutions: [.init(legacy: key(.skill, "docs"), artifact: legacy)],
            marketplaceResolutions: [.init(
                packageID: package.id, artifact: artifact, linkedLegacy: key(.skill, "docs"))])
        #expect(!mismatched.canMigrateInventory)
        #expect(mismatched.marketplaceArtifactBindings.isEmpty)
    }

    private var digest: ContentDigest { .init(value: String(repeating: "a", count: 64)) }
    private func key(_ domain: LegacyReferenceDomain, _ id: String) -> LegacyReferenceKey { .init(domain: domain, identifier: id) }

    private func record(_ domain: LegacyReferenceDomain, _ id: String, authority: ContentAuthority) throws -> ArtifactRecord {
        let reference = key(domain, id)
        let entry = try WorkspaceMigrationIdentity.mapping(keys: [reference], workspaceID: workspaceID)[0]
        let kind: ArtifactKind = domain == .skill ? .skill : (domain == .plugin ? .nativePlugin : .mcpServer)
        return .init(identity: .init(id: ArtifactID(entry.objectID.rawValue), kind: kind, displayName: id), authority: authority)
    }

    private func skill(_ id: String, owned: Bool = false) -> Skill {
        .init(id: id, name: id, displayName: id, summary: "Summary", bundle: "standalone", scope: "This Mac", owned: owned,
              triggers: ["Trigger"], negativeTrigger: "Negative trigger", files: ["SKILL.md", "scripts/tool.sh"], clients: [], validationCount: 2)
    }

    private func plugin(_ id: String, skills: [String]) -> Plugin {
        .init(id: id, name: id, summary: "Observed package", source: "OpenAI Bundled", scope: "This Mac", revision: "Unknown",
              skills: skills, profiles: [], clients: [.init(client: .codex, state: .healthy, detail: "Found", isInstalled: true)], installed: true)
    }

    private func marketplacePackage(
        _ id: String,
        components: Set<ComponentKind>,
        ownership: PackageOwnership?,
        nativeInstalls: [NativeInstall] = []
    ) -> MarketplacePackage {
        .init(
            id: id, name: id, publisher: "Publisher", summary: "Package", sourceName: "Catalog",
            components: components, supportedClients: [.codex], location: "catalog/package",
            isInstalled: true, nativeInstalls: nativeInstalls, ownership: ownership)
    }

    private func nativeObservation(pluginID: String, skillID: String) -> TargetObservation {
        .init(surface: .codexCLI, installed: true, commandAvailable: true, discoveredSkills: [skillID], discoveredPlugins: [pluginID],
              skillMetadata: [skillID: .init(path: "/private/native/skills/\(skillID)", source: "Native", providerPluginID: pluginID)],
              pluginMetadata: [pluginID: .init(name: pluginID, source: "/private/native", scope: "This Mac", enabled: false, skillIDs: [skillID])],
              capabilities: .init(supportsPluginInstall: true, supportsProjectScope: true, supportsLocalMarketplace: true,
                                  supportsMCPAuthentication: false, supportsConnectorDiscovery: false, requiresNewSession: true,
                                  requiresRestart: false, supportsMachineReadableOutput: true), lastScannedAt: Date(timeIntervalSince1970: 1_700_000_000))
    }

    private func nativePluginObservation(pluginID: String) -> TargetObservation {
        .init(
            surface: .codexCLI, installed: true, commandAvailable: true,
            discoveredPlugins: [pluginID],
            pluginMetadata: [
                pluginID: .init(name: pluginID, source: "/private/native", scope: "This Mac", enabled: false),
            ],
            capabilities: .init(
                supportsPluginInstall: true, supportsProjectScope: true, supportsLocalMarketplace: true,
                supportsMCPAuthentication: false, supportsConnectorDiscovery: false, requiresNewSession: true,
                requiresRestart: false, supportsMachineReadableOutput: true),
            lastScannedAt: Date(timeIntervalSince1970: 1_700_000_000))
    }
}
