import Foundation
import Testing

@testable import AgentToolingCore

/// What Claude Code downloads from the claude.ai account is the account's.
/// These pin the places that would otherwise treat it as a loose local tool:
/// the scan, the audit, the engine's removal, skill placement, and every
/// marketplace command.
@Suite("Accounts · what the account owns stays the account's")
struct AccountOwnedContentSafetyTests {
    static func temporaryHome() throws -> URL {
        let home = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
            .appending(path: "account-safety-\(UUID())", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        return home
    }

    static func skill(_ url: URL, name: String) throws {
        try AccountSurfaceParsingTests.write(url.appending(path: "SKILL.md"), "---\nname: \(name)\ndescription: A skill.\n---\n")
    }

    @Test func reservedNamesAreRecognisedInEveryCase() {
        for name in ["synced", "Synced", "SYNCED", "anthropic-skills", "anthropic-skills:pdf"] {
            #expect(ClaudeAccountSync.isReservedSkillFolderName(name), "\(name)")
        }
        for name in ["pdf", "synced-notes", "my-synced", "anthropic"] {
            #expect(!ClaudeAccountSync.isReservedSkillFolderName(name), "\(name)")
        }
    }

    @Test func aPathIsInsideTheSyncedFolderOnlyUnderClaudesSkills() throws {
        let home = URL(filePath: "/Users/example", directoryHint: .isDirectory)
        #expect(ClaudeAccountSync.isInsideSyncedSkills(home.appending(path: ".claude/skills/synced"), homeURL: home))
        #expect(ClaudeAccountSync.isInsideSyncedSkills(home.appending(path: ".claude/skills/synced/pdf/SKILL.md"), homeURL: home))
        #expect(ClaudeAccountSync.isInsideSyncedSkills(home.appending(path: ".claude/skills/Synced/pdf"), homeURL: home))
        #expect(!ClaudeAccountSync.isInsideSyncedSkills(home.appending(path: ".claude/skills/syncedish"), homeURL: home))
        #expect(!ClaudeAccountSync.isInsideSyncedSkills(home.appending(path: ".claude/skills/pdf"), homeURL: home))
        #expect(!ClaudeAccountSync.isInsideSyncedSkills(home.appending(path: ".codex/skills/synced/pdf"), homeURL: home))
        #expect(!ClaudeAccountSync.isInsideSyncedSkills(home.appending(path: ".claude/plugins/synced"), homeURL: home))
    }

    /// The inventory reports resolved paths, so a `~/.claude` that is a link
    /// still has its synced folder recognised.
    @Test func aLinkedClaudeFolderIsSeenThrough() throws {
        let root = try Self.temporaryHome()
        defer { try? FileManager.default.removeItem(at: root) }
        let home = root.appending(path: "home", directoryHint: .isDirectory)
        let real = root.appending(path: "dotfiles/claude", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: real.appending(path: "skills/synced/pdf"), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: home.appending(path: ".claude"), withDestinationURL: real)
        #expect(ClaudeAccountSync.isInsideSyncedSkills(real.appending(path: "skills/synced/pdf"), homeURL: home))
    }

    @Test func aPluginIdentifiersOriginIsAfterItsLastAt() {
        #expect(ClaudeAccountSync.origin(ofPluginID: "design@synced") == "synced")
        #expect(ClaudeAccountSync.pluginName(ofPluginID: "design@synced") == "design")
        #expect(ClaudeAccountSync.origin(ofPluginID: "scoped@team@synced") == "synced")
        #expect(ClaudeAccountSync.pluginName(ofPluginID: "scoped@team@synced") == "scoped@team")
        #expect(ClaudeAccountSync.origin(ofPluginID: "design") == nil)
        #expect(ClaudeAccountSync.origin(ofPluginID: "@synced") == nil)
        #expect(ClaudeAccountSync.isSyncedPluginID("design@synced"))
        #expect(!ClaudeAccountSync.isSyncedPluginID("design@synced-marketplace"))
        for origin in ["synced", "inline", "skills-dir"] {
            #expect(ClaudeAccountSync.hasReservedOrigin("x@\(origin)"))
        }
        #expect(!ClaudeAccountSync.hasReservedOrigin("x@agent-tooling"))
    }

    // MARK: Commands

    @Test func noMarketplaceCommandIsBuiltForAReservedOrigin() throws {
        let home = try Self.temporaryHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let policy = OperationCommandPolicy(
            libraryURL: home.appending(path: "library", directoryHint: .isDirectory),
            gitBackupRoot: home.appending(path: "backup", directoryHint: .isDirectory), homeURL: home)
        for verb in ["install", "uninstall", "update"] {
            for origin in ["synced", "inline", "skills-dir"] {
                #expect(throws: OperationEngineError.self, "\(verb) x@\(origin)") {
                    try policy.validate(executable: "claude", arguments: ["plugin", verb, "x@\(origin)", "--scope", "user"])
                }
            }
            try policy.validate(executable: "claude", arguments: ["plugin", verb, "x@vendor", "--scope", "user"])
        }
        #expect(NativePluginInstallRegister.command(for: .claude, externalPluginID: "design@synced") == nil)
        #expect(NativePluginInstallRegister.command(for: .claude, externalPluginID: "design@vendor") != nil)
    }

