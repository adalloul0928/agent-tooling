import Foundation
import Testing

@testable import AgentToolingCore

private struct AdoptionStubRunner: CommandRunning {
    let versions: [String: String]

    func run(executable: String, arguments: [String], currentDirectory: URL?) async throws -> CommandOutput {
        guard arguments == ["--version"], let version = versions[executable] else {
            return CommandOutput(status: 0, standardOutput: "", standardError: "")
        }
        return CommandOutput(status: 0, standardOutput: version + "\n", standardError: "")
    }
}

@MainActor
struct SkillAdoptionTests {
    @Test func adoptionPlanIsReviewedBeforeAnythingEntersTheManagedLibrary() async throws {
        let root = try temporaryDirectory()
        let home = root.appending(path: "home", directoryHint: .isDirectory)
        let clientSkill = home.appending(path: ".claude/skills/doc-review", directoryHint: .isDirectory)
        try write(definition(name: "doc-review"), to: clientSkill.appending(path: "SKILL.md"))
        try write("# Reference\n", to: clientSkill.appending(path: "references/reference.md"))
        let store = try WorkspaceStore(rootURL: root.appending(path: "workspace", directoryHint: .isDirectory))
        let model = try AppModel(store: store, runner: AdoptionStubRunner(versions: ["claude": "2.0.0"]), homeURL: home)
        await model.runDoctor()

        #expect(model.canAdoptSkill(id: "doc-review"))
        model.planSkillAdoption(skillIDs: ["doc-review"])

        let plan = try #require(model.pendingPlan)
        #expect(plan.steps.filter { $0.kind == .copyDirectory }.count == 1)
        #expect(plan.steps.first?.destinationPath == store.libraryURL.path(percentEncoded: false))
        #expect(model.skills.first { $0.id == "doc-review" }?.owned == false)
        let packageURL = store.libraryURL.appending(path: "packages/local-doc-review", directoryHint: .isDirectory)
        #expect(!FileManager.default.fileExists(atPath: packageURL.path(percentEncoded: false)))

        await model.executePendingPlan()

        let adopted = try #require(model.skills.first { $0.id == "doc-review" })
        #expect(adopted.owned)
        #expect(adopted.bundle == "local-doc-review")
        #expect(adopted.validationCount == 3)
        #expect(adopted.files == ["SKILL.md", "references/reference.md"].sorted())
        #expect(model.operationReceipts.first?.results.allSatisfy { $0.status == .succeeded } == true)
        for path in ["skills/doc-review/SKILL.md", "skills/doc-review/references/reference.md", "plugin.json"] {
            #expect(FileManager.default.fileExists(atPath: packageURL.appending(path: path).path(percentEncoded: false)))
        }

        // The client keeps its own copy: adoption copies, it never moves.
        #expect(try String(contentsOf: clientSkill.appending(path: "SKILL.md"), encoding: .utf8) == definition(name: "doc-review"))
        #expect(FileManager.default.fileExists(atPath: clientSkill.appending(path: "references/reference.md").path(percentEncoded: false)))

        model.planInstall(skillID: "doc-review")
        #expect(model.pendingPlan?.steps.contains { $0.kind == .copyDirectory } == true)
    }

    @Test func adoptingAnAlreadyManagedSkillNeverCreatesASecondPackage() async throws {
        let root = try temporaryDirectory()
        let home = root.appending(path: "home", directoryHint: .isDirectory)
        try write(definition(name: "doc-review"), to: home.appending(path: ".claude/skills/doc-review/SKILL.md"))
        let store = try WorkspaceStore(rootURL: root.appending(path: "workspace", directoryHint: .isDirectory))
        let model = try AppModel(store: store, runner: AdoptionStubRunner(versions: ["claude": "2.0.0"]), homeURL: home)
        await model.runDoctor()
        model.planSkillAdoption(skillIDs: ["doc-review"])
        await model.executePendingPlan()

        #expect(model.canAdoptSkill(id: "doc-review") == false)
        model.planSkillAdoption(skillIDs: ["doc-review"])

        #expect(model.pendingPlan == nil)
        #expect(model.lastError?.contains("already managed") == true)
        let packages = try FileManager.default.contentsOfDirectory(
            atPath: store.libraryURL.appending(path: "packages", directoryHint: .isDirectory).path(percentEncoded: false))
        #expect(packages.filter { !$0.hasPrefix(".") } == ["local-doc-review"])
        #expect(model.skills.filter { $0.owned }.count == 1)
    }

