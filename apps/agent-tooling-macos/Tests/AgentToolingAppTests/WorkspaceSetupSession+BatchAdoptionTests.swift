import AgentToolingTestSupport
import Foundation
import Testing

@testable import AgentToolingApp
@testable import AgentToolingCore

/// Checkup's "Add all N to library": every skill in one commit, each found by
/// the folder the check found it in.
@Suite("Checkup session · batch adoption", .serialized, .timeLimit(.minutes(5)))
@MainActor
struct WorkspaceSetupSessionBatchAdoptionTests {
    /// The acceptance: on Juniper, Checkup's Claude Code group offers "Add
    /// all 3 to library", and it adds all three, in one revision. Before the
    /// batch, the second and third found the library moved on by the first.
    @Test func checkupsAddAllThreeAddsEverySkillInOneCommit() async throws {
        let fixture = try await LaunchpadFixture()
        defer { fixture.remove() }
        let workspace = try await fixture.sample(.afterRead).workspace
        let session = workspace.setup
        let checkup = try #require(session.checkup)
        let item = try #require(
            CheckupTriage.items(from: checkup).first {
                $0.client == .claude && $0.findings.allSatisfy { $0.kind == .unmanagedSkill }
            })
        #expect(item.primaryTitle == "Add all 3 to library")
        let head = try fixture.head(of: workspace)

        await session.applyAll(item.actions)

        #expect(session.errorMessage == nil, "\(session.errorMessage ?? "")")
        #expect(session.lastApplyMessage == "3 of 3 done.")
        let document = try #require(try workspace.store.snapshot()).document
        for name in ["frontend-design", "release-notes", "webapp-testing"] {
            let artifact = try #require(document.artifacts.first { $0.declaredName == name && $0.identity.parentPackageID == nil })
            #expect(artifact.authority == .centralPersonal, "\(name) is yours")
        }
        // The revision right after the head holds all three: one commit.
        let first = try #require(try Self.revision(after: head, in: workspace.store))
        let adopted = first.artifacts.filter { $0.identity.kind == .skill && $0.authority == .centralPersonal }
        #expect(Set(adopted.compactMap(\.declaredName)) == ["frontend-design", "release-notes", "webapp-testing"])
        #expect(
            session.checkup?.openFindings.contains { $0.kind == .unmanagedSkill && $0.client == .claude } == false,
            "the re-audit no longer lists them")
    }

    /// A folder whose SKILL.md names another skill is found by its folder,
    /// so it is refused by both names, not as a skill the library never saw,
    /// and the message names the skill as Checkup's finding does, since no
    /// row beside it says which; the rest still land.
    @Test func aSkillIsFoundByItsFolderAndAMismatchedNameIsRefusedByBothNames() async throws {
        let fixture = try await LaunchpadFixture()
        defer { fixture.remove() }
        try fixture.world.home.plant(
            ".claude/skills/frontend-design/SKILL.md",
            "---\nname: frontend-ui\ndescription: Builds distinctive UI.\n---\n\nChoose one visual direction.\n")
        let workspace = try await fixture.sample(.afterRead).workspace
        let session = workspace.setup
        let skills = fixture.home.appending(path: ".claude/skills", directoryHint: .isDirectory)
        let actions: [SetupAction] = ["frontend-design", "release-notes"].map {
            .adoptSkill(path: skills.appending(path: $0).path(percentEncoded: false), client: .claude)
        }

        await session.applyAll(actions)

        #expect(session.lastApplyMessage == "1 of 2 done.")
        #expect(
            session.errorMessage
                == "1 did not go through. First: frontend-design’s SKILL.md calls it frontend-ui, not frontend-design, so it cannot be added yet. Rename one to match."
        )
        let document = try #require(try workspace.store.snapshot()).document
        #expect(document.artifacts.first { $0.declaredName == "release-notes" }?.authority == .centralPersonal)
        #expect(document.artifacts.first { $0.declaredName == "frontend-design" }?.authority == .trackedOnly)
    }

    /// Two folders that hold one tracked skill make it yours once, from the
    /// first, and both steps say it is in the library.
    @Test func twoCopiesOfOneSkillMakeItYoursOnce() async throws {
        let fixture = try await LaunchpadFixture()
        defer { fixture.remove() }
        let workspace = try await fixture.sample(.afterRead).workspace
        let session = workspace.setup
        let head = try fixture.head(of: workspace)
        let claude = fixture.home.appending(path: ".claude/skills/webapp-testing").path(percentEncoded: false)
        let codex = fixture.home.appending(path: ".codex/skills/webapp-testing").path(percentEncoded: false)

        let results = await session.adopt(paths: [claude, codex])

        #expect(try results[claude]?.get() == "webapp-testing is in the library now. Install it from its details.")
        #expect(try results[codex]?.get() == "webapp-testing is in the library now. Install it from its details.")
        let saved = try #require(try workspace.store.snapshot())
        #expect(saved.document.revision.parentIDs == [head], "one revision")
        let artifact = try #require(saved.document.artifacts.first { $0.declaredName == "webapp-testing" })
        let claudeTree = try await WorkspaceSkillPreparation.capturePersonal(
            directory: URL(filePath: claude, directoryHint: .isDirectory))
        #expect(artifact.contentDigest == claudeTree.tree.digest, "from the first folder")
    }

    @Test func aFolderTheLibraryDoesNotTrackSaysSo() async throws {
        let fixture = try await LaunchpadFixture()
        defer { fixture.remove() }
        let workspace = try await fixture.sample(.afterRead).workspace
        let stray = fixture.home.appending(path: ".claude/skills/never-read").path(percentEncoded: false)

        await #expect(throws: SetupApplyError.self) {
            try await workspace.setup.adopt(path: stray)
        }
    }

    /// The first revision after `head` on the way to the current one.
    private static func revision(after head: WorkspaceObjectID, in store: WorkspaceRevisionStore) throws -> PortableWorkspaceDocument? {
        var current = try store.snapshot()?.document
        while let document = current, document.revision.id != head {
            if document.revision.parentIDs == [head] { return document }
            current = try document.revision.parentIDs.first.flatMap { try store.revision($0) }
        }
        return nil
    }
}