    /// The account reader's two questions are admitted, and nothing near them.
    @Test func theAccountReadersQuestionsAreAdmittedExactly() throws {
        let home = try Self.temporaryHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let policy = OperationCommandPolicy(
            libraryURL: home.appending(path: "library", directoryHint: .isDirectory),
            gitBackupRoot: home.appending(path: "backup", directoryHint: .isDirectory), homeURL: home)
        try policy.validate(executable: "claude", arguments: ["auth", "status", "--json"])
        try policy.validate(executable: "claude", arguments: ["plugin", "list", "--json"])
        for refused in [
            ["auth", "login"], ["auth", "logout"], ["auth", "status", "--text", "--json"], ["plugin", "disable", "x@synced"],
        ] {
            #expect(throws: OperationEngineError.self, "\(refused)") { try policy.validate(executable: "claude", arguments: refused) }
        }
    }

    @Test func noSkillIsPlacedUnderAReservedName() throws {
        let home = URL(filePath: "/Users/example", directoryHint: .isDirectory)
        for name in ["synced", "Synced", "anthropic-skills"] {
            #expect(throws: NativeSkillDestinationError.invalidSkillID, "\(name)") {
                _ = try NativeSkillDestination.skillURL(client: .claude, skillID: name, homeURL: home, scope: .user, projectRoot: nil)
            }
        }
        // Only Claude Code reserves the name; another client's folder is its own.
        _ = try NativeSkillDestination.skillURL(client: .codex, skillID: "synced", homeURL: home, scope: .user, projectRoot: nil)
        _ = try NativeSkillDestination.skillURL(client: .claude, skillID: "review", homeURL: home, scope: .user, projectRoot: nil)
    }

    // MARK: The scan

    private actor InventoryRunner: CommandRunning {
        func run(executable: String, arguments: [String], currentDirectory: URL?) async throws -> CommandOutput {
            switch arguments {
            case ["--version"]: return CommandOutput(status: 0, standardOutput: "2.1.300", standardError: "")
            case ["plugin", "list", "--json"]:
                return CommandOutput(
                    status: 0,
                    standardOutput: """
                        [{"id":"design@synced","installPath":"/p/design","enabled":true,"scope":"synced"},
                         {"id":"tool@vendor","installPath":"/p/tool","enabled":true,"scope":"user"}]
                        """, standardError: "")
            default: return CommandOutput(status: 1, standardOutput: "", standardError: "")
            }
        }
    }

    @Test func theScanLeavesTheAccountsSkillsAndPluginsOut() async throws {
        let home = try Self.temporaryHome()
        defer { try? FileManager.default.removeItem(at: home) }
        try Self.skill(home.appending(path: ".claude/skills/synced/pdf"), name: "pdf")
        try Self.skill(home.appending(path: ".claude/skills/review"), name: "review")
        let observation = await ClaudeCodeAdapter().scan(homeURL: home, runner: InventoryRunner())
        #expect(observation.skillMetadata.keys.contains("review"))
        #expect(!observation.skillMetadata.keys.contains("pdf"), "the account's skill is not a loose skill")
        #expect(!observation.skillMetadata.keys.contains("synced"))
        #expect(observation.pluginMetadata.keys.contains("tool@vendor"))
        #expect(!observation.pluginMetadata.keys.contains("design@synced"), "the account's plugin is not this Mac's package")
    }

    /// The synced folder has no SKILL.md of its own; before this, the audit
    /// called it an empty skill folder and offered to remove it.
    @Test func theAuditDoesNotOfferToRemoveTheSyncedFolder() throws {
        let home = try Self.temporaryHome()
        defer { try? FileManager.default.removeItem(at: home) }
        try Self.skill(home.appending(path: ".claude/skills/synced/pdf"), name: "pdf")
        try FileManager.default.createDirectory(at: home.appending(path: ".claude/skills/empty"), withIntermediateDirectories: true)
        let observation = TargetObservation(
            surface: .claudeCode, installed: true, commandAvailable: true, version: "2.1.300",
            capabilities: .init(
                supportsPluginInstall: true, supportsProjectScope: true, supportsLocalMarketplace: true,
                supportsMCPAuthentication: true, supportsConnectorDiscovery: true, requiresNewSession: true,
                requiresRestart: false, supportsMachineReadableOutput: true))
        let report = SetupAuditor(homeURL: home, searchPath: []).audit(
            observations: [observation], managed: [.claude], library: .init(managedSkillNames: []))
        #expect(!report.findings.contains { $0.subject.lowercased() == "synced" })
        #expect(
            report.findings.contains { $0.kind == .skillWithoutDefinition && $0.subject == "empty" },
            "a real empty folder is still reported")
    }

    // MARK: The engine

    @Test func theEngineRefusesToMoveTheSyncedFolder() async throws {
        let fixture = try AccountPreferenceApplyTests.Fixture()
        defer { fixture.remove() }
        let synced = fixture.home.appending(path: ".claude/skills/synced", directoryHint: .isDirectory)
        let loose = fixture.home.appending(path: ".claude/skills/loose", directoryHint: .isDirectory)
        try Self.skill(synced.appending(path: "pdf"), name: "pdf")
        try Self.skill(loose, name: "loose")
        let plan = OperationPlan(
            kind: .installSkill, title: "Remove", summary: "",
            steps: [
                .init(
                    kind: .removeUnmanagedSkillCopy, title: "Remove synced", detail: "", destinationPath: synced.path(percentEncoded: false)
                ),
                .init(
                    kind: .removeUnmanagedSkillCopy, title: "Remove loose", detail: "", destinationPath: loose.path(percentEncoded: false)),
            ])
        let receipt = await OperationExecutor(store: fixture.store, homeURL: fixture.home).execute(plan)
        #expect(receipt.results.map(\.status) == [.failed, .succeeded])
        #expect(FileManager.default.fileExists(atPath: synced.appending(path: "pdf/SKILL.md").path(percentEncoded: false)))
        #expect(!FileManager.default.fileExists(atPath: loose.path(percentEncoded: false)), "a real loose copy still moves")
    }
}

