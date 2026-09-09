import Darwin
import Foundation
import Testing

@testable import AgentToolingCore

struct WorkspaceMigrationPilotFixtureTests {
    @Test func exportsPreparedPersonalAndNativePilotOnlyWhenExplicitlyRequested() async throws {
        let fixture = try WorkspaceMigrationServiceTests.Fixture()
        var retainFixture = false
        defer {
            if !retainFixture { fixture.remove() }
        }

        var snapshot = fixture.snapshot(label: "my-setup")
        snapshot.profiles[0].name = "My setup"
        snapshot.preferences.automaticallyCheckHealth = false
        let native = fixture.nativeSnapshot()
        snapshot.skills += native.skills
        snapshot.plugins = native.plugins
        snapshot.profiles += native.profiles
        snapshot.targetObservations = native.targetObservations
        try fixture.legacy.saveWorkspaceSnapshot(snapshot)

        let personalTree = try await PackageTreeCapture().capture(directory: fixture.source)
        let personalKey = LegacyReferenceKey(domain: .skill, identifier: "owned")
        let pluginKey = LegacyReferenceKey(domain: .plugin, identifier: "browser")
        let childKey = LegacyReferenceKey(domain: .skill, identifier: "browse")
        let identities = try WorkspaceMigrationIdentity.mapping(
            keys: [personalKey, pluginKey, childKey],
            workspaceID: fixture.context.workspaceID
        )
        func artifactID(_ key: LegacyReferenceKey) throws -> ArtifactID {
            ArtifactID(try #require(identities.first { $0.legacy == key }?.objectID.rawValue))
        }
        let personalID = try artifactID(personalKey)
        let pluginID = try artifactID(pluginKey)
        let childID = try artifactID(childKey)

        var plugin = ArtifactRecord(
            identity: .init(id: pluginID, kind: .nativePlugin, displayName: "Browser"),
            authority: .nativeOwned,
            nativeRoutes: [.init(client: .codex, externalPluginID: "browser")]
        )
        plugin.declaredName = "browser"
        let child = ArtifactRecord(
            identity: .init(
                id: childID,
                kind: .skill,
                displayName: "Browse",
                parentPackageID: pluginID
            ),
            authority: .nativeOwned,
            declaredName: "browse",
            packageRelativePath: "skills/browse"
        )
        var decisions = WorkspaceMigrationDecisions()
        decisions.artifacts = [
            .init(
                legacy: personalKey,
                artifact: .init(
                    identity: .init(id: personalID, kind: .skill, displayName: "Owned"),
                    authority: .centralPersonal,
                    declaredName: "owned",
                    contentDigest: personalTree.digest
                )
            ),
            .init(legacy: pluginKey, artifact: plugin),
            .init(legacy: childKey, artifact: child),
        ]
        decisions.rootContent = [personalID: personalTree]

        let checkpoint = try await WorkspaceLegacyCheckpoint.capture(databaseURL: fixture.legacy.databaseURL)
        let preparation = try WorkspaceMigrationPreparation.build(
            attemptID: WorkspaceObjectID(),
            checkpoint: checkpoint,
            legacyDatabaseURL: fixture.legacy.databaseURL,
            context: fixture.context,
            decisions: decisions,
            sourceDirectories: [personalID: fixture.source]
        )
        _ = try await fixture.service().stage(preparation)

        let location = WorkspaceMigrationReviewLocation(
            legacyRoot: fixture.legacy.rootURL,
            containerRoot: fixture.root.appending(path: "revisions"),
            checkpointRoot: fixture.root.appending(path: "checkpoints"),
            contentRoot: fixture.root.appending(path: "content"),
            workspaceID: fixture.context.workspaceID,
            deviceID: fixture.context.deviceID,
            attemptID: preparation.record.manifest.attemptID
        )
        let state = try await WorkspaceMigrationReviewService(location: location).state()
        #expect(state.journalEntry.phase == .prepared)
        #expect(state.currentRevisionID == nil)
        #expect(state.authoritySelection == nil)
        #expect(state.reviewedSummary.centralPersonalCount == 1)
        #expect(state.reviewedSummary.nativeOwnedCount == 1)
        #expect(state.reviewedSummary.wholePluginChildCount == 1)
        let reviewedArtifacts = state.journalEntry.record.document.artifacts
        let reviewedPlugin = try #require(reviewedArtifacts.first { $0.identity.id == pluginID })
        let reviewedChild = try #require(reviewedArtifacts.first { $0.identity.id == childID })
        #expect(reviewedPlugin.authority == .nativeOwned)
        #expect(reviewedPlugin.nativeRoutes == [.init(client: .codex, externalPluginID: "browser")])
        #expect(reviewedChild.authority == .nativeOwned)
        #expect(reviewedChild.identity.parentPackageID == pluginID)
        #expect(state.journalEntry.record.manifest.content.map(\.artifactID) == [personalID])

        guard let descriptorPath = ProcessInfo.processInfo.environment["WORKSPACE_MIGRATION_PILOT_DESCRIPTOR"] else {
            return
        }
        let descriptorURL = URL(fileURLWithPath: descriptorPath)
        guard descriptorPath.hasPrefix("/"), descriptorPath != "/",
              descriptorURL.standardizedFileURL.path == descriptorPath,
              Self.pathEntryIsAbsent(descriptorPath) else {
            throw PilotFixtureError.invalidDescriptor
        }
        let home = fixture.root.appending(path: "home")
        try FileManager.default.createDirectory(
            at: home,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        try location.encode().write(to: descriptorURL, options: .withoutOverwriting)
        retainFixture = true
        print("Workspace migration pilot descriptor: \(descriptorURL.path)")
        print("Workspace migration pilot home: \(home.path)")
    }

    private enum PilotFixtureError: Error {
        case invalidDescriptor
    }

    private static func pathEntryIsAbsent(_ path: String) -> Bool {
        var metadata = stat()
        return lstat(path, &metadata) == -1 && errno == ENOENT
    }
}
