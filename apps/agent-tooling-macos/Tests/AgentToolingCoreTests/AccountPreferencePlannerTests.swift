import Foundation
import Testing

@testable import AgentToolingCore

@Suite("Accounts · what applying the shared choices changes")
struct AccountPreferencePlannerTests {
    static func claude(
        file: [AccountPreferenceKey: AccountPreferenceValue] = [:],
        effective: [AccountPreferenceKey: AccountPreferenceValue]? = nil,
        constrained: [AccountPreferenceKey: String] = [:], blocker: String? = nil
    ) -> AccountObservation {
        AccountObservation(
            provider: .claude, signIn: .init(method: .subscription), switches: effective ?? file, fileValues: file,
            constrained: constrained, writeBlocker: blocker)
    }

    static func codex(file: [AccountPreferenceKey: AccountPreferenceValue] = [:]) -> AccountObservation {
        AccountObservation(provider: .chatGPT, signIn: .init(method: .subscription), switches: file, fileValues: file)
    }

    static func preferences(_ entries: (AccountPreferenceKey, AccountPreferenceValue)...) -> AccountPreferences {
        AccountPreferences(entries: entries.map { AccountPreference($0.0, value: $0.1) })
    }

    static func object(_ text: String) throws -> [String: Any] {
        try #require(try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
    }

    /// Applies a plan's edits to a text, the way the engine will.
    static func applied(_ plan: AccountPreferencePlan, to text: String) throws -> String {
        try plan.changes.flatMap(\.edits).reduce(text) { try ClientConfigurationEditor.apply($1, to: $0) }
    }

    /// TOML as written, without the indentation the editor gives keys inside
    /// a table, so a test reads what the file says rather than its layout.
    static func flat(_ text: String) -> String {
        text.split(separator: "\n", omittingEmptySubsequences: false)
            .map { String($0.drop { $0 == " " || $0 == "\t" }) }
            .joined(separator: "\n")
    }

    static func appliedFlat(_ plan: AccountPreferencePlan, to text: String) throws -> String {
        flat(try applied(plan, to: text))
    }

    // MARK: Claude Code

    @Test func turningSkillsOffSetsTheDocumentedKey() throws {
        let plan = AccountPreferencePlanner.plan(
            preferences: Self.preferences((.init(.skillSync), .off)), observation: Self.claude(), configurationText: nil)
        #expect(plan.changes.count == 1)
        #expect(plan.changes[0].current == .on, "unset means on")
        #expect(plan.changes[0].edits == [.init(file: .claudeSettings, keyPath: ["syncClaudeAiSkills"], value: .bool(false))])
        #expect(try Self.object(Self.applied(plan, to: ""))["syncClaudeAiSkills"] as? Bool == false)
        #expect(plan.outOfStep == 1)
    }

    /// `true` means the same as unset, so turning a sync back on removes the
    /// key this file set, and leaves everything else in the file alone.
    @Test func turningSkillsBackOnRemovesTheKey() throws {
        let text = #"{"syncClaudeAiSkills": false, "theme": "dark"}"#
        let plan = AccountPreferencePlanner.plan(
            preferences: Self.preferences((.init(.skillSync), .on)),
            observation: Self.claude(file: [.init(.skillSync): .off]), configurationText: text)
        #expect(plan.changes.first?.edits == [.init(file: .claudeSettings, keyPath: ["syncClaudeAiSkills"], value: .remove)])
        let result = try Self.object(Self.applied(plan, to: text))
        #expect(result["syncClaudeAiSkills"] == nil)
        #expect(result["theme"] as? String == "dark")
    }

    @Test func connectorsUseTheDisableKey() throws {
        let plan = AccountPreferencePlanner.plan(
            preferences: Self.preferences((.init(.connectors), .off), (.init(.pluginSync), .off)),
            observation: Self.claude(), configurationText: "{}")
        let result = try Self.object(Self.applied(plan, to: "{}"))
        #expect(result["disableClaudeAiConnectors"] as? Bool == true)
        #expect(result["syncClaudeAiPlugins"] as? Bool == false)
        #expect(plan.changes.count == 2, "both are rehearsed against the file as the first leaves it")
    }