// MARK: - Checkup's findings about accounts

@Suite("Accounts · what Checkup says about them")
struct AccountAuditTests {
    static let workspace = WorkspaceObjectID()

    static func observation(
        _ provider: AccountProvider = .claude, method: AccountSignIn.Method = .subscription, email: String = "me@example.com",
        items: [AccountItem] = [], contents: Bool = true, overrides: [AccountShellOverride] = [], unavailable: String? = nil
    ) -> AccountObservation {
        AccountObservation(
            provider: provider, signIn: .init(method: method, provider: method == .thirdParty ? "bedrock" : nil, email: email),
            items: items, unavailableReason: unavailable, contentsRead: contents, shellOverrides: overrides)
    }

    static func peer(_ name: String, email: String, method: AccountSignIn.Method = .subscription) -> AccountPeerReport {
        let signIn = AccountSignIn(method: method, email: email)
        return .init(
            deviceName: name,
            summaries: [
                .init(
                    provider: .claude, signInMethod: method, plan: nil,
                    accountFingerprint: PublishedAccountSummary.fingerprint(provider: .claude, signIn: signIn, workspaceID: workspace),
                    itemCounts: nil, switchesOutOfStep: nil, observedAt: .now)
            ])
    }

    @Test func aSubscriptionWithNothingOutstandingSaysNothing() {
        #expect(AccountAuditor.findings(observations: [Self.observation()], plans: [:], peers: [], workspaceID: Self.workspace).isEmpty)
    }

    @Test func aClientOnAnotherSignInIsReported() throws {
        let findings = AccountAuditor.findings(
            observations: [Self.observation(method: .thirdParty)], plans: [:], peers: [], workspaceID: Self.workspace)
        let finding = try #require(findings.first)
        #expect(findings.count == 1)
        #expect(finding.kind == .accountSignIn)
        #expect(finding.client == .claude)
        #expect(finding.severity == .medium)
        #expect(finding.detail.contains("Amazon Bedrock"))
        #expect(finding.actions == [.openAccounts(provider: .claude)])
        #expect(!finding.actions.contains { $0.changesFiles })
    }

