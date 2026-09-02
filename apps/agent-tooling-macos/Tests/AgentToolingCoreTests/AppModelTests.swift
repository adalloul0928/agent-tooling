import Foundation
import Testing

@testable import AgentToolingCore

private struct StubRunner: CommandRunning {
    let versions: [String: String]
    let responses: [String: CommandOutput]

    init(versions: [String: String], responses: [String: CommandOutput] = [:]) {
        self.versions = versions
        self.responses = responses
    }

    func run(executable: String, arguments: [String], currentDirectory: URL?) async throws -> CommandOutput {
        if let response = responses[([executable] + arguments).joined(separator: " ")] { return response }
        if arguments == ["--version"] {
            if let version = versions[executable] {
                return CommandOutput(status: 0, standardOutput: version + "\n", standardError: "")
            }
            return CommandOutput(status: 127, standardOutput: "", standardError: "command not found")
        }
        return CommandOutput(status: 0, standardOutput: "", standardError: "")
    }
}

private actor RecordingRunner: CommandRunning {
    struct Invocation: Sendable, Equatable {
        var executable: String
        var arguments: [String]
        var currentDirectory: URL?
    }

    private var invocations: [Invocation] = []

    func run(executable: String, arguments: [String], currentDirectory: URL?) async throws -> CommandOutput {
        invocations.append(Invocation(executable: executable, arguments: arguments, currentDirectory: currentDirectory))
        return CommandOutput(status: 0, standardOutput: "", standardError: "")
    }

    func recordedInvocations() -> [Invocation] { invocations }
}

@MainActor
struct AppModelTests {
    @Test func workspaceStorePersistsAcrossInstances() throws {
        let root = try temporaryDirectory()
        let first = try WorkspaceStore(rootURL: root)
        try first.save(["local", "first-class"], for: "test.values")

        let second = try WorkspaceStore(rootURL: root)
        let values = try second.load("test.values", as: [String].self)

        #expect(values == ["local", "first-class"])
        #expect(FileManager.default.fileExists(atPath: root.appending(path: "agent-tooling.sqlite").path(percentEncoded: false)))
    }

    @Test func workspaceStoreRejectsUnsafeRootsSymlinksAndKeys() throws {
        #expect(throws: WorkspaceStoreError.self) {
            _ = try WorkspaceStore(rootURL: FileManager.default.homeDirectoryForCurrentUser)
        }

