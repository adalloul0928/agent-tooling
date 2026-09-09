import Foundation
import Testing

@testable import AgentToolingCore

@Suite("Workspace migration candidate preparation")
struct WorkspaceMigrationCandidatePreparationTests {
    @Test func preparesDerivedPersonalContentAndSafeTrackedStandalone() async throws {
        let fixture = try WorkspaceMigrationServiceTests.Fixture()
        defer { fixture.remove() }
        var snapshot = fixture.snapshot(label: "personal")
        snapshot.skills.append(Self.unmanagedSkill("observed"))
        try fixture.legacy.saveWorkspaceSnapshot(snapshot)
        try Self.installManagedFixture(fixture)
        let checkpoint = try await WorkspaceLegacyCheckpoint.capture(databaseURL: fixture.legacy.databaseURL)
        let request = Self.request(fixture, checkpoint: checkpoint, choices: [
            .init(legacy: Self.key(.skill, "owned"), strategy: .centralPersonal),
        ])

        let preview = try await WorkspaceMigrationCandidatePreparationService().preview(request)

        #expect(preview.canPrepare)
        let preparation = try #require(preview.preparation)
        #expect(preparation.record.manifest.content.count == 1)
        #expect(preparation.record.manifest.sourceCaptures.first?.directoryPath
            == Self.managedSkillURL(fixture).path)
        #expect(preview.items.first { $0.legacy == Self.key(.skill, "observed") }?.selectedChoice == .trackedOnly)
        #expect(preparation.record.document.artifacts.contains {
            $0.identity.aliases.contains(.init(namespace: "legacy.skill", value: "observed"))
                && $0.authority == .trackedOnly
        })
    }

    @Test func preservesInstalledUpstreamBytesRevisionAndSourceIntentWithoutFetching() async throws {
        let fixture = try WorkspaceMigrationServiceTests.Fixture()
        defer { fixture.remove() }
        let installed = fixture.root.appending(path: "installed-upstream")
        try FileManager.default.copyItem(at: fixture.source, to: installed)
        try FileManager.default.removeItem(at: installed.appending(path: "README"))
        var binding = try SkillRepositoryBinding(
            repositoryURL: "https://github.com/Example/Skills",
            ref: "release",
            subdirectory: "skills/owned"
        )
        binding.installedRevision = String(repeating: "a", count: 40)
        binding.installedFingerprints = [installed.path: try DirectoryFingerprint.sha256(of: installed)]
        let skill = Skill(
            id: "owned", name: "owned", displayName: "Upstream", summary: "Fixture",
            bundle: "external", scope: "This Mac", owned: true, triggers: [], negativeTrigger: "",
            files: ["SKILL.md"], clients: [], validationCount: 0, repositoryBinding: binding
        )
        try fixture.legacy.saveWorkspaceSnapshot(.init(skills: [skill], activeProfileID: ""))
        let checkpoint = try await WorkspaceLegacyCheckpoint.capture(databaseURL: fixture.legacy.databaseURL)
        let sourceID = WorkspaceObjectID()
        let subscriptionID = WorkspaceObjectID()
        let preview = try await WorkspaceMigrationCandidatePreparationService().preview(Self.request(
            fixture,
            checkpoint: checkpoint,
            choices: [.init(
                legacy: Self.key(.skill, "owned"),
                strategy: .centralUpstream(
                    installedDirectory: installed,
                    sourceID: sourceID,
                    subscriptionID: subscriptionID
                )
            )]
        ))

        let preparation = try #require(preview.preparation)
        #expect(preview.issues.isEmpty)
        #expect(preparation.record.document.sources == [.init(
            id: sourceID,
            role: .publisherRepository,
            repositoryURL: binding.repositoryURL,
            requestedRef: "release",
            packageRelativePaths: ["skills/owned"]
        )])
        let lock = try #require(preparation.record.document.subscriptions.first?.lock)
        let artifactDigest = try #require(preparation.record.document.artifacts.first?.contentDigest)
        #expect(lock.approvedRevision == .init(kind: .gitCommitSHA1, value: String(repeating: "a", count: 40)))
        #expect(lock.approvedContent == artifactDigest)
        #expect(lock.publisherID == "github:example")
        #expect(preparation.record.manifest.sourceCaptures.first?.directoryPath == installed.path)
    }

    @Test func changedOrUnrecordedUpstreamFolderIsAReviewBlocker() async throws {
        let fixture = try WorkspaceMigrationServiceTests.Fixture()
        defer { fixture.remove() }
        let installed = fixture.root.appending(path: "installed-upstream")
        try FileManager.default.copyItem(at: fixture.source, to: installed)
        try FileManager.default.removeItem(at: installed.appending(path: "README"))
        var binding = try SkillRepositoryBinding(repositoryURL: "https://github.com/example/skills")
        binding.installedRevision = String(repeating: "b", count: 40)
        binding.installedFingerprints = [installed.path: String(repeating: "c", count: 64)]
        let skill = Skill(
            id: "owned", name: "owned", displayName: "Upstream", summary: "Fixture",
            bundle: "external", scope: "This Mac", owned: false, triggers: [], negativeTrigger: "",
            files: ["SKILL.md"], clients: [], validationCount: 0, repositoryBinding: binding
        )
        try fixture.legacy.saveWorkspaceSnapshot(.init(skills: [skill], activeProfileID: ""))
        let checkpoint = try await WorkspaceLegacyCheckpoint.capture(databaseURL: fixture.legacy.databaseURL)
        let preview = try await WorkspaceMigrationCandidatePreparationService().preview(Self.request(
            fixture,
            checkpoint: checkpoint,
            choices: [.init(
                legacy: Self.key(.skill, "owned"),
                strategy: .centralUpstream(
                    installedDirectory: installed,
                    sourceID: WorkspaceObjectID(),
                    subscriptionID: WorkspaceObjectID()
                )
            )]
        ))

        #expect(!preview.canPrepare)
        #expect(preview.issues.map(\.kind) == [.changedUpstreamContent])
    }

    @Test func attachesValidatedStandaloneWithoutCentralizingItsBytes() async throws {
        let fixture = try WorkspaceMigrationServiceTests.Fixture()
        defer { fixture.remove() }
        let skill = Self.unmanagedSkill("owned")
        try fixture.legacy.saveWorkspaceSnapshot(.init(skills: [skill], activeProfileID: ""))
        let checkpoint = try await WorkspaceLegacyCheckpoint.capture(databaseURL: fixture.legacy.databaseURL)
        let sourceID = WorkspaceObjectID()
        let preview = try await WorkspaceMigrationCandidatePreparationService().preview(Self.request(
            fixture,
            checkpoint: checkpoint,
            choices: [.init(
                legacy: Self.key(.skill, "owned"),
                strategy: .attachedAuthoring(directory: fixture.source, sourceID: sourceID)
            )]
        ))

        let preparation = try #require(preview.preparation)
        #expect(preparation.record.manifest.content.isEmpty)
        #expect(preparation.record.manifest.sourceCaptures.isEmpty)
        #expect(preparation.record.document.sources == [.init(
            id: sourceID, role: .attachedAuthoring, packageRelativePaths: ["."]
        )])
        #expect(preparation.record.device.sourceLocations == [
            .init(sourceRootID: sourceID, checkoutPath: fixture.source.path),
        ])
    }

    @Test func nativePluginRetainsItsWholeObservedChildGraphAndRoutes() async throws {
        let fixture = try WorkspaceMigrationServiceTests.Fixture()
        defer { fixture.remove() }
        var snapshot = fixture.snapshot(label: "personal")
        var native = fixture.nativeSnapshot()
        native.plugins[0].skills = []
        native.targetObservations[0].pluginMetadata["browser"]?.skillIDs = []
        snapshot.skills += native.skills
        snapshot.plugins = native.plugins
        snapshot.profiles += native.profiles
        snapshot.targetObservations = native.targetObservations
        try fixture.legacy.saveWorkspaceSnapshot(snapshot)
        try Self.installManagedFixture(fixture)
        let checkpoint = try await WorkspaceLegacyCheckpoint.capture(databaseURL: fixture.legacy.databaseURL)
        let preview = try await WorkspaceMigrationCandidatePreparationService().preview(Self.request(
            fixture,
            checkpoint: checkpoint,
            choices: [
                .init(legacy: Self.key(.skill, "owned"), strategy: .centralPersonal),
                .init(
                    legacy: Self.key(.plugin, "browser"),
                    strategy: .nativePackage(
                        routes: [.init(client: .codex, externalPluginID: "browser")],
                        children: [.init(
                            legacy: Self.key(.skill, "browse"),
                            packageRelativePath: "skills/browse"
                        )]
                    )
                ),
            ]
        ))

        let document = try #require(preview.preparation?.record.document)
        let parent = try #require(document.artifacts.first { $0.identity.kind == .nativePlugin })
        let child = try #require(document.artifacts.first { $0.identity.displayName == "Browse" })
        #expect(parent.authority == .nativeOwned)
        #expect(parent.nativeRoutes == [.init(client: .codex, externalPluginID: "browser")])
        #expect(child.identity.parentPackageID == parent.identity.id)
        #expect(child.authority == .nativeOwned)
        #expect(preview.items.first { $0.legacy == Self.key(.plugin, "browser") }?.bundledChildCount == 1)
    }

    @Test func nativePluginRetainsDeclaredMCPChildWithoutInventingAFileOrDefinition() async throws {
        let fixture = try WorkspaceMigrationServiceTests.Fixture()
        defer { fixture.remove() }
        var snapshot = fixture.snapshot(label: "personal")
        var native = fixture.nativeSnapshot()
        native.mcpServers = [MCPServer(
            id: "browser-tools",
            name: "Browser tools",
            summary: "Native plugin declaration",
            endpoint: "Native plugin declaration",
            transport: .stdio,
            authentication: "Not inferred",
            scope: "This Mac",
            clients: [],
            definitionOrigin: .observed
        )]
        native.targetObservations[0].discoveredMCPServers = ["browser-tools"]
        native.targetObservations[0].pluginMetadata["browser"]?.mcpServerIDs = ["browser-tools"]
        snapshot.skills += native.skills
        snapshot.mcpServers = native.mcpServers
        snapshot.plugins = native.plugins
        snapshot.profiles += native.profiles
        snapshot.targetObservations = native.targetObservations
        try fixture.legacy.saveWorkspaceSnapshot(snapshot)
        try Self.installManagedFixture(fixture)
        let checkpoint = try await WorkspaceLegacyCheckpoint.capture(databaseURL: fixture.legacy.databaseURL)
        let personal = WorkspaceMigrationInventoryChoice(
            legacy: Self.key(.skill, "owned"), strategy: .centralPersonal)
        let nativePackage = WorkspaceMigrationInventoryChoice(
            legacy: Self.key(.plugin, "browser"),
            strategy: .nativePackage(
                routes: [.init(client: .codex, externalPluginID: "browser")],
                children: [
                    .init(legacy: Self.key(.skill, "browse"), packageRelativePath: "skills/browse"),
                    .init(legacy: Self.key(.mcpServer, "browser-tools")),
                ]
            )
        )
        let preview = try await WorkspaceMigrationCandidatePreparationService().preview(Self.request(
            fixture,
            checkpoint: checkpoint,
            choices: [personal, nativePackage]
        ))

        let preparation = try #require(preview.preparation)
        let parent = try #require(preparation.record.document.artifacts.first { $0.identity.kind == .nativePlugin })
        let child = try #require(preparation.record.document.artifacts.first {
            $0.identity.kind == .mcpServer && $0.identity.parentPackageID == parent.identity.id
        })
        #expect(child.declaredName == "browser-tools")
        #expect(child.packageRelativePath == nil)
        #expect(child.contentDigest == nil)
        #expect(child.nativeRoutes.isEmpty)
        #expect(preparation.record.document.mcpDefinitions?.isEmpty == true)
        #expect(!preparation.record.manifest.content.contains { $0.artifactID == child.identity.id })

        let inventedPath = WorkspaceMigrationInventoryChoice(
            legacy: Self.key(.plugin, "browser"),
            strategy: .nativePackage(
                routes: [.init(client: .codex, externalPluginID: "browser")],
                children: [
                    .init(legacy: Self.key(.skill, "browse"), packageRelativePath: "skills/browse"),
                    .init(legacy: Self.key(.mcpServer, "browser-tools"), packageRelativePath: "mcp.json"),
                ]
            )
        )
        let rejected = try await WorkspaceMigrationCandidatePreparationService().preview(Self.request(
            fixture,
            checkpoint: checkpoint,
            choices: [personal, inventedPath]
        ))
        #expect(rejected.issues.contains { $0.kind == .invalidNativePackage })
    }

    @Test func incompleteNativeGraphAndStandaloneChildSelectionAreBlocked() async throws {
        let fixture = try WorkspaceMigrationServiceTests.Fixture()
        defer { fixture.remove() }
        try fixture.legacy.saveWorkspaceSnapshot(fixture.nativeSnapshot())
        let checkpoint = try await WorkspaceLegacyCheckpoint.capture(databaseURL: fixture.legacy.databaseURL)
        let child = WorkspaceMigrationInventoryChoice(
            legacy: Self.key(.skill, "browse"),
            strategy: .trackedOnly
        )
        let parent = WorkspaceMigrationInventoryChoice(
            legacy: Self.key(.plugin, "browser"),
            strategy: .nativePackage(
                routes: [.init(client: .codex, externalPluginID: "browser")],
                children: [.init(legacy: Self.key(.skill, "browse"), packageRelativePath: "skills/browse")]
            )
        )
        let preview = try await WorkspaceMigrationCandidatePreparationService().preview(Self.request(
            fixture, checkpoint: checkpoint, choices: [parent, child]
        ))

        #expect(!preview.canPrepare)
        #expect(preview.issues.contains { $0.kind == .invalidNativePackage && $0.legacy == child.legacy })
    }

    @Test func missingDerivedPersonalTreeAndDuplicateChoicesRemainTyped() async throws {
        let fixture = try WorkspaceMigrationServiceTests.Fixture()
        defer { fixture.remove() }
        try fixture.legacy.saveWorkspaceSnapshot(fixture.snapshot(label: "personal"))
        let checkpoint = try await WorkspaceLegacyCheckpoint.capture(databaseURL: fixture.legacy.databaseURL)
        let choice = WorkspaceMigrationInventoryChoice(
            legacy: Self.key(.skill, "owned"),
            strategy: .centralPersonal
        )
        let duplicate = try await WorkspaceMigrationCandidatePreparationService().preview(Self.request(
            fixture, checkpoint: checkpoint, choices: [choice, choice]
        ))
        #expect(duplicate.issues.map(\.kind) == [.duplicateChoice])

        let missing = try await WorkspaceMigrationCandidatePreparationService().preview(Self.request(
            fixture, checkpoint: checkpoint, choices: [choice]
        ))
        #expect(!missing.canPrepare)
        #expect(missing.issues.map(\.kind) == [.missingPersonalContent])
    }

    @Test func shuffledChoicesProduceTheSameSealedCandidate() async throws {
        let fixture = try WorkspaceMigrationServiceTests.Fixture()
        defer { fixture.remove() }
        var snapshot = fixture.snapshot(label: "personal")
        snapshot.skills.append(Self.unmanagedSkill("observed"))
        try fixture.legacy.saveWorkspaceSnapshot(snapshot)
        try Self.installManagedFixture(fixture)
        let checkpoint = try await WorkspaceLegacyCheckpoint.capture(databaseURL: fixture.legacy.databaseURL)
        let personal = WorkspaceMigrationInventoryChoice(
            legacy: Self.key(.skill, "owned"), strategy: .centralPersonal)
        let tracked = WorkspaceMigrationInventoryChoice(
            legacy: Self.key(.skill, "observed"), strategy: .trackedOnly)
        let service = WorkspaceMigrationCandidatePreparationService()
        let first = try await service.preview(Self.request(fixture, checkpoint: checkpoint, choices: [personal, tracked]))
        let second = try await service.preview(Self.request(fixture, checkpoint: checkpoint, choices: [tracked, personal]))

        let firstDocument = try #require(first.preparation?.record.document)
        let secondDocument = try #require(second.preparation?.record.document)
        #expect(try WorkspaceDocumentCoding.encode(firstDocument) == WorkspaceDocumentCoding.encode(secondDocument))
        #expect(first.items == second.items)
    }

    private static func request(
        _ fixture: WorkspaceMigrationServiceTests.Fixture,
        checkpoint: WorkspaceLegacyCheckpoint,
        choices: [WorkspaceMigrationInventoryChoice]
    ) -> WorkspaceMigrationCandidatePreparationRequest {
        .init(
            attemptID: WorkspaceObjectID(rawValue: UUID(uuidString: "00000000-0000-0000-0000-000000000701")!),
            checkpoint: checkpoint,
            legacyDatabaseURL: fixture.legacy.databaseURL,
            context: fixture.context,
            choices: choices
        )
    }

    private static func installManagedFixture(_ fixture: WorkspaceMigrationServiceTests.Fixture) throws {
        let destination = managedSkillURL(fixture)
        try FileManager.default.createDirectory(
            at: destination.deletingLastPathComponent(),
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try FileManager.default.copyItem(at: fixture.source, to: destination)
    }

    private static func managedSkillURL(_ fixture: WorkspaceMigrationServiceTests.Fixture) -> URL {
        fixture.legacy.rootURL
            .appending(path: "library/packages/standalone/skills/owned", directoryHint: .isDirectory)
    }

    private static func unmanagedSkill(_ id: String) -> Skill {
        .init(
            id: id, name: id, displayName: id.capitalized, summary: "Observed",
            bundle: "standalone", scope: "This Mac", owned: false, triggers: [], negativeTrigger: "",
            files: ["SKILL.md"], clients: [], validationCount: 0
        )
    }

    private static func key(_ domain: LegacyReferenceDomain, _ identifier: String) -> LegacyReferenceKey {
        .init(domain: domain, identifier: identifier)
    }
}
