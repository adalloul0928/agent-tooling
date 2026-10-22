import Foundation
import Testing

@testable import AgentToolingApp
@testable import AgentToolingCore

/// What `PluginsSectionRenderTests` needs beyond the shared fixture: a
/// centrally tracked package with a saved assignment but no native presence
/// anywhere, so the render test can prove that case draws too — the exact
/// shape the plan warns a screen must never draw as "installed".
extension ShellRenderFixture {
    static let package = ArtifactID()

    /// Adds a `.package` artifact and requests it for Claude Code, using only
    /// the workspace's own public commands — never a second, ad hoc write path
    /// into the store the harness already sealed.
    func addRequestedPackage() async throws {
        guard let head = try await workspace.service.snapshot()?.document.revision.id else {
            Issue.record("Fixture workspace has no revision to append the package artifact onto.")
            return
        }
        _ = try store.commitMetadata(
            expectedRevisionID: head, idempotencyKey: WorkspaceObjectID(),
            inputDigest: String(repeating: "0", count: 64), writerID: WorkspaceObjectID(),
            mutation: { document in
                document.artifacts.append(
                    .init(
                        identity: .init(id: Self.package, kind: .package, displayName: "Example Package"),
                        authority: .centralPersonal))
                return [Self.package]
            })
        await workspace.library.refresh()
        await workspace.library.reviewAssignments(
            artifactIDs: [Self.package],
            destinations: [.init(surface: .claudeCode, scope: .user, deviceIDs: [store.deviceID])])
        await workspace.library.applyReviewedAssignments()
    }
}
