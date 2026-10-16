import Foundation
import Testing

@testable import AgentToolingApp
@testable import AgentToolingCore

/// The skill creator's two pieces of lifted-out state carry rules the view used
/// to inline: what makes a first message valid, what the options summary says,
/// what the first request carries, which draft file opens first, and when every
/// file has been read. None of that was reachable by a test while it lived in
/// the view body; these pin it directly.
@Suite("Skill creator options rules")
struct SkillCreatorOptionsTests {
    @Test func summaryNamesTheAssistantsChoiceWhenNoNameIsSuggested() {
        let options = SkillCreatorOptions(proposedName: "", scope: .user, projectRoot: "", targets: [])
        let text = options.summaryText(client: .claude)
        #expect(text.contains("Claude Code chooses the name"))
        // The home scope has one name across the app.
        #expect(text.contains("on this Mac"))
        #expect(!text.contains("for you"))
        #expect(text.contains("offered to no app yet"))
    }

    @Test func summaryReflectsASuggestedNameProjectScopeAndTargets() {
        let options = SkillCreatorOptions(
            proposedName: "release-readiness", scope: .project, projectRoot: "/tmp",
            targets: [.codex, .claude])
        let text = options.summaryText(client: .codex)
        #expect(text.contains("named release-readiness"))
        #expect(text.contains("for a project"))
        // Targets read in a stable, name-sorted order.
        #expect(text.contains("offered to Claude Code, Codex"))
    }

    @Test func anUnmanagedClientCannotBeAsked() {
        let options = SkillCreatorOptions(targets: [.claude])
        let message = options.validationMessage(
            isManagingClient: false, client: .claude, composerTooLong: false, hasConversation: false)
        #expect(message?.contains("not managing Claude Code") == true)
    }

    @Test func anOverlongMessageIsRefusedBeforeTheOptionsAreEvenChecked() {
        // No targets would normally fail, but length is checked first.
        let options = SkillCreatorOptions(targets: [])
        let message = options.validationMessage(
            isManagingClient: true, client: .codex, composerTooLong: true, hasConversation: false)
        #expect(message == "Shorten the message before sending it.")
    }

    @Test func onceAConversationHasStartedOnlyLengthStillMatters() {
        // Empty targets and a bad name would fail a first message, but the
        // options are fixed once a draft is under way, so they are not re-checked.
        let options = SkillCreatorOptions(proposedName: "Not A Valid Name", scope: .user, targets: [])
        #expect(
            options.validationMessage(
                isManagingClient: true, client: .codex, composerTooLong: false, hasConversation: true) == nil)
    }

    @Test func aSuggestedNameMustBeANormalizedIdentifier() {
        // An underscore is not among the allowed characters, so normalization
        // throws and the name is refused.
        let options = SkillCreatorOptions(proposedName: "not_valid", targets: [.codex])
        let message = options.validationMessage(
            isManagingClient: true, client: .codex, composerTooLong: false, hasConversation: false)
        #expect(message?.contains("lowercase letters, numbers, and single hyphens") == true)
    }

    @Test func aProjectScopeNeedsAnExistingFolder() {
        let options = SkillCreatorOptions(
            proposedName: "", scope: .project, projectRoot: "/this/does/not/exist", targets: [.codex])
        let message = options.validationMessage(
            isManagingClient: true, client: .codex, composerTooLong: false, hasConversation: false)
        #expect(message == "Choose an existing project folder under Options.")
    }

    @Test func atLeastOneTargetIsRequired() {
        let options = SkillCreatorOptions(proposedName: "", scope: .user, targets: [])
        let message = options.validationMessage(
            isManagingClient: true, client: .codex, composerTooLong: false, hasConversation: false)
        #expect(message?.contains("at least one app") == true)
    }

    @Test func aUserScopedRequestWithAValidNameAndATargetIsReady() {
        let options = SkillCreatorOptions(proposedName: "release-readiness", scope: .user, targets: [.codex])
        #expect(
            options.validationMessage(
                isManagingClient: true, client: .codex, composerTooLong: false, hasConversation: false) == nil)
    }

    @Test func aRealDirectoryPassesTheProjectFolderCheck() throws {
        let folder = FileManager.default.temporaryDirectory
            .appending(path: "options-check-\(UUID())", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let options = SkillCreatorOptions(scope: .project, projectRoot: folder.path, targets: [.codex])
        #expect(options.projectFolderIsValid)
        #expect(
            options.validationMessage(
                isManagingClient: true, client: .codex, composerTooLong: false, hasConversation: false) == nil)
    }

    @Test func theRootAndANonAbsolutePathAreNotValidProjectFolders() {
        #expect(!SkillCreatorOptions(scope: .project, projectRoot: "/").projectFolderIsValid)
        #expect(!SkillCreatorOptions(scope: .project, projectRoot: "relative/path").projectFolderIsValid)
    }

    @Test func makeRequestCarriesTheNameSortedTargetsAndTheGivenInstruction() {
        let id = UUID()
        let options = SkillCreatorOptions(
            proposedName: "release-readiness", scope: .user, projectRoot: "/tmp", targets: [.codex, .claude])
        let request = options.makeRequest(id: id, client: .claude, instruction: "Write it.")
        #expect(request.id == id)
        #expect(request.client == .claude)
        #expect(request.instruction == "Write it.")
        #expect(request.proposedName == "release-readiness")
        #expect(request.scope == .user)
        // A user-scoped request leaves the project root out even when one is set.
        #expect(request.projectRoot == nil)
        #expect(request.targets == [.claude, .codex])
    }

    @Test func makeRequestDropsABlankNameAndKeepsAProjectRootForAProjectScope() {
        let options = SkillCreatorOptions(
            proposedName: "   ", scope: .project, projectRoot: "/tmp/project", targets: [.codex])
        let request = options.makeRequest(id: UUID(), client: .codex, instruction: "Draft.")
        // A blank-only name is only dropped when it is literally empty; the
        // view trims before this, so a whitespace name reaches makeRequest as a
        // value. What matters here is the project root travels with a project.
        #expect(request.projectRoot == "/tmp/project")

        let blank = SkillCreatorOptions(proposedName: "", scope: .project, projectRoot: "/tmp", targets: [.codex])
        #expect(blank.makeRequest(id: UUID(), client: .codex, instruction: "Draft.").proposedName == nil)
    }
}

