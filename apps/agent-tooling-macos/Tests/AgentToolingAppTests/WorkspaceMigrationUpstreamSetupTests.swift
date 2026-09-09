import Darwin
import Foundation
import Testing

@testable import AgentToolingCore
@testable import AgentToolingApp

@MainActor
struct WorkspaceMigrationUpstreamSetupTests {
    @Test func selectingAnUpstreamCandidateCapturesItsTreeAndPrepares() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let session = WorkspaceMigrationSetupSession(location: fixture.location)
        await session.inspect()
        let requirement = try #require(session.upstreamIntake?.requirements.first)
        #expect(requirement.candidates.count == 2)
        let candidate = try #require(requirement.candidates.first { $0.directoryPath == fixture.pathB.path })
        await session.selectUpstreamFolder(candidate.id, for: requirement.legacy)
        #expect(session.upstreamIntake?.selections[requirement.legacy] == candidate.id)
        #expect(session.preview?.canPrepare == true, "\(session.preview?.issues ?? [])")
        let preparation = try #require(session.preview?.preparation)
        #expect(preparation.record.manifest.sourceCaptures.count == 1)
        #expect(preparation.content.count == 1)
        #expect(preparation.record.manifest.sourceCaptures.first?.directoryPath == fixture.pathB.path)
        let contentID = try #require(preparation.record.manifest.content.first?.artifactID)
        let captured = try #require(preparation.content[contentID])
        #expect(captured.entries.contains(.init(relativePath: "REFERENCE.md", kind: .file(
            bytes: Data("reference B\n".utf8), executable: false))))
        let artifact = try #require(preparation.record.document.artifacts.first)
        let subscription = try #require(preparation.record.document.subscriptions.first)
        #expect(artifact.authority == .centralUpstream(subscriptionID: subscription.id))
        #expect(subscription.artifactID == artifact.identity.id)
        await session.stage()
        #expect(session.reviewSession?.state?.journalEntry.phase == .prepared)
    }

    @Test func changingSelectedTreeBlocksStaleStage() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let session = WorkspaceMigrationSetupSession(location: fixture.location)
        await session.inspect()
        let requirement = try #require(session.upstreamIntake?.requirements.first)
        let candidate = try #require(requirement.candidates.first { $0.directoryPath == fixture.pathB.path })
        await session.selectUpstreamFolder(candidate.id, for: requirement.legacy)
        #expect(session.upstreamIntake?.selections[requirement.legacy] == candidate.id)
        try Data("changed after review\n".utf8).write(to: fixture.pathB.appending(path: "REFERENCE.md"))
        await session.stage()
        #expect(session.reviewSession == nil)
        #expect(session.errorMessage != nil)
    }

    @Test func bindingRevisionChangeAndCollapsedPathsRequireExplicitReselection() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let session = WorkspaceMigrationSetupSession(location: fixture.location)
        await session.inspect()
        let requirement = try #require(session.upstreamIntake?.requirements.first)
        let candidate = try #require(requirement.candidates.first)
        await session.selectUpstreamFolder(candidate.id, for: requirement.legacy)
        #expect(session.upstreamIntake?.selections[requirement.legacy] == candidate.id)
        try fixture.rewriteBinding(revision: String(repeating: "b", count: 40), paths: [fixture.pathA.path])
        await session.inspect()
        #expect(session.upstreamIntake?.selections[requirement.legacy] == nil)
        #expect(session.preview?.canPrepare == false)
        let refreshed = try #require(session.upstreamIntake?.requirements.first)
        #expect(refreshed.candidates.count == 1)
        await session.selectUpstreamFolder(refreshed.candidates[0].id, for: refreshed.legacy)
        #expect(session.preview?.canPrepare == true)
    }

    @Test func exportsUnmigratedUpstreamFixtureWhenRequested() throws {
        guard let output = ProcessInfo.processInfo.environment["WORKSPACE_MIGRATION_UPSTREAM_FIXTURE"] else { return }
        let fixture = try Fixture()
        do {
            let payload: [String: Any] = ["workspace": fixture.store.rootURL.path, "home": fixture.location.homeRoot.path,
                "pathA": fixture.pathA.path, "pathB": fixture.pathB.path, "skill": "upstream"]
            try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
                .write(to: URL(fileURLWithPath: output), options: .withoutOverwriting)
        } catch {
            fixture.remove()
            throw error
        }
    }

    private final class Fixture {
        let root: URL
        let store: WorkspaceStore
        let location: WorkspaceMigrationLegacyLocation
        let pathA: URL
        let pathB: URL
        var snapshot: WorkspaceSnapshot

        init() throws {
            root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
                .appending(path: "migration-upstream-\(UUID().uuidString)")
            store = try WorkspaceStore(rootURL: root.appending(path: "legacy"))
            let home = root.appending(path: "home")
            try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700])
            location = .init(legacyRoot: store.rootURL, homeRoot: home)
            pathA = root.appending(path: "repo-a/upstream").resolvingSymlinksInPath()
            pathB = root.appending(path: "repo-b/upstream").resolvingSymlinksInPath()
            for (path, marker) in [(pathA, "A"), (pathB, "B")] {
                try FileManager.default.createDirectory(at: path, withIntermediateDirectories: true,
                    attributes: [.posixPermissions: 0o700])
                try Data("---\nname: upstream\ndescription: Upstream fixture\n---\n\n# \(marker)\n".utf8)
                    .write(to: path.appending(path: "SKILL.md"))
                try Data("reference \(marker)\n".utf8).write(to: path.appending(path: "REFERENCE.md"))
            }
            let fingerprints = [pathA.path: try DirectoryFingerprint.sha256(of: pathA), pathB.path: try DirectoryFingerprint.sha256(of: pathB)]
            var binding = try SkillRepositoryBinding(repositoryURL: "https://github.com/example/skills", ref: "main",
                subdirectory: "upstream", installedFingerprints: fingerprints)
            binding.installedRevision = String(repeating: "a", count: 40)
            var skill = Skill(id: "upstream", name: "upstream", displayName: "Upstream", summary: "Fixture",
                bundle: "standalone", scope: "This Mac", owned: true, triggers: [], negativeTrigger: "",
                files: ["SKILL.md", "REFERENCE.md"], clients: [.init(client: .codex, state: .healthy, detail: "Found", isInstalled: true)], validationCount: 0)
            skill.repositoryBinding = binding
            let profile = ToolingProfile(id: "profile", name: "Profile", summary: "Fixture", checks: [], enabledPlugins: [],
                requiredMCPs: [], requiredSkills: [skill.id])
            var preferences = WorkspacePreferences(enabledClients: [.codex]); preferences.automaticallyCheckHealth = false
            snapshot = .init(skills: [skill], profiles: [profile], activeProfileID: profile.id, preferences: preferences)
            try store.saveWorkspaceSnapshot(snapshot)
        }

        func rewriteBinding(revision: String, paths: [String]) throws {
            var updated = snapshot
            guard var binding = updated.skills.first?.repositoryBinding else { return }
            binding.installedRevision = revision
            binding.installedFingerprints = Dictionary(uniqueKeysWithValues: paths.compactMap { path in
                guard let fingerprint = try? DirectoryFingerprint.sha256(of: URL(fileURLWithPath: path)) else { return nil }
                return (path, fingerprint)
            })
            updated.skills[0].repositoryBinding = binding
            snapshot = updated
            try store.saveWorkspaceSnapshot(updated)
        }

        func remove() {
            func unlock(_ url: URL) { var s = stat(); guard lstat(url.path, &s) == 0 else { return }; _ = chmod(url.path, 0o700); guard s.st_mode & S_IFMT == S_IFDIR else { return }; for child in (try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil)) ?? [] { unlock(child) } }
            unlock(root); try? FileManager.default.removeItem(at: root)
        }
    }
}
