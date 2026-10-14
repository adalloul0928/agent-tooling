import Foundation
import SwiftUI
import Testing

@testable import AgentToolingApp
@testable import AgentToolingCore

/// Install is one step: choose the apps, press the button, the files land. The
/// pipeline behind it is unchanged; what these pin is when it stays out of
/// sight and when it steps in front.
@Suite("One-step install") @MainActor
struct WorkspaceInstallSessionTests {
    /// A skill the library holds the bytes of, assigned nowhere yet.
    private func heldSkill(in fixture: ShellRenderFixture, name: String = "release-readiness") async throws -> ArtifactID {
        let tree = try CapturedPackageTree(entries: [
            .init(relativePath: "SKILL.md", kind: .file(bytes: Data("""
                ---
                name: \(name)
                description: Check whether a release is ready to ship.
                ---

                # \(name)

                Body.
                """.utf8), executable: false)),
        ])
        let prepared = try WorkspaceSkillPreparation.personal(tree: tree)
        await fixture.workspace.library.refresh()
        let head = try #require(fixture.workspace.library.state?.snapshot.document.revision.id)
        let artifactID = ArtifactID()
        _ = try await fixture.workspace.service.intakeStandaloneSkill(
            .init(expectedRevisionID: head, artifactID: artifactID, displayName: name, prepared: prepared), prepared: prepared)
        await fixture.workspace.library.refresh()
        return artifactID
    }

    private func session(_ fixture: ShellRenderFixture) -> WorkspaceInstallSession {
        WorkspaceInstallSession(
            library: fixture.workspace.library, deployment: fixture.workspace.deployment,
            device: fixture.workspace.device, service: fixture.workspace.service)
    }

    private func claudeSkillFolder(_ fixture: ShellRenderFixture, _ name: String) -> URL {
        fixture.home.appending(path: ".claude/skills/\(name)", directoryHint: .isDirectory)
    }

    @Test func installingWhereNothingIsRunsWithoutAReviewAndLandsTheFiles() async throws {
        let fixture = try await ShellRenderFixture()
        defer { fixture.remove() }
        let skill = try await heldSkill(in: fixture)
        let install = session(fixture)

        await install.install(artifactIDs: [skill], destinations: [.init(surface: .claudeCode, scope: .user)])

        guard case .finished(let outcome) = install.phase else {
            Issue.record("expected the install to finish directly, got \(install.phase); error=\(install.errorMessage ?? "nil") libraryError=\(fixture.workspace.library.errorMessage ?? "nil") refusal=\(String(describing: fixture.workspace.library.lastRefusal))")
            return
        }
        #expect(outcome.installed == [.claude])
        #expect(outcome.failed.isEmpty)
        #expect(outcome.canUndo)
        #expect(install.errorMessage == nil)
        let skillFile = claudeSkillFolder(fixture, "release-readiness").appending(path: "SKILL.md")
        #expect(FileManager.default.fileExists(atPath: skillFile.path))
        // The assignment is saved too: the install is remembered, not just done.
        let row = fixture.workspace.library.state?.library.rows.first { $0.artifactID == skill }
        #expect(row?.requestedAssignments.contains { $0.destination.surface == .claudeCode } == true)
    }

    @Test func aFolderThisAppDidNotPutThereSendsTheInstallToReview() async throws {
        let fixture = try await ShellRenderFixture()
        defer { fixture.remove() }
        let skill = try await heldSkill(in: fixture)
        // Somebody else's copy, at the place the install would write.
        let folder = claudeSkillFolder(fixture, "release-readiness")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data("# Theirs\n".utf8).write(to: folder.appending(path: "SKILL.md"))
        let install = session(fixture)

        await install.install(artifactIDs: [skill], destinations: [.init(surface: .claudeCode, scope: .user)])

        guard case .reviewing(let reasons) = install.phase else {
            Issue.record("expected a review, got \(install.phase)")
            return
        }
        #expect(reasons.contains { if case .replacesUnprovenContent = $0 { return true }; return false })
        // Nothing was written while the plan waits to be read.
        let bytes = try Data(contentsOf: folder.appending(path: "SKILL.md"))
        #expect(String(decoding: bytes, as: UTF8.self) == "# Theirs\n")
        #expect(install.reviewPlan?.items.count == 1)
        // The executor would refuse this step whoever approved it, so the
        // review says so instead of offering a button that fails.
        #expect(install.heldBack.map(\.artifactID) == [skill])
        #expect(install.runnableReviewItems.isEmpty)

        await install.approveReview()
        guard case .finished(let outcome) = install.phase else {
            Issue.record("expected approving to finish, got \(install.phase)")
            return
        }
        #expect(outcome.installed.isEmpty)
        #expect(outcome.failed.isEmpty)
        #expect(outcome.skipped.count == 1)
        #expect(!outcome.canUndo)
        #expect(String(decoding: try Data(contentsOf: folder.appending(path: "SKILL.md")), as: UTF8.self) == "# Theirs\n")
    }