/// The review selection's rules: which file opens first, how reading is
/// tracked, and when the draft can be saved.
@Suite("Skill creator review selection rules")
struct SkillCreatorReviewSelectionTests {
    private func result(files: [SkillDraftFile], skillMarkdown: String = "# Skill\n") throws -> SkillDraftResult {
        let request = SkillDraftRequest(instruction: "Write a skill.", targets: [.codex])
        return SkillDraftResult(
            request: request, skillName: "release-readiness",
            description: "Check whether a release is ready to ship.",
            packageURL: URL(fileURLWithPath: "/tmp/pkg"),
            skillURL: URL(fileURLWithPath: "/tmp/pkg/skills/release-readiness"),
            manifest: try AgentPluginManifest(
                name: "release-readiness", description: "Check whether a release is ready to ship."),
            skillMarkdown: skillMarkdown,
            files: files, fingerprint: String(repeating: "a", count: 64), createdAt: .now)
    }

    private func file(_ path: String, bytes: Int = 10, executable: Bool = false, content: String? = "x") -> SkillDraftFile {
        .init(relativePath: path, byteCount: bytes, isExecutable: executable, textContent: content)
    }

    @Test func theDefinitionOpensFirstAndCountsAsRead() {
        var selection = SkillCreatorReviewSelection()
        selection.selectInitial(from: [
            file("plugin.json"), file("skills/release-readiness/SKILL.md"), file("scripts/run.sh"),
        ])
        #expect(selection.selectedPath == "skills/release-readiness/SKILL.md")
        #expect(selection.reviewedPaths == ["skills/release-readiness/SKILL.md"])
    }

    @Test func withNoDefinitionTheFirstFileOpens() {
        var selection = SkillCreatorReviewSelection()
        selection.selectInitial(from: [file("plugin.json"), file("notes.txt")])
        #expect(selection.selectedPath == "plugin.json")
        #expect(selection.reviewedPaths == ["plugin.json"])
    }

    @Test func selectingTheInitialFileIsANoOpOnceAFileIsOpen() {
        var selection = SkillCreatorReviewSelection()
        selection.select("notes.txt")
        selection.selectInitial(from: [file("skills/x/SKILL.md"), file("notes.txt")])
        #expect(selection.selectedPath == "notes.txt")
        #expect(selection.reviewedPaths == ["notes.txt"])
    }

    @Test func selectingAFileMarksItReadAndSaveWaitsUntilEveryFileHasBeenOpened() throws {
        let result = try result(files: [file("plugin.json"), file("skills/x/SKILL.md"), file("scripts/run.sh")])
        var selection = SkillCreatorReviewSelection()
        selection.selectInitial(from: result.files)
        #expect(!selection.allReviewed(in: result))
        #expect(selection.progress(for: result) == "Open 2 more generated files before saving.")

        selection.select("plugin.json")
        #expect(selection.progress(for: result) == "Open 1 more generated file before saving.")

        selection.select("scripts/run.sh")
        #expect(selection.allReviewed(in: result))
        #expect(selection.progress(for: result) == "Every generated file has been opened for review.")
    }

    @Test func theDefinitionShowsTheSkillMarkdownAndOtherFilesTheirOwnText() throws {
        let result = try result(
            files: [file("skills/x/SKILL.md", content: "ignored on disk"), file("plugin.json", content: "{\"a\":1}")],
            skillMarkdown: "# The real markdown\n")
        var selection = SkillCreatorReviewSelection()

        selection.select("skills/x/SKILL.md")
        #expect(selection.selectedFile(in: result)?.relativePath == "skills/x/SKILL.md")
        #expect(selection.selectedContent(in: result) == "# The real markdown\n")

        selection.select("plugin.json")
        #expect(selection.selectedContent(in: result) == "{\"a\":1}")
    }

    @Test func resetClearsTheSelectionForAFreshPackage() {
        var selection = SkillCreatorReviewSelection()
        selection.select("plugin.json")
        selection.reset()
        #expect(selection.selectedPath.isEmpty)
        #expect(selection.reviewedPaths.isEmpty)
    }
}
