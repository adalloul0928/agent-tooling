import Foundation
import Testing

@testable import AgentToolingCore

@MainActor
@Suite("Codex skill draft integration")
struct CodexSkillDraftIntegrationTests {
    @Test func reviewedDraftIsAdoptedBeforeAConfirmationRequiredInstallPlanIsPresented() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let request = CodexSkillDraftRequest(
            instruction: "Create a focused release-readiness skill.",
            proposedName: "codex-release-readiness",
            scope: .user,
            targets: [.codex]
        )
        let result = try stageDraft(
            request: request,
            name: "codex-release-readiness",
            description: "Review release readiness and report blocking evidence.",
            store: fixture.store
        )
        try fixture.store.saveCodexSkillDraftRequest(request)
        let service = CodexSkillDraftService(
            stagingRootURL: fixture.stagingRoot,
            skillCreatorURL: fixture.root.appending(path: "unused-skill-creator", directoryHint: .isDirectory)
        )
        let model = try AppModel(
            store: fixture.store,
            runner: DraftIntegrationCommandRunner(),
            homeURL: fixture.home,
            codexSkillDraftService: service
        )

        let adopted = try #require(await model.adoptCodexSkillDraft(result))

        #expect(adopted.id == result.skillName)
        #expect(adopted.authoringOrigin == .codexGenerated)
        #expect(adopted.validationCount == 3)
        #expect(adopted.owned)
        #expect(adopted.clients.map(\.client) == [.codex])
        #expect(adopted.clients.allSatisfy { $0.state == .pending })
        #expect(model.skills.first(where: { $0.id == adopted.id }) == adopted)
        #expect(model.activities.first?.title == "Codex Release Readiness generated with Codex")

        // The creator is itself a sheet. Adoption must not publish the install
        // plan until that sheet has dismissed, or SwiftUI can attempt to
        // present two modal sheets at once. SkillsView performs this explicit
        // handoff from its onDismiss callback.
        #expect(model.pendingPlan == nil)
        model.planInstall(
            skillID: adopted.id,
            targets: Set(result.request.targets),
            includeFreshSessionCanary: true
        )
        let plan = try #require(model.pendingPlan)
        #expect(plan.kind == .installSkill)
        #expect(plan.requiresConfirmation)
        #expect(plan.targetSurfaces == [.codexCLI])
        #expect(plan.steps.filter { $0.kind == .copyDirectory }.count == 1)
        #expect(plan.steps.filter { $0.kind == .manual }.count == 1)
        #expect(
            plan.steps.first(where: { $0.kind == .copyDirectory })?.destinationPath
                == fixture.home
                .appending(path: ".agents/skills/codex-release-readiness", directoryHint: .isDirectory)
                .path(percentEncoded: false)
        )
        #expect(model.isInteractionLocked)
        #expect(
            !FileManager.default.fileExists(
                atPath: fixture.home.appending(path: ".agents/skills/codex-release-readiness").path(percentEncoded: false)
            )
        )

        let managedPackage = fixture.store.libraryURL.appending(
            path: "packages/local-codex-release-readiness",
            directoryHint: .isDirectory
        )
        #expect(FileManager.default.fileExists(atPath: managedPackage.appending(path: "plugin.json").path(percentEncoded: false)))
        #expect(
            FileManager.default.fileExists(
                atPath: managedPackage.appending(path: "skills/codex-release-readiness/SKILL.md").path(percentEncoded: false)
            )
        )
        #expect(!FileManager.default.fileExists(atPath: result.packageURL.deletingLastPathComponent().path(percentEncoded: false)))
        #expect(try fixture.store.loadCodexSkillDraftRequest(id: request.id) == nil)

        let reloadedStore = try WorkspaceStore(rootURL: fixture.store.rootURL)
        let persisted = try #require(try reloadedStore.loadWorkspaceSnapshot())
        let persistedSkill = try #require(persisted.skills.first(where: { $0.id == adopted.id }))
        #expect(persistedSkill.authoringOrigin == .codexGenerated)
        #expect(persistedSkill.validationCount == 3)
        #expect(try reloadedStore.loadCodexSkillDraftRequest(id: request.id) == nil)
    }

    @Test func failedPostCopyValidationRollsBackManagedPackageAndPreservesRecoverableDraft() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let request = CodexSkillDraftRequest(
            instruction: "Create a draft whose invalid summary exercises adoption rollback.",
            proposedName: "rollback-draft",
            scope: .user,
            targets: [.codex]
        )
        // WorkspaceLibrary adopts this structurally valid package, then its
        // stricter skill validation rejects the one-character description.
        // That puts AppModel's post-copy rollback path under test.
        let result = try stageDraft(
            request: request,
            name: "rollback-draft",
            description: "A",
            store: fixture.store
        )
        try fixture.store.saveCodexSkillDraftRequest(request)
        let model = try AppModel(
            store: fixture.store,
            runner: DraftIntegrationCommandRunner(),
            homeURL: fixture.home,
            codexSkillDraftService: CodexSkillDraftService(
                stagingRootURL: fixture.stagingRoot,
                skillCreatorURL: fixture.root.appending(path: "unused-skill-creator", directoryHint: .isDirectory)
            )
        )

        let adopted = await model.adoptCodexSkillDraft(result)

        #expect(adopted == nil)
        #expect(model.pendingPlan == nil)
        #expect(!model.skills.contains(where: { $0.id == result.skillName }))
        #expect(model.lastError != nil)
        #expect(
            !FileManager.default.fileExists(
                atPath: fixture.store.libraryURL
                    .appending(path: "packages/local-rollback-draft", directoryHint: .isDirectory)
                    .path(percentEncoded: false)
            )
        )
        #expect(FileManager.default.fileExists(atPath: result.packageURL.path(percentEncoded: false)))
        #expect(try fixture.store.loadCodexSkillDraftRequest(id: request.id) == request)
        #expect(try fixture.store.loadWorkspaceSnapshot()?.skills.contains(where: { $0.id == result.skillName }) != true)
    }
}

