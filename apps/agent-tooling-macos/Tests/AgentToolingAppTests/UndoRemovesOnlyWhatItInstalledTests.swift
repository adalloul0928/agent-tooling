import Foundation
import Testing

@testable import AgentToolingApp
@testable import AgentToolingCore

/// Undo is scoped to the one install that offered it: it withdraws the
/// contributions that install added and takes back the copies it placed, and
/// nothing else. The hazard this pins is a removal that was already pending for
/// another destination of the same artifact — left over from an unrelated
/// withdrawal — being swept up by an undo that scoped its removals by artifact
/// rather than by the exact place-and-thing it had written.
@Suite("Undo removes only what it installed") @MainActor
struct UndoRemovesOnlyWhatItInstalledTests {
    /// Both CLIs installed, so one skill can have a destination on each.
    private struct TwoCLIObserver: DeviceObserving {
        var observations: [TargetObservation] = [
            ShellRenderFixture.observation(.claudeCode, installed: true, commandAvailable: true, version: "2.1.263"),
            ShellRenderFixture.observation(.codexCLI, installed: true, commandAvailable: true, version: "0.9.0"),
        ]

        func observe(homeRoot: URL) async throws -> [TargetObservation] { observations }
    }

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

    private func skillFolder(_ fixture: ShellRenderFixture, _ relativeRoot: String, _ name: String) -> URL {
        fixture.home.appending(path: "\(relativeRoot)/\(name)", directoryHint: .isDirectory)
    }

    @Test func undoLeavesAnUnrelatedPendingRemovalAtAnotherDestinationAlone() async throws {
        let fixture = try await ShellRenderFixture(deviceObserver: TwoCLIObserver())
        defer { fixture.remove() }
        await fixture.workspace.device.refresh()
        let skill = try await heldSkill(in: fixture)

        // 1. Install the skill at Codex. This destination has nothing to do
        //    with the install the test will later undo.
        let atCodex = session(fixture)
        await atCodex.install(artifactIDs: [skill], destinations: [.init(surface: .codexCLI, scope: .user)])
        guard case .finished = atCodex.phase else {
            Issue.record("expected the Codex install to finish, got \(atCodex.phase); error=\(atCodex.errorMessage ?? "nil")")
            return
        }
        let codexFolder = skillFolder(fixture, ".agents/skills", "release-readiness")
        #expect(FileManager.default.fileExists(atPath: codexFolder.path))

        // 2. Withdraw the Codex assignment without taking the copy back out.
        //    This is the unrelated action that leaves a removal pending for
        //    the skill at Codex: the file is still there, nothing asks for it.
        await fixture.workspace.library.refresh()
        let codexContribution = try #require(
            fixture.workspace.library.state?.library.rows
                .first { $0.artifactID == skill }?
                .requestedAssignments.first { $0.destination.surface == .codexCLI }?.id)
        await fixture.workspace.library.reviewRemoval(contributionIDs: [codexContribution])
        await fixture.workspace.library.applyReviewedAssignments()
        #expect(fixture.workspace.library.lastReceipt != nil)
        // The withdrawal only touched the assignment; the copy is still on disk.
        #expect(FileManager.default.fileExists(atPath: codexFolder.path))

        // 3. Install the same skill at Claude Code. This is the install under
        //    test; its Undo must reach only this destination.
        let atClaude = session(fixture)
        await atClaude.install(artifactIDs: [skill], destinations: [.init(surface: .claudeCode, scope: .user)])
        guard case .finished(let outcome) = atClaude.phase else {
            Issue.record("expected the Claude install to finish, got \(atClaude.phase); error=\(atClaude.errorMessage ?? "nil")")
            return
        }
        #expect(outcome.canUndo)
        let claudeFolder = skillFolder(fixture, ".claude/skills", "release-readiness")
        #expect(FileManager.default.fileExists(atPath: claudeFolder.path))
        // Installing at Claude did not touch the Codex copy.
        #expect(FileManager.default.fileExists(atPath: codexFolder.path))

        // 4. Undo the Claude install. It must take back only the copy it placed
        //    at Claude; the Codex copy, pending removal for an unrelated reason,
        //    must be left exactly where it is.
        await atClaude.undo()
        guard case .finished = atClaude.phase else {
            Issue.record("expected undo to finish, got \(atClaude.phase); error=\(atClaude.errorMessage ?? "nil")")
            return
        }
        #expect(atClaude.errorMessage == nil)
        #expect(!FileManager.default.fileExists(atPath: claudeFolder.path), "undo should remove the Claude copy it installed")
        #expect(
            FileManager.default.fileExists(atPath: codexFolder.path),
            "undo must not apply the unrelated removal pending at the Codex destination")
    }
}
