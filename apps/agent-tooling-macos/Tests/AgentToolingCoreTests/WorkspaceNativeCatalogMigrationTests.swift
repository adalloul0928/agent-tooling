import Foundation
import Testing
@testable import AgentToolingCore

struct WorkspaceNativeCatalogMigrationTests {
    private let workspaceID = WorkspaceObjectID(UUID(uuidString: "00000000-0000-0000-0000-000000000cab")!)

    @Test func parserEncodedCatalogRowAutomaticallyAliasesItsExactObservedNativeRoot() throws {
        let externalID = "browser@market"
        let root = try nativeRoot(legacyID: externalID, routes: [.init(client: .codex, externalPluginID: externalID)])
        let package = catalog("codex:\(externalID)", client: .codex, name: "Unrelated display name", arguments: ["not", "an", "identity"])
        let snapshot = WorkspaceSnapshot(
            plugins: [plugin(externalID)],
            targetObservations: [observation(client: .codex, externalID: externalID)],
            marketplacePackages: [package]
        )

        let preview = try WorkspaceInventoryMigration.preview(
            snapshot: snapshot,
            workspaceID: workspaceID,
            resolutions: [.init(legacy: key(.plugin, externalID), artifact: root)]
        )

        #expect(preview.canMigrateInventory)
        #expect(preview.marketplaceArtifactBindings == [package.id: root.identity.id])
        #expect(preview.artifacts.first?.identity.aliases.contains(
            .init(namespace: "legacy.marketplacePackage", value: package.id)
        ) == true)
        #expect(preview.marketplaceCoverage == [.init(packageID: package.id, disposition: .mapped)])
        let restored = try JSONDecoder.agentTooling().decode(
            WorkspaceSnapshot.self,
            from: JSONEncoder.agentTooling().encode(preview.retainedLegacySnapshot)
        )
        #expect(restored.marketplacePackages == [package])
    }

    @Test func cachedInstalledCatalogFlagWithoutObservedRootRemainsLocalDiscoveryMetadata() throws {
        let package = catalog("codex:stale@market", client: .codex, name: "Stale cache")
        let preview = try WorkspaceInventoryMigration.preview(
            snapshot: .init(marketplacePackages: [package]), workspaceID: workspaceID
        )

        #expect(preview.canMigrateInventory)
        #expect(preview.artifacts.isEmpty)
        #expect(preview.managedMCPAssignments.isEmpty)
        #expect(preview.marketplaceArtifactBindings.isEmpty)
        #expect(preview.marketplaceCoverage == [.init(packageID: package.id, disposition: .retainedLocally)])
        #expect(preview.retainedLegacySnapshot.marketplacePackages == [package])
    }

    @Test func unknownSourceNameAndInstallArgumentsDoNotCreateANativeCatalogLink() throws {
        let externalID = "browser@market"
        let root = try nativeRoot(legacyID: externalID, routes: [.init(client: .codex, externalPluginID: externalID)])
        var package = catalog("local:browser", client: .codex, name: externalID, arguments: ["plugin", "install", externalID])
        package.sourceName = "Codex"
        package.publisher = "Marketplace"
        let snapshot = WorkspaceSnapshot(
            plugins: [plugin(externalID)],
            targetObservations: [observation(client: .codex, externalID: externalID)],
            marketplacePackages: [package]
        )

        let preview = try WorkspaceInventoryMigration.preview(
            snapshot: snapshot,
            workspaceID: workspaceID,
            resolutions: [.init(legacy: key(.plugin, externalID), artifact: root)]
        )

        #expect(!preview.canMigrateInventory)
        #expect(preview.marketplaceArtifactBindings.isEmpty)
        #expect(preview.marketplaceCoverage == [.init(packageID: package.id, disposition: .needsReview)])
    }

    @Test func ambiguousResolvedNativeRootsForOneClientIdentityBlockAutomaticLinking() throws {
        let externalID = "shared@market"
        let first = try nativeRoot(legacyID: "first", routes: [.init(client: .codex, externalPluginID: externalID)])
        let second = try nativeRoot(legacyID: "second", routes: [.init(client: .codex, externalPluginID: externalID)])
        let package = catalog("codex:\(externalID)", client: .codex)
        let snapshot = WorkspaceSnapshot(
            plugins: [plugin("first"), plugin("second")],
            targetObservations: [observation(client: .codex, externalID: externalID)],
            marketplacePackages: [package]
        )

        let preview = try WorkspaceInventoryMigration.preview(
            snapshot: snapshot,
            workspaceID: workspaceID,
            resolutions: [
                .init(legacy: key(.plugin, "first"), artifact: first),
                .init(legacy: key(.plugin, "second"), artifact: second),
            ]
        )

        #expect(!preview.canMigrateInventory)
        #expect(preview.marketplaceArtifactBindings.isEmpty)
        #expect(preview.marketplaceCoverage == [.init(packageID: package.id, disposition: .needsReview)])
    }

    @Test func explicitAndPreservedLinksCannotReplaceTheExactAutomaticIdentity() throws {
        let externalID = "browser@market"
        let root = try nativeRoot(legacyID: externalID, routes: [.init(client: .codex, externalPluginID: externalID)])
        let other = try nativeRoot(legacyID: "other", routes: [.init(client: .codex, externalPluginID: "other@market")])
        let package = catalog("codex:\(externalID)", client: .codex)
        let snapshot = WorkspaceSnapshot(
            plugins: [plugin(externalID), plugin("other")],
            targetObservations: [observation(client: .codex, externalIDs: [externalID, "other@market"])],
            marketplacePackages: [package]
        )
        let resolutions: [WorkspaceInventoryMigrationResolution] = [
            .init(legacy: key(.plugin, externalID), artifact: root),
            .init(legacy: key(.plugin, "other"), artifact: other),
        ]

        let explicitConflict = try WorkspaceInventoryMigration.preview(
            snapshot: snapshot, workspaceID: workspaceID, resolutions: resolutions,
            marketplaceResolutions: [.init(packageID: package.id, artifact: other, linkedLegacy: key(.plugin, "other"))]
        )
        #expect(!explicitConflict.canMigrateInventory)
        #expect(explicitConflict.marketplaceArtifactBindings.isEmpty)

        let preservedConflict = try WorkspaceInventoryMigration.preview(
            snapshot: snapshot, workspaceID: workspaceID, resolutions: resolutions,
            preservingMarketplaceBindings: [package.id: other.identity.id]
        )
        #expect(!preservedConflict.canMigrateInventory)
        #expect(preservedConflict.marketplaceArtifactBindings.isEmpty)
    }

    @Test func oneRootCanRetainCodexAndClaudeAliasesButNotTwoAliasesForOneClient() throws {
        let externalID = "browser@market"
        let root = try nativeRoot(legacyID: externalID, routes: [
            .init(client: .codex, externalPluginID: externalID),
            .init(client: .claude, externalPluginID: externalID),
        ])
        let codex = catalog("codex:\(externalID)", client: .codex)
        let claude = catalog("claude:\(externalID)", client: .claude)
        let snapshot = WorkspaceSnapshot(
            plugins: [plugin(externalID)],
            targetObservations: [
                observation(client: .codex, externalID: externalID),
                observation(client: .claude, externalID: externalID),
            ],
            marketplacePackages: [codex, claude]
        )

        let preview = try WorkspaceInventoryMigration.preview(
            snapshot: snapshot,
            workspaceID: workspaceID,
            resolutions: [.init(legacy: key(.plugin, externalID), artifact: root)],
            preservingMarketplaceBindings: [codex.id: root.identity.id, claude.id: root.identity.id]
        )
        #expect(preview.canMigrateInventory)
        #expect(preview.marketplaceArtifactBindings == [codex.id: root.identity.id, claude.id: root.identity.id])

        let duplicateClientRoot = try nativeRoot(legacyID: "multi", routes: [
            .init(client: .codex, externalPluginID: "one@market"),
            .init(client: .codex, externalPluginID: "two@market"),
        ])
        let duplicateSnapshot = WorkspaceSnapshot(
            plugins: [plugin("multi")],
            targetObservations: [
                observation(client: .codex, externalIDs: ["one@market", "two@market"]),
            ],
            marketplacePackages: [
                catalog("codex:one@market", client: .codex),
                catalog("codex:two@market", client: .codex),
            ]
        )
        let duplicate = try WorkspaceInventoryMigration.preview(
            snapshot: duplicateSnapshot,
            workspaceID: workspaceID,
            resolutions: [.init(legacy: key(.plugin, "multi"), artifact: duplicateClientRoot)]
        )
        #expect(!duplicate.canMigrateInventory)
        #expect(duplicate.issues.contains { $0.marketplacePackageID == "codex:two@market" })
    }

    @Test func contradictoryReservedNativeRowCannotFallThroughAsManagedUpstream() throws {
        let sourceID = WorkspaceObjectID()
        let subscriptionID = WorkspaceObjectID()
        let artifactID = ArtifactID()
        let digest = ContentDigest(value: String(repeating: "a", count: 64))
        let repository = "https://github.com/example/native-looking-package"
        let artifact = ArtifactRecord(
            identity: .init(id: artifactID, kind: .package, displayName: "Native-looking package"),
            authority: .centralUpstream(subscriptionID: subscriptionID),
            contentDigest: digest
        )
        let source = PortableSourceDescriptor(
            id: sourceID,
            role: .publisherRepository,
            repositoryURL: repository,
            requestedRef: "main",
            packageRelativePaths: ["."]
        )
        let subscription = UpstreamSubscription(
            id: subscriptionID,
            artifactID: artifactID,
            sourceID: sourceID,
            lock: .init(
                publisherID: "github:example",
                sourceRootID: sourceID,
                requestedRef: "main",
                approvedRevision: .init(kind: .gitCommitSHA1, value: String(repeating: "b", count: 40)),
                approvedContent: digest,
                packageRelativePath: "."
            )
        )
        var package = catalog("codex:reviewer@team", client: .codex)
        package.ownership = .managed
        package.provenance = .init(source: .init(kind: .gitRepository, location: repository))

        let preview = try WorkspaceInventoryMigration.preview(
            snapshot: .init(marketplacePackages: [package]),
            workspaceID: workspaceID,
            sources: [source],
            subscriptions: [subscription],
            marketplaceResolutions: [.init(packageID: package.id, artifact: artifact)]
        )

        #expect(!preview.canMigrateInventory)
        #expect(preview.artifacts.isEmpty)
        #expect(preview.marketplaceArtifactBindings.isEmpty)
        #expect(preview.marketplaceCoverage == [.init(packageID: package.id, disposition: .needsReview)])
        #expect(preview.issues.contains { $0.kind == .invalidResolution && $0.marketplacePackageID == package.id })
    }

    @Test func malformedReservedNativeIDCannotFallThroughAsTrackedContent() throws {
        var package = catalog("claude:contains/path", client: .claude)
        package.ownership = .unmanaged
        let artifact = ArtifactRecord(
            identity: .init(kind: .package, displayName: "Tracked package"),
            authority: .trackedOnly
        )

        let preview = try WorkspaceInventoryMigration.preview(
            snapshot: .init(marketplacePackages: [package]),
            workspaceID: workspaceID,
            marketplaceResolutions: [.init(packageID: package.id, artifact: artifact)]
        )

        #expect(!preview.canMigrateInventory)
        #expect(preview.artifacts.isEmpty)
        #expect(preview.marketplaceArtifactBindings.isEmpty)
        #expect(preview.marketplaceCoverage == [.init(packageID: package.id, disposition: .needsReview)])
        #expect(preview.issues.contains { $0.kind == .invalidResolution && $0.marketplacePackageID == package.id })
    }

    private func nativeRoot(legacyID: String, routes: [NativePackageRoute]) throws -> ArtifactRecord {
        let entry = try WorkspaceMigrationIdentity.mapping(
            keys: [key(.plugin, legacyID)], workspaceID: workspaceID
        )[0]
        return .init(
            identity: .init(id: ArtifactID(entry.objectID.rawValue), kind: .nativePlugin, displayName: legacyID),
            authority: .nativeOwned,
            declaredName: legacyID,
            nativeRoutes: routes
        )
    }

    private func catalog(
        _ id: String,
        client: ClientKind,
        name: String = "Catalog package",
        arguments: [String] = []
    ) -> MarketplacePackage {
        .init(
            id: id,
            name: name,
            publisher: "Untrusted publisher label",
            summary: "Cached native catalog metadata",
            sourceName: "Untrusted source label",
            components: [.plugin],
            supportedClients: [client],
            location: "catalog/package",
            isInstalled: true,
            nativeInstalls: [.init(
                client: client,
                executable: client == .codex ? "codex" : "claude",
                arguments: arguments,
                detail: "Cached route",
                isInstalled: true
            )],
            ownership: .nativeClient
        )
    }

    private func plugin(_ id: String) -> Plugin {
        .init(
            id: id, name: id, summary: "Observed native plugin", source: "Display only", scope: "This Mac",
            revision: "current", skills: [], profiles: [], clients: [], installed: true
        )
    }

    private func observation(client: ClientKind, externalID: String) -> TargetObservation {
        observation(client: client, externalIDs: [externalID])
    }

    private func observation(client: ClientKind, externalIDs: [String]) -> TargetObservation {
        .init(
            surface: client == .claude ? .claudeCode : .codexCLI,
            installed: true,
            commandAvailable: true,
            discoveredPlugins: externalIDs,
            pluginMetadata: Dictionary(uniqueKeysWithValues: externalIDs.map { id in
                (id, ObservedPluginMetadata(
                    name: "Display label", source: "/private/observed", scope: "This Mac", enabled: true
                ))
            }),
            capabilities: .init(
                supportsPluginInstall: true, supportsProjectScope: true, supportsLocalMarketplace: true,
                supportsMCPAuthentication: false, supportsConnectorDiscovery: false, requiresNewSession: false,
                requiresRestart: false, supportsMachineReadableOutput: true
            ),
            lastScannedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
    }

    private func key(_ domain: LegacyReferenceDomain, _ identifier: String) -> LegacyReferenceKey {
        .init(domain: domain, identifier: identifier)
    }
}