@Suite("Codex skill draft request persistence")
struct CodexSkillDraftRequestPersistenceTests {
    @Test func stateRecordRoundTripsAndDeletesAcrossStoreInstances() throws {
        let root = try makeTemporaryDirectory(prefix: "CodexSkillDraftRequestPersistenceTests")
        defer { try? FileManager.default.removeItem(at: root) }
        let request = CodexSkillDraftRequest(
            id: UUID(),
            instruction: "Create a project skill that summarizes verified release evidence.",
            proposedName: "release-evidence",
            scope: .project,
            projectRoot: "/Users/example/project",
            targets: [.codex, .gemini]
        )
        let retained = CodexSkillDraftRequest(
            id: UUID(),
            instruction: "Keep this independent request.",
            proposedName: "independent-request",
            targets: [.codex]
        )

        let first = try WorkspaceStore(rootURL: root)
        try first.saveCodexSkillDraftRequest(request)
        try first.saveCodexSkillDraftRequest(retained)
        try first.saveWorkspaceSnapshot(WorkspaceSnapshot())

        let second = try WorkspaceStore(rootURL: root)
        #expect(try second.loadCodexSkillDraftRequest(id: request.id) == request)
        #expect(try second.loadCodexSkillDraftRequest(id: retained.id) == retained)
        try second.deleteCodexSkillDraftRequest(id: request.id)

        let third = try WorkspaceStore(rootURL: root)
        #expect(try third.loadCodexSkillDraftRequest(id: request.id) == nil)
        #expect(try third.loadCodexSkillDraftRequest(id: retained.id) == retained)
        #expect(try third.loadWorkspaceSnapshot() != nil)

        try third.deleteCodexSkillDraftRequest(id: request.id)
        try third.deleteCodexSkillDraftRequest(id: retained.id)
        #expect(try first.loadCodexSkillDraftRequest(id: retained.id) == nil)
    }
}

private struct DraftIntegrationFixture {
    var root: URL
    var home: URL
    var store: WorkspaceStore
    var stagingRoot: URL
}

private struct DraftIntegrationCommandRunner: CommandRunning {
    func run(executable _: String, arguments _: [String], currentDirectory _: URL?) async throws -> CommandOutput {
        CommandOutput(status: 0, standardOutput: "", standardError: "")
    }
}

private func makeFixture() throws -> DraftIntegrationFixture {
    let root = try makeTemporaryDirectory(prefix: "CodexSkillDraftIntegrationTests")
    let home = root.appending(path: "home", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    let store = try WorkspaceStore(rootURL: root.appending(path: "workspace", directoryHint: .isDirectory))
    return DraftIntegrationFixture(
        root: root,
        home: home,
        store: store,
        stagingRoot: store.cacheURL.appending(path: "skill-drafts", directoryHint: .isDirectory)
    )
}

private func stageDraft(
    request: CodexSkillDraftRequest,
    name: String,
    description: String,
    store: WorkspaceStore
) throws -> CodexSkillDraftResult {
    let requestURL = store.cacheURL
        .appending(path: "skill-drafts", directoryHint: .isDirectory)
        .appending(path: "request-\(request.id.uuidString.lowercased())", directoryHint: .isDirectory)
    let packageURL = requestURL.appending(path: "draft", directoryHint: .isDirectory)
    let skillURL = packageURL.appending(path: "skills/\(name)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: skillURL, withIntermediateDirectories: true)

    let manifest = try AgentPluginManifest(name: name, description: description)
    try AgentToolingCoding.encoder().encode(manifest).write(
        to: packageURL.appending(path: "plugin.json"),
        options: .atomic
    )
    let markdown = """
        ---
        name: \(name)
        description: \(description)
        ---

        # Generated Skill

        Follow the reviewed workflow and report evidence.
        """
    try Data(markdown.utf8).write(to: skillURL.appending(path: "SKILL.md"), options: .atomic)
    try AgentToolingCoding.encoder().encode(request).write(
        to: requestURL.appending(path: CodexSkillDraftService.requestMetadataFileName),
        options: .atomic
    )
    let fingerprint = try DirectoryFingerprint.sha256(
        of: packageURL,
        maximumItems: 256,
        maximumBytes: 8 * 1_024 * 1_024
    )
    return CodexSkillDraftResult(
        request: request,
        skillName: name,
        description: description,
        packageURL: packageURL,
        skillURL: skillURL,
        manifest: manifest,
        skillMarkdown: markdown,
        files: [
            CodexSkillDraftFile(
                relativePath: "plugin.json",
                byteCount: try Data(contentsOf: packageURL.appending(path: "plugin.json")).count,
                isExecutable: false,
                textContent: String(data: try Data(contentsOf: packageURL.appending(path: "plugin.json")), encoding: .utf8)
            ),
            CodexSkillDraftFile(
                relativePath: "skills/\(name)/SKILL.md",
                byteCount: markdown.lengthOfBytes(using: .utf8),
                isExecutable: false,
                textContent: markdown
            ),
        ],
        fingerprint: fingerprint,
        createdAt: .now
    )
}

private func makeTemporaryDirectory(prefix: String) throws -> URL {
    let directory = FileManager.default.temporaryDirectory.appending(
        path: "\(prefix)-\(UUID().uuidString)",
        directoryHint: .isDirectory
    )
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory
}
