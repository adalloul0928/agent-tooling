import Foundation
import Testing

@testable import AgentToolingCore

struct WorkspaceMigrationServiceTests {
    @Test func stagesReopensAndInitializesTheReviewedCompleteFolderWithoutTouchingLegacyOrNative() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.legacy.saveWorkspaceSnapshot(fixture.snapshot(label: "reviewed"))
        let preparation = try await fixture.preparation()
        let beforeLegacy = try AgentToolingCoding.encoder().encode(
            try #require(try fixture.legacy.loadWorkspaceSnapshot()))
        let beforeNative = try Data(contentsOf: fixture.nativeSentinel)

        let first = try await fixture.service().stage(preparation)
        #expect(first.phase == .prepared)
        #expect(first.record.manifest.deploymentNames.count == 1)
        #expect(first.record.manifest.deploymentNames.first?.name == "owned")

        let reopened = try fixture.service()
        #expect(try await reopened.journal() == [first])
        let initialized = try await reopened.initialize(
            attemptID: preparation.record.manifest.attemptID,
            inputDigest: try preparation.record.inputDigest)
        #expect(initialized.phase == .initialized)

        let stored = try #require(try fixture.revisionStore().snapshot())
        #expect(stored.document.assignments == preparation.record.document.assignments)
        #expect(stored.document.assignments.count == 1)
        #expect(stored.document.assignments[0].desiredEnabled == true)
        let content = try await fixture.contentStore().read(preparation.record.manifest.content[0].digest)
        #expect(content == preparation.content[preparation.record.manifest.content[0].artifactID])
        #expect(content.entries.contains(.init(relativePath: "resources", kind: .directory)))
        #expect(content.entries.contains(.init(relativePath: "scripts/run", kind: .file(
            bytes: Data("#!/bin/sh\necho owned\n".utf8), executable: true))))
        #expect(content.entries.contains(.init(relativePath: "README", kind: .symbolicLink(target: "SKILL.md"))))
        #expect(try AgentToolingCoding.encoder().encode(
            try #require(try fixture.legacy.loadWorkspaceSnapshot())) == beforeLegacy)
        #expect(try Data(contentsOf: fixture.nativeSentinel) == beforeNative)
    }

    @Test func changedLegacyAfterStageBlocksInitializationAndLeavesTheNewStoreEmpty() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.legacy.saveWorkspaceSnapshot(fixture.snapshot(label: "reviewed"))
        let preparation = try await fixture.preparation()
        let service = try fixture.service()
        _ = try await service.stage(preparation)
        try fixture.legacy.saveWorkspaceSnapshot(fixture.snapshot(label: "changed"))

        await #expect(throws: WorkspaceMigrationError.changedLegacyStore) {
            _ = try await service.initialize(attemptID: preparation.record.manifest.attemptID,
                inputDigest: try preparation.record.inputDigest)
        }
        #expect(try fixture.revisionStore().snapshot() == nil)
        #expect(try fixture.revisionStore().migration(preparation.record.manifest.attemptID)?.phase == .prepared)
    }

    @Test func changedSourceAfterStageBlocksInitialization() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.legacy.saveWorkspaceSnapshot(fixture.snapshot(label: "reviewed"))
        let preparation = try await fixture.preparation()
        let service = try fixture.service()
        _ = try await service.stage(preparation)
        try Data("changed source\n".utf8).write(to: fixture.source.appending(path: "SKILL.md"))

        do {
            _ = try await service.initialize(attemptID: preparation.record.manifest.attemptID,
                inputDigest: try preparation.record.inputDigest)
            Issue.record("Changing the reviewed source must require a new preparation.")
        } catch let error as WorkspaceMigrationError {
            guard case .changedSource = error else {
                Issue.record("Expected changedSource, got \(error)")
                return
            }
        }
        #expect(try fixture.revisionStore().snapshot() == nil)
    }

    @Test func initializedReceiptReplaysHistoricallyAfterLaterPortableAndLegacyEdits() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.legacy.saveWorkspaceSnapshot(fixture.snapshot(label: "reviewed"))
        let preparation = try await fixture.preparation()
        let service = try fixture.service()
        _ = try await service.stage(preparation)
        _ = try await service.initialize(attemptID: preparation.record.manifest.attemptID,
            inputDigest: try preparation.record.inputDigest)

        let revisionStore = try fixture.revisionStore()
        let initial = try #require(try revisionStore.snapshot())
        _ = try revisionStore.commitMetadata(
            expectedRevisionID: initial.document.revision.id,
            idempotencyKey: WorkspaceObjectID(),
            inputDigest: String(repeating: "a", count: 64),
            writerID: WorkspaceObjectID()) { document in
                document.artifacts[0].identity.displayName = "Renamed after migration"
                return [document.artifacts[0].identity.id]
            }
        try fixture.legacy.saveWorkspaceSnapshot(fixture.snapshot(label: "legacy later"))

        let replay = try await fixture.service().initialize(
            attemptID: preparation.record.manifest.attemptID,
            inputDigest: try preparation.record.inputDigest)
        #expect(replay.phase == .initialized)
        #expect(try fixture.revisionStore().snapshot()?.document.artifacts[0].identity.displayName
            == "Renamed after migration")
        #expect(try fixture.legacy.loadWorkspaceSnapshot()?.profiles.first?.id == "legacy later")
    }

    @Test func sameAttemptWithDifferentSealedCandidateIsAnIdempotencyConflict() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.legacy.saveWorkspaceSnapshot(fixture.snapshot(label: "reviewed"))
        let original = try await fixture.preparation()
        _ = try await fixture.service().stage(original)
        let conflicting = try await fixture.preparation(displayName: "Different reviewed name")

        await #expect(throws: WorkspaceMigrationError.preparationConflict) {
            _ = try await fixture.service().stage(conflicting)
        }
        #expect(try fixture.revisionStore().migration(original.record.manifest.attemptID)?.record
            == original.record)
    }

    @Test func nativePluginAndChildStageWithoutStandaloneContentOrDeployment() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.legacy.saveWorkspaceSnapshot(fixture.nativeSnapshot())
        let preparation = try await fixture.nativePreparation()

        #expect(preparation.record.manifest.content.isEmpty)
        #expect(preparation.record.manifest.sourceCaptures.isEmpty)
        #expect(preparation.record.manifest.deploymentNames.isEmpty)
        let service = try fixture.service()
        _ = try await service.stage(preparation)
        _ = try await service.initialize(attemptID: preparation.record.manifest.attemptID,
            inputDigest: try preparation.record.inputDigest)

        let document = try #require(try fixture.revisionStore().snapshot()?.document)
        let parent = try #require(document.artifacts.first { $0.identity.kind == .nativePlugin })
        let child = try #require(document.artifacts.first { $0.identity.kind == .skill })
        #expect(parent.authority == .nativeOwned)
        #expect(parent.nativeRoutes == [.init(client: .codex, externalPluginID: "browser")])
        #expect(child.authority == .nativeOwned)
        #expect(child.identity.parentPackageID == parent.identity.id)
    }

    @Test(arguments: [true, false])
    func explicitNativeSelectionRequiresScopeAndPersistsItsEnablement(_ enabled: Bool) async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        var snapshot = fixture.nativeSnapshot()
        snapshot.profiles[0].enabledPlugins = enabled ? ["browser"] : []
        snapshot.profiles[0].targetBindings = [.init(item: .init(kind: .plugin, identifier: "browser"),
            client: .codex, enabled: enabled)]
        try fixture.legacy.saveWorkspaceSnapshot(snapshot)
        await #expect(throws: WorkspaceMigrationError.needsReview) {
            _ = try await fixture.nativePreparation()
        }
        let preparation = try await fixture.nativePreparation(scope: .user)
        #expect(preparation.record.document.assignments.count == 1)
        #expect(preparation.record.document.assignments.first?.desiredEnabled == enabled)
        let service = try fixture.service()
        _ = try await service.stage(preparation)
        _ = try await service.initialize(attemptID: preparation.record.manifest.attemptID,
            inputDigest: try preparation.record.inputDigest)
        let stored = try #require(try fixture.revisionStore().snapshot())
        #expect(stored.document.assignments == preparation.record.document.assignments)
        #expect(preparation.record.manifest.content.isEmpty)
        #expect(preparation.record.manifest.deploymentNames.isEmpty)
    }

    struct Fixture {
        let root: URL
        let legacy: WorkspaceStore
        let source: URL
        let nativeSentinel: URL
        let context: WorkspaceMigrationContext

        init() throws {
            root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
                .appending(path: "workspace-migration-service-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700])
            for directory in ["checkpoints", "content", "revisions"] {
                try FileManager.default.createDirectory(at: root.appending(path: directory), withIntermediateDirectories: false,
                    attributes: [.posixPermissions: 0o700])
            }
            legacy = try WorkspaceStore(rootURL: root.appending(path: "legacy"))
            source = root.appending(path: "source")
            try FileManager.default.createDirectory(at: source.appending(path: "resources"), withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: source.appending(path: "scripts"), withIntermediateDirectories: true)
            try Data("---\nname: owned\ndescription: Owned migration fixture\n---\n\n# Owned\n".utf8)
                .write(to: source.appending(path: "SKILL.md"))
            let script = source.appending(path: "scripts/run")
            try Data("#!/bin/sh\necho owned\n".utf8).write(to: script)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)
            try FileManager.default.createSymbolicLink(
                atPath: source.appending(path: "README").path,
                withDestinationPath: "SKILL.md")
            let native = root.appending(path: "native")
            try FileManager.default.createDirectory(at: native, withIntermediateDirectories: true)
            nativeSentinel = native.appending(path: "unmanaged.txt")
            try Data("native remains unmanaged".utf8).write(to: nativeSentinel)
            context = .init(
                workspaceID: Self.id("00000000-0000-0000-0000-000000000101"),
                deviceID: Self.id("00000000-0000-0000-0000-000000000102"),
                revision: .init(id: Self.id("00000000-0000-0000-0000-000000000103"),
                    writerID: Self.id("00000000-0000-0000-0000-000000000104"),
                    createdAt: Date(timeIntervalSince1970: 1_700_000_000)))
        }

        func remove() {
            // Immutable central objects deliberately contain non-writable
            // directories. Only make this disposable fixture tree removable;
            // lstat keeps internal links from escaping it during cleanup.
            func makeRemovable(_ url: URL) {
                var value = stat()
                guard lstat(url.path, &value) == 0, value.st_mode & S_IFMT == S_IFDIR else { return }
                _ = chmod(url.path, 0o700)
                for child in (try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil)) ?? [] {
                    makeRemovable(child)
                }
            }
            makeRemovable(root)
            try? FileManager.default.removeItem(at: root)
        }

        func snapshot(label: String) -> WorkspaceSnapshot {
            let skill = Skill(id: "owned", name: "owned", displayName: "Owned", summary: "Fixture",
                bundle: "standalone", scope: "This Mac", owned: true, triggers: [], negativeTrigger: "",
                files: ["SKILL.md"], clients: [.init(client: .codex, state: .healthy, detail: "Found", isInstalled: true)],
                validationCount: 0)
            let binding = OnboardingTargetBinding(item: .init(kind: .skill, identifier: "owned"), client: .codex, enabled: true)
            let profile = ToolingProfile(id: label, name: label, summary: "Fixture", scope: .user,
                checks: [], enabledPlugins: [], requiredMCPs: [], requiredSkills: ["owned"], targetBindings: [binding])
            return WorkspaceSnapshot(skills: [skill], profiles: [profile], activeProfileID: label,
                preferences: .init(enabledClients: [.codex]))
        }

        func nativeSnapshot() -> WorkspaceSnapshot {
            let skill = Skill(id: "browse", name: "browse", displayName: "Browse", summary: "Native child",
                bundle: "browser", scope: "This Mac", owned: false, triggers: [], negativeTrigger: "",
                files: ["SKILL.md"], clients: [], validationCount: 0)
            let plugin = Plugin(id: "browser", name: "Browser", summary: "Native package", source: "Codex",
                scope: "This Mac", revision: "current", skills: ["browse"], profiles: [],
                clients: [.init(client: .codex, state: .healthy, detail: "Found", isInstalled: true)], installed: true)
            let observation = TargetObservation(
                surface: .codexCLI, installed: true, commandAvailable: true,
                discoveredSkills: ["browse"], discoveredPlugins: ["browser"],
                skillMetadata: ["browse": .init(path: "/private/native/skills/browse", source: "Native",
                    providerPluginID: "browser")],
                pluginMetadata: ["browser": .init(name: "Browser", source: "/private/native", scope: "This Mac",
                    enabled: true, skillIDs: ["browse"])],
                capabilities: .init(supportsPluginInstall: true, supportsProjectScope: true,
                    supportsLocalMarketplace: true, supportsMCPAuthentication: false,
                    supportsConnectorDiscovery: false, requiresNewSession: true, requiresRestart: false,
                    supportsMachineReadableOutput: true),
                lastScannedAt: Date(timeIntervalSince1970: 1_700_000_000))
            let profile = ToolingProfile(id: "native", name: "Native", summary: "Fixture", scope: .user,
                checks: [], enabledPlugins: [], requiredMCPs: [], requiredSkills: ["browse"])
            return WorkspaceSnapshot(skills: [skill], plugins: [plugin], profiles: [profile],
                targetObservations: [observation], activeProfileID: "native")
        }

        func preparation(displayName: String = "Owned") async throws -> WorkspaceMigrationPreparation {
            let checkpoint = try await WorkspaceLegacyCheckpoint.capture(databaseURL: legacy.databaseURL)
            let tree = try await PackageTreeCapture().capture(directory: source)
            let key = LegacyReferenceKey(domain: .skill, identifier: "owned")
            let mapping = try WorkspaceMigrationIdentity.mapping(keys: [key], workspaceID: context.workspaceID)
            let artifactID = ArtifactID(try #require(mapping.first?.objectID.rawValue))
            var decisions = WorkspaceMigrationDecisions()
            decisions.artifacts = [.init(legacy: key, artifact: .init(
                identity: .init(id: artifactID, kind: .skill, displayName: displayName),
                authority: .centralPersonal, declaredName: "owned", contentDigest: tree.digest))]
            decisions.rootContent = [artifactID: tree]
            return try WorkspaceMigrationPreparation.build(
                attemptID: Self.id("00000000-0000-0000-0000-000000000105"), checkpoint: checkpoint,
                legacyDatabaseURL: legacy.databaseURL, context: context, decisions: decisions,
                sourceDirectories: [artifactID: source])
        }

        func nativePreparation(scope: ToolingScope? = nil) async throws -> WorkspaceMigrationPreparation {
            let checkpoint = try await WorkspaceLegacyCheckpoint.capture(databaseURL: legacy.databaseURL)
            let skillKey = LegacyReferenceKey(domain: .skill, identifier: "browse")
            let pluginKey = LegacyReferenceKey(domain: .plugin, identifier: "browser")
            let mapping = try WorkspaceMigrationIdentity.mapping(keys: [skillKey, pluginKey], workspaceID: context.workspaceID)
            let skillID = ArtifactID(try #require(mapping.first { $0.legacy == skillKey }?.objectID.rawValue))
            let pluginID = ArtifactID(try #require(mapping.first { $0.legacy == pluginKey }?.objectID.rawValue))
            var parent = ArtifactRecord(
                identity: .init(id: pluginID, kind: .nativePlugin, displayName: "Browser"),
                authority: .nativeOwned,
                nativeRoutes: [.init(client: .codex, externalPluginID: "browser")])
            parent.declaredName = "browser"
            let child = ArtifactRecord(
                identity: .init(id: skillID, kind: .skill, displayName: "Browse", parentPackageID: pluginID),
                authority: .nativeOwned,
                declaredName: "browse",
                packageRelativePath: "skills/browse")
            var decisions = WorkspaceMigrationDecisions()
            decisions.artifacts = [
                .init(legacy: pluginKey, artifact: parent),
                .init(legacy: skillKey, artifact: child),
            ]
            return try WorkspaceMigrationPreparation.build(
                attemptID: Self.id("00000000-0000-0000-0000-000000000106"), checkpoint: checkpoint,
                legacyDatabaseURL: legacy.databaseURL, context: context, decisions: decisions,
                sourceDirectories: [:],
                nativePluginPlacements: scope.map { [.init(artifactID: pluginID, client: .codex, scope: $0)] } ?? [])
        }

        func revisionStore() throws -> WorkspaceRevisionStore {
            try WorkspaceRevisionStore(containerRoot: root.appending(path: "revisions"),
                workspaceID: context.workspaceID, deviceID: context.deviceID)
        }

        func contentStore() throws -> CentralPackageContentStore {
            try CentralPackageContentStore(directory: root.appending(path: "content"))
        }

        func checkpointStore() throws -> WorkspaceLegacyCheckpointStore {
            try WorkspaceLegacyCheckpointStore(directory: root.appending(path: "checkpoints"))
        }

        func service() throws -> WorkspaceMigrationService {
            try .init(store: revisionStore(), checkpoints: checkpointStore(), content: contentStore())
        }

        private static func id(_ value: String) -> WorkspaceObjectID {
            WorkspaceObjectID(UUID(uuidString: value)!)
        }
    }
}