    @Test func oneAccountPluginIsTurnedOffByItsSyncedID() throws {
        let text = #"{"enabledPlugins":{"personal@agent-tooling":true}}"#
        let plan = AccountPreferencePlanner.plan(
            preferences: Self.preferences((.init(.plugin, subject: "design"), .off)),
            observation: Self.claude(), configurationText: text)
        let enabled = try #require(try Self.object(Self.applied(plan, to: text))["enabledPlugins"] as? [String: Bool])
        #expect(enabled == ["personal@agent-tooling": true, "design@synced": false])
    }

    /// Turning a connector off adds a serverName entry; turning it back on
    /// takes out only that entry, never another server's or a richer one.
    @Test func oneConnectorIsDeniedAndAllowedAgainByItsListedName() throws {
        let off = AccountPreferencePlanner.plan(
            preferences: Self.preferences((.init(.connector, subject: "Google Calendar"), .off)),
            observation: Self.claude(), configurationText: #"{"deniedMcpServers":[{"serverName":"filesystem"}]}"#)
        let denied = try Self.applied(off, to: #"{"deniedMcpServers":[{"serverName":"filesystem"}]}"#)
        let entries = try #require(try Self.object(denied)["deniedMcpServers"] as? [[String: String]])
        #expect(entries == [["serverName": "filesystem"], ["serverName": "claude.ai Google Calendar"]])

        let text =
            #"{"deniedMcpServers":[{"serverName":"claude.ai Google Calendar"},{"serverName":"filesystem"},{"serverName":"claude.ai Google Calendar","note":"kept"}]}"#
        let on = AccountPreferencePlanner.plan(
            preferences: Self.preferences((.init(.connector, subject: "Google Calendar"), .on)),
            observation: Self.claude(file: [.init(.connector, subject: "Google Calendar"): .off]), configurationText: text)
        let allowed = try #require(try Self.object(Self.applied(on, to: text))["deniedMcpServers"] as? [[String: String]])
        #expect(allowed == [["serverName": "filesystem"], ["serverName": "claude.ai Google Calendar", "note": "kept"]])
    }

    @Test func aChoiceThisMacAlreadyFollowsChangesNothing() {
        let plan = AccountPreferencePlanner.plan(
            preferences: Self.preferences((.init(.skillSync), .on), (.init(.plugin, subject: "notes"), .off)),
            observation: Self.claude(file: [.init(.plugin, subject: "notes"): .off]), configurationText: nil)
        #expect(plan.isEmpty)
        #expect(plan.held.isEmpty)
        #expect(Set(plan.following) == [.init(.skillSync), .init(.plugin, subject: "notes")])
        #expect(plan.outOfStep == 0)
    }

    /// Managed settings sit above the file this app edits; a choice they
    /// decide is held with their reason rather than written uselessly.
    @Test func aChoiceThePolicyDecidesIsHeld() {
        let key = AccountPreferenceKey(.connector, subject: "Slack")
        let plan = AccountPreferencePlanner.plan(
            preferences: Self.preferences((key, .on)),
            observation: Self.claude(effective: [key: .off], constrained: [key: "Set by your organization's managed settings"]),
            configurationText: nil)
        #expect(plan.changes.isEmpty)
        #expect(plan.held.map(\.reason) == ["Set by your organization's managed settings"])
        #expect(plan.outOfStep == 1)
    }

    /// Off in some other settings file (a local or project one) and not in
    /// this one: removing a key that is not here would do nothing.
    @Test func anOffThisFileDidNotSetIsHeld() {
        let plan = AccountPreferencePlanner.plan(
            preferences: Self.preferences((.init(.skillSync), .on)),
            observation: Self.claude(effective: [.init(.skillSync): .off]), configurationText: "{}")
        #expect(plan.changes.isEmpty)
        #expect(plan.held.first?.reason.contains("Another settings file") == true)
    }

    @Test func aMacWhoseFolderIsElsewhereHoldsEveryChoice() {
        let plan = AccountPreferencePlanner.plan(
            preferences: Self.preferences((.init(.skillSync), .off), (.init(.pluginSync), .off)),
            observation: Self.claude(blocker: "Claude Code reads its settings from /Volumes/x."), configurationText: nil)
        #expect(plan.changes.isEmpty)
        #expect(plan.held.count == 2)
        #expect(plan.held.allSatisfy { $0.reason.contains("/Volumes/x") })
    }

    @Test func aFileTheEditorCannotReadIsHeldNotBroken() {
        let plan = AccountPreferencePlanner.plan(
            preferences: Self.preferences((.init(.skillSync), .off)), observation: Self.claude(),
            configurationText: "{ this is not json")
        #expect(plan.changes.isEmpty)
        #expect(plan.held.first?.reason.contains("could not be read") == true)
    }

    /// A file that is there but could not be read, here one over the size
    /// limit, is not an empty one. Each choice that needs an edit is held with
    /// the read's own reason; one this Mac already follows still is followed.
    @Test func aFileThatCouldNotBeReadHoldsTheChoicesThatNeedAnEdit() {
        let tooLarge = ConfigurationFileTooLargeError(path: ".claude/settings.json", maximumBytes: 4 * 1_048_576)
        let plan = AccountPreferencePlanner.plan(
            preferences: Self.preferences((.init(.skillSync), .off), (.init(.pluginSync), .on)),
            observation: Self.claude(), configuration: .failure(tooLarge))
        #expect(plan.changes.isEmpty)
        #expect(plan.held.map(\.key) == [.init(.skillSync)])
        #expect(plan.held.first?.reason == tooLarge.errorDescription)
        #expect(plan.following == [.init(.pluginSync)])
    }

    @Test func theOtherAccountsChoicesAreNotThisPlans() {
        let plan = AccountPreferencePlanner.plan(
            preferences: Self.preferences((.init(.apps), .off)), observation: Self.claude(), configurationText: nil)
        #expect(plan.isEmpty && plan.held.isEmpty && plan.following.isEmpty)
    }

    // MARK: Codex

    @Test func oneAppIsTurnedOffInItsOwnTable() throws {
        let text = "model = \"gpt-6\"\n\n[mcp_servers.docs]\ncommand = \"docs-mcp\"\n"
        let plan = AccountPreferencePlanner.plan(
            preferences: Self.preferences((.init(.app, subject: "github"), .off), (.init(.apps), .on)),
            observation: Self.codex(file: [.init(.apps): .off]), configurationText: text)
        #expect(plan.changes.map(\.key) == [.init(.apps), .init(.app, subject: "github")])
        let result = try Self.appliedFlat(plan, to: text)
        #expect(result.contains("model = \"gpt-6\""))
        #expect(result.contains("[mcp_servers.docs]\ncommand = \"docs-mcp\""))
        #expect(result.contains("[apps.github]\nenabled = false"))
        #expect(result.contains("[features]\napps = true"))
    }

    /// The approval mode and the tool kinds have no documented default, so
    /// nothing is assumed: the choice is written explicitly.
    @Test func defaultsForEveryAppAreWrittenToTheDefaultTable() throws {
        let plan = AccountPreferencePlanner.plan(
            preferences: Self.preferences((.init(.approvalMode), .prompt), (.init(.destructiveTools), .off)),
            observation: Self.codex(), configurationText: nil)
        #expect(plan.changes.map(\.current) == [nil, nil])
        #expect(!plan.changes[0].summary.contains("(now"))
        let result = try Self.appliedFlat(plan, to: "")
        #expect(result.contains("[apps._default]"))
        #expect(result.contains("destructive_enabled = false"))
        #expect(result.contains("default_tools_approval_mode = \"prompt\""))
    }

    @Test func anExistingAppTableIsEditedInPlace() throws {
        let text = "[apps.github]\nenabled = true\ndestructive_enabled = false\n"
        let plan = AccountPreferencePlanner.plan(
            preferences: Self.preferences((.init(.app, subject: "github"), .off)),
            observation: Self.codex(file: [.init(.app, subject: "github"): .on]), configurationText: text)
        #expect(try Self.applied(plan, to: text) == "[apps.github]\nenabled = false\ndestructive_enabled = false\n")
        let quoted = "[apps.\"github\"]\nenabled = true\n"
        let quotedPlan = AccountPreferencePlanner.plan(
            preferences: Self.preferences((.init(.app, subject: "github"), .off)),
            observation: Self.codex(file: [.init(.app, subject: "github"): .on]), configurationText: quoted)
        #expect(try Self.applied(quotedPlan, to: quoted) == "[apps.\"github\"]\nenabled = false\n")
    }

    /// TOML can define the same key without its table header. A second
    /// definition beside one of these makes the file invalid and Codex would
    /// not start, so each is held instead.
    @Test(arguments: [
        "apps.github.enabled = true\n",
        "apps = { github = { enabled = true } }\n",
        "[apps]\ngithub = { enabled = true }\n",
        "[apps]\ngithub.enabled = true\n",
        "[apps]\ngithub.destructive_enabled = false\n",
        "[apps.github]\n\"enabled\" = true\n",
        "[[apps.github.tools]]\nname = \"x\"\n",
    ])
    func aKeyDefinedInAnotherFormIsHeld(text: String) {
        let plan = AccountPreferencePlanner.plan(
            preferences: Self.preferences((.init(.app, subject: "github"), .off)),
            observation: Self.codex(), configurationText: text)
        #expect(plan.changes.isEmpty, "\(text)")
        #expect(plan.held.first?.reason.contains("in a form this app does not rewrite") == true, "\(text)")
    }

    @Test(arguments: [
        "# apps.github.enabled = true\n",
        "[apps.other]\nenabled = false\n",
        "[apps]\nother = { enabled = false }\n",
        "notes = \"\"\"\napps.github.enabled = true\n\"\"\"\n",
        "list = [\n  \"apps.github.enabled = true\",\n]\n",
    ])
    func somethingThatOnlyLooksLikeTheKeyIsNotAnObstacle(text: String) throws {
        let plan = AccountPreferencePlanner.plan(
            preferences: Self.preferences((.init(.app, subject: "github"), .off)),
            observation: Self.codex(), configurationText: text)
        #expect(plan.held.isEmpty, "\(text)")
        #expect(try Self.appliedFlat(plan, to: text).contains("[apps.github]\nenabled = false"), "\(text)")
    }

    // MARK: The reviewed plan

    @Test func theOperationPlanIsOneBackedUpEditPerChange() throws {
        let home = URL(filePath: "/Users/example", directoryHint: .isDirectory)
        let plan = AccountPreferencePlanner.plan(
            preferences: Self.preferences((.init(.skillSync), .off), (.init(.connector, subject: "Gmail"), .off)),
            observation: Self.claude(), configurationText: nil)
        let operation = try plan.operationPlan(homeURL: home)
        #expect(operation.kind == .configureMCP)
        #expect(operation.targetSurfaces == [.claudeCode])
        #expect(operation.requiresConfirmation)
        #expect(operation.steps.count == 2)
        #expect(operation.steps.allSatisfy { $0.kind == .editClientConfiguration && $0.isReversible })
        #expect(operation.steps.allSatisfy { $0.destinationPath == "/Users/example/.claude/settings.json" })
        let decoded = try operation.steps.map { try ClientConfigurationEdit.decode(try #require($0.contents)) }
        #expect(decoded == plan.changes.flatMap(\.edits))
    }
}

// MARK: - Lists of objects in a JSON settings file

@Suite("Client configuration · lists of objects")
struct ClientConfigurationObjectListTests {
    static func edit(_ value: ClientConfigurationEdit.Value) -> ClientConfigurationEdit {
        .init(file: .claudeSettings, keyPath: ["deniedMcpServers"], value: value)
    }

    @Test func anEntryIsAddedOnceAndTheListIsMadeIfMissing() throws {
        let add = Self.edit(.appendObjectToList(field: "serverName", value: "claude.ai Gmail"))
        let once = try ClientConfigurationEditor.apply(add, to: "")
        let twice = try ClientConfigurationEditor.apply(add, to: once)
        #expect(once == twice)
        #expect(once.contains(#""serverName" : "claude.ai Gmail""#))
    }

    @Test func removingTakesOnlyTheExactSingleFieldEntry() throws {
        let text =
            #"{"deniedMcpServers":[{"serverName":"claude.ai Gmail"},{"serverName":"claude.ai Gmail","why":"x"},{"serverName":"filesystem"},"claude.ai Gmail"]}"#
        let result = try ClientConfigurationEditor.apply(
            Self.edit(.removeObjectFromList(field: "serverName", value: "claude.ai Gmail")), to: text)
        let list = try #require(
            (try JSONSerialization.jsonObject(with: Data(result.utf8)) as? [String: Any])?["deniedMcpServers"] as? [Any])
        #expect(list.count == 3)
        #expect((list.first as? [String: String]) == ["serverName": "claude.ai Gmail", "why": "x"])
    }

    @Test func aKeyThatIsNotAListIsRefused() {
        #expect(throws: ClientConfigurationEditError.notAList("deniedMcpServers")) {
            _ = try ClientConfigurationEditor.apply(
                Self.edit(.appendObjectToList(field: "serverName", value: "x")), to: #"{"deniedMcpServers":"all"}"#)
        }
    }

    @Test func aTOMLFileNeverTakesAnObjectListEdit() {
        let edit = ClientConfigurationEdit(file: .codexConfig, keyPath: ["apps"], value: .appendObjectToList(field: "id", value: "x"))
        #expect(!edit.isSafe)
        #expect(throws: ClientConfigurationEditError.unsafeEdit) { _ = try ClientConfigurationEditor.apply(edit, to: "") }
    }

    @Test func anObjectListEditTravelsAsAReviewedStep() throws {
        let edit = Self.edit(.removeObjectFromList(field: "serverName", value: "claude.ai Gmail"))
        #expect(try ClientConfigurationEdit.decode(try edit.encoded()) == edit)
        #expect(edit.summary == #"Take {"serverName": "claude.ai Gmail"} out of deniedMcpServers in .claude/settings.json"#)
        #expect(!Self.edit(.appendObjectToList(field: "server\"Name", value: "x")).isSafe)
    }
}

// MARK: - End to end, through the engine

@Suite("Accounts · applying through the operation engine")
struct AccountPreferenceApplyTests {
    struct Fixture {
        let root: URL
        let home: URL
        let store: WorkspaceRevisionStore

        init() throws {
            root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
                .appending(path: "account-apply-\(UUID())", directoryHint: .isDirectory)
            home = root.appending(path: "home", directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
            let document = try WorkspaceDocumentCoding.seal(
                .init(
                    workspaceID: WorkspaceObjectID(), revision: .init(writerID: WorkspaceObjectID())))
            let device = DeviceWorkspaceState(workspaceID: document.workspaceID)
            store = try WorkspaceRevisionStore(
                containerRoot: root.appending(path: "workspace", directoryHint: .isDirectory),
                workspaceID: document.workspaceID, deviceID: device.deviceID)
            try store.initialize(document: document, device: device)
            try store.prepareManagedDirectories()
        }

        func remove() { try? FileManager.default.removeItem(at: root) }

        func trashedCopies(named name: String) -> [String] {
            let trash = store.rootURL.appending(path: "trash", directoryHint: .isDirectory)
            let stamps = (try? FileManager.default.contentsOfDirectory(at: trash, includingPropertiesForKeys: nil)) ?? []
            return stamps.compactMap { try? String(contentsOf: $0.appending(path: name), encoding: .utf8) }
        }
    }

    @Test func claudesSettingsAreEditedAndTheOriginalKept() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let settings = fixture.home.appending(path: ".claude/settings.json")
        try AccountSurfaceParsingTests.write(settings, #"{"theme":"dark","deniedMcpServers":[{"serverName":"filesystem"}]}"#)
        let original = try String(contentsOf: settings, encoding: .utf8)
        let plan = AccountPreferencePlanner.plan(
            preferences: AccountPreferencePlannerTests.preferences(
                (.init(.skillSync), .off), (.init(.plugin, subject: "notes"), .off), (.init(.connector, subject: "Gmail"), .off)),
            observation: AccountPreferencePlannerTests.claude(), configurationText: original)

        let receipt = await OperationExecutor(store: fixture.store, homeURL: fixture.home).execute(
            try plan.operationPlan(homeURL: fixture.home))
        #expect(receipt.results.count == 3)
        #expect(receipt.results.allSatisfy { $0.status == .succeeded }, "\(receipt.results.map(\.output))")

        let result = try AccountPreferencePlannerTests.object(String(contentsOf: settings, encoding: .utf8))
        #expect(result["theme"] as? String == "dark")
        #expect(result["syncClaudeAiSkills"] as? Bool == false)
        #expect((result["enabledPlugins"] as? [String: Bool]) == ["notes@synced": false])
        #expect((result["deniedMcpServers"] as? [[String: String]]) == [["serverName": "filesystem"], ["serverName": "claude.ai Gmail"]])
        #expect(fixture.trashedCopies(named: "settings.json").contains(original), "the file as it was is kept")

        // Planned again against the edited file, nothing is left to do.
        let again = AccountPreferencePlanner.plan(
            preferences: AccountPreferencePlannerTests.preferences(
                (.init(.skillSync), .off), (.init(.plugin, subject: "notes"), .off), (.init(.connector, subject: "Gmail"), .off)),
            observation: AccountPreferencePlannerTests.claude(file: [
                .init(.skillSync): .off, .init(.plugin, subject: "notes"): .off, .init(.connector, subject: "Gmail"): .off,
            ]),
            configurationText: try String(contentsOf: settings, encoding: .utf8))
        #expect(again.isEmpty && again.held.isEmpty)
    }

    @Test func codexsConfigurationIsEditedAndItsOtherTablesKept() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let config = fixture.home.appending(path: ".codex/config.toml")
        let original = "# Mine\nmodel = \"gpt-6\"\n\n[features]\nhooks = true\n\n[mcp_servers.docs]\ncommand = \"docs-mcp\"\n"
        try AccountSurfaceParsingTests.write(config, original)
        let plan = AccountPreferencePlanner.plan(
            preferences: AccountPreferencePlannerTests.preferences((.init(.apps), .off), (.init(.app, subject: "github"), .off)),
            observation: AccountPreferencePlannerTests.codex(), configurationText: original)

        let receipt = await OperationExecutor(store: fixture.store, homeURL: fixture.home).execute(
            try plan.operationPlan(homeURL: fixture.home))
        #expect(receipt.results.allSatisfy { $0.status == .succeeded }, "\(receipt.results.map(\.output))")
        let result = AccountPreferencePlannerTests.flat(try String(contentsOf: config, encoding: .utf8))
        #expect(result.hasPrefix("# Mine\nmodel = \"gpt-6\"\n"))
        #expect(result.contains("[features]\nhooks = true\napps = false"))
        #expect(result.contains("[mcp_servers.docs]\ncommand = \"docs-mcp\""))
        #expect(result.contains("[apps.github]\nenabled = false"))
        #expect(fixture.trashedCopies(named: "config.toml").contains(original))
    }
}
