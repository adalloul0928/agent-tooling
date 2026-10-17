import Foundation
import Testing

@testable import AgentToolingApp
@testable import AgentToolingCore

/// Updates: found on the policy's cadence, installed by policy or by a press,
/// and only into copies this app can prove are its own.
@Suite("Updates") @MainActor
struct WorkspaceUpdateSessionTests {
    private nonisolated static let repository = "https://github.com/publisher/skills"

    private nonisolated static func tree(body: String) throws -> CapturedPackageTree {
        try CapturedPackageTree(entries: [
            .init(relativePath: "SKILL.md", kind: .file(bytes: Data("""
                ---
                name: release-readiness
                description: Check whether a release is ready to ship.
                ---

                # Release Readiness

                \(body)
                """.utf8), executable: false)),
        ])
    }

    private nonisolated static func published(_ tree: CapturedPackageTree, revision: Character) throws -> PreparedStandaloneSkill {
        try PreparedStandaloneSkill(
            tree: tree,
            upstream: .init(
                repositoryURL: repository, requestedRef: "main",
                revision: .init(kind: .gitCommitSHA1, value: String(repeating: revision, count: 40)),
                packageRelativePath: "skills/release-readiness", publisherID: "github:publisher"))
    }

    /// A skill the library holds and follows, installed in Claude Code by
    /// this app, so there is a proven copy for an update to replace.
    private func followedSkill(in fixture: ShellRenderFixture) async throws -> ArtifactID {
        let tree = try Self.tree(body: "Version one")
        let personal = try WorkspaceSkillPreparation.personal(tree: tree)
        await fixture.workspace.library.refresh()
        var head = try #require(fixture.workspace.library.state?.snapshot.document.revision.id)
        let artifactID = ArtifactID()
        let intake = try await fixture.workspace.service.intakeStandaloneSkill(
            .init(expectedRevisionID: head, artifactID: artifactID, displayName: "Release Readiness", prepared: personal),
            prepared: personal)
        head = intake.committedRevisionID
        let published = try Self.published(tree, revision: "a")
        _ = try await fixture.workspace.service.linkSkillUpstream(
            try LinkSkillUpstreamCommand(
                expectedRevisionID: head, artifactID: artifactID, expectedContentDigest: tree.digest, prepared: published),
            prepared: published)
        await fixture.workspace.library.refresh()

        let install = WorkspaceInstallSession(
            library: fixture.workspace.library, deployment: fixture.workspace.deployment,
            device: fixture.workspace.device, service: fixture.workspace.service)
        await install.install(artifactIDs: [artifactID], destinations: [.init(surface: .claudeCode, scope: .user)])
        guard case .finished(let outcome) = install.phase, outcome.installed == [.claude] else {
            throw WorkspaceRevisionStoreError.notInitialized
        }
        return artifactID
    }

    private func session(
        _ fixture: ShellRenderFixture, publishing: @escaping @Sendable () throws -> PreparedStandaloneSkill
    ) -> WorkspaceUpdateSession {
        WorkspaceUpdateSession(
            library: fixture.workspace.library, deployment: fixture.workspace.deployment,
            device: fixture.workspace.device, marketplace: fixture.workspace.marketplace,
            service: fixture.workspace.service, store: fixture.workspace.store, homeRoot: fixture.home,
            fetchUpstream: { _, _ in try publishing() })
    }

    private func installedBody(_ fixture: ShellRenderFixture) throws -> String {
        let url = fixture.home.appending(path: ".claude/skills/release-readiness/SKILL.md")
        return String(decoding: try Data(contentsOf: url), as: UTF8.self)
    }

    @Test func aRepositoryThatPublishesTheSameContentIsUpToDate() async throws {
        let fixture = try await ShellRenderFixture()
        defer { fixture.remove() }
        let skill = try await followedSkill(in: fixture)
        let updates = session(fixture) { try Self.published(try Self.tree(body: "Version one"), revision: "a") }

        await updates.check()

        #expect(updates.availability(for: skill)?.isUpToDate == true)
        #expect(updates.available.isEmpty)
        #expect(fixture.workspace.device.lastUpdateCheck != nil)
    }

    @Test func aChangedRepositoryIsFoundAndWaitsUnderTheAskPolicy() async throws {
        let fixture = try await ShellRenderFixture()
        defer { fixture.remove() }
        let skill = try await followedSkill(in: fixture)
        let updates = session(fixture) { try Self.published(try Self.tree(body: "Version two"), revision: "b") }

        await updates.check(installingAutomatically: true)

        #expect(updates.availability(for: skill)?.hasUpdate == true)
        #expect(updates.available.map(\.id) == [skill])
        #expect(updates.installedAutomatically.isEmpty)
        #expect(try installedBody(fixture).contains("Version one"))

        // The press. The library takes the content and the proven copy follows.
        #expect(await updates.update(skill))
        #expect(updates.errorMessage == nil)
        #expect(try installedBody(fixture).contains("Version two"))
        #expect(updates.availability(for: skill)?.isUpToDate == true)
        let row = fixture.workspace.library.state?.library.rows.first { $0.artifactID == skill }
        #expect(row?.contentDigest == (try Self.tree(body: "Version two")).digest)
    }