        let root = try temporaryDirectory()
        let target = root.appending(path: "target", directoryHint: .isDirectory)
        let linkedRoot = root.appending(path: "linked", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: linkedRoot, withDestinationURL: target)
        #expect(throws: WorkspaceStoreError.self) {
            _ = try WorkspaceStore(rootURL: linkedRoot)
        }

        let workspace = root.appending(path: "workspace", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        let externalDatabase = root.appending(path: "external.sqlite")
        try Data().write(to: externalDatabase)
        try FileManager.default.createSymbolicLink(
            at: workspace.appending(path: "agent-tooling.sqlite"), withDestinationURL: externalDatabase)
        #expect(throws: WorkspaceStoreError.self) {
            _ = try WorkspaceStore(rootURL: workspace)
        }

        let safeStore = try WorkspaceStore(rootURL: root.appending(path: "safe-workspace"))
        #expect(throws: WorkspaceStoreError.self) {
            try safeStore.save(["value"], for: "")
        }
    }

    @Test func snapshotValidatorRejectsUnsafeNestedMachineState() throws {
        let unsafeRoute = NativeInstall(
            client: .codex,
            executable: "sh",
            arguments: ["-c", "echo unsafe"],
            detail: "Unsafe"
        )
        let package = MarketplacePackage(
            id: "unsafe",
            name: "Unsafe",
            publisher: "Test",
            summary: "Unsafe route",
            sourceName: "Test",
            components: [.plugin],
            supportedClients: [.codex],
            location: "unsafe",
            nativeInstalls: [unsafeRoute]
        )
        #expect(throws: WorkspaceSnapshotValidationError.self) {
            try WorkspaceSnapshotValidator.validate(WorkspaceSnapshot(marketplacePackages: [package]), mode: .localState)
        }

        let unsupportedLocation = MarketplacePackage(
            id: "unsupported-location",
            name: "Unsupported",
            publisher: "Test",
            summary: "Unsupported source scheme",
            sourceName: "Test",
            components: [.plugin],
            supportedClients: [.codex],
            location: "file:///private/tmp/package"
        )
        #expect(throws: WorkspaceSnapshotValidationError.self) {
            try WorkspaceSnapshotValidator.validate(
                WorkspaceSnapshot(marketplacePackages: [unsupportedLocation]),
                mode: .localState
            )
        }

        let misleadingLocation = MarketplacePackage(
            id: "misleading-location",
            name: "Misleading",
            publisher: "Test",
            summary: "Not actually an HTTP URL",
            sourceName: "Test",
            components: [.plugin],
            supportedClients: [.codex],
            location: "http-plugin"
        )
        try WorkspaceSnapshotValidator.validate(
            WorkspaceSnapshot(marketplacePackages: [misleadingLocation]),
            mode: .localState
        )

        let activity = ActivityReceipt(
            kind: .validation,
            title: "Unsafe output",
            detail: "token=plain-text-secret",
            date: .now,
            state: .attention
        )
        #expect(throws: WorkspaceSnapshotValidationError.self) {
            try WorkspaceSnapshotValidator.validate(WorkspaceSnapshot(activities: [activity]), mode: .localState)
        }
    }

    @Test func preparedPlanCannotBeSilentlyReplacedByAnotherAction() throws {
        let root = try temporaryDirectory()
        let store = try WorkspaceStore(rootURL: root.appending(path: "workspace", directoryHint: .isDirectory))
        let model = try AppModel(store: store, runner: StubRunner(versions: [:]), homeURL: root.appending(path: "home"))

        model.prepareBackup()
        let firstPlanID = model.pendingPlan?.id
        model.prepareBackup()

        #expect(model.pendingPlan?.id == firstPlanID)
        #expect(model.isInteractionLocked)
        #expect(model.lastError?.contains("current review") == true)
    }

    @Test func appModelRejectsSemanticallyCorruptPersistedDesiredState() throws {
        let root = try temporaryDirectory()
        let store = try WorkspaceStore(rootURL: root.appending(path: "workspace", directoryHint: .isDirectory))
        let duplicate = Skill(
            id: "duplicate", name: "duplicate", displayName: "Duplicate", summary: "One", bundle: "local-duplicate", scope: "This Mac",
            owned: true, triggers: [], negativeTrigger: "", files: ["SKILL.md"], clients: [], validationCount: 0)
        try store.save(WorkspaceSnapshot(skills: [duplicate, duplicate]), for: "workspace.snapshot")

        #expect(throws: WorkspaceSnapshotValidationError.self) {
            _ = try AppModel(store: store, runner: StubRunner(versions: [:]), homeURL: root.appending(path: "home"))
        }
    }

    @Test func portableProjectionStripsMachineStateAndProjectPaths() throws {
        let project = "/Users/example/private-project"
        let profile = ToolingProfile(
            id: "project", name: "Project", summary: "Local", scope: .project, projectRoot: project, checks: [], enabledPlugins: [],
            requiredMCPs: [])
        let server = MCPServer(
            id: "docs", name: "Docs", summary: "Managed by Agent Tooling", endpoint: "https://example.com/mcp", transport: .http,
            authentication: "OAuth", scope: ToolingScope.project.displayName, projectRoot: project, clients: [], definitionOrigin: .managed)
        let skill = Skill(
            id: "review", name: "review", displayName: "Review", summary: "Review", bundle: "local-review",
            scope: ToolingScope.project.displayName, owned: true, triggers: [], negativeTrigger: "", files: ["SKILL.md"], clients: [],
            validationCount: 0, projectRoot: project)
        let snapshot = WorkspaceSnapshot(
            skills: [skill],
            mcpServers: [server],
            profiles: [profile],
            activities: [ActivityReceipt(kind: .configuration, title: "Local", detail: "History", date: .now, state: .healthy)],
            sources: [
                ToolingSource(name: "Local", kind: .localFolder, location: project),
                ToolingSource(name: "Remote", kind: .agentPlugins, location: "https://agent-plugins.org/"),
            ],
            activeProfileID: "project",
            importedRepositoryPath: project
        )

        let portable = snapshot.portableDesiredState()
        try WorkspaceSnapshotValidator.validate(portable, mode: .portableImport)

        #expect(portable.skills.first?.projectRoot == nil)
        #expect(portable.mcpServers.first?.projectRoot == nil)
        #expect(portable.profiles.first?.projectRoot == nil)
        #expect(portable.activities.isEmpty)
        #expect(portable.importedRepositoryPath == nil)
        #expect(portable.sources.map(\.name) == ["Remote"])
    }

    @Test func snapshotValidatorRejectsProfileInheritanceCycles() {
        let first = ToolingProfile(
            id: "first", name: "First", summary: "", inheritedFrom: "second", checks: [], enabledPlugins: [], requiredMCPs: [])
        let second = ToolingProfile(
            id: "second", name: "Second", summary: "", inheritedFrom: "first", checks: [], enabledPlugins: [], requiredMCPs: [])

        #expect(throws: WorkspaceSnapshotValidationError.self) {
            try WorkspaceSnapshotValidator.validate(
                WorkspaceSnapshot(profiles: [first, second], activeProfileID: "first"), mode: .portableImport)
        }
    }

    @Test func creatingAndInstallingSkillUsesNoGitAndReachesAllThreeClients() async throws {
        let root = try temporaryDirectory()
        let home = root.appending(path: "test-home", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        let store = try WorkspaceStore(rootURL: root.appending(path: "workspace", directoryHint: .isDirectory))
        let model = try AppModel(store: store, runner: StubRunner(versions: [:]), homeURL: home)
        var draft = SkillDraft()
        draft.name = "release-readiness"
        draft.purpose = "Verify a release candidate before submission."
        draft.triggers = ["Check release readiness", "Prepare the release", "Audit the candidate"]
        draft.negativeTrigger = "Building an unrelated feature"
        draft.selectedTargets = Set(ClientKind.allCases)

        let skill = model.createSkill(from: draft)

        #expect(skill?.id == "release-readiness")
        #expect(skill?.validationCount == 3)
        #expect(model.pendingPlan?.steps.filter { $0.kind == .copyDirectory }.count == 3)
        #expect(
            model.pendingPlan?.steps.contains { $0.executable == "gemini" && $0.arguments.prefix(2) == ["extensions", "link"] } == false)
        #expect(model.pendingPlan?.steps.filter { $0.title.contains("Fresh-session canary") }.count == 3)
        #expect(
            FileManager.default.fileExists(
                atPath: store.libraryURL.appending(path: "packages/local-release-readiness/skills/release-readiness/SKILL.md").path(
                    percentEncoded: false)))
        #expect(
            !FileManager.default.fileExists(
                atPath: store.libraryURL.appending(path: "packages/local-release-readiness/gemini-extension.json").path(
                    percentEncoded: false)))
        let portableManifest =
            try JSONSerialization.jsonObject(
                with: Data(contentsOf: store.libraryURL.appending(path: "packages/local-release-readiness/plugin.json"))) as? [String: Any]
        #expect(portableManifest?["$schema"] as? String == "https://agent-plugins.org/schemas/1.0.0/plugin.schema.json")
        #expect(portableManifest?["schema_version"] == nil)

        let approvedPlan = try #require(model.pendingPlan)
        await model.executePendingPlan()

        for path in [
            ".claude/skills/release-readiness/SKILL.md", ".agents/skills/release-readiness/SKILL.md",
            ".gemini/skills/release-readiness/SKILL.md",
        ] {
            #expect(FileManager.default.fileExists(atPath: home.appending(path: path).path(percentEncoded: false)))
        }
        #expect(model.operationReceipts.first?.state == .pending)
        #expect(model.operationReceipts.first?.results.contains { $0.status == .succeeded } == true)
        #expect(model.operationReceipts.first?.results.contains { $0.status == .manual } == true)
        #expect(model.operationReceipts.first?.targetSurfaces.count == 3)
        let recordedPlan = try store.loadEntity(
            approvedPlan.id.uuidString.lowercased(),
            domain: .plans,
            as: OperationPlan.self
        )
        #expect(recordedPlan?.id == approvedPlan.id)
        #expect(
            try recordedPlan.map { try OperationPlanApproval.review($0).digest }
                == OperationPlanApproval.review(approvedPlan).digest
        )
        let recordedReceipts = try store.listEntities(domain: .receipts, as: OperationReceipt.self)
        #expect(recordedReceipts.contains { $0.planID == approvedPlan.id })
    }

    @Test func skillAuthoringBoundsInputAndCreatesAnExecutableScript() throws {
        let root = try temporaryDirectory()
        let store = try WorkspaceStore(rootURL: root.appending(path: "workspace", directoryHint: .isDirectory))
        let library = WorkspaceLibrary(store: store)
        var draft = SkillDraft()
        draft.name = "bounded-skill"
        draft.purpose = "A focused reusable workflow."
        draft.triggers = ["Run the bounded workflow"]
        draft.negativeTrigger = "Unrelated work"
        draft.selectedTargets = [.codex]

        var oversized = draft
        oversized.purpose = String(repeating: "x", count: WorkspaceLibrary.maximumPurposeLength + 1)
        #expect(throws: WorkspaceLibraryError.self) {
            _ = try library.createSkill(from: oversized)
        }

        var relativeProject = draft
        relativeProject.scope = .project
        relativeProject.projectRoot = "relative/project"
        #expect(throws: WorkspaceLibraryError.self) {
            _ = try library.createSkill(from: relativeProject)
        }

        draft.includeScript = true
        let created = try library.createSkill(from: draft)
        let script = created.skillURL.appending(path: "scripts/helper.sh", directoryHint: .notDirectory)
        let attributes = try FileManager.default.attributesOfItem(atPath: script.path(percentEncoded: false))
        let permissions = try #require((attributes[.posixPermissions] as? NSNumber)?.intValue)
        #expect(permissions == 0o700)
        let scriptContents = try String(contentsOf: script, encoding: .utf8)
        #expect(scriptContents.contains("exit 64"))
        #expect(scriptContents.contains("has not been implemented"))
        let manifest = try #require(
            try JSONSerialization.jsonObject(with: Data(contentsOf: created.packageURL.appending(path: "plugin.json"))) as? [String: Any]
        )
        #expect(manifest["name"] as? String == "bounded-skill")
        #expect(manifest["display_name"] == nil)
        #expect(manifest["extensions"] == nil)
    }

    @Test func localOnlySkillMayBeCreatedWithoutInstallTargetsAndLongNamesRemainValid() throws {
        let root = try temporaryDirectory()
        let store = try WorkspaceStore(rootURL: root.appending(path: "workspace", directoryHint: .isDirectory))
        let model = try AppModel(store: store, runner: StubRunner(versions: [:]), homeURL: root.appending(path: "home"))
        var draft = SkillDraft()
        draft.name = String(repeating: "a", count: WorkspaceLibrary.maximumIdentifierLength)
        draft.purpose = "Keep this workflow only in the managed library."
        draft.triggers = ["Create the local workflow"]
        draft.negativeTrigger = "Install the workflow"
        draft.selectedTargets = []
        draft.syncClients = false

        let created = try #require(model.createSkill(from: draft))

        #expect(created.bundle == "local-\(draft.name)")
        #expect(created.clients.isEmpty)
        #expect(model.pendingPlan == nil)
        let persisted = try #require(try store.load("workspace.snapshot", as: WorkspaceSnapshot.self))
        #expect(persisted.skills.first?.id == draft.name)
    }

    @Test func managedSkillUpdateRejectsSymbolicLinksAndRemovesLegacyOverlays() throws {
        let root = try temporaryDirectory()
        let store = try WorkspaceStore(rootURL: root.appending(path: "workspace", directoryHint: .isDirectory))
        let library = WorkspaceLibrary(store: store)
        var draft = SkillDraft()
        draft.name = "managed-review"
        draft.purpose = "Review a managed skill."
        draft.triggers = ["Review the managed skill"]
        draft.negativeTrigger = "Review unrelated code"
        draft.syncClients = false
        let created = try library.createSkill(from: draft)
        let legacyOverlay = created.packageURL.appending(path: "extensions/codex/manifest.json")
        try write("{}", to: legacyOverlay)

        let updated = try library.updateSkill(created.skill, from: draft)

        #expect(!FileManager.default.fileExists(atPath: updated.packageURL.appending(path: "extensions").path(percentEncoded: false)))
        let external = root.appending(path: "external.txt")
        try Data("outside".utf8).write(to: external)
        try FileManager.default.createSymbolicLink(
            at: updated.skillURL.appending(path: "linked-secret"),
            withDestinationURL: external
        )
        #expect(throws: DirectoryFingerprintError.self) {
            _ = try library.updateSkill(updated.skill, from: draft)
        }
    }

    @Test func managedSkillUpdateCanCommitOrRestoreItsPreviousPackage() throws {
        let root = try temporaryDirectory()
        let store = try WorkspaceStore(rootURL: root.appending(path: "workspace", directoryHint: .isDirectory))
        let library = WorkspaceLibrary(store: store)
        var draft = SkillDraft()
        draft.name = "transactional-skill"
        draft.purpose = "Original purpose"
        draft.triggers = ["Use the original workflow"]
        draft.negativeTrigger = "Use an unrelated workflow"
        draft.syncClients = false
        let created = try library.createSkill(from: draft)
        let skillFile = created.skillURL.appending(path: "SKILL.md")
        let originalContents = try String(contentsOf: skillFile, encoding: .utf8)

        draft.purpose = "Edited purpose"
        let firstUpdate = try library.updateSkill(created.skill, from: draft)
        #expect(try String(contentsOf: skillFile, encoding: .utf8).contains("Edited purpose"))
        #expect(try library.rollbackUpdate(firstUpdate) == nil)
        #expect(try String(contentsOf: skillFile, encoding: .utf8) == originalContents)

        let secondUpdate = try library.updateSkill(created.skill, from: draft)
        let rollbackURL = try #require(secondUpdate.rollbackPackageURL)
        #expect(FileManager.default.fileExists(atPath: rollbackURL.path(percentEncoded: false)))
        #expect(library.commitUpdate(secondUpdate) == nil)
        #expect(!FileManager.default.fileExists(atPath: rollbackURL.path(percentEncoded: false)))
        #expect(try String(contentsOf: skillFile, encoding: .utf8).contains("Edited purpose"))

        var freshDraft = draft
        freshDraft.name = "discarded-creation"
        let discarded = try library.createSkill(from: freshDraft)
        try library.rollbackCreation(discarded)
        #expect(!FileManager.default.fileExists(atPath: discarded.packageURL.path(percentEncoded: false)))
    }

    @Test func syncingLocalOnlySkillsExplainsThatAnAppMustBeSelected() async throws {
        let root = try temporaryDirectory()
        let store = try WorkspaceStore(rootURL: root.appending(path: "workspace", directoryHint: .isDirectory))
        let model = try AppModel(store: store, runner: StubRunner(versions: [:]), homeURL: root.appending(path: "home"))
        var draft = SkillDraft()
        draft.name = "local-only"
        draft.purpose = "Stay in the local library."
        draft.triggers = ["Keep this local"]
        draft.negativeTrigger = "Install this workflow"
        draft.syncClients = false
        draft.selectedTargets = []
        _ = try #require(model.createSkill(from: draft))

        await model.runSync()

        #expect(model.pendingPlan?.title == "Sync local library")
        #expect(model.pendingPlan?.steps.first?.title == "No app selected")
        #expect(model.pendingPlan?.summary.contains("Choose at least one app") == true)
    }

    @Test func writePlansRemainReviewRequiredWhenLoadingLegacyDisabledPreference() async throws {
        let root = try temporaryDirectory()
        let home = root.appending(path: "home", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        let store = try WorkspaceStore(rootURL: root.appending(path: "workspace", directoryHint: .isDirectory))
        let legacySnapshot = """
            {"preferences":{"confirmWrites":false,"automaticallyCheckHealth":true}}
            """
        let decoded = try JSONDecoder().decode(WorkspaceSnapshot.self, from: Data(legacySnapshot.utf8))
        try store.save(decoded, for: "workspace.snapshot")
        let model = try AppModel(store: store, runner: StubRunner(versions: [:]), homeURL: home)
        var draft = SkillDraft()
        draft.name = "always-reviewed"
        draft.purpose = "Verify write review cannot be disabled."
        draft.triggers = ["Review a client write"]
        draft.negativeTrigger = "Keep this skill local"
        draft.selectedTargets = [.codex]

        _ = try #require(model.createSkill(from: draft))

        #expect(model.pendingPlan?.steps.contains(where: { $0.kind == .copyDirectory }) == true)
        #expect(model.pendingPlan?.requiresConfirmation == true)
    }

    @Test func editingManagedSkillUpdatesSourceAndKeepsInstallReviewGuard() throws {
        let root = try temporaryDirectory()
        let home = root.appending(path: "test-home", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        let store = try WorkspaceStore(rootURL: root.appending(path: "workspace", directoryHint: .isDirectory))
        let model = try AppModel(store: store, runner: StubRunner(versions: [:]), homeURL: home)
        var draft = SkillDraft()
        draft.name = "release-readiness"
        draft.purpose = "Check a release."
        draft.triggers = ["Check release", "", ""]
        draft.negativeTrigger = "Unrelated work"
        draft.syncClients = false
        let created = try #require(model.createSkill(from: draft))

        draft.purpose = "Verify a release candidate before submission."
        draft.triggers = ["Audit the release", "Prepare submission", ""]
        draft.includeReference = true
        draft.selectedTargets = [.claude, .codex]
        draft.syncClients = true
        let updated = try #require(model.updateSkill(id: created.id, from: draft))

        #expect(updated.summary == "Verify a release candidate before submission.")
        #expect(updated.triggers == ["Audit the release", "Prepare submission"])
        #expect(updated.files.contains("references/reference.md"))
        #expect(model.pendingPlan?.requiresConfirmation == true)
        let source = try String(
            contentsOf: store.libraryURL.appending(path: "packages/local-release-readiness/skills/release-readiness/SKILL.md"),
            encoding: .utf8)
        #expect(source.contains("description: \"Verify a release candidate before submission.\""))
        #expect(source.contains("- Audit the release"))
    }

    @Test func projectScopedSkillInstallsOnlyInsideTheSelectedProject() async throws {
        let root = try temporaryDirectory()
        let home = root.appending(path: "home", directoryHint: .isDirectory)
        let project = root.appending(path: "Example Project", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        let store = try WorkspaceStore(rootURL: root.appending(path: "workspace", directoryHint: .isDirectory))
        let model = try AppModel(store: store, runner: StubRunner(versions: [:]), homeURL: home)
        var draft = SkillDraft()
        draft.name = "project-review"
        draft.purpose = "Review changes in this project."
        draft.triggers = ["Review this project", "", ""]
        draft.negativeTrigger = "Review another project"
        draft.scope = .project
        draft.projectRoot = project.path(percentEncoded: false)
        draft.selectedTargets = Set(ClientKind.allCases)
        draft.runCanary = false

        let skill = try #require(model.createSkill(from: draft))
        let steps = try #require(model.pendingPlan?.steps.filter { $0.kind == .copyDirectory })

        #expect(skill.projectRoot == project.path(percentEncoded: false))
        #expect(steps.count == 3)
        #expect(steps.allSatisfy { $0.projectRootPath == project.path(percentEncoded: false) })
        #expect(steps.allSatisfy { $0.destinationPath?.hasPrefix(project.path(percentEncoded: false)) == true })

        await model.executePendingPlan()

        for path in [
            ".claude/skills/project-review/SKILL.md", ".agents/skills/project-review/SKILL.md", ".gemini/skills/project-review/SKILL.md",
        ] {
            #expect(FileManager.default.fileExists(atPath: project.appending(path: path).path(percentEncoded: false)))
            #expect(!FileManager.default.fileExists(atPath: home.appending(path: path).path(percentEncoded: false)))
        }
    }

    @Test func editingManagedSkillRemovesDeselectedOptionalFolders() throws {
        let root = try temporaryDirectory()
        let store = try WorkspaceStore(rootURL: root.appending(path: "workspace", directoryHint: .isDirectory))
        let model = try AppModel(store: store, runner: StubRunner(versions: [:]), homeURL: root.appending(path: "home"))
        var draft = SkillDraft()
        draft.name = "clean-skill"
        draft.purpose = "A purpose: with YAML punctuation\nand another line."
        draft.triggers = ["Clean up a skill", "", ""]
        draft.negativeTrigger = "Unrelated work"
        draft.syncClients = false
        draft.includeScript = true
        draft.includeReference = true
        let skill = try #require(model.createSkill(from: draft))

        draft.includeScript = false
        draft.includeReference = false
        let updated = try #require(model.updateSkill(id: skill.id, from: draft))
        let skillURL = store.libraryURL.appending(path: "packages/local-clean-skill/skills/clean-skill")

        #expect(!updated.files.contains(where: { $0.hasPrefix("scripts/") || $0.hasPrefix("references/") }))
        #expect(!FileManager.default.fileExists(atPath: skillURL.appending(path: "scripts").path(percentEncoded: false)))
        #expect(!FileManager.default.fileExists(atPath: skillURL.appending(path: "references").path(percentEncoded: false)))
        let definition = try String(contentsOf: skillURL.appending(path: "SKILL.md"), encoding: .utf8)
        #expect(definition.contains("description: \"A purpose: with YAML punctuation\\nand another line.\""))
    }

    @Test func emptySkillTargetSelectionNeverExpandsToEveryClient() throws {
        let root = try temporaryDirectory()
        let store = try WorkspaceStore(rootURL: root.appending(path: "workspace", directoryHint: .isDirectory))
        let model = try AppModel(store: store, runner: StubRunner(versions: [:]), homeURL: root.appending(path: "home"))
        var draft = SkillDraft()
        draft.name = "target-guard"
        draft.purpose = "Test explicit install targets."
        draft.triggers = ["Test target handling", "", ""]
        draft.negativeTrigger = "Unrelated work"
        draft.syncClients = false
        let skill = try #require(model.createSkill(from: draft))

        model.planInstall(skillID: skill.id, targets: [])

        #expect(model.pendingPlan == nil)
        #expect(model.lastError == "Choose at least one app before reviewing an installation.")
    }

    @Test func scannerSeparatesClientObservationsAndDoesNotNeedARepository() async throws {
        let root = try temporaryDirectory()
        let home = root.appending(path: "home", directoryHint: .isDirectory)
        try write("{\"mcpServers\": {\"sentry\": {}}}", to: home.appending(path: ".claude/settings.json"))
        try write("[mcp_servers.context7]\n", to: home.appending(path: ".codex/config.toml"))
        try write("{\"mcpServers\": {\"filesystem\": {}}}", to: home.appending(path: ".gemini/settings.json"))
        try write(
            "---\nname: local-skill\ndescription: A local test skill\n---\n",
            to: home.appending(path: ".claude/skills/local-skill/SKILL.md"))
        try write(
            "---\nname: local-skill\ndescription: A local test skill\n---\n",
            to: home.appending(path: ".agents/skills/local-skill/SKILL.md"))
        try write(
            "---\nname: codex-only\ndescription: A Codex app skill\n---\n", to: home.appending(path: ".codex/skills/codex-only/SKILL.md"))
        try write(
            "{\"name\":\"local-extension\",\"version\":\"1.0.0\"}",
            to: home.appending(path: ".gemini/extensions/local-extension/gemini-extension.json"))
        try write(
            "---\nname: local-skill\ndescription: A local test skill\n---\n",
            to: home.appending(path: ".gemini/extensions/local-extension/skills/local-skill/SKILL.md"))

        let observations = await ClientAdapterRegistry().scanAll(
            homeURL: home, runner: StubRunner(versions: ["claude": "claude 2.1", "codex": "codex 1.0", "gemini": "gemini 0.5"]))
        let inventory = InventoryCompiler.compile(observations: observations, homeURL: home)

        #expect(observations.count == 3)
        #expect(!observations.contains(where: { !$0.installed }))
        #expect(observations.first(where: { $0.surface == .claudeCode })?.discoveredMCPServers == ["sentry"])
        #expect(observations.first(where: { $0.surface == .codexCLI })?.discoveredMCPServers == ["context7"])
        #expect(observations.first(where: { $0.surface == .codexCLI })?.discoveredSkills.contains("codex-only") == true)
        #expect(observations.first(where: { $0.surface == .geminiCLI })?.discoveredMCPServers == ["filesystem"])
        #expect(inventory.skills.first?.clients.count == 3)
    }

    @Test func scannerSupportsDirectlyLinkedSkillsWithoutTraversingAnExternalTree() async throws {
        let root = try temporaryDirectory()
        let home = root.appending(path: "home", directoryHint: .isDirectory)
        let linkedSkill = root.appending(path: "shared/direct-skill", directoryHint: .isDirectory)
        let externalCollection = root.appending(path: "external-collection", directoryHint: .isDirectory)
        try write("---\nname: direct-skill\ndescription: A directly linked skill\n---\n", to: linkedSkill.appending(path: "SKILL.md"))
        try write(
            "---\nname: nested-skill\ndescription: Must not be reached through an arbitrary link\n---\n",
            to: externalCollection.appending(path: "nested/nested-skill/SKILL.md"))
        let skillRoot = home.appending(path: ".agents/skills", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: skillRoot, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: skillRoot.appending(path: "direct-skill"), withDestinationURL: linkedSkill)
        try FileManager.default.createSymbolicLink(
            at: skillRoot.appending(path: "external-collection"), withDestinationURL: externalCollection)

        let observations = await ClientAdapterRegistry().scanAll(homeURL: home, runner: StubRunner(versions: ["codex": "codex 1.0"]))
        let codex = try #require(observations.first(where: { $0.surface == .codexCLI }))

        #expect(codex.discoveredSkills.contains("direct-skill"))
        #expect(!codex.discoveredSkills.contains("nested-skill"))
    }

    @Test func scannerSkipsOversizedConfigurationWithAnExplicitDiagnostic() async throws {
        let root = try temporaryDirectory()
        let home = root.appending(path: "home", directoryHint: .isDirectory)
        let oversized = String(repeating: "x", count: BoundedFileAccess.maximumConfigurationBytes + 1)
        try write(oversized, to: home.appending(path: ".codex/config.toml"))

        let observations = await ClientAdapterRegistry().scanAll(homeURL: home, runner: StubRunner(versions: ["codex": "codex 1.0"]))
        let codex = try #require(observations.first(where: { $0.surface == .codexCLI }))

        #expect(codex.discoveredMCPServers.isEmpty)
        #expect(codex.notes.contains(where: { $0.contains("Skipped config.toml") && $0.contains("read limit") }))
    }

    @Test func scannerDoesNotTreatNestedMCPEnvironmentSectionsAsServers() async throws {
        let root = try temporaryDirectory()
        let home = root.appending(path: "home", directoryHint: .isDirectory)
        try write(
            "[mcp_servers.node_repl]\ncommand = 'node'\n[mcp_servers.node_repl.env]\nNODE_NO_WARNINGS = '1'\n",
            to: home.appending(path: ".codex/config.toml"))

        let observations = await ClientAdapterRegistry().scanAll(homeURL: home, runner: StubRunner(versions: ["codex": "codex 1.0"]))
        let codex = observations.first(where: { $0.surface == .codexCLI })

        #expect(codex?.discoveredMCPServers == ["node_repl"])
    }

    @Test func scannerDistinguishesRunnableCLIWithoutVersionOutputFromMissingCLI() async throws {
        let root = try temporaryDirectory()
        let home = root.appending(path: "home", directoryHint: .isDirectory)
        try write("{}", to: home.appending(path: ".claude/settings.json"))
        let runner = StubRunner(
            versions: [:],
            responses: [
                "claude --version": CommandOutput(status: 1, standardOutput: "", standardError: "version unavailable"),
                "claude plugin list --json": CommandOutput(status: 1, standardOutput: "", standardError: "not authenticated"),
            ]
        )

        let observations = await ClientAdapterRegistry().scanAll(homeURL: home, runner: runner)
        let claude = try #require(observations.first(where: { $0.surface == .claudeCode }))
        let codex = try #require(observations.first(where: { $0.surface == .codexCLI }))

        #expect(claude.commandAvailable)
        #expect(claude.version == nil)
        #expect(!codex.commandAvailable)
    }

    @Test func scannerParsesQuotedTOMLMCPNamesWithoutTreatingNestedTablesAsServers() async throws {
        let root = try temporaryDirectory()
        let home = root.appending(path: "home", directoryHint: .isDirectory)
        try write(
            """
            [mcp_servers."company.docs"]
            url = "https://example.com/mcp"
            [mcp_servers."company.docs".headers]
            Authorization = "redacted"
            [mcp_servers.plain]
            command = "plain"
            [mcp_servers.plain.env]
            MODE = "safe"
            """, to: home.appending(path: ".codex/config.toml"))

        let observations = await ClientAdapterRegistry().scanAll(homeURL: home, runner: StubRunner(versions: ["codex": "codex 1.0"]))
        let codex = observations.first(where: { $0.surface == .codexCLI })

        #expect(codex?.discoveredMCPServers == ["company.docs", "plain"])
    }

    @Test func mcpIsReadyWhenAtLeastOneConfiguredClientIsHealthy() {
        let server = MCPServer(
            id: "figma",
            name: "Figma",
            summary: "Configured in Codex",
            endpoint: "https://mcp.figma.com/mcp",
            transport: .http,
            authentication: "OAuth",
            scope: "User",
            clients: [
                ClientState(client: .codex, state: .healthy, detail: "Configured"),
                ClientState(client: .claude, state: .unavailable, detail: "Not configured"),
                ClientState(client: .gemini, state: .unavailable, detail: "Not installed"),
            ]
        )

        #expect(server.aggregateState == .healthy)
    }

    @Test func mcpRemovalUsesOnlyTheSelectedClientsNativeCommand() throws {
        let root = try temporaryDirectory()
        let store = try WorkspaceStore(rootURL: root.appending(path: "workspace", directoryHint: .isDirectory))
        let snapshot = WorkspaceSnapshot(
            mcpServers: [
                MCPServer(
                    id: "figma", name: "Figma", summary: "Configured", endpoint: "https://mcp.figma.com/mcp", transport: .http,
                    authentication: "OAuth", scope: "User",
                    clients: [
                        ClientState(client: .codex, state: .healthy, detail: "Configured"),
                        ClientState(client: .claude, state: .healthy, detail: "Configured"),
                    ])
            ])
        try store.save(snapshot, for: "workspace.snapshot")
        let model = try AppModel(
            store: store, runner: StubRunner(versions: [:]), homeURL: root.appending(path: "home", directoryHint: .isDirectory))

        model.planMCPRemoval(serverID: "figma", client: .codex)

        #expect(model.pendingPlan?.targetSurfaces == [.codexCLI])
        #expect(model.pendingPlan?.steps.first?.executable == "codex")
        #expect(model.pendingPlan?.steps.first?.arguments == ["mcp", "remove", "figma"])
        #expect(model.pendingPlan?.requiresConfirmation == true)
    }

    @Test func projectScopedMCPCommandsRunOnlyFromTheReviewedProjectFolder() async throws {
        let root = try temporaryDirectory()
        let project = root.appending(path: "project", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        let store = try WorkspaceStore(rootURL: root.appending(path: "workspace", directoryHint: .isDirectory))
        let runner = RecordingRunner()
        let engine = OperationEngine(store: store, runner: runner, homeURL: root.appending(path: "home"))
        let step = OperationStep(
            kind: .command,
            title: "Remove project MCP",
            detail: "Test exact working-directory authorization",
            executable: "claude",
            arguments: ["mcp", "remove", "--scope", "project", "figma"],
            currentDirectoryPath: project.path(percentEncoded: false),
            projectRootPath: project.path(percentEncoded: false)
        )

        let receipt = await engine.execute(
            OperationPlan(kind: .configureMCP, title: "Project MCP", summary: "Test", scope: .project, steps: [step]))

        #expect(receipt.state == .healthy)
        #expect(await runner.recordedInvocations().first?.currentDirectory == project)
    }

    @Test func operationEngineRejectsForgedCommandWorkingDirectories() async throws {
        let root = try temporaryDirectory()
        let project = root.appending(path: "project", directoryHint: .isDirectory)
        let other = root.appending(path: "other", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
        let store = try WorkspaceStore(rootURL: root.appending(path: "workspace", directoryHint: .isDirectory))
        let runner = RecordingRunner()
        let engine = OperationEngine(store: store, runner: runner, homeURL: root.appending(path: "home"))
        let step = OperationStep(
            kind: .command, title: "Forged cwd", detail: "Must fail", executable: "claude",
            arguments: ["mcp", "remove", "--scope", "project", "figma"], currentDirectoryPath: other.path(percentEncoded: false),
            projectRootPath: project.path(percentEncoded: false))

        let receipt = await engine.execute(
            OperationPlan(kind: .configureMCP, title: "Forged", summary: "Test", scope: .project, steps: [step]))

        #expect(receipt.state == .attention)
        #expect(await runner.recordedInvocations().isEmpty)
    }

    @Test func operationCommandDisplayRedactsURLAndFlagSecrets() {
        let step = OperationStep(
            kind: .command, title: "Sensitive", detail: "Test", executable: "tool",
            arguments: ["https://user:password@example.com/mcp?token=secret", "--api-key", "sk-private-value"])

        #expect(step.renderedCommand?.contains("password") == false)
        #expect(step.renderedCommand?.contains("secret") == false)
        #expect(step.renderedCommand?.contains("sk-private-value") == false)
        #expect(step.renderedCommand?.contains("[redacted]") == true)
    }

    @Test func scannerUsesNativePluginAndMCPInventoriesIncludingBundledSkills() async throws {
        let root = try temporaryDirectory()
        let home = root.appending(path: "home", directoryHint: .isDirectory)
        let claudePlugin = root.appending(path: "claude-plugin", directoryHint: .isDirectory)
        let codexPlugin = root.appending(path: "codex-plugin", directoryHint: .isDirectory)
        try write(
            "---\nname: release-check\ndescription: Check a release\n---\n",
            to: claudePlugin.appending(path: "skills/release-check/SKILL.md"))
        try write(
            "---\nname: issue-triage\ndescription: Triage an issue\n---\n", to: codexPlugin.appending(path: "skills/issue-triage/SKILL.md"))
        try write("{}", to: home.appending(path: ".claude/settings.json"))
        try write("", to: home.appending(path: ".codex/config.toml"))

        let claudeJSON = """
            [{"id":"developer-workflows@agent-tooling","version":"abc123","scope":"user","enabled":true,"installPath":"\(claudePlugin.path(percentEncoded: false))","mcpServers":{"heroui-pro":{"type":"stdio","command":"doppler"}}}]
            """
        let codexJSON = """
            {"installed":[{"pluginId":"github@openai-curated","name":"github","version":"def456","enabled":true,"source":{"source":"local","path":"\(codexPlugin.path(percentEncoded: false))"}}],"available":[]}
            """
        let codexMCPJSON = """
            [{"name":"figma","enabled":true,"transport":{"type":"streamable_http","url":"https://mcp.figma.com/mcp"},"auth_status":"o_auth"}]
            """
        let runner = StubRunner(
            versions: ["claude": "claude 2.1", "codex": "codex 1.0"],
            responses: [
                "claude plugin list --json": CommandOutput(status: 0, standardOutput: claudeJSON, standardError: ""),
                "codex plugin list --available --json": CommandOutput(status: 0, standardOutput: codexJSON, standardError: ""),
                "codex mcp list --json": CommandOutput(status: 0, standardOutput: codexMCPJSON, standardError: ""),
            ]
        )

        let observations = await ClientAdapterRegistry().scanAll(homeURL: home, runner: runner)
        let inventory = InventoryCompiler.compile(observations: observations, homeURL: home)

        #expect(
            inventory.plugins.contains {
                $0.id == "developer-workflows@agent-tooling" && $0.revision == "abc123"
                    && $0.skills == ["developer-workflows:release-check"]
            })
        #expect(
            inventory.plugins.contains {
                $0.id == "github@openai-curated" && $0.revision == "def456" && $0.skills == ["github:issue-triage"]
            })
        #expect(inventory.skills.contains { $0.id == "developer-workflows:release-check" && $0.summary == "Check a release" })
        #expect(inventory.skills.contains { $0.id == "github:issue-triage" && $0.summary == "Triage an issue" })
        #expect(inventory.mcpServers.contains { $0.id == "heroui-pro" && $0.transport == .stdio })
        #expect(inventory.mcpServers.contains { $0.id == "figma" && $0.transport == .http && $0.authentication == "O Auth" })
    }

    @Test func operationEngineRefusesWritesOutsideManagedAndSupportedRoots() async throws {
        let root = try temporaryDirectory()
        let workspace = try WorkspaceStore(rootURL: root.appending(path: "workspace", directoryHint: .isDirectory))
        let source = workspace.libraryURL.appending(path: "packages/example", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try write("safe", to: source.appending(path: "SKILL.md"))
        let fingerprint = try DirectoryFingerprint.sha256(of: source)
        let engine = OperationEngine(
            store: workspace, runner: StubRunner(versions: [:]), homeURL: root.appending(path: "home", directoryHint: .isDirectory))
        let plan = OperationPlan(
            kind: .installSkill, title: "Unsafe", summary: "Test",
            steps: [
                OperationStep(
                    kind: .copyDirectory, title: "Unsafe copy", detail: "Must fail", sourcePath: source.path(percentEncoded: false),
                    sourceFingerprint: fingerprint, destinationPath: "/tmp/agent-tooling-test-unsafe")
            ])

        let receipt = await engine.execute(plan)

        #expect(receipt.state == .attention)
        #expect(receipt.results.first?.status == .failed)
    }

    @Test func operationEngineRefusesForgedWritesInsideTheWorkspaceDatabaseArea() async throws {
        let root = try temporaryDirectory()
        let workspace = try WorkspaceStore(rootURL: root.appending(path: "workspace", directoryHint: .isDirectory))
        let engine = OperationEngine(store: workspace, runner: StubRunner(versions: [:]), homeURL: root.appending(path: "home"))
        let plan = OperationPlan(
            kind: .exportBackup, title: "Forged write", summary: "Test",
            steps: [
                OperationStep(
                    kind: .writeFile, title: "Overwrite state", detail: "Must fail",
                    destinationPath: workspace.databaseURL.path(percentEncoded: false), contents: "forged")
            ])

        let receipt = await engine.execute(plan)

        #expect(receipt.results.first?.status == .failed)
        #expect(receipt.results.first?.output.contains("refused to write") == true)
    }

    @Test func operationEngineAllowsOnlyOneSkillDirectoryBelowANativeRoot() async throws {
        let root = try temporaryDirectory()
        let workspace = try WorkspaceStore(rootURL: root.appending(path: "workspace", directoryHint: .isDirectory))
        let source = workspace.libraryURL.appending(path: "packages/example", directoryHint: .isDirectory)
        try write("safe", to: source.appending(path: "SKILL.md"))
        let destination = root.appending(path: "home/.agents/skills/example/nested", directoryHint: .isDirectory)
        let fingerprint = try DirectoryFingerprint.sha256(of: source)
        let engine = OperationEngine(store: workspace, runner: StubRunner(versions: [:]), homeURL: root.appending(path: "home"))

        let receipt = await engine.execute(
            OperationPlan(
                kind: .installSkill, title: "Nested", summary: "Test",
                steps: [
                    OperationStep(
                        kind: .copyDirectory, title: "Copy", detail: "Must fail", sourcePath: source.path(percentEncoded: false),
                        sourceFingerprint: fingerprint, destinationPath: destination.path(percentEncoded: false))
                ]))

        #expect(receipt.results.first?.status == .failed)
        #expect(!FileManager.default.fileExists(atPath: destination.path(percentEncoded: false)))
    }

    @Test func operationEngineValidatesExactMCPCommandShapesAndDestinations() async throws {
        let root = try temporaryDirectory()
        let workspace = try WorkspaceStore(rootURL: root.appending(path: "workspace", directoryHint: .isDirectory))
        let runner = RecordingRunner()
        let engine = OperationEngine(store: workspace, runner: runner, homeURL: root.appending(path: "home"))
        let valid = OperationStep(
            kind: .command, title: "Add docs", detail: "Valid", executable: "codex",
            arguments: ["mcp", "add", "company.docs", "--url", "https://example.com/mcp"])
        let unsafeName = OperationStep(
            kind: .command, title: "Bad name", detail: "Invalid", executable: "codex", arguments: ["mcp", "remove", "name with spaces"])
        let unsafeURL = OperationStep(
            kind: .command, title: "Secret URL", detail: "Invalid", executable: "claude",
            arguments: ["mcp", "add", "--transport", "http", "--scope", "user", "docs", "https://example.com/mcp?token=secret"])

        let validReceipt = await engine.execute(OperationPlan(kind: .configureMCP, title: "Valid", summary: "Test", steps: [valid]))
        let nameReceipt = await engine.execute(OperationPlan(kind: .configureMCP, title: "Bad name", summary: "Test", steps: [unsafeName]))
        let urlReceipt = await engine.execute(OperationPlan(kind: .configureMCP, title: "Bad URL", summary: "Test", steps: [unsafeURL]))

        #expect(validReceipt.results.first?.status == .succeeded)
        #expect(nameReceipt.results.first?.status == .failed)
        #expect(urlReceipt.results.first?.status == .failed)
        #expect(await runner.recordedInvocations().count == 1)
    }

    @Test func geminiMCPCommandsMatchTheCurrentNativeCLIContract() async throws {
        let root = try temporaryDirectory()
        let projectRoot = root.appending(path: "project", directoryHint: .isDirectory)
        let home = root.appending(path: "home", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: projectRoot, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        let workspace = try WorkspaceStore(rootURL: root.appending(path: "workspace", directoryHint: .isDirectory))
        let model = try AppModel(
            store: workspace,
            runner: StubRunner(versions: ["gemini": "gemini 1"]),
            homeURL: home
        )
        await model.runDoctor()

        var httpDraft = MCPDraft()
        httpDraft.name = "Company docs"
        httpDraft.endpoint = "https://example.com/mcp"
        httpDraft.addToClaude = false
        httpDraft.addToCodex = false
        _ = try #require(model.addMCPServer(from: httpDraft))
        let httpStep = try #require(model.pendingPlan?.steps.first(where: { $0.kind == .command }))
        #expect(
            httpStep.arguments == [
                "mcp", "add", "--scope", "user", "--transport", "http", "company-docs", "https://example.com/mcp",
            ])
        model.discardPendingPlan()

        var stdioDraft = MCPDraft()
        stdioDraft.name = "Local search"
        stdioDraft.endpoint = "npx -y package --scope server-owned"
        stdioDraft.transport = .stdio
        stdioDraft.scope = .project
        stdioDraft.projectRoot = projectRoot.path(percentEncoded: false)
        stdioDraft.addToClaude = false
        stdioDraft.addToCodex = false
        let stdioServer = try #require(model.addMCPServer(from: stdioDraft))
        let stdioStep = try #require(model.pendingPlan?.steps.first(where: { $0.kind == .command }))
        #expect(
            stdioStep.arguments == [
                "mcp", "add", "--scope", "project", "--transport", "stdio", "local-search", "--", "npx", "-y", "package",
                "--scope", "server-owned",
            ])
        #expect(stdioStep.currentDirectoryPath == projectRoot.path(percentEncoded: false))
        model.discardPendingPlan()

        model.planMCPRemoval(serverID: stdioServer.id, client: .gemini)
        let removalStep = try #require(model.pendingPlan?.steps.first(where: { $0.kind == .command }))
        #expect(removalStep.arguments == ["mcp", "remove", "--scope", "project", "local-search"])

        let runner = RecordingRunner()
        let engine = OperationEngine(store: workspace, runner: runner, homeURL: home)
        let validPlan = OperationPlan(
            kind: .configureMCP,
            title: "Valid Gemini commands",
            summary: "Exercise exact native command validation.",
            scope: .project,
            steps: [httpStep, stdioStep, removalStep]
        )
        let validReceipt = await engine.execute(validPlan)
        #expect(!validReceipt.results.contains { $0.status == .failed })

        let unsafeStep = OperationStep(
            kind: .command,
            title: "Missing argument separator",
            detail: "Must be rejected before invoking Gemini.",
            executable: "gemini",
            arguments: [
                "mcp", "add", "--scope", "project", "--transport", "stdio", "local-search", "npx", "--scope", "user",
            ]
        )
        let unsafeReceipt = await engine.execute(
            OperationPlan(kind: .configureMCP, title: "Unsafe Gemini command", summary: "Test", steps: [unsafeStep]))
        #expect(unsafeReceipt.results.first?.status == .failed)
        #expect(await runner.recordedInvocations().count == 3)
    }

    @Test func operationEngineRejectsACopyWhenTheReviewedSourceChanges() async throws {
        let root = try temporaryDirectory()
        let workspace = try WorkspaceStore(rootURL: root.appending(path: "workspace", directoryHint: .isDirectory))
        let source = workspace.libraryURL.appending(path: "packages/example", directoryHint: .isDirectory)
        let definition = source.appending(path: "SKILL.md")
        try write("reviewed", to: definition)
        let reviewedFingerprint = try DirectoryFingerprint.sha256(of: source)
        try write("changed after review", to: definition)
        let destination = root.appending(path: "home/.agents/skills/example", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root.appending(path: "home"), withIntermediateDirectories: true)
        let engine = OperationEngine(store: workspace, runner: StubRunner(versions: [:]), homeURL: root.appending(path: "home"))

        let receipt = await engine.execute(
            OperationPlan(
                kind: .installSkill, title: "Changed source", summary: "Test",
                steps: [
                    OperationStep(
                        kind: .copyDirectory, title: "Copy", detail: "Must fail", sourcePath: source.path(percentEncoded: false),
                        sourceFingerprint: reviewedFingerprint, destinationPath: destination.path(percentEncoded: false))
                ]))

        #expect(receipt.results.first?.status == .failed)
        #expect(receipt.results.first?.output.contains("changed after it was reviewed") == true)
        #expect(!FileManager.default.fileExists(atPath: destination.path(percentEncoded: false)))
    }

    @Test func operationEngineRejectsProjectDestinationOutsideDeclaredProjectRoot() async throws {
        let root = try temporaryDirectory()
        let workspace = try WorkspaceStore(rootURL: root.appending(path: "workspace", directoryHint: .isDirectory))
        let source = workspace.libraryURL.appending(path: "packages/example", directoryHint: .isDirectory)
        let approvedProject = root.appending(path: "approved", directoryHint: .isDirectory)
        let otherProject = root.appending(path: "other", directoryHint: .isDirectory)
        try write("safe", to: source.appending(path: "SKILL.md"))
        try FileManager.default.createDirectory(at: approvedProject, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: otherProject, withIntermediateDirectories: true)
        let destination = otherProject.appending(path: ".agents/skills/example", directoryHint: .isDirectory)
        let engine = OperationEngine(store: workspace, runner: StubRunner(versions: [:]), homeURL: root.appending(path: "home"))
        let plan = OperationPlan(
            kind: .installSkill, title: "Mismatched project", summary: "Test",
            steps: [
                OperationStep(
                    kind: .copyDirectory,
                    title: "Copy",
                    detail: "Must fail",
                    sourcePath: source.path(percentEncoded: false),
                    sourceFingerprint: try DirectoryFingerprint.sha256(of: source),
                    destinationPath: destination.path(percentEncoded: false),
                    projectRootPath: approvedProject.path(percentEncoded: false)
                )
            ])

        let receipt = await engine.execute(plan)

        #expect(receipt.results.first?.status == .failed)
        #expect(!FileManager.default.fileExists(atPath: destination.path(percentEncoded: false)))
    }

    @Test func operationEngineRejectsUnapprovedSubcommands() async throws {
        let root = try temporaryDirectory()
        let workspace = try WorkspaceStore(rootURL: root.appending(path: "workspace", directoryHint: .isDirectory))
        let engine = OperationEngine(store: workspace, runner: StubRunner(versions: [:]), homeURL: root.appending(path: "home"))
        let plan = OperationPlan(
            kind: .installPlugin, title: "Unsafe command", summary: "Test",
            steps: [
                OperationStep(
                    kind: .command, title: "Run unrelated command", detail: "Must fail", executable: "codex",
                    arguments: ["exec", "do-something"])
            ])

        let receipt = await engine.execute(plan)

        #expect(receipt.state == .attention)
        #expect(receipt.results.first?.status == .failed)
        #expect(receipt.results.first?.output.contains("unapproved arguments") == true)
    }

    @Test func operationEngineRejectsSymbolicLinksBeforeCopying() async throws {
        let root = try temporaryDirectory()
        let workspace = try WorkspaceStore(rootURL: root.appending(path: "workspace", directoryHint: .isDirectory))
        let source = workspace.libraryURL.appending(path: "packages/example", directoryHint: .isDirectory)
        let external = root.appending(path: "outside-secret.txt")
        try write("not portable", to: external)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: source.appending(path: "linked-secret.txt"), withDestinationURL: external)
        let destination = root.appending(path: "home/.agents/skills/example")
        let engine = OperationEngine(store: workspace, runner: StubRunner(versions: [:]), homeURL: root.appending(path: "home"))
        let plan = OperationPlan(
            kind: .installSkill, title: "Unsafe source", summary: "Test",
            steps: [
                OperationStep(
                    kind: .copyDirectory, title: "Copy", detail: "Must fail", sourcePath: source.path(percentEncoded: false),
                    sourceFingerprint: "reviewed-but-invalid", destinationPath: destination.path(percentEncoded: false))
            ])

        let receipt = await engine.execute(plan)

        #expect(receipt.results.first?.status == .failed)
        #expect(!FileManager.default.fileExists(atPath: destination.path(percentEncoded: false)))
    }

    @Test func operationEngineRejectsSymlinkedNativeSkillRoots() async throws {
        let root = try temporaryDirectory()
        let workspace = try WorkspaceStore(rootURL: root.appending(path: "workspace", directoryHint: .isDirectory))
        let home = root.appending(path: "home", directoryHint: .isDirectory)
        let external = root.appending(path: "outside", directoryHint: .isDirectory)
        let source = workspace.libraryURL.appending(path: "packages/example", directoryHint: .isDirectory)
        try write("safe", to: source.appending(path: "SKILL.md"))
        try FileManager.default.createDirectory(at: home.appending(path: ".agents"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: external, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(
            at: home.appending(path: ".agents/skills"),
            withDestinationURL: external
        )
        let destination = home.appending(path: ".agents/skills/example")
        let engine = OperationEngine(store: workspace, runner: StubRunner(versions: [:]), homeURL: home)
        let receipt = await engine.execute(
            OperationPlan(
                kind: .installSkill, title: "Redirected root", summary: "Test",
                steps: [
                    OperationStep(
                        kind: .copyDirectory,
                        title: "Copy",
                        detail: "Must fail",
                        sourcePath: source.path(percentEncoded: false),
                        sourceFingerprint: try DirectoryFingerprint.sha256(of: source),
                        destinationPath: destination.path(percentEncoded: false)
                    )
                ]))

        #expect(receipt.results.first?.status == .failed)
        #expect(!FileManager.default.fileExists(atPath: external.appending(path: "example").path(percentEncoded: false)))
    }

    @Test func operationEngineRedactsAndBoundsPersistedCommandOutput() async throws {
        let root = try temporaryDirectory()
        let workspace = try WorkspaceStore(rootURL: root.appending(path: "workspace", directoryHint: .isDirectory))
        let longOutput = "token=secretvalue\n" + String(repeating: "x", count: 80_000)
        let runner = StubRunner(
            versions: [:],
            responses: ["codex mcp remove docs": CommandOutput(status: 0, standardOutput: longOutput, standardError: "")]
        )
        let engine = OperationEngine(store: workspace, runner: runner, homeURL: root.appending(path: "home"))
        let receipt = await engine.execute(
            OperationPlan(
                kind: .configureMCP, title: "Bound output", summary: "Test",
                steps: [
                    OperationStep(
                        kind: .command, title: "Remove docs", detail: "Test", executable: "codex", arguments: ["mcp", "remove", "docs"])
                ]))
        let output = try #require(receipt.results.first?.output)

        #expect(!output.contains("plain-text-secret"))
        #expect(output.contains("[redacted]"))
        #expect(output.hasSuffix("[output truncated]"))
        #expect(output.count < 61_000)
    }

    @Test func sensitiveValueRedactionDoesNotConsumeTheNextLineAfterOrdinaryText() {
        let input = "plain-text-secret\nThis line must remain visible."
        #expect(SensitiveValueRedactor.redact(input) == input)
        #expect(SensitiveValueRedactor.redact("No secret was changed.") == "No secret was changed.")
        #expect(!SensitiveValueRedactor.containsCredentialValue(in: "OAuth token management and API-key guidance"))
        #expect(
            !SensitiveValueRedactor.containsCredentialValue(
                in: "Set CONTEXT7_API_KEY for higher rate limits. See https://example.com/docs?topic=authentication."))
        #expect(SensitiveValueRedactor.containsCredentialValue(in: "token=plain-text-secret"))
        #expect(SensitiveValueRedactor.containsCredentialValue(in: "https://example.com/connect?access_token=plain-text-secret"))
        #expect(SensitiveValueRedactor.redact("env OPENAI_API_KEY private-value") == "env OPENAI_API_KEY [redacted]")
    }

    @Test func legacyRealityScanReceiptUsesCurrentSetupCheckCopy() {
        let receipt = ActivityReceipt(
            kind: .validation,
            title: "Reality scan completed",
            detail: "Existing configuration was inspected.",
            date: .now,
            state: .healthy
        )

        #expect(receipt.title == "Reality scan completed")
        #expect(receipt.displayTitle == "Setup check completed")
    }

    @Test func dirtyGitBackupStopsBeforeAnyExportedFileChanges() async throws {
        let root = try temporaryDirectory()
        let store = try WorkspaceStore(rootURL: root.appending(path: "workspace", directoryHint: .isDirectory))
        let service = BackupService(store: store)
        try FileManager.default.createDirectory(at: service.exportURL.appending(path: ".git"), withIntermediateDirectories: true)
        let existing = service.exportURL.appending(path: "workspace.json")
        try write("keep me", to: existing)
        let command = "git -C \(service.exportURL.path(percentEncoded: false)) status --porcelain=v1 --untracked-files=all"
        let runner = StubRunner(
            versions: [:],
            responses: [command: CommandOutput(status: 0, standardOutput: " M workspace.json\n", standardError: "")]
        )
        let engine = OperationEngine(store: store, runner: runner, homeURL: root.appending(path: "home"))

        let receipt = await engine.execute(try service.exportPlan(snapshot: WorkspaceSnapshot()))

        #expect(receipt.state == .attention)
        #expect(receipt.results.first(where: { $0.output.contains("uncommitted or untracked") })?.status == .failed)
        #expect(receipt.results.contains(where: { $0.status == .skipped }))
        #expect(try String(contentsOf: existing, encoding: .utf8) == "keep me")
    }

    @Test func processRunnerTimesOutAndStopsLongRunningCommand() async throws {
        let runner = ProcessCommandRunner(timeout: .milliseconds(100))
        let start = ContinuousClock.now

        await #expect(throws: ProcessCommandRunnerError.self) {
            _ = try await runner.run(executable: "sleep", arguments: ["5"], currentDirectory: nil)
        }

        // Leave room for a saturated concurrent test runner while still
        // proving that the five-second child did not run to completion.
        #expect(start.duration(to: .now) < .seconds(4))
    }

    @Test func processRunnerDoesNotLetAppCommandsWaitForInteractiveInput() async throws {
        let runner = ProcessCommandRunner(timeout: .seconds(3))
        let start = ContinuousClock.now

        let output = try await runner.run(
            executable: "sh",
            arguments: ["-c", "read value"],
            currentDirectory: nil
        )

        #expect(output.status != 0)
        #expect(start.duration(to: .now) < .seconds(2))
    }

    @Test func cancelledOperationReceiptDoesNotClaimItsSkippedStepsCompleted() async throws {
        let root = try temporaryDirectory()
        let store = try WorkspaceStore(rootURL: root.appending(path: "workspace", directoryHint: .isDirectory))
        let engine = OperationEngine(store: store, homeURL: root.appending(path: "home"))
        let plan = OperationPlan(
            kind: .guidedAccountCheck,
            title: "Cancellation receipt",
            summary: "Exercise cooperative cancellation.",
            steps: [
                OperationStep(kind: .scan, title: "First check", detail: "Queues a check."),
                OperationStep(kind: .scan, title: "Second check", detail: "Must be skipped."),
            ]
        )

        let task = Task { await engine.execute(plan) }
        task.cancel()
        let receipt = await task.value

        #expect(receipt.state == .pending)
        #expect(receipt.results.contains(where: { $0.status == .skipped }))
        #expect(receipt.verificationSummary.contains("stopped"))
        #expect(!receipt.verificationSummary.contains("All requested local steps completed"))
    }

    @Test func manualOnlyOperationReceiptDoesNotClaimLocalChangesCompleted() async throws {
        let root = try temporaryDirectory()
        let store = try WorkspaceStore(rootURL: root.appending(path: "workspace", directoryHint: .isDirectory))
        let engine = OperationEngine(store: store, homeURL: root.appending(path: "home"))
        let plan = OperationPlan(
            kind: .installSkill,
            title: "Manual guidance",
            summary: "Nothing should be written.",
            steps: [OperationStep(kind: .manual, title: "Create a skill", detail: "Add a portable skill first.")]
        )

        let receipt = await engine.execute(plan)

        #expect(receipt.state == .pending)
        // The summary now itemizes the batch before repeating the guidance.
        #expect(receipt.verificationSummary.hasPrefix("succeeded 0 · failed 0 · skipped 0 · manual 1."))
        #expect(
            receipt.verificationSummary.hasSuffix("No local changes were made. Follow the manual guidance, then check setup again."))
    }

    @Test func marketplaceInspectsPortablePackageAndFlagsExecutableContent() throws {
        let root = try temporaryDirectory()
        let package = root.appending(path: "plugins/example", directoryHint: .isDirectory)
        try write(
            "{\"$schema\":\"https://agent-plugins.org/schemas/1.0.0/plugin.schema.json\",\"name\":\"example\",\"description\":\"Portable example\"}",
            to: package.appending(path: "plugin.json"))
        try write("---\nname: example-skill\ndescription: Example\n---\n", to: package.appending(path: "skills/example-skill/SKILL.md"))
        try write("#!/bin/sh\n", to: package.appending(path: "scripts/run.sh"))
        let source = ToolingSource(name: "Test source", kind: .localFolder, location: root.path(percentEncoded: false))

        let packages = try MarketplaceService().inspect(source)

        #expect(packages.count == 1)
        #expect(packages.first?.components.contains(.skill) == true)
        #expect(packages.first?.components.contains(.plugin) == true)
        #expect(packages.first?.hasExecutableContent == true)
    }

    @Test func nativeCatalogMetadataProducesOnlyClientSpecificInstallRoutes() throws {
        let catalog = """
            {"installed":[],"available":[{"pluginId":"calendar@openai-curated","name":"calendar","marketplaceName":"openai-curated","version":"1.2.3","source":{"source":"local","path":"/tmp/calendar"},"installPolicy":"AVAILABLE","authPolicy":"ON_INSTALL"}]}
            """

        let packages = MarketplaceService().packagesFromCodexCatalogJSON(catalog)

        #expect(packages.count == 1)
        #expect(packages.first?.supportedClients == [.codex])
        #expect(packages.first?.nativeInstalls.first?.executable == "codex")
        #expect(packages.first?.nativeInstalls.first?.arguments == ["plugin", "add", "calendar@openai-curated"])
        #expect(packages.first?.nativeInstalls.first?.removalArguments == ["plugin", "remove", "calendar@openai-curated"])
        #expect(packages.first?.nativeInstalls.first?.isInstalled == false)
    }

    @Test func nativeCatalogDeduplicationPreservesInstalledRouteState() throws {
        let catalog = """
            {"installed":[{"pluginId":"calendar@openai-curated","name":"calendar","marketplaceName":"openai-curated","version":"1.2.3"}],"available":[{"pluginId":"calendar@openai-curated","name":"calendar","marketplaceName":"openai-curated","version":"1.2.3"}]}
            """

        let packages = MarketplaceService().packagesFromCodexCatalogJSON(catalog)
        let package = try #require(packages.first)
        let route = try #require(package.nativeInstalls.first)

        #expect(packages.count == 1)
        #expect(package.isInstalled)
        #expect(route.isInstalled == true)
        #expect(route.reportsInstalled(in: package))
        #expect(package.installedClients == [.codex])
    }

    @Test func legacyNativeInstallWithoutRouteStateRemainsDecodable() throws {
        let legacy = """
            {"client":"Codex","executable":"codex","arguments":["plugin","add","calendar"],"scope":"user","detail":"Install"}
            """

        let route = try JSONDecoder().decode(NativeInstall.self, from: Data(legacy.utf8))

        #expect(route.isInstalled == nil)
    }

    @Test func installedPluginRemovalUsesExactNativeClientCommand() async throws {
        let root = try temporaryDirectory()
        let store = try WorkspaceStore(rootURL: root.appending(path: "workspace", directoryHint: .isDirectory))
        let packages = MarketplaceService().packagesFromCodexCatalogJSON(
            """
            {"installed":[{"pluginId":"calendar@openai-curated","name":"calendar","marketplaceName":"openai-curated","source":{"source":"local","path":"/tmp/calendar"}}],"available":[]}
            """)
        try store.save(WorkspaceSnapshot(marketplacePackages: packages), for: "workspace.snapshot")
        let model = try AppModel(
            store: store, runner: StubRunner(versions: [:]), homeURL: root.appending(path: "home", directoryHint: .isDirectory))

        await model.planPluginRemoval(pluginID: "calendar@openai-curated", client: .codex)

        #expect(model.pendingPlan?.steps.first?.executable == "codex")
        #expect(model.pendingPlan?.steps.first?.arguments == ["plugin", "remove", "calendar@openai-curated"])
        #expect(model.pendingPlan?.summary.contains("Remove this exact plugin identifier") == true)
        #expect(model.pendingPlan?.steps.first?.detail.contains("Remove this exact plugin identifier") == true)
        #expect(model.pendingPlan?.requiresConfirmation == true)
    }

    @Test func backupExportAndRestorePreviewKeepGitOptionalAndConflictsReviewable() async throws {
        let root = try temporaryDirectory()
        let store = try WorkspaceStore(rootURL: root.appending(path: "workspace", directoryHint: .isDirectory))
        let package = store.libraryURL.appending(path: "packages/local-example", directoryHint: .isDirectory)
        try write("---\nname: example\ndescription: Backup test\n---\n", to: package.appending(path: "skills/example/SKILL.md"))
        let snapshot = WorkspaceSnapshot(skills: [
            Skill(
                id: "example", name: "example", displayName: "Example", summary: "Backup test", bundle: "local-example", scope: "User",
                owned: true, triggers: [], negativeTrigger: "", files: ["SKILL.md"], clients: [], validationCount: 0)
        ])
        let service = BackupService(store: store)
        let engine = OperationEngine(
            store: store, runner: ProcessCommandRunner(), homeURL: root.appending(path: "home", directoryHint: .isDirectory))

        let exportReceipt = await engine.execute(try service.exportPlan(snapshot: snapshot))
        #expect(!exportReceipt.results.contains { $0.status == .failed })
        #expect(FileManager.default.fileExists(atPath: service.exportURL.appending(path: ".git").path(percentEncoded: false)))
        #expect(
            FileManager.default.fileExists(
                atPath: service.exportURL.appending(path: "library/packages/local-example/skills/example/SKILL.md").path(
                    percentEncoded: false)))

        var changed = snapshot
        changed.skills[0].summary = "Changed locally"
        let preview = try service.importPreview(at: service.exportURL, current: changed)
        #expect(preview.conflicts.count == 1)
        #expect(preview.plan.kind == .restoreBackup)

        let restoreReceipt = await engine.execute(preview.plan)
        #expect(!restoreReceipt.results.contains { $0.status == .failed })
        #expect(FileManager.default.fileExists(atPath: store.receiptsURL.appending(path: "rollback").path(percentEncoded: false)))
    }

    @Test func backupPlanExportsPortableStateToLocalGitWithoutRequiringARemote() throws {
        let root = try temporaryDirectory()
        let store = try WorkspaceStore(rootURL: root.appending(path: "workspace", directoryHint: .isDirectory))
        let plan = try BackupService(store: store).exportPlan(snapshot: WorkspaceSnapshot())

        #expect(plan.steps.contains { $0.executable == "git" && $0.arguments.contains("init") })
        #expect(!plan.steps.contains { $0.arguments.contains("push") })
        #expect(plan.summary.contains("No GitHub account"))
    }

    @Test func emptyWorkspaceBackupProducesACompleteRestorableLibrary() async throws {
        let root = try temporaryDirectory()
        let store = try WorkspaceStore(rootURL: root.appending(path: "workspace", directoryHint: .isDirectory))
        let service = BackupService(store: store)
        let engine = OperationEngine(store: store, runner: ProcessCommandRunner(), homeURL: root.appending(path: "home"))

        let receipt = await engine.execute(try service.exportPlan(snapshot: WorkspaceSnapshot()))
        let preview = try service.importPreview(at: service.exportURL, current: WorkspaceSnapshot())

        #expect(!receipt.results.contains { $0.status == .failed })
        #expect(FileManager.default.fileExists(atPath: service.exportURL.appending(path: "library").path(percentEncoded: false)))
        #expect(preview.snapshot.skills.isEmpty)
    }

    @Test func backupRestoreRejectsLibraryPackagesMissingFromTheLock() async throws {
        let root = try temporaryDirectory()
        let store = try WorkspaceStore(rootURL: root.appending(path: "workspace", directoryHint: .isDirectory))
        try write("portable", to: store.libraryURL.appending(path: "packages/local-example/skills/example/SKILL.md"))
        let snapshot = WorkspaceSnapshot(skills: [
            Skill(
                id: "example", name: "example", displayName: "Example", summary: "Test", bundle: "local-example", scope: "This Mac",
                owned: true, triggers: [], negativeTrigger: "", files: ["SKILL.md"], clients: [], validationCount: 0)
        ])
        let service = BackupService(store: store)
        let engine = OperationEngine(store: store, runner: ProcessCommandRunner(), homeURL: root.appending(path: "home"))
        _ = await engine.execute(try service.exportPlan(snapshot: snapshot))
        try write("unexpected", to: service.exportURL.appending(path: "library/packages/extra/README.md"))

        #expect(throws: BackupError.self) {
            _ = try service.importPreview(at: service.exportURL, current: snapshot)
        }
    }

    @Test func backupRestoreRejectsModifiedPackageContentEvenWhenIDsStillMatch() async throws {
        let root = try temporaryDirectory()
        let store = try WorkspaceStore(rootURL: root.appending(path: "workspace", directoryHint: .isDirectory))
        try write("portable", to: store.libraryURL.appending(path: "packages/local-example/skills/example/SKILL.md"))
        let snapshot = WorkspaceSnapshot(skills: [
            Skill(
                id: "example", name: "example", displayName: "Example", summary: "Test", bundle: "local-example", scope: "This Mac",
                owned: true, triggers: [], negativeTrigger: "", files: ["SKILL.md"], clients: [], validationCount: 0)
        ])
        let service = BackupService(store: store)
        let engine = OperationEngine(store: store, runner: ProcessCommandRunner(), homeURL: root.appending(path: "home"))
        _ = await engine.execute(try service.exportPlan(snapshot: snapshot))
        try write("tampered", to: service.exportURL.appending(path: "library/packages/local-example/skills/example/SKILL.md"))

        #expect(throws: BackupError.self) {
            _ = try service.importPreview(at: service.exportURL, current: snapshot)
        }
    }

    @Test func unscannedMCPConfigurationUsesManualStepsInsteadOfAssumingCLIsExist() throws {
        let root = try temporaryDirectory()
        let store = try WorkspaceStore(rootURL: root.appending(path: "workspace", directoryHint: .isDirectory))
        let model = try AppModel(store: store, runner: StubRunner(versions: [:]), homeURL: root.appending(path: "home"))
        var draft = MCPDraft()
        draft.name = "docs"
        draft.endpoint = "https://example.com/mcp"

        let server = try #require(model.addMCPServer(from: draft))

        #expect(server.clients.count == 3)
        #expect(model.pendingPlan?.steps.filter { $0.kind == .command }.isEmpty == true)
        #expect(model.pendingPlan?.steps.filter { $0.kind == .manual }.count == 3)
    }

    @Test func scopedProfilesAndMCPPlansKeepTargetLimitationsExplicit() async throws {
        let root = try temporaryDirectory()
        let projectRoot = root.appending(path: "project", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: projectRoot, withIntermediateDirectories: true)
        let store = try WorkspaceStore(rootURL: root.appending(path: "workspace", directoryHint: .isDirectory))
        let model = try AppModel(
            store: store,
            runner: StubRunner(versions: ["claude": "claude 2", "codex": "codex 1", "gemini": "gemini 1"]),
            homeURL: root.appending(path: "home", directoryHint: .isDirectory)
        )
        await model.runDoctor()
        let base = model.createProfile(name: "base", summary: "Base", scope: .user, projectRoot: nil)
        #expect(base != nil)
        model.updateProfile(
            id: "base", name: "base", summary: "Base", scope: .user, projectRoot: nil, enabledPlugins: ["calendar"],
            requiredMCPs: ["filesystem"])
        let project = model.createProfile(
            name: "project", summary: "Project", scope: .project, projectRoot: projectRoot.path(percentEncoded: false),
            inheritedFrom: "base")
        let effective = model.effectiveProfile(for: project?.id ?? "")
        #expect(effective?.enabledPlugins == ["calendar"])
        #expect(effective?.requiredMCPs == ["filesystem"])
        #expect(effective?.scope == .project)

        var draft = MCPDraft()
        draft.name = "filesystem"
        draft.endpoint = "npx -y @modelcontextprotocol/server-filesystem /tmp"
        draft.transport = .stdio
        draft.scope = .project
        draft.projectRoot = projectRoot.path(percentEncoded: false)
        _ = model.addMCPServer(from: draft)
        let steps = model.pendingPlan?.steps ?? []
        #expect(steps.contains { $0.executable == "claude" && $0.arguments.contains("project") })
        #expect(
            steps.contains {
                $0.executable == "gemini"
                    && $0.arguments == [
                        "mcp", "add", "--scope", "project", "--transport", "stdio", "filesystem", "--", "npx", "-y",
                        "@modelcontextprotocol/server-filesystem", "/tmp",
                    ]
            })
        #expect(steps.contains { $0.kind == .manual && $0.title.contains("Codex") })
        #expect(steps.filter { $0.kind == .command }.allSatisfy { $0.currentDirectoryPath == projectRoot.path(percentEncoded: false) })
    }

    @Test func mcpDraftValidationPreservesQuotedStdioArgumentsAndScope() async throws {
        let root = try temporaryDirectory()
        let projectRoot = root.appending(path: "project", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: projectRoot, withIntermediateDirectories: true)
        let store = try WorkspaceStore(rootURL: root.appending(path: "workspace", directoryHint: .isDirectory))
        let model = try AppModel(
            store: store,
            runner: StubRunner(versions: ["claude": "claude 2"]),
            homeURL: root.appending(path: "home")
        )
        await model.runDoctor()
        var draft = MCPDraft()
        draft.name = "quoted-command"
        draft.transport = .stdio
        draft.endpoint = "npx --package \"package with spaces\" server --root '/tmp/a b'"
        draft.scope = .project
        draft.projectRoot = projectRoot.path(percentEncoded: false)
        draft.addToClaude = true
        draft.addToCodex = false
        draft.addToGemini = false

        let server = model.addMCPServer(from: draft)
        let command = try #require(model.pendingPlan?.steps.first(where: { $0.kind == .command }))

        #expect(server != nil)
        #expect(command.arguments.suffix(6) == ["npx", "--package", "package with spaces", "server", "--root", "/tmp/a b"])
        #expect(model.pendingPlan?.scope == .project)
        #expect(command.detail.contains("project scope"))
        #expect(command.currentDirectoryPath == projectRoot.path(percentEncoded: false))
    }

    @Test func mcpDraftRequiresAValidDestinationAndAtLeastOneTarget() throws {
        let root = try temporaryDirectory()
        let store = try WorkspaceStore(rootURL: root.appending(path: "workspace", directoryHint: .isDirectory))
        let model = try AppModel(store: store, runner: StubRunner(versions: [:]), homeURL: root.appending(path: "home"))
        var draft = MCPDraft()
        draft.name = "invalid-server"
        draft.endpoint = "not a URL"
        #expect(model.addMCPServer(from: draft) == nil)
        #expect(model.mcpServers.isEmpty)

        draft.endpoint = "https://example.com/mcp"
        draft.addToClaude = false
        draft.addToCodex = false
        draft.addToGemini = false
        #expect(model.addMCPServer(from: draft) == nil)
        #expect(model.lastError == "Choose at least one app for this MCP server.")
    }

    @Test func mcpDraftRejectsInlineCredentialsAndProjectScopeWithoutAFolder() throws {
        let root = try temporaryDirectory()
        let store = try WorkspaceStore(rootURL: root.appending(path: "workspace", directoryHint: .isDirectory))
        let model = try AppModel(store: store, runner: StubRunner(versions: [:]), homeURL: root.appending(path: "home"))
        var draft = MCPDraft()
        draft.name = "sensitive"
        draft.endpoint = "https://user:password@example.com/mcp?token=secret"
        #expect(model.addMCPServer(from: draft) == nil)
        #expect(model.lastError?.contains("credentials") == true)

        draft.endpoint = "npx server --token secret"
        draft.transport = .stdio
        #expect(model.addMCPServer(from: draft) == nil)
        #expect(model.lastError?.contains("API keys") == true)

        draft.endpoint = "env OPENAI_API_KEY secret npx server"
        #expect(model.addMCPServer(from: draft) == nil)
        #expect(model.lastError?.contains("API keys") == true)

        draft.endpoint = "npx server"
        draft.scope = .project
        #expect(model.addMCPServer(from: draft) == nil)
        #expect(model.lastError?.contains("project folder") == true)
    }

    @Test func legacyManagedMCPRecordsRetainExplicitDesiredStateSemantics() throws {
        let legacy = """
            {"id":"legacy","name":"Legacy","summary":"Desired local MCP configuration","endpoint":"https://example.com/mcp","transport":"HTTP","authentication":"OAuth","scope":"This Mac","clients":[],"secretNames":[]}
            """

        let server = try JSONDecoder().decode(MCPServer.self, from: Data(legacy.utf8))

        #expect(server.definitionOrigin == nil)
        #expect(server.isManagedDefinition)
    }

    @Test func inventoryCompilerAggregatesMultipleSurfacesForOneClientWithoutCrashing() {
        let capabilities = TargetCapabilities(
            supportsPluginInstall: true, supportsProjectScope: true, supportsLocalMarketplace: true, supportsMCPAuthentication: true,
            supportsConnectorDiscovery: false, requiresNewSession: false, requiresRestart: false, supportsMachineReadableOutput: true)
        let unavailable = TargetObservation(
            surface: .claudeDesktop, installed: true, commandAvailable: false, discoveredSkills: ["shared"], capabilities: capabilities)
        let available = TargetObservation(
            surface: .claudeCode, installed: true, commandAvailable: true, version: "1.0", discoveredSkills: ["shared"],
            capabilities: capabilities)

        let inventory = InventoryCompiler.compile(observations: [unavailable, available], homeURL: URL(fileURLWithPath: "/tmp"))

        #expect(inventory.skills.first?.clients.first(where: { $0.client == .claude })?.state == .healthy)
    }

    @Test func marketplaceDoesNotClaimEveryClientForNativeOnlyPackages() throws {
        let root = try temporaryDirectory()
        let claudePackage = root.appending(path: "plugins/claude-only")
        try write("{\"name\":\"claude-only\"}", to: claudePackage.appending(path: ".claude-plugin/plugin.json"))
        try write(
            "---\nname: claude-skill\ndescription: Claude only\n---\n", to: claudePackage.appending(path: "skills/claude-skill/SKILL.md"))
        let source = ToolingSource(name: "Native source", kind: .localFolder, location: root.path(percentEncoded: false))

        let packages = try MarketplaceService().inspect(source)

        #expect(packages.first?.supportedClients == [.claude])
    }

    @Test func marketplaceFindsRepositoriesContainingOnlyATopLevelSkillsFolder() throws {
        let root = try temporaryDirectory()
        try write("---\nname: one\ndescription: Portable\n---\n", to: root.appending(path: "skills/one/SKILL.md"))
        let source = ToolingSource(name: "Skill source", kind: .localFolder, location: root.path(percentEncoded: false))

        let packages = try MarketplaceService().inspect(source)

        #expect(packages.count == 1)
        #expect(packages.first?.components == [.skill])
        #expect(packages.first?.supportedClients == Set(ClientKind.allCases))
    }

    @Test func marketplaceRejectsPackageSymlinksThatEscapeTheSelectedRoot() throws {
        let root = try temporaryDirectory()
        let package = root.appending(path: "plugins/example", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: package, withIntermediateDirectories: true)
        let externalManifest = root.deletingLastPathComponent().appending(path: "external-\(UUID().uuidString).json")
        try write("{\"$schema\":\"https://agent-plugins.org/schemas/1.0.0/plugin.schema.json\",\"name\":\"escaped\"}", to: externalManifest)
        try FileManager.default.createSymbolicLink(at: package.appending(path: "plugin.json"), withDestinationURL: externalManifest)
        let source = ToolingSource(name: "Unsafe source", kind: .localFolder, location: root.path(percentEncoded: false))

        #expect(throws: MarketplaceError.self) {
            _ = try MarketplaceService().inspect(source)
        }
    }

    @Test func marketplaceAllowsInternalSkillSymlinksAndStillValidatesTheSkill() throws {
        let root = try temporaryDirectory()
        let sharedSkill = root.appending(path: "shared", directoryHint: .isDirectory)
        try write("---\nname: shared\ndescription: Internal portable skill\n---\n", to: sharedSkill.appending(path: "SKILL.md"))
        try FileManager.default.createDirectory(at: root.appending(path: "skills"), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: root.appending(path: "skills/shared"), withDestinationURL: sharedSkill)
        let source = ToolingSource(name: "Internal link", kind: .localFolder, location: root.path(percentEncoded: false))

        let packages = try MarketplaceService().inspect(source)

        #expect(packages.count == 1)
        #expect(packages.first?.components == [.skill])
        #expect(packages.first?.supportedClients == Set(ClientKind.allCases))
    }

    @Test func marketplaceRejectsMalformedPortableManifestsInsteadOfGuessing() throws {
        let root = try temporaryDirectory()
        try write("{\"name\":\"missing-schema\"}", to: root.appending(path: "plugin.json"))
        let source = ToolingSource(name: "Malformed", kind: .localFolder, location: root.path(percentEncoded: false))

        #expect(throws: MarketplaceError.self) {
            _ = try MarketplaceService().inspect(source)
        }
    }

    @Test func claudeCatalogParserDoesNotMistakeArbitraryObjectsForPlugins() {
        let catalog = "{\"profiles\":[{\"id\":\"team\",\"name\":\"Team profile\"}]}"

        #expect(MarketplaceService().packagesFromClaudeCatalogJSON(catalog).isEmpty)
    }

    @Test func preparingBackupDoesNotClaimSuccessBeforeExecution() throws {
        let root = try temporaryDirectory()
        let store = try WorkspaceStore(rootURL: root.appending(path: "workspace", directoryHint: .isDirectory))
        let model = try AppModel(store: store, runner: StubRunner(versions: [:]), homeURL: root.appending(path: "home"))

        model.prepareBackup()

        #expect(model.pendingPlan?.kind == .exportBackup)
        #expect(model.backupConfiguration.isEnabled == false)
        #expect(model.backupConfiguration.location == nil)
    }

    @Test func backupRestoreWarnsWhenItWouldDeleteLocalOnlyDesiredState() async throws {
        let root = try temporaryDirectory()
        let store = try WorkspaceStore(rootURL: root.appending(path: "workspace", directoryHint: .isDirectory))
        try write("portable", to: store.libraryURL.appending(path: "packages/local-kept/skills/kept/SKILL.md"))
        let original = WorkspaceSnapshot(skills: [
            Skill(
                id: "kept", name: "kept", displayName: "Kept", summary: "Kept", bundle: "local-kept", scope: "This Mac", owned: true,
                triggers: [], negativeTrigger: "", files: ["SKILL.md"], clients: [], validationCount: 0)
        ])
        let service = BackupService(store: store)
        let engine = OperationEngine(store: store, runner: ProcessCommandRunner(), homeURL: root.appending(path: "home"))
        _ = await engine.execute(try service.exportPlan(snapshot: original))
        var current = original
        current.skills.append(
            Skill(
                id: "local-only", name: "local-only", displayName: "Local Only", summary: "Would be removed", bundle: "local-local-only",
                scope: "This Mac", owned: true, triggers: [], negativeTrigger: "", files: [], clients: [], validationCount: 0))

        let preview = try service.importPreview(at: service.exportURL, current: current)

        #expect(preview.conflicts.contains { $0.identifier == "local-only" && $0.backupSummary.contains("remove") })
    }

    @Test func managedPolicyRejectsInheritanceCycles() throws {
        let root = try temporaryDirectory()
        let store = try WorkspaceStore(rootURL: root.appending(path: "workspace", directoryHint: .isDirectory))
        let model = try AppModel(store: store, runner: StubRunner(versions: [:]), homeURL: root.appending(path: "home"))
        let policyURL = root.appending(path: "cyclic-policy.json")
        try write(
            """
            {"schema":"agent-tooling-policy/v1","id":"cycle","name":"Cycle","profiles":[
              {"id":"one","name":"One","summary":"","inheritedFrom":"two","checks":[],"enabledPlugins":[],"requiredMCPs":[]},
              {"id":"two","name":"Two","summary":"","inheritedFrom":"one","checks":[],"enabledPlugins":[],"requiredMCPs":[]}
            ]}
            """, to: policyURL)

        model.importManagedPolicy(at: policyURL)

        #expect(model.managedPolicies.isEmpty)
        #expect(model.lastError?.contains("cycle") == true)
    }

    @Test func managedPolicyRejectsSymlinkedAndUnknownExecutableInput() throws {
        let root = try temporaryDirectory()
        let policyURL = root.appending(path: "policy.json")
        try write("{\"schema\":\"agent-tooling-policy/v1\",\"id\":\"safe\",\"name\":\"Safe\",\"hooks\":[\"run-me\"]}", to: policyURL)

        #expect(throws: PolicyError.self) {
            _ = try PolicyService().load(at: policyURL)
        }

        let validURL = root.appending(path: "valid.json")
        try write("{\"schema\":\"agent-tooling-policy/v1\",\"id\":\"safe\",\"name\":\"Safe\"}", to: validURL)
        let linkedURL = root.appending(path: "linked.json")
        try FileManager.default.createSymbolicLink(at: linkedURL, withDestinationURL: validURL)
        #expect(throws: PolicyError.self) {
            _ = try PolicyService().load(at: linkedURL)
        }
    }

    @Test func managedPolicyNormalizesRulesAndRejectsDuplicatesAndDuplicateChecks() throws {
        let root = try temporaryDirectory()
        let duplicateRule = root.appending(path: "duplicate-rule.json")
        try write(
            "{\"schema\":\"agent-tooling-policy/v1\",\"id\":\"rules\",\"name\":\"Rules\",\"requiredPluginIDs\":[\"calendar\",\" calendar \" ]}",
            to: duplicateRule)
        #expect(throws: PolicyError.self) {
            _ = try PolicyService().load(at: duplicateRule)
        }

        let duplicateCheck = root.appending(path: "duplicate-check.json")
        try write(
            "{\"schema\":\"agent-tooling-policy/v1\",\"id\":\"checks\",\"name\":\"Checks\",\"profiles\":[{\"id\":\"team\",\"name\":\"Team\",\"checks\":[{\"id\":\"auth\",\"name\":\"Auth\"},{\"id\":\"AUTH\",\"name\":\"Auth again\"}]}]}",
            to: duplicateCheck)
        #expect(throws: PolicyError.self) {
            _ = try PolicyService().load(at: duplicateCheck)
        }
    }

    @Test func connectorMetadataPersistsWithoutCredentialValues() throws {
        let root = try temporaryDirectory()
        let store = try WorkspaceStore(rootURL: root.appending(path: "workspace", directoryHint: .isDirectory))
        let first = try AppModel(
            store: store, runner: StubRunner(versions: [:]), homeURL: root.appending(path: "home", directoryHint: .isDirectory))
        first.addConnector(
            name: "Calendar", provider: "Google", ownership: .account, target: .codexCloud, scope: .account,
            secretReferenceNames: ["GOOGLE_CLIENT_ID"])

        let second = try AppModel(
            store: store, runner: StubRunner(versions: [:]), homeURL: root.appending(path: "home", directoryHint: .isDirectory))
        #expect(second.connectors.count == 1)
        #expect(second.connectors.first?.secretReferenceNames == ["GOOGLE_CLIENT_ID"])
        #expect(second.connectors.first?.bindings.first?.target == .codexCloud)

        let legacy = try JSONDecoder().decode(WorkspaceSnapshot.self, from: Data("{}".utf8))
        #expect(legacy.connectors.isEmpty)
    }

    @Test func connectorValidationRejectsScopeMismatchesValuesAndDuplicates() throws {
        #expect(throws: ConnectorValidationError.self) {
            _ = try ConnectorValidator.validate(
                name: "Calendar",
                provider: "Google",
                target: .codexCloud,
                scope: .project,
                secretReferenceNames: []
            )
        }
        let noProvider = try ConnectorValidator.validate(
            name: "Calendar",
            provider: "",
            target: .codexCloud,
            scope: .account,
            secretReferenceNames: []
        )
        #expect(noProvider.provider.isEmpty)
        #expect(throws: ConnectorValidationError.self) {
            _ = try ConnectorValidator.validate(
                name: "Calendar\nInjected",
                provider: "Google",
                target: .codexCloud,
                scope: .account,
                secretReferenceNames: []
            )
        }
        #expect(throws: ConnectorValidationError.self) {
            _ = try ConnectorValidator.validate(
                name: "Calendar",
                provider: "Google",
                target: .codexCloud,
                scope: .account,
                secretReferenceNames: ["TOKEN=secret"]
            )
        }

        let root = try temporaryDirectory()
        let store = try WorkspaceStore(rootURL: root.appending(path: "workspace", directoryHint: .isDirectory))
        let model = try AppModel(store: store, runner: StubRunner(versions: [:]), homeURL: root.appending(path: "home"))
        #expect(
            model.addConnector(
                name: "Calendar", provider: "Google", ownership: .account, target: .codexCloud, scope: .account,
                secretReferenceNames: [" GOOGLE_CLIENT_ID ", "google_client_id"]))
        #expect(model.connectors.first?.secretReferenceNames.count == 1)
        #expect(
            !model.addConnector(
                name: "calendar", provider: "Other", ownership: .account, target: .codexCloud, scope: .account, secretReferenceNames: []))
        #expect(model.lastError?.contains("already recorded") == true)

        let id = try #require(model.connectors.first?.id)
        model.removeConnector(id: id)
        #expect(model.connectors.isEmpty)
    }

    @Test func snapshotValidatorRejectsUnsafeAccountSettingsURLs() {
        let account = AccountSurface(
            surface: .codexCloud,
            name: "Hosted settings",
            status: .manual,
            guidance: "Review it",
            verificationURL: "https://example.com/settings?token=secret"
        )
        #expect(throws: WorkspaceSnapshotValidationError.self) {
            try WorkspaceSnapshotValidator.validate(
                WorkspaceSnapshot(accountSurfaces: [account]),
                mode: .portableImport
            )
        }
    }

    @Test func behaviorPreferencesPersistAcrossModelInstances() async throws {
        let root = try temporaryDirectory()
        let store = try WorkspaceStore(rootURL: root.appending(path: "workspace", directoryHint: .isDirectory))
        let first = try AppModel(store: store, runner: StubRunner(versions: [:]), homeURL: root.appending(path: "home"))
        await first.bootstrap()
        #expect(first.setAutomaticallyCheckHealth(false))

        let second = try AppModel(store: store, runner: StubRunner(versions: [:]), homeURL: root.appending(path: "home"))
        #expect(second.automaticallyCheckHealth == false)

        let legacy = try JSONDecoder().decode(WorkspaceSnapshot.self, from: Data("{}".utf8))
        #expect(legacy.preferences == WorkspacePreferences())

        let encoded = try JSONEncoder().encode(WorkspacePreferences(automaticallyCheckHealth: false))
        let encodedJSON = try #require(String(data: encoded, encoding: .utf8))
        #expect(!encodedJSON.contains("confirmWrites"))
    }

    @Test func accountAndConnectorAttestationsCanBeRefreshed() throws {
        let root = try temporaryDirectory()
        let store = try WorkspaceStore(rootURL: root.appending(path: "workspace", directoryHint: .isDirectory))
        let model = try AppModel(store: store, runner: StubRunner(versions: [:]), homeURL: root.appending(path: "home"))
        let accountID = try #require(model.accountSurfaces.first?.id)

        model.markAccountSurfaceVerified(accountID)
        let firstAccountDate = try #require(model.accountSurfaces.first(where: { $0.id == accountID })?.lastVerifiedAt)
        model.markAccountSurfaceVerified(accountID)
        let refreshedAccountDate = try #require(model.accountSurfaces.first(where: { $0.id == accountID })?.lastVerifiedAt)

        #expect(refreshedAccountDate >= firstAccountDate)
        #expect(model.activities.filter { $0.title.contains("marked verified") }.count == 2)

        #expect(
            model.addConnector(
                name: "Source Control", provider: "GitHub", ownership: .account, target: .claudeCloud, scope: .account,
                secretReferenceNames: []))
        let connector = try #require(model.connectors.first)
        let bindingID = try #require(connector.bindings.first?.id)
        model.markConnectorBindingVerified(connectorID: connector.id, bindingID: bindingID)
        let firstBindingDate = try #require(model.connectors.first?.bindings.first?.lastVerifiedAt)
        model.markConnectorBindingVerified(connectorID: connector.id, bindingID: bindingID)
        let refreshedBindingDate = try #require(model.connectors.first?.bindings.first?.lastVerifiedAt)

        #expect(refreshedBindingDate >= firstBindingDate)
        #expect(model.activities.filter { $0.title.contains("binding marked verified") }.count == 2)
    }

    @Test func profileEditingRejectsANameAlreadyUsedByAnotherConfiguration() throws {
        let root = try temporaryDirectory()
        let store = try WorkspaceStore(rootURL: root.appending(path: "workspace", directoryHint: .isDirectory))
        let model = try AppModel(store: store, runner: StubRunner(versions: [:]), homeURL: root.appending(path: "home"))
        let first = try #require(model.createProfile(name: "First", summary: "", scope: .user, projectRoot: nil))
        let second = try #require(model.createProfile(name: "Second", summary: "", scope: .user, projectRoot: nil))

        #expect(
            !model.updateProfile(
                id: second.id, name: first.name, summary: "", scope: .user, projectRoot: nil, enabledPlugins: [], requiredMCPs: []))
        #expect(model.lastError?.contains("already uses") == true)
    }

    @Test func encryptedFolderSyncEncryptsPortableLibraryAndRestoresOnlyManagedFiles() async throws {
        let root = try temporaryDirectory()
        let store = try WorkspaceStore(rootURL: root.appending(path: "workspace", directoryHint: .isDirectory))
        let skillURL = store.libraryURL.appending(path: "packages/local-example/skills/example/SKILL.md")
        let helperURL = store.libraryURL.appending(path: "packages/local-example/skills/example/scripts/helper.sh")
        try write("portable-library-content", to: skillURL)
        try write("#!/bin/sh\nexit 0\n", to: helperURL)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: helperURL.path(percentEncoded: false))
        let snapshot = WorkspaceSnapshot(
            skills: [
                Skill(
                    id: "example", name: "example", displayName: "Example", summary: "Portable", bundle: "local-example", scope: "This Mac",
                    owned: true, triggers: [], negativeTrigger: "", files: ["SKILL.md", "scripts/helper.sh"], clients: [],
                    validationCount: 0)
            ],
            activities: [
                ActivityReceipt(kind: .configuration, title: "Machine-only", detail: "Should not sync", date: .now, state: .healthy)
            ])
        let folder = root.appending(path: "synced-folder", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let service = EncryptedSyncService(store: store, keyProvider: FixedSyncKeyProvider())
        let engine = OperationEngine(
            store: store, runner: StubRunner(versions: [:]), homeURL: root.appending(path: "home", directoryHint: .isDirectory))

        let exportReceipt = await engine.execute(try service.exportPlan(snapshot: snapshot, destinationFolder: folder))
        #expect(!exportReceipt.results.contains { $0.status == .failed })
        let archive = folder.appending(path: EncryptedSyncService.archiveFileName)
        let ciphertext = try String(contentsOf: archive, encoding: .utf8)
        #expect(!ciphertext.contains("portable-library-content"))
        #expect(!ciphertext.contains("Machine-only"))

        try write("changed", to: skillURL)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: helperURL.path(percentEncoded: false))
        let preview = try service.importPreview(at: archive)
        #expect(preview.snapshot.activities.isEmpty)
        #expect(preview.libraryFileCount == 2)
        let restoreReceipt = await engine.execute(preview.plan)
        #expect(!restoreReceipt.results.contains { $0.status == .failed })
        #expect(try String(contentsOf: skillURL, encoding: .utf8) == "portable-library-content")
        let restoredPermissions = try #require(
            (FileManager.default.attributesOfItem(atPath: helperURL.path(percentEncoded: false))[.posixPermissions] as? NSNumber)?.intValue)
        #expect(restoredPermissions == 0o700)
    }

    @Test func managedPolicyImportsProfilesAndBlocksNamedMarketplacePlugins() throws {
        let root = try temporaryDirectory()
        let store = try WorkspaceStore(rootURL: root.appending(path: "workspace", directoryHint: .isDirectory))
        let model = try AppModel(
            store: store, runner: StubRunner(versions: [:]), homeURL: root.appending(path: "home", directoryHint: .isDirectory))
        let policyURL = root.appending(path: "agent-tooling-policy.json")
        try write(
            """
            {"schema":"agent-tooling-policy/v1","id":"acme-policy","name":"Acme baseline","blockedPluginIDs":["calendar"],"profiles":[{"id":"team","name":"Team","summary":"Managed","checks":[],"enabledPlugins":[],"requiredMCPs":[]}]}
            """, to: policyURL)

        model.importManagedPolicy(at: policyURL)
        #expect(model.managedPolicies.first?.id == "acme-policy")
        #expect(model.profiles.contains { $0.id == "policy-acme-policy-team" && $0.scope == .managed })

        let packages = [
            MarketplacePackage(
                id: "codex:calendar", name: "calendar", publisher: "Test", summary: "Test", sourceName: "Test", components: [.plugin],
                supportedClients: [.codex], location: "calendar",
                nativeInstalls: [
                    NativeInstall(client: .codex, executable: "codex", arguments: ["plugin", "add", "calendar"], detail: "Test")
                ])
        ]
        let loadedSnapshot = try store.load("workspace.snapshot", as: WorkspaceSnapshot.self)
        let persisted = try #require(loadedSnapshot)
        try store.saveWorkspaceSnapshot(
            WorkspaceSnapshot(
                skills: persisted.skills,
                mcpServers: persisted.mcpServers,
                plugins: persisted.plugins,
                profiles: persisted.profiles,
                activities: persisted.activities,
                operationReceipts: persisted.operationReceipts,
                targetObservations: persisted.targetObservations,
                sources: persisted.sources,
                marketplacePackages: packages,
                accountSurfaces: persisted.accountSurfaces,
                connectors: persisted.connectors,
                activeProfileID: persisted.activeProfileID,
                importedRepositoryPath: persisted.importedRepositoryPath,
                backupConfiguration: persisted.backupConfiguration,
                encryptedSyncConfiguration: persisted.encryptedSyncConfiguration,
                preferences: persisted.preferences,
                managedPolicies: persisted.managedPolicies
            ))
        let reloadedModel = try AppModel(
            store: store, runner: StubRunner(versions: [:]), homeURL: root.appending(path: "home", directoryHint: .isDirectory))
        reloadedModel.planMarketplaceInstall(packageID: "codex:calendar", client: .codex)
        #expect(reloadedModel.lastError?.contains("blocks installation") == true)
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
