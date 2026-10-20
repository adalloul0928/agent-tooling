import Foundation
import Testing

@testable import AgentToolingApp
@testable import AgentToolingCore

/// The one-step install is a reviewed apply: it installs the plan it read,
/// only while the library is still at the revision it read the plan at, and
/// after an app's own tool ran it checks that app again, and only that app,
/// before it reads the plan again (D29), so what it just installed is not
/// offered a second time.
@Suite("One-step install · reviewed apply", .serialized, .timeLimit(.minutes(5)))
@MainActor
struct WorkspaceInstallSessionReviewedApplyTests {
    /// A plugin Claude Code's own tool installs: Claude Code alone is checked
    /// again, and the plan read next holds nothing for the plugin.
    @Test func aPluginInstallChecksOnlyItsAppAgainAndIsNotOfferedAgain() async throws {
        let observer = CountingDeviceObserver(Self.observations(reportingPlugin: false))
        let fixture = try await ShellRenderFixture(deviceObserver: observer)
        defer { fixture.remove() }
        let log = try fixture.installFakeClaude()
        await fixture.workspace.device.refresh()
        let checksBefore = observer.fullChecks
        let install = Self.session(fixture)
        // What Claude Code reports once its own tool has run.
        observer.answer(with: Self.observations(reportingPlugin: true))

        await install.install(
            artifactIDs: [ShellRenderFixture.plugin], destinations: [.init(surface: .claudeCode, scope: .user)])
        if case .reviewing = install.phase { await install.approveReview() }

        guard case .finished(let outcome) = install.phase else {
            Issue.record("The install did not finish: \(install.phase); \(install.errorMessage ?? "no message")")
            return
        }
        #expect(outcome.installed == [.claude])
        #expect(try String(contentsOf: log, encoding: .utf8).contains("plugin install example@vendor --scope user"))
        #expect(observer.scopedChecks == [[.claude]])
        #expect(observer.fullChecks == checksBefore)
        let deployment = fixture.workspace.deployment
        #expect(deployment.plan?.items.contains { $0.artifactID == ShellRenderFixture.plugin } == false)
        #expect(deployment.pendingCount == 0)
    }

    /// A copy is the executor's own work, measured from the folder itself:
    /// no app is checked again.
    @Test func aCopyChecksNoAppAgain() async throws {
        let observer = CountingDeviceObserver(Self.observations(reportingPlugin: false))
        let fixture = try await ShellRenderFixture(deviceObserver: observer)
        defer { fixture.remove() }
        await fixture.workspace.device.refresh()
        let skill = try await Self.heldSkill(in: fixture)
        let install = Self.session(fixture)

        await install.install(artifactIDs: [skill], destinations: [.init(surface: .claudeCode, scope: .user)])

        guard case .finished(let outcome) = install.phase else {
            Issue.record("The install did not finish: \(install.phase); \(install.errorMessage ?? "no message")")
            return
        }
        #expect(outcome.installed == [.claude])
        #expect(FileManager.default.fileExists(atPath: Self.skillFile(fixture).path))
        #expect(observer.scopedChecks.isEmpty)
    }

    /// The person approves a plan the library has moved past: nothing is
    /// installed, even when the Apps screen read the plan again meanwhile, so
    /// the plan on screen is never run against a library it was not read
    /// from.
    @Test func anApprovalAfterTheLibraryMovedInstallsNothing() async throws {
        let fixture = try await ShellRenderFixture()
        defer { fixture.remove() }
        let skill = try await Self.heldSkill(in: fixture)
        let install = Self.session(fixture)
        await install.install(
            artifactIDs: [skill], destinations: [.init(surface: .claudeCode, scope: .user)], requestedByAgent: true)
        guard case .reviewing = install.phase else {
            Issue.record("An agent's request is always shown first, got \(install.phase)")
            return
        }

        // Another write lands, and the Apps screen reads the plan again.
        let workspace = fixture.workspace
        let head = try #require(try workspace.store.snapshot()?.document.revision.id)
        _ = try await workspace.service.registerDevice(
            .init(expectedRevisionID: head, deviceID: workspace.store.deviceID, name: "Juniper"))
        await workspace.library.refresh()
        await workspace.deployment.prepare()
        await install.approveReview()

        #expect(install.errorMessage == "Your library changed while this was open. Review again.")
        #expect(install.phase == .choosing)
        #expect(!FileManager.default.fileExists(atPath: Self.skillFile(fixture).path))
        #expect(try workspace.store.operationReceipts().isEmpty)
    }

    // MARK: - Helpers

    private static func session(_ fixture: ShellRenderFixture) -> WorkspaceInstallSession {
        WorkspaceInstallSession(
            library: fixture.workspace.library, deployment: fixture.workspace.deployment,
            device: fixture.workspace.device, service: fixture.workspace.service)
    }

    /// Claude Code present and answering, reporting the fixture's plugin for
    /// the account or not; Codex absent.
    private static func observations(reportingPlugin: Bool) -> [TargetObservation] {
        var claude = ShellRenderFixture.observation(.claudeCode, installed: true, commandAvailable: true, version: "2.1.268")
        // What the real scan records for Claude Code; without it the app has
        // no plugin component and the request is excluded before planning.
        claude.capabilities.supportsPluginInstall = true
        if reportingPlugin {
            claude.pluginMetadata[NativeInstallTests.route] = .init(
                name: "Example Plugin", source: "test", scope: "User", enabled: true)
        }
        let codex = ShellRenderFixture.observation(.codexCLI, installed: false, commandAvailable: false)
        return [claude, codex]
    }

    private static let skillName = "reviewed-apply"

    private static func skillFile(_ fixture: ShellRenderFixture) -> URL {
        fixture.home.appending(path: ".claude/skills/\(skillName)/SKILL.md")
    }

    /// A skill the library holds the bytes of, assigned nowhere yet.
    private static func heldSkill(in fixture: ShellRenderFixture) async throws -> ArtifactID {
        let tree = try CapturedPackageTree(entries: [
            .init(
                relativePath: "SKILL.md",
                kind: .file(
                    bytes: Data(
                        """
                        ---
                        name: \(skillName)
                        description: Check that a reviewed apply runs what it read.
                        ---

                        # \(skillName)

                        Body.
                        """.utf8), executable: false))
        ])
        let prepared = try WorkspaceSkillPreparation.personal(tree: tree)
        await fixture.workspace.library.refresh()
        let head = try #require(fixture.workspace.library.state?.snapshot.document.revision.id)
        let artifactID = ArtifactID()
        _ = try await fixture.workspace.service.intakeStandaloneSkill(
            .init(expectedRevisionID: head, artifactID: artifactID, displayName: skillName, prepared: prepared),
            prepared: prepared)
        await fixture.workspace.library.refresh()
        return artifactID
    }
}