    @Test func oneUnusableSourceIsReportedWithoutCancellingTheBatch() throws {
        let root = try temporaryDirectory()
        let store = try WorkspaceStore(rootURL: root.appending(path: "workspace", directoryHint: .isDirectory))
        let library = WorkspaceLibrary(store: store)
        let usable = root.appending(path: "client/.claude/skills/doc-review", directoryHint: .isDirectory)
        try write(definition(name: "doc-review"), to: usable.appending(path: "SKILL.md"))
        let namespaced = root.appending(path: "client/.claude/plugins/reviews/skills/release-notes", directoryHint: .isDirectory)
        try write(definition(name: "release-notes"), to: namespaced.appending(path: "SKILL.md"))
        let linkTarget = root.appending(path: "external/linked-skill", directoryHint: .isDirectory)
        try write(definition(name: "linked-skill"), to: linkTarget.appending(path: "SKILL.md"))
        let linked = root.appending(path: "client/.claude/skills/linked-skill", directoryHint: .isDirectory)
        try FileManager.default.createSymbolicLink(at: linked, withDestinationURL: linkTarget)
        let mismatched = root.appending(path: "client/.claude/skills/renamed", directoryHint: .isDirectory)
        try write(definition(name: "something-else"), to: mismatched.appending(path: "SKILL.md"))

        let adoption = try library.adoptionPlan(for: [
            candidate(id: "doc-review", sourcePath: usable.path(percentEncoded: false)),
            candidate(id: "reviews:release-notes", sourcePath: namespaced.path(percentEncoded: false)),
            candidate(id: "linked-skill", sourcePath: linked.path(percentEncoded: false)),
            candidate(id: "renamed", sourcePath: mismatched.path(percentEncoded: false)),
            candidate(id: "vanished", sourcePath: root.appending(path: "client/.claude/skills/gone").path(percentEncoded: false)),
            candidate(id: "unscanned", sourcePath: nil),
        ])

        #expect(adoption.skills.map(\.id) == ["doc-review", "release-notes"])
        #expect(adoption.rejections.map(\.id) == ["linked-skill", "renamed", "vanished", "unscanned"])
        #expect(adoption.rejections.first { $0.id == "linked-skill" }?.reason.contains("symbolic link") == true)
        #expect(adoption.rejections.first { $0.id == "renamed" }?.reason.contains("required frontmatter") == true)
        #expect(adoption.rejections.first { $0.id == "vanished" }?.reason.contains("no longer on this Mac") == true)
        #expect(adoption.rejections.first { $0.id == "unscanned" }?.reason.contains("Check setup again") == true)
        #expect(adoption.plan.summary.contains("Skipped 4 skills"))
        library.discardAdoption(adoption)
    }

    @Test func repeatedIdentifiersInOneBatchAreRejectedRatherThanDuplicated() throws {
        let root = try temporaryDirectory()
        let store = try WorkspaceStore(rootURL: root.appending(path: "workspace", directoryHint: .isDirectory))
        let library = WorkspaceLibrary(store: store)
        let claude = root.appending(path: "client/.claude/skills/doc-review", directoryHint: .isDirectory)
        let codex = root.appending(path: "client/.agents/skills/doc-review", directoryHint: .isDirectory)
        try write(definition(name: "doc-review"), to: claude.appending(path: "SKILL.md"))
        try write(definition(name: "doc-review"), to: codex.appending(path: "SKILL.md"))

        let adoption = try library.adoptionPlan(for: [
            candidate(id: "doc-review", sourcePath: claude.path(percentEncoded: false)),
            candidate(id: "reviews:doc-review", sourcePath: codex.path(percentEncoded: false)),
        ])

        #expect(adoption.skills.map(\.id) == ["doc-review"])
        #expect(adoption.rejections.first?.reason.contains("already contains a skill named doc-review") == true)
        library.discardAdoption(adoption)

        #expect(throws: WorkspaceLibraryError.self) {
            _ = try library.adoptionPlan(for: [candidate(id: "unscanned", sourcePath: nil)])
        }
    }

    @Test func aPortableNameAnotherSkillAlreadyAnswersToIsRefused() throws {
        let root = try temporaryDirectory()
        let store = try WorkspaceStore(rootURL: root.appending(path: "workspace", directoryHint: .isDirectory))
        let library = WorkspaceLibrary(store: store)
        let provided = root.appending(path: "client/.claude/plugins/reviews/skills/release-notes", directoryHint: .isDirectory)
        try write(definition(name: "release-notes"), to: provided.appending(path: "SKILL.md"))

        #expect(throws: WorkspaceLibraryError.self) {
            _ = try library.adoptionPlan(
                for: [candidate(id: "reviews:release-notes", sourcePath: provided.path(percentEncoded: false))],
                reservedIdentifiers: ["release-notes"]
            )
        }

        let adoption = try library.adoptionPlan(
            for: [candidate(id: "reviews:release-notes", sourcePath: provided.path(percentEncoded: false))],
            reservedIdentifiers: ["other-skill"]
        )
        #expect(adoption.skills.map(\.id) == ["release-notes"])
        library.discardAdoption(adoption)
    }

    @Test func discardingAReviewLeavesNoStagedCopyBehind() async throws {
        let root = try temporaryDirectory()
        let home = root.appending(path: "home", directoryHint: .isDirectory)
        try write(definition(name: "doc-review"), to: home.appending(path: ".claude/skills/doc-review/SKILL.md"))
        let store = try WorkspaceStore(rootURL: root.appending(path: "workspace", directoryHint: .isDirectory))
        let model = try AppModel(store: store, runner: AdoptionStubRunner(versions: ["claude": "2.0.0"]), homeURL: home)
        await model.runDoctor()
        model.planSkillAdoption(skillIDs: ["doc-review"])
        #expect(model.pendingPlan != nil)

        model.discardPendingPlan()

        let remaining = try FileManager.default.contentsOfDirectory(atPath: store.libraryURL.path(percentEncoded: false))
        #expect(remaining.filter { $0.hasPrefix(".adoption-") }.isEmpty)
        #expect(model.skills.first { $0.id == "doc-review" }?.owned == false)
    }

    private func candidate(id: String, sourcePath: String?) -> SkillAdoptionCandidate {
        SkillAdoptionCandidate(
            skill: Skill(
                id: id,
                name: id,
                displayName: id,
                summary: "A discovered skill.",
                bundle: "Local installation",
                scope: "This Mac",
                owned: false,
                triggers: [],
                negativeTrigger: "",
                files: ["SKILL.md"],
                clients: [ClientState(client: .claude, state: .healthy, detail: "Available", isInstalled: true)],
                validationCount: 0
            ),
            sourcePath: sourcePath
        )
    }

    private func definition(name: String) -> String {
        """
        ---
        name: \(name)
        description: Review a document before it is published.
        ---

        # \(name)

        Steps go here.
        """
    }

    private func temporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appending(
            path: "agent-tooling-tests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func write(_ contents: String, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(contents.utf8).write(to: url, options: .atomic)
    }
}