    @Test func eachShellOverrideIsItsOwnFinding() {
        let findings = AccountAuditor.findings(
            observations: [Self.observation(overrides: [.anthropicAPIKey, .claudeConfigDirectory])],
            plans: [:], peers: [], workspaceID: Self.workspace)
        #expect(findings.map(\.kind) == [.accountShellOverride, .accountShellOverride])
        #expect(findings.map(\.severity) == [.medium, .low])
        #expect(findings.allSatisfy { $0.detail.contains("never its value") })
        #expect(Set(findings.map(\.id)).count == 2)
    }

    @Test func choicesNotFollowedOfferTheReviewedApplyOnlyWhenThereIsAnEdit() throws {
        var plan = AccountPreferencePlan(provider: .claude)
        plan.changes = [.init(key: .init(.skillSync), desired: .off, current: .on, edits: [])]
        let editable = AccountAuditor.findings(
            observations: [Self.observation()], plans: [.claude: plan], peers: [], workspaceID: Self.workspace)
        #expect(editable.first?.kind == .accountChoicesNotFollowed)
        #expect(editable.first?.actions == [.applyAccountChoices(provider: .claude)])

        var held = AccountPreferencePlan(provider: .claude)
        held.held = [.init(key: .init(.skillSync), desired: .off, reason: "Policy")]
        let heldOnly = AccountAuditor.findings(
            observations: [Self.observation()], plans: [.claude: held], peers: [], workspaceID: Self.workspace)
        #expect(heldOnly.first?.actions == [.openAccounts(provider: .claude)])
        #expect(heldOnly.first?.evidence.first?.contains("Policy") == true)
    }

    @Test func connectorsThatNeedTheVendorsSiteSayWhere() {
        let item = AccountItem(
            provider: .claude, kind: .connector, key: "Google Calendar", name: "Google Calendar",
            state: .init(tone: .attention, label: "Needs sign-in on claude.ai"))
        let findings = AccountAuditor.findings(
            observations: [Self.observation(items: [item])], plans: [:], peers: [], workspaceID: Self.workspace)
        #expect(findings.map(\.kind) == [.accountConnectorNeedsSignIn])
        #expect(findings.first?.actions == [.openAccountSite(provider: .claude, kind: .connector)])
        // A light read never claims a connector is fine or broken.
        #expect(
            AccountAuditor.findings(
                observations: [Self.observation(items: [item], contents: false)], plans: [:], peers: [], workspaceID: Self.workspace
            ).isEmpty)
    }

    @Test func aDifferentAccountFromAnotherMacIsTheLoudestFinding() throws {
        let findings = AccountAuditor.findings(
            observations: [Self.observation()],
            plans: [:],
            peers: [
                Self.peer("Studio", email: "me@example.com"), Self.peer("Laptop", email: "work@example.com"),
                Self.peer("Old Mac", email: "x@example.com", method: .apiKey),
            ],
            workspaceID: Self.workspace)
        let finding = try #require(findings.first)
        #expect(findings.count == 1)
        #expect(finding.kind == .accountDiffersFromOtherMacs)
        #expect(finding.severity == .high)
        #expect(finding.evidence == ["Laptop"])
        #expect(!finding.detail.contains("work@example.com"))
    }

    @Test func anUnreadableAccountSaysNothingItCannotProve() {
        #expect(
            AccountAuditor.findings(
                observations: [Self.observation(method: .thirdParty, unavailable: "Codex was not found.")],
                plans: [:], peers: [], workspaceID: Self.workspace
            ).isEmpty)
    }

    @Test func accountActionsAreNamedAndOnlyApplyingChangesFiles() {
        #expect(SetupAction.applyAccountChoices(provider: .chatGPT).changesFiles)
        #expect(!SetupAction.openAccountSite(provider: .chatGPT, kind: .app).changesFiles)
        #expect(!SetupAction.openAccounts(provider: .claude).changesFiles)
        #expect(SetupAction.openAccountSite(provider: .claude, kind: nil).title == "Open claude.ai")
        #expect(AccountProvider.claude.manageURL(for: .connector).absoluteString == "https://claude.ai/customize/connectors")
        #expect(AccountProvider.chatGPT.manageURL(for: .app).absoluteString == "https://chatgpt.com/apps")
    }
}