    @Test func theAutomaticPolicyInstallsSkillsWithoutAPress() async throws {
        let fixture = try await ShellRenderFixture()
        defer { fixture.remove() }
        let skill = try await followedSkill(in: fixture)
        var policy = fixture.workspace.device.updatePolicy
        policy.skills = .automatic
        await fixture.workspace.device.setUpdatePolicy(policy)
        #expect(fixture.workspace.device.updatePolicy.skills == .automatic)
        let updates = session(fixture) { try Self.published(try Self.tree(body: "Version two"), revision: "b") }

        await updates.check(installingAutomatically: true)

        #expect(updates.installedAutomatically == ["Release Readiness"])
        #expect(updates.availability(for: skill)?.isUpToDate == true)
        #expect(try installedBody(fixture).contains("Version two"))
    }

    @Test func theCadenceDecidesWhetherOpeningChecks() async throws {
        let fixture = try await ShellRenderFixture()
        defer { fixture.remove() }
        _ = try await followedSkill(in: fixture)
        var policy = fixture.workspace.device.updatePolicy
        policy.cadence = .manual
        await fixture.workspace.device.setUpdatePolicy(policy)
        let updates = session(fixture) { try Self.published(try Self.tree(body: "Version two"), revision: "b") }

        await updates.checkIfDue()
        #expect(updates.available.isEmpty)
        #expect(fixture.workspace.device.lastUpdateCheck == nil)

        policy.cadence = .onOpen
        await fixture.workspace.device.setUpdatePolicy(policy)
        await updates.checkIfDue()
        #expect(updates.available.count == 1)
        #expect(fixture.workspace.device.lastUpdateCheck != nil)
    }

    @Test func aCopySomebodyElseEditedIsLeftAlone() async throws {
        let fixture = try await ShellRenderFixture()
        defer { fixture.remove() }
        let skill = try await followedSkill(in: fixture)
        // Edit the installed copy by hand: it is no longer the copy this app made.
        let url = fixture.home.appending(path: ".claude/skills/release-readiness/SKILL.md")
        try Data("# Mine now\n".utf8).write(to: url)
        let updates = session(fixture) { try Self.published(try Self.tree(body: "Version two"), revision: "b") }
        await updates.check()

        #expect(await updates.update(skill))

        // The library moved on; the edited copy did not, and the person is told.
        let row = fixture.workspace.library.state?.library.rows.first { $0.artifactID == skill }
        #expect(row?.contentDigest == (try Self.tree(body: "Version two")).digest)
        #expect(try installedBody(fixture) == "# Mine now\n")
        #expect(updates.notice?.contains("Claude Code kept a copy") == true)
        // It points at the review without quoting a button title. The button
        // counts the plan, and this copy's step is in it, so it reads "Review
        // 1 change…"; a quoted "Review changes…" never matched it.
        #expect(updates.notice?.hasSuffix("Review the changes on the Apps screen to replace it.") == true)
        #expect(updates.notice?.contains(ActionTitles.reviewChanges(count: nil)) == false)
        #expect(
            updates.notice?.contains(
                SyncCenterView.reviewTitle(for: fixture.workspace.deployment.plan, scopedTo: nil)) == false)
        // The Apps screen still offers the replacement for a person to decide.
        #expect(fixture.workspace.deployment.plan?.items.contains {
            $0.artifactID == skill && { if case .updateContent = $0.action { return true }; return false }($0)
        } == true)
    }

    /// The whole plugin path through the app's own wiring: the catalog says
    /// newer, the press runs Claude Code's own update command at the tool the
    /// scan located, and the executor's allowlist lets exactly that through.
    @Test func aPluginUpdateRunsTheAppsOwnUpdateCommand() async throws {
        let fixture = try await ShellRenderFixture()
        defer { fixture.remove() }
        let log = try fixture.installFakeClaude()
        let updates = session(fixture) { throw CancellationError() }
        updates.record(.init(
            id: ShellRenderFixture.plugin, displayName: "Example Plugin", kind: .plugin,
            availability: .updateAvailable(installed: "1.0.0", available: "1.1.0")))

        #expect(await updates.update(ShellRenderFixture.plugin))

        #expect(updates.errorMessage == nil)
        let asked = String(decoding: try Data(contentsOf: log), as: UTF8.self)
        #expect(asked == "plugin update example@vendor --scope user\n")
        #expect(updates.availability(for: ShellRenderFixture.plugin)?.isUpToDate == true)
    }

    @Test func aPluginIsUpdatableOnlyWhereItsAppRecordsAnUpdateCommand() async throws {
        let fixture = try await ShellRenderFixture()
        defer { fixture.remove() }
        let updates = session(fixture) { throw CancellationError() }
        await updates.check()
        // The fixture's plugin is Claude Code's, which records `plugin update`,
        // so the entry can be updated from here; whether the catalog says it
        // needs to is the catalog's business.
        let entry = try #require(updates.entries[ShellRenderFixture.plugin])
        #expect(entry.kind == .plugin)
        #expect(entry.cannotUpdate == nil)
        // Codex records no update command, so its packages are updated in Codex.
        #expect(NativePluginInstallRegister.command(for: .codex, externalPluginID: "example")?.updateArguments == nil)
        #expect(NativePluginInstallRegister.command(for: .claude, externalPluginID: "example@vendor")?.updateArguments
            == ["plugin", "update", "example@vendor", "--scope", "user"])
    }
}