    @Test func undoTakesTheFilesBackOutAndWithdrawsTheAssignment() async throws {
        let fixture = try await ShellRenderFixture()
        defer { fixture.remove() }
        let skill = try await heldSkill(in: fixture)
        let install = session(fixture)
        await install.install(artifactIDs: [skill], destinations: [.init(surface: .claudeCode, scope: .user)])
        let folder = claudeSkillFolder(fixture, "release-readiness")
        #expect(FileManager.default.fileExists(atPath: folder.path))

        await install.undo()

        guard case .finished(let outcome) = install.phase else {
            Issue.record("expected undo to finish, got \(install.phase)")
            return
        }
        #expect(!outcome.canUndo)
        #expect(install.errorMessage == nil)
        #expect(!FileManager.default.fileExists(atPath: folder.path))
        let row = fixture.workspace.library.state?.library.rows.first { $0.artifactID == skill }
        #expect(row?.requestedAssignments.isEmpty == true)
    }

    @Test func anAgentsRequestIsAlwaysShownFirst() async throws {
        let fixture = try await ShellRenderFixture()
        defer { fixture.remove() }
        let skill = try await heldSkill(in: fixture)
        let install = session(fixture)

        await install.install(
            artifactIDs: [skill], destinations: [.init(surface: .claudeCode, scope: .user)], requestedByAgent: true)

        guard case .reviewing(let reasons) = install.phase else {
            Issue.record("expected a review, got \(install.phase)")
            return
        }
        #expect(reasons == [.requestedByAgent])
        #expect(!FileManager.default.fileExists(atPath: claudeSkillFolder(fixture, "release-readiness").path))

        await install.approveReview()
        guard case .finished(let outcome) = install.phase else {
            Issue.record("expected approving to install, got \(install.phase)")
            return
        }
        #expect(outcome.installed == [.claude])
        #expect(FileManager.default.fileExists(atPath: claudeSkillFolder(fixture, "release-readiness").path))
    }
}

extension WorkspaceInstallSessionTests {
    /// The picker draws in every phase with the pipeline in the environment.
    /// The phases are reached by running the real pipeline; what each phase
    /// does is pinned by the tests above, so this only insists that each one
    /// the run reaches can be drawn. Under a full parallel test run the
    /// install has been seen to finish instead of reviewing; both are drawn.
    @Test func thePickerDrawsChoosingReviewingAndFinished() async throws {
        let fixture = try await ShellRenderFixture()
        defer { fixture.remove() }
        await fixture.workspace.device.refresh()
        let skill = try await heldSkill(in: fixture)
        let folder = claudeSkillFolder(fixture, "release-readiness")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data("# Theirs\n".utf8).write(to: folder.appending(path: "SKILL.md"))
        let pipeline = InstallPipeline(
            deployment: fixture.workspace.deployment, device: fixture.workspace.device,
            service: fixture.workspace.service, homeRoot: fixture.home)
        let install = session(fixture)
        func sheet() -> some View {
            WorkspaceAssignmentSheet(
                session: fixture.workspace.library, artifactIDs: [skill], initialClients: [.claude], installSession: install)
                .environment(\.installPipeline, pipeline)
                .environment(\.availableClients, [.claude, .codex, .gemini, .kiro])
                .environment(AppNavigationState())
        }
        try expectDrawn(sheet())
        await install.install(artifactIDs: [skill], destinations: [.init(surface: .claudeCode, scope: .user)])
        try expectDrawn(sheet())
        if case .reviewing = install.phase {
            await install.approveReview()
            try expectDrawn(sheet())
        }
        guard case .finished = install.phase else {
            Issue.record("expected an outcome, got \(install.phase); error=\(install.errorMessage ?? "nil")")
            return
        }
    }
}
