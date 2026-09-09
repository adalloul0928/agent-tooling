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
        #expect(
            plan.steps.first?.destinationPath
                == store.libraryURL.appending(path: "packages/local-doc-review", directoryHint: .isDirectory)
                .path(percentEncoded: false)
        )
        #expect(model.skills.first { $0.id == "doc-review" }?.owned == false)
        let packageURL = store.libraryURL.appending(path: "packages/local-doc-review", directoryHint: .isDirectory)
        #expect(!FileManager.default.fileExists(atPath: packageURL.path(percentEncoded: false)))

        await model.executePendingPlan(try OperationPlanApproval.review(plan))

        let adopted = try #require(model.skills.first { $0.id == "doc-review" })
        #expect(adopted.owned)
        #expect(adopted.authoringOrigin == .externalAdopted)
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
        await model.executePendingPlan(try OperationPlanApproval.review(try #require(model.pendingPlan)))

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

        #expect(adoption.skills.map(\.id) == ["doc-review", "release-notes", "something-else"])
        #expect(adoption.sourceSkillIDs == [
            "doc-review": "doc-review", "reviews:release-notes": "release-notes", "renamed": "something-else",
        ])
        #expect(adoption.rejections.map(\.id) == ["linked-skill", "vanished", "unscanned"])
        #expect(adoption.rejections.first { $0.id == "linked-skill" }?.reason.contains("symbolic link") == true)
        #expect(adoption.rejections.first { $0.id == "vanished" }?.reason.contains("no longer on this Mac") == true)
        #expect(adoption.rejections.first { $0.id == "unscanned" }?.reason.contains("Check setup again") == true)
        #expect(adoption.plan.summary.contains("Skipped 3 skills"))
        library.discardAdoption(adoption)
    }

    @Test func repeatedIdentifiersInOneBatchAreRejectedRatherThanDuplicated() throws {
        let root = try temporaryDirectory()
        let store = try WorkspaceStore(rootURL: root.appending(path: "workspace", directoryHint: .isDirectory))
        let library = WorkspaceLibrary(store: store)
        let claude = root.appending(path: "client/.claude/skills/first-folder", directoryHint: .isDirectory)
        let codex = root.appending(path: "client/.agents/skills/second-folder", directoryHint: .isDirectory)
        try write(definition(name: "doc-review"), to: claude.appending(path: "SKILL.md"))
        try write(definition(name: "doc-review"), to: codex.appending(path: "SKILL.md"))

        let adoption = try library.adoptionPlan(for: [
            candidate(id: "first-folder", sourcePath: claude.path(percentEncoded: false)),
            candidate(id: "reviews:second-folder", sourcePath: codex.path(percentEncoded: false)),
        ])

        #expect(adoption.skills.map(\.id) == ["doc-review"])
        #expect(adoption.sourceSkillIDs == ["first-folder": "doc-review"])
        #expect(adoption.rejections.first?.id == "reviews:second-folder")
        #expect(adoption.rejections.first?.reason.contains("already uses the portable name doc-review") == true)
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

extension SkillAdoptionTests {
    @Test func adoptionUsesDeclaredIdentityAndPreservesTheWholeSourceFolder() throws {
        let root = try temporaryDirectory()
        let store = try WorkspaceStore(rootURL: root.appending(path: "workspace", directoryHint: .isDirectory))
        let library = WorkspaceLibrary(store: store)
        let source = root.appending(path: "client/plugin/skills/source-folder", directoryHint: .isDirectory)
        let markdown = """
            ---
            name: "doc-review"
            description: >-
              Review a document before publication,
              including its references and examples.
            ---

            # Document review

            Read [the reference](references/guide.md).
            """
        try write(markdown, to: source.appending(path: "SKILL.md"))
        try write("Read [the example](../assets/example.txt).\n", to: source.appending(path: "references/guide.md"))
        try write("Example bytes\n", to: source.appending(path: "assets/example.txt"))
        try write("#!/bin/sh\nexit 0\n", to: source.appending(path: "scripts/check.sh"))
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: source.appending(path: "scripts/check.sh").path)
        let before = try DirectoryFingerprint.sha256(of: source)

        let adoption = try library.adoptionPlan(for: [candidate(id: "reviews:source-folder", sourcePath: source.path)])
        defer { library.discardAdoption(adoption) }

        let adopted = try #require(adoption.skills.first)
        #expect(adopted.id == "doc-review")
        #expect(adopted.name == "doc-review")
        #expect(adopted.bundle == "local-doc-review")
        #expect(adopted.summary == "Review a document before publication, including its references and examples.")
        #expect(adoption.sourceSkillIDs == ["reviews:source-folder": "doc-review"])
        #expect(adoption.rejections.isEmpty)
        #expect(adopted.files == ["SKILL.md", "assets/example.txt", "references/guide.md", "scripts/check.sh"])

        let step = try #require(adoption.plan.steps.first)
        let stagedPackage = URL(fileURLWithPath: try #require(step.sourcePath), isDirectory: true)
        let stagedSkill = stagedPackage.appending(path: "skills/doc-review", directoryHint: .isDirectory)
        #expect(try Data(contentsOf: stagedSkill.appending(path: "SKILL.md")) == Data(markdown.utf8))
        #expect(try DirectoryFingerprint.sha256(of: stagedSkill) == before)
        #expect(try DirectoryFingerprint.sha256(of: source) == before)
        #expect(try DirectoryFingerprint.sha256(of: stagedPackage) == step.sourceFingerprint)
        let manifest = try #require(
            JSONSerialization.jsonObject(with: Data(contentsOf: stagedPackage.appending(path: "plugin.json"))) as? [String: Any]
        )
        #expect(manifest["name"] as? String == "doc-review")
        #expect(!FileManager.default.fileExists(atPath: library.packagesURL.appending(path: "local-doc-review").path))
    }

    @Test(arguments: [">", ">-", "|", "|-", "plain"])
    func adoptionReadsMultilineDescriptions(style: String) throws {
        let root = try temporaryDirectory()
        let store = try WorkspaceStore(rootURL: root.appending(path: "workspace", directoryHint: .isDirectory))
        let library = WorkspaceLibrary(store: store)
        let source = root.appending(path: "client/source-folder", directoryHint: .isDirectory)
        let description = style == "plain"
            ? "Review a document\n  before publication."
            : "\(style)\n  Review a document\n  before publication."
        try write("---\nname: 'doc-review'\ndescription: \(description)\n---\n\n# Review\n", to: source.appending(path: "SKILL.md"))

        let adoption = try library.adoptionPlan(for: [candidate(id: "source-folder", sourcePath: source.path)])
        defer { library.discardAdoption(adoption) }

        let expected = style.hasPrefix("|") ? "Review a document\nbefore publication." : "Review a document before publication."
        #expect(adoption.skills.first?.summary.trimmingCharacters(in: .whitespacesAndNewlines) == expected)
        #expect(adoption.sourceSkillIDs == ["source-folder": "doc-review"])
    }

    @Test(arguments: ["Doc-Review", "doc review", "../doc-review", "doc--review"])
    func adoptionDoesNotRewriteInvalidDeclaredNames(name: String) throws {
        let root = try temporaryDirectory()
        let store = try WorkspaceStore(rootURL: root.appending(path: "workspace", directoryHint: .isDirectory))
        let library = WorkspaceLibrary(store: store)
        let source = root.appending(path: "client/source-folder", directoryHint: .isDirectory)
        let markdown = definition(name: name)
        try write(markdown, to: source.appending(path: "SKILL.md"))

        do {
            _ = try library.adoptionPlan(for: [candidate(id: "source-folder", sourcePath: source.path)])
            Issue.record("An invalid declared name was adopted.")
        } catch WorkspaceLibraryError.noAdoptableSkillCandidates(let rejections) {
            #expect(rejections.map(\.id) == ["source-folder"])
            #expect(rejections.first?.reason.contains("not a valid skill identifier") == true)
        }
        #expect(try Data(contentsOf: source.appending(path: "SKILL.md")) == Data(markdown.utf8))
    }

    @Test func declaredIdentityCannotReplaceAnExistingManagedPackage() throws {
        let root = try temporaryDirectory()
        let store = try WorkspaceStore(rootURL: root.appending(path: "workspace", directoryHint: .isDirectory))
        let library = WorkspaceLibrary(store: store)
        let existing = try createManagedSkill(named: "doc-review", in: library)
        let before = try DirectoryFingerprint.sha256(of: existing.packageURL)
        let source = root.appending(path: "client/source-folder", directoryHint: .isDirectory)
        try write(definition(name: "doc-review"), to: source.appending(path: "SKILL.md"))

        do {
            _ = try library.adoptionPlan(for: [candidate(id: "source-folder", sourcePath: source.path)])
            Issue.record("A managed package collision was accepted.")
        } catch WorkspaceLibraryError.noAdoptableSkillCandidates(let rejections) {
            #expect(rejections.first?.reason.contains("already contains a skill named doc-review") == true)
        }
        #expect(try DirectoryFingerprint.sha256(of: existing.packageURL) == before)
    }

    @Test func declaringAnotherSelectedRecordsIDCannotReplaceARejectedSource() throws {
        let root = try temporaryDirectory()
        let store = try WorkspaceStore(rootURL: root.appending(path: "workspace", directoryHint: .isDirectory))
        let library = WorkspaceLibrary(store: store)
        let source = root.appending(path: "client/source-folder", directoryHint: .isDirectory)
        try write(definition(name: "doc-review"), to: source.appending(path: "SKILL.md"))

        do {
            _ = try library.adoptionPlan(for: [
                candidate(id: "source-folder", sourcePath: source.path),
                candidate(id: "doc-review", sourcePath: nil),
            ])
            Issue.record("Adoption occupied another selected record's ID.")
        } catch WorkspaceLibraryError.noAdoptableSkillCandidates(let rejections) {
            #expect(rejections.map(\.id) == ["source-folder", "doc-review"])
            #expect(rejections.first?.reason.contains("already uses the portable name doc-review") == true)
        }
    }

    @Test func managedValidationDistinguishesNameMismatchFromMissingMetadata() throws {
        let root = try temporaryDirectory()
        let store = try WorkspaceStore(rootURL: root.appending(path: "workspace", directoryHint: .isDirectory))
        let library = WorkspaceLibrary(store: store)
        let existing = try createManagedSkill(named: "doc-review", in: library)
        let definitionURL = existing.skillURL.appending(path: "SKILL.md")
        try write(definition(name: "different-name"), to: definitionURL)

        do {
            _ = try library.validateSkill(existing.skill)
            Issue.record("A different declared name passed managed validation.")
        } catch WorkspaceLibraryError.skillNameMismatch(let expected, let declared) {
            #expect(expected == "doc-review")
            #expect(declared == "different-name")
        }

        try write("---\nname: doc-review\n---\n", to: definitionURL)
        do {
            _ = try library.validateSkill(existing.skill)
            Issue.record("A missing description passed managed validation.")
        } catch {
            #expect(error.localizedDescription.localizedCaseInsensitiveContains("description"))
            #expect(!error.localizedDescription.contains("different-name"))
        }
    }

    @Test func sourceEditsUseTheSameMultilineMetadataAsAdoptionAndValidation() throws {
        let root = try temporaryDirectory()
        let store = try WorkspaceStore(rootURL: root.appending(path: "workspace", directoryHint: .isDirectory))
        let library = WorkspaceLibrary(store: store)
        let existing = try createManagedSkill(named: "doc-review", in: library)
        let markdown = "---\nname: 'doc-review'\ndescription: >-\n  Review a document\n  before publication.\n---\n\n# Review\n"

        let updated = try library.updateSkillSource(existing.skill, markdown: markdown)
        #expect(updated.skill.summary == "Review a document before publication.")
        #expect(updated.skill.validationCount == 3)
        #expect(try library.validateSkill(updated.skill) == 3)
        #expect(try Data(contentsOf: updated.skillURL.appending(path: "SKILL.md")) == Data(markdown.utf8))
        #expect(library.commitUpdate(updated) == nil)
    }

    private func createManagedSkill(named name: String, in library: WorkspaceLibrary) throws -> CreatedSkill {
        var draft = SkillDraft()
        draft.name = name
        draft.purpose = "Review a document."
        draft.triggers = ["Review this document."]
        draft.negativeTrigger = "Do not publish it."
        draft.selectedTargets = [.claude]
        return try library.createSkill(from: draft)
    }

    /// A batch reviews as one step per skill. Adopting three skills must not
    /// read as a single rewrite of the whole managed library, and it must not
    /// restage packages the library already holds.
    @Test func eachAdoptedSkillIsItsOwnReviewableStep() throws {
        let root = try temporaryDirectory()
        let store = try WorkspaceStore(rootURL: root.appending(path: "workspace", directoryHint: .isDirectory))
        let library = WorkspaceLibrary(store: store)

        var existing = SkillDraft()
        existing.name = "already-managed"
        existing.purpose = "A package the library already holds."
        existing.triggers = ["one", "two", "three"]
        existing.negativeTrigger = "Never for anything else."
        existing.selectedTargets = [.claude]
        let untouched = try library.createSkill(from: existing)
        let untouchedFingerprint = try DirectoryFingerprint.sha256(of: untouched.packageURL)

        var sources: [SkillAdoptionCandidate] = []
        for name in ["alpha-review", "beta-review", "gamma-review"] {
            let source = root.appending(path: "client/\(name)", directoryHint: .isDirectory)
            try write(definition(name: name), to: source.appending(path: "SKILL.md"))
            sources.append(candidate(id: name, sourcePath: source.path(percentEncoded: false)))
        }

        let adoption = try library.adoptionPlan(for: sources)
        defer { library.discardAdoption(adoption) }

        #expect(adoption.plan.steps.count == 3)
        #expect(adoption.plan.steps.allSatisfy { $0.kind == .copyDirectory })
        #expect(
            Set(adoption.plan.steps.compactMap(\.destinationPath).map { $0.hasSuffix("/") ? String($0.dropLast()) : $0 })
                == Set(
                    ["alpha-review", "beta-review", "gamma-review"].map {
                        store.libraryURL.appending(path: "packages/local-\($0)", directoryHint: .notDirectory)
                            .path(percentEncoded: false)
                    })
        )
        // Every step carries its own fingerprint, so the review names the exact
        // bytes of each skill rather than one hash over everything.
        #expect(Set(adoption.plan.steps.compactMap(\.sourceFingerprint)).count == 3)
        // No step targets the library root, and the package already in the
        // library is neither restaged nor rewritten.
        #expect(!adoption.plan.steps.contains { $0.destinationPath == store.libraryURL.path(percentEncoded: false) })
        #expect(try DirectoryFingerprint.sha256(of: untouched.packageURL) == untouchedFingerprint)
    }
}
