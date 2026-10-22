import AgentToolingTestSupport
import Foundation
import SwiftUI
import Testing

@testable import AgentToolingApp
@testable import AgentToolingCore

/// The shapes the Skills screen reaches for, added to the shared fixture rather
/// than to the harness every screen uses.

extension ShellRenderFixture {
    /// Saves one assignment for the standalone skill, through the same review
    /// `WorkspaceAssignmentSheet` saves with, so the list has a row whose
    /// verdict says a place was asked for. Nothing here writes a row directly.
    func assignStandaloneSkill(to surface: TargetSurface = .claudeCode) async {
        await workspace.library.reviewAssignments(
            artifactIDs: [Self.skill],
            destinations: [.init(surface: surface, scope: .user)])
        await workspace.library.applyReviewedAssignments()
    }

    /// Isolated preferences, so a test never reads or writes this Mac's own.
    /// The Skills screen keeps its filters and grouping in app storage, and a
    /// test that shared them would depend on whatever the last run left
    /// behind. Their file lives in a scratch folder, never in
    /// `~/Library/Preferences` (`ScratchDefaults`).
    static func preferences() throws -> RenderPreferences {
        RenderPreferences(scratch: try ScratchDefaults("skills-render"))
    }
}

/// One test's app storage, and the way to take it away again, file and all.
struct RenderPreferences {
    let scratch: ScratchDefaults

    var suite: String { scratch.suite }
    var defaults: UserDefaults { scratch.defaults }

    func remove() { scratch.remove() }
}

/// One skill's stored files, scripted.
///
/// A render test that used the real one would read a content store and, for an
/// upstream check, run `git` against the network. This answers from memory and
/// records what it was asked to do, so a test can also prove that drawing the
/// screen asks it for nothing.
final class StubSkillContentService: SkillContentServing, @unchecked Sendable {
    private let lock = NSLock()
    private var reads: [ArtifactID] = []
    private var writes: [ArtifactID] = []
    private var fetches: [String] = []

    var readCount: Int { lock.withLock { reads.count } }
    var writeCount: Int { lock.withLock { writes.count } }
    var fetchCount: Int { lock.withLock { fetches.count } }

    static let definition = """
        ---
        name: standalone-skill
        description: A stored skill the render tests read.
        ---

        # Standalone Skill

        ## When to use this skill

        - When a test needs a definition with real frontmatter
        """

    static func tree(_ markdown: String = definition) throws -> CapturedPackageTree {
        try CapturedPackageTree(entries: [
            .init(relativePath: "SKILL.md", kind: .file(bytes: Data(markdown.utf8), executable: false)),
            .init(relativePath: "references", kind: .directory),
            .init(
                relativePath: "references/reference.md",
                kind: .file(bytes: Data("# Reference\n".utf8), executable: false)),
        ])
    }

    func read(
        artifactID: ArtifactID, revisionID: WorkspaceObjectID,
        through service: WorkspaceApplicationService
    ) async throws -> WorkspaceSkillContentSnapshot {
        lock.withLock { reads.append(artifactID) }
        let tree = try Self.tree()
        return .init(
            revisionID: revisionID,
            artifact: .init(
                identity: .init(id: artifactID, kind: .skill, displayName: "Standalone Skill"),
                authority: .centralPersonal, declaredName: "standalone-skill",
                contentDigest: tree.digest),
            tree: tree)
    }

    func replace(
        _ tree: CapturedPackageTree, of artifactID: ArtifactID, expecting digest: ContentDigest,
        at revisionID: WorkspaceObjectID, through service: WorkspaceApplicationService
    ) async throws {
        lock.withLock { writes.append(artifactID) }
    }

    func admit(
        _ tree: CapturedPackageTree, named displayName: String,
        at revisionID: WorkspaceObjectID, through service: WorkspaceApplicationService
    ) async throws {
        lock.withLock { writes.append(ArtifactID()) }
    }

    func upstream(_ binding: SkillRepositoryBinding, cachedIn cacheRoot: URL) async throws -> PreparedStandaloneSkill {
        lock.withLock { fetches.append(binding.repositoryURL) }
        return try WorkspaceSkillPreparation.personal(tree: try Self.tree())
    }
}
