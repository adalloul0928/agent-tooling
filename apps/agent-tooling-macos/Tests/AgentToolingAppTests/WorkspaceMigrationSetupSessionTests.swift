import Darwin
import Foundation
import Testing

@testable import AgentToolingCore
@testable import AgentToolingApp

@MainActor
struct WorkspaceMigrationSetupSessionTests {
    @Test func inspectionDoesNotStageOrSwitchAndExplicitSaveOnlyPrepares() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let before = try WorkspaceLegacyCheckpoint.captureSynchronously(databaseURL: fixture.store.databaseURL)
        let session = WorkspaceMigrationSetupSession(location: fixture.location)
        let directoryBefore = try FileManager.default.contentsOfDirectory(atPath: fixture.store.rootURL.path).sorted()

        await session.inspect()

        #expect(session.preview?.canPrepare == true, "\(session.preview?.issues ?? [])")
        #expect(session.intake?.issues.isEmpty == true)
        #expect(session.reviewSession == nil)
        #expect(try FileManager.default.contentsOfDirectory(atPath: fixture.store.rootURL.path).sorted() == directoryBefore)
        await session.stage()
        let review = try #require(session.reviewSession, "\(session.errorMessage ?? "No review")")
        #expect(review.state?.journalEntry.phase == .prepared)
        #expect(review.state?.authoritySelection == nil)
        #expect(try WorkspaceRevisionStore(containerRoot: review.location.containerRoot,
            workspaceID: review.location.workspaceID, deviceID: review.location.deviceID,
            access: .existingReadOnly).snapshot() == nil)
        #expect(try WorkspaceLegacyCheckpoint.captureSynchronously(databaseURL: fixture.store.databaseURL).sha256 == before.sha256)
        #expect(try FileManager.default.contentsOfDirectory(atPath: fixture.location.homeRoot.path).isEmpty)
        let descriptor = review.location.containerRoot.deletingLastPathComponent().appending(path: "review.json")
        #expect(try WorkspaceMigrationReviewLocation.decode(Data(contentsOf: descriptor)) == review.location)
    }

    @Test func sourceChangeAfterInspectionCannotSaveAStaleReview() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let session = WorkspaceMigrationSetupSession(location: fixture.location)
        await session.inspect()
        #expect(session.preview?.canPrepare == true)
        try Data("changed after review".utf8).write(to: fixture.skillDirectory.appending(path: "SKILL.md"))

        await session.stage()

        #expect(session.reviewSession == nil)
        #expect(session.errorMessage != nil)
        #expect(try WorkspaceAuthorityStore(legacyRoot: fixture.store.rootURL).read() == nil)
    }

    @Test func missingPersonalFolderIsNotReclassifiedAsTracked() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try FileManager.default.removeItem(at: fixture.skillDirectory)
        let session = WorkspaceMigrationSetupSession(location: fixture.location)
        await session.inspect()
        #expect(session.preview?.canPrepare == false)
        #expect(session.preview?.issues.contains { $0.kind == .missingPersonalContent } == true)
        await session.stage()
        #expect(session.reviewSession == nil)
    }

    @Test func exportDisposableSettingsPilotWhenRequested() throws {
        guard let output = ProcessInfo.processInfo.environment["WORKSPACE_MIGRATION_SETUP_FIXTURE"] else { return }
        let fixture = try Fixture()
        do {
            let data = try JSONSerialization.data(withJSONObject: [
                "workspace": fixture.store.rootURL.path, "home": fixture.location.homeRoot.path], options: [.sortedKeys])
            try data.write(to: URL(fileURLWithPath: output), options: .withoutOverwriting)
        } catch {
            fixture.remove()
            throw error
        }
    }

    private struct Fixture {
        let root: URL
        let store: WorkspaceStore
        let location: WorkspaceMigrationLegacyLocation
        let skillDirectory: URL

        init() throws {
            root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
                .appending(path: "migration-setup-\(UUID().uuidString)")
            store = try WorkspaceStore(rootURL: root.appending(path: "legacy"))
            let home = root.appending(path: "home")
            try FileManager.default.createDirectory(at: home, withIntermediateDirectories: false)
            location = .init(legacyRoot: store.rootURL, homeRoot: home)
            skillDirectory = store.libraryURL.appending(path: "packages/personal/skills/owned")
            try FileManager.default.createDirectory(at: skillDirectory, withIntermediateDirectories: true)
            try Data("---\nname: owned\ndescription: Personal migration fixture\n---\n\nKeep complete folder contents.\n".utf8)
                .write(to: skillDirectory.appending(path: "SKILL.md"))
            let skill = Skill(id: "owned", name: "owned", displayName: "Owned", summary: "Personal migration fixture",
                bundle: "personal", scope: "This Mac", owned: true, triggers: [], negativeTrigger: "", files: ["SKILL.md"],
                clients: [.init(client: .codex, state: .healthy, detail: "Found", isInstalled: true)], validationCount: 0)
            let profile = ToolingProfile(id: "my-setup", name: "My setup", summary: "Migration fixture", checks: [],
                enabledPlugins: [], requiredMCPs: [], requiredSkills: [skill.id], targetBindings: [
                    .init(item: .init(kind: .skill, identifier: skill.id), client: .codex, enabled: true)])
            var preferences = WorkspacePreferences(enabledClients: [.codex])
            preferences.automaticallyCheckHealth = false
            try store.saveWorkspaceSnapshot(.init(skills: [skill], profiles: [profile], activeProfileID: profile.id,
                preferences: preferences))
        }

        func remove() {
            func unlock(_ url: URL) {
                var status = stat()
                guard lstat(url.path, &status) == 0, status.st_mode & S_IFMT == S_IFDIR else { return }
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
