import Foundation
import Testing

@testable import AgentToolingCore

@Suite("Accounts · the choices every Mac shares")
struct AccountPreferencesDocumentTests {
    // MARK: What a choice may say

    @Test func aChoiceNamesItsItemExactlyWhenItsSettingNeedsOne() throws {
        try AccountPreferences(entries: [
            .init(.init(.skillSync), value: .off),
            .init(.init(.plugin, subject: "design"), value: .off),
            .init(.init(.connector, subject: "Google Calendar"), value: .off),
            .init(.init(.app, subject: "google_drive"), value: .on),
            .init(.init(.approvalMode), value: .prompt),
            .init(.init(.approvalMode, subject: "github"), value: .approve),
        ]).validate()

        for invalid: AccountPreference in [
            .init(.init(.plugin), value: .off),  // a plugin choice must name the plugin
            .init(.init(.skillSync, subject: "pdf"), value: .off),  // an account-wide switch names nothing
            .init(.init(.skillSync), value: .prompt),  // not a value this switch takes
            .init(.init(.approvalMode), value: .off),
            .init(.init(.plugin, subject: "design@synced"), value: .off),  // the name, not the id
            .init(.init(.connector, subject: "Name \"with\" quotes"), value: .off),
            .init(.init(.connector, subject: " padded"), value: .off),
            .init(.init(.app, subject: "_default"), value: .off),  // reserved by Codex
            .init(.init(.app, subject: "google drive"), value: .off),  // not a bare TOML key
            .init(.init(.app, subject: "drive.files"), value: .off),
            .init(provider: .claude, setting: .app, subject: "github", value: .off),  // wrong provider
        ] {
            #expect(throws: WorkspaceDomainValidationError.self, "\(invalid)") {
                try AccountPreferences(entries: [invalid]).validate()
            }
        }
    }

    @Test func anItemOffersAChoiceOnlyWhenItsNameCanBeSaved() {
        func item(_ provider: AccountProvider, _ key: String, _ setting: AccountSetting?) -> AccountItem {
            .init(provider: provider, kind: .connector, key: key, name: key, state: .init(tone: .ready, label: "On"), setting: setting)
        }
        #expect(item(.claude, "Gmail", .connector).preferenceKey == .init(.connector, subject: "Gmail"))
        #expect(item(.chatGPT, "github", .app).preferenceKey == .init(.app, subject: "github"))
        #expect(item(.claude, "Say \"hi\"", .connector).preferenceKey == nil)
        #expect(item(.chatGPT, "google drive", .app).preferenceKey == nil)
        #expect(item(.claude, "pdf", nil).preferenceKey == nil, "a synced skill has no switch of its own")
        #expect(item(.claude, "Gmail", .skillSync).preferenceKey == nil, "an account-wide switch is not an item's")
        #expect(item(.claude, "github", .app).preferenceKey == nil, "another account's setting")
    }

    @Test func oneSwitchHoldsOneChoice() {
        let preferences = AccountPreferences(entries: [
            .init(.init(.skillSync), value: .off), .init(.init(.skillSync), value: .on),
        ])
        #expect(throws: WorkspaceDomainValidationError.duplicate("account preference")) { try preferences.validate() }
    }

    @Test func aSwitchKeyHasOneStableIdentity() {
        let calendar = AccountPreferenceKey(.connector, subject: "Google Calendar")
        #expect(calendar.objectID == AccountPreferenceKey(.connector, subject: "Google Calendar").objectID)
        #expect(calendar.objectID != AccountPreferenceKey(.connector, subject: "Gmail").objectID)
        #expect(calendar.objectID != AccountPreferenceKey(.plugin, subject: "Google Calendar").objectID)
        #expect(AccountPreferenceKey(.approvalMode).objectID != AccountPreferenceKey(.approvalMode, subject: "").objectID)
        // UUIDv8, RFC 4122 variant: lowercase and canonical, like every other ID.
        let text = calendar.objectID.rawValue.uuidString
        #expect(text[text.index(text.startIndex, offsetBy: 14)] == "8")
    }

    // MARK: The portable document

    static func document(schema: UInt = PortableWorkspaceDocument.currentSchemaVersion, preferences: AccountPreferences? = nil) -> PortableWorkspaceDocument {
        PortableWorkspaceDocument(
            schemaVersion: schema, minimumReaderVersion: schema, minimumWriterVersion: schema,
            workspaceID: WorkspaceObjectID(), revision: .init(writerID: WorkspaceObjectID()),
            accountPreferences: preferences)
    }

    @Test func choicesRoundTripCanonicallyInSchemaSix() throws {
        let preferences = AccountPreferences(entries: [
            .init(.init(.plugin, subject: "zeta"), value: .off),
            .init(.init(.app, subject: "github"), value: .off),
            .init(.init(.skillSync), value: .off),
        ])
        let sealed = try WorkspaceDocumentCoding.seal(Self.document(preferences: preferences))
        #expect(sealed.schemaVersion == 6)
        let decoded = try WorkspaceDocumentCoding.decode(WorkspaceDocumentCoding.encode(sealed))
        #expect(decoded == sealed)
        #expect(decoded.accountPreferences?.entries.map(\.key) == [
            .init(.skillSync), .init(.plugin, subject: "zeta"), .init(.app, subject: "github"),
        ], "sorted by provider, then setting, then item")
    }

    @Test func aSchemaSixDocumentAlwaysCarriesTheRecord() throws {
        #expect(Self.document().accountPreferences == AccountPreferences(), "an explicit empty record")
        var missing = Self.document()
        missing.accountPreferences = nil
        #expect(throws: WorkspaceDomainValidationError.self) { try missing.validateStructure() }
    }

    @Test func anOlderSchemaCannotCarryChoices() throws {
        let older = Self.document(schema: 5)
        #expect(older.accountPreferences == nil)
        try older.validateStructure()
        var smuggled = older
        smuggled.accountPreferences = AccountPreferences(entries: [.init(.init(.skillSync), value: .off)])
        #expect(throws: WorkspaceDomainValidationError.self) { try smuggled.validateStructure() }
    }

    /// The field is left out of the digest when absent, so an older document's
    /// digest is exactly what an older build computed for it.
    @Test func anOlderDocumentDigestsWithoutTheField() throws {
        let older = try WorkspaceDocumentCoding.seal(Self.document(schema: 5))
        let text = String(decoding: try WorkspaceDocumentCoding.encode(older), as: UTF8.self)
        #expect(!text.contains("accountPreferences"))
        _ = try WorkspaceDocumentCoding.decode(Data(text.utf8))
    }

    @Test func raisingTheSchemaKeepsAnOlderDocumentValid() throws {
        var document = Self.document(schema: 3)
        try document.validateStructure()
        document.raiseToAccountPreferencesSchema()
        #expect(document.schemaVersion == 6 && document.minimumReaderVersion == 6 && document.minimumWriterVersion == 6)
        #expect(document.accountPreferences == AccountPreferences())
        try document.validateStructure()
    }

    // MARK: Saving a choice

    struct Store {
        let root: URL
        let store: WorkspaceRevisionStore
        let service: WorkspaceApplicationService

        init(schema: UInt) throws {
            root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
                .appending(path: "account-preferences-\(UUID())", directoryHint: .isDirectory)
            let document = try WorkspaceDocumentCoding.seal(AccountPreferencesDocumentTests.document(schema: schema))
            let device = DeviceWorkspaceState(workspaceID: document.workspaceID)
            store = try WorkspaceRevisionStore(
                containerRoot: root.appending(path: "store", directoryHint: .isDirectory),
                workspaceID: document.workspaceID, deviceID: device.deviceID)
            try store.initialize(document: document, device: device)
            service = WorkspaceApplicationService(store: store, writerID: WorkspaceObjectID())
        }

        func head() async throws -> PortableWorkspaceDocument {
            try #require(try await service.snapshot()).document
        }

        func remove() { try? FileManager.default.removeItem(at: root) }
    }

    /// The first choice on a workspace written before schema 6 raises it, in
    /// the same revision that records the choice.
    @Test func savingAChoiceRaisesAnOlderWorkspace() async throws {
        let fixture = try Store(schema: 5)
        defer { fixture.remove() }
        let before = try await fixture.head()
        #expect(before.schemaVersion == 5)
        let key = AccountPreferenceKey(.connector, subject: "Gmail")
        _ = try await fixture.service.setAccountPreferences(.init(
            expectedRevisionID: before.revision.id, changes: [.init(key: key, value: .off)]))
        let after = try await fixture.head()
        #expect(after.schemaVersion == 6)
        #expect(after.accountPreferences?.value(for: key) == .off)
        #expect(after.revision.parentIDs == [before.revision.id])
    }

    @Test func aChoiceIsReplacedOrLetGo() async throws {
        let fixture = try Store(schema: 6)
        defer { fixture.remove() }
        let skills = AccountPreferenceKey(.skillSync)
        let apps = AccountPreferenceKey(.apps)
        _ = try await fixture.service.setAccountPreferences(.init(
            expectedRevisionID: try await fixture.head().revision.id,
            changes: [.init(key: skills, value: .off), .init(key: apps, value: .on)]))
        _ = try await fixture.service.setAccountPreferences(.init(
            expectedRevisionID: try await fixture.head().revision.id,
            changes: [.init(key: skills, value: .on), .init(key: apps, value: nil)]))
        let preferences = try #require(try await fixture.head().accountPreferences)
        #expect(preferences.entries == [.init(skills, value: .on)])
    }

    @Test func repeatingACommandIsAnsweredFromItsReceipt() async throws {
        let fixture = try Store(schema: 6)
        defer { fixture.remove() }
        let command = SetAccountPreferencesCommand(
            expectedRevisionID: try await fixture.head().revision.id,
            changes: [.init(key: .init(.pluginSync), value: .off)])
        let first = try await fixture.service.setAccountPreferences(command)
        let second = try await fixture.service.setAccountPreferences(command)
        #expect(first == second)
        #expect(try await fixture.head().revision.id == first.committedRevisionID)
    }

    @Test func anInvalidOrEmptyCommandWritesNothing() async throws {
        let fixture = try Store(schema: 5)
        defer { fixture.remove() }
        let head = try await fixture.head().revision.id
        for changes: [SetAccountPreferencesCommand.Change] in [
            [],
            [.init(key: .init(.plugin, subject: "x@synced"), value: .off)],
            [.init(key: .init(.skillSync), value: .off), .init(key: .init(.skillSync), value: .on)],
        ] {
            await #expect(throws: (any Error).self) {
                _ = try await fixture.service.setAccountPreferences(.init(expectedRevisionID: head, changes: changes))
            }
        }
        let after = try await fixture.head()
        #expect(after.revision.id == head)
        #expect(after.schemaVersion == 5, "a refused command does not raise the schema either")
    }

    // MARK: Two Macs

    static func merge(
        base: [AccountPreference]?, local: [AccountPreference], remote: [AccountPreference]
    ) -> (WorkspaceMergeResult, base: PortableWorkspaceDocument, local: PortableWorkspaceDocument, remote: PortableWorkspaceDocument) {
        var ancestor = document(preferences: AccountPreferences(entries: base ?? []))
        var mine = ancestor
        mine.revision = .init(parentIDs: [ancestor.revision.id], writerID: WorkspaceObjectID())
        mine.accountPreferences = AccountPreferences(entries: local)
        var theirs = ancestor
        theirs.revision = .init(parentIDs: [ancestor.revision.id], writerID: WorkspaceObjectID())
        theirs.accountPreferences = AccountPreferences(entries: remote)
        if base == nil { ancestor = mine }
        let result = WorkspaceMergeEngine.merge(
            base: base == nil ? nil : ancestor, local: mine, remote: theirs, writerID: WorkspaceObjectID())
        return (result, ancestor, mine, theirs)
    }

    static let skillsOff = AccountPreference(.init(.skillSync), value: .off)
    static let skillsOn = AccountPreference(.init(.skillSync), value: .on)
    static let gmailOff = AccountPreference(.init(.connector, subject: "Gmail"), value: .off)

    @Test func aChoiceOnlyOneMacMadeIsTaken() {
        let (result, _, _, _) = Self.merge(base: [], local: [Self.skillsOff], remote: [Self.gmailOff])
        #expect(result.isResolved)
        #expect(result.document?.accountPreferences?.entries == [Self.skillsOff, Self.gmailOff])
    }

    @Test func theSameChoiceOnBothMacsIsSettled() {
        let (result, _, _, _) = Self.merge(base: [], local: [Self.skillsOff], remote: [Self.skillsOff])
        #expect(result.isResolved)
        #expect(result.document?.accountPreferences?.entries == [Self.skillsOff])
    }

    @Test func letGoOnOneMacAndUntouchedOnTheOtherIsLetGo() {
        let (result, _, _, _) = Self.merge(base: [Self.skillsOff], local: [], remote: [Self.skillsOff])
        #expect(result.isResolved)
        #expect(result.document?.accountPreferences?.entries.isEmpty == true)
    }

    @Test func twoDifferentChoicesAreThePersonsToMake() throws {
        let (result, _, _, _) = Self.merge(base: [], local: [Self.skillsOff], remote: [Self.skillsOn])
        let conflict = try #require(result.conflicts.first)
        #expect(result.conflicts.count == 1)
        #expect(conflict.kind == .accountPreference)
        #expect(conflict.objectID == AccountPreferenceKey(.skillSync).objectID)
        #expect(conflict.kind.isSettledByChoosingASide)
        #expect(result.document?.accountPreferences?.entries == [Self.skillsOff], "this Mac's value is kept meanwhile")
    }

    @Test func letGoAgainstChangedIsAlsoAConflict() {
        let changedThere = Self.merge(base: [Self.skillsOff], local: [], remote: [Self.skillsOn])
        #expect(changedThere.0.conflicts.map(\.kind) == [.accountPreference])
        #expect(changedThere.0.document?.accountPreferences?.entries.isEmpty == true)
        let changedHere = Self.merge(base: [Self.skillsOff], local: [Self.skillsOn], remote: [])
        #expect(changedHere.0.conflicts.map(\.kind) == [.accountPreference])
        #expect(changedHere.0.document?.accountPreferences?.entries == [Self.skillsOn])
    }

    @Test(arguments: [WorkspaceConflictChoice.keepLocal, .takeRemote])
    func choosingASideSettlesIt(choice: WorkspaceConflictChoice) throws {
        let (result, base, local, remote) = Self.merge(base: [], local: [Self.skillsOff], remote: [Self.skillsOn])
        let resolved = WorkspaceConflictResolver.resolve(
            base: base, local: local, remote: remote, conflicts: result.conflicts,
            resolutions: result.conflicts.map {
                .init(kind: $0.kind, artifactID: $0.artifactID, objectID: $0.objectID, choice: choice)
            },
            writerID: WorkspaceObjectID())
        #expect(resolved.isResolved)
        #expect(resolved.document?.accountPreferences?.entries == [choice == .keepLocal ? Self.skillsOff : Self.skillsOn])
    }

    @Test func choosingToTakeALetGoRemovesTheChoice() throws {
        let (result, base, local, remote) = Self.merge(base: [Self.skillsOff], local: [Self.skillsOn], remote: [])
        let resolved = WorkspaceConflictResolver.resolve(
            base: base, local: local, remote: remote, conflicts: result.conflicts,
            resolutions: result.conflicts.map { .init(kind: $0.kind, objectID: $0.objectID, choice: .takeRemote) },
            writerID: WorkspaceObjectID())
        #expect(resolved.isResolved)
        #expect(resolved.document?.accountPreferences?.entries.isEmpty == true)
    }

    /// A Mac that has not upgraded merges with one that has: the result is the
    /// newer schema, carrying the newer Mac's choices.
    @Test func anOlderMacsRevisionMergesIntoTheNewerSchema() throws {
        var older = Self.document(schema: 5)
        older.revision = .init(writerID: WorkspaceObjectID())
        var newer = older
        newer.raiseToAccountPreferencesSchema()
        newer.revision = .init(parentIDs: [older.revision.id], writerID: WorkspaceObjectID())
        newer.accountPreferences = AccountPreferences(entries: [Self.gmailOff])
        let result = WorkspaceMergeEngine.merge(base: older, local: older, remote: newer, writerID: WorkspaceObjectID())
        #expect(result.isResolved)
        #expect(result.document?.schemaVersion == 6)
        #expect(result.document?.accountPreferences?.entries == [Self.gmailOff])
    }

    // MARK: What other Macs are told

    static func observation(
        _ provider: AccountProvider = .claude, method: AccountSignIn.Method = .subscription,
        email: String? = "Me@Example.com", organization: String? = "org-1", contents: Bool = true
    ) -> AccountObservation {
        AccountObservation(
            provider: provider, observedAt: Date(timeIntervalSince1970: 1_700_000_000),
            signIn: .init(method: method, email: email, organizationID: organization, organizationName: "Example Org", plan: "max"),
            items: [
                .init(provider: provider, kind: .connector, key: "Gmail", name: "Gmail", state: .init(tone: .ready, label: "Connected")),
                .init(provider: provider, kind: .skill, key: "pdf", name: "pdf", state: .init(tone: .ready, label: "Synced")),
            ],
            contentsRead: contents, shellOverrides: [.anthropicAPIKey])
    }

    @Test func twoMacsOnOneAccountShareAFingerprint() {
        let workspace = WorkspaceObjectID()
        let here = PublishedAccountSummary.fingerprint(provider: .claude, signIn: Self.observation().signIn, workspaceID: workspace)
        let there = PublishedAccountSummary.fingerprint(
            provider: .claude, signIn: Self.observation(email: "  me@example.com ").signIn, workspaceID: workspace)
        #expect(here != nil)
        #expect(here == there, "an address differs only in case and spacing")
        #expect(here != PublishedAccountSummary.fingerprint(provider: .claude, signIn: Self.observation(organization: "org-2").signIn, workspaceID: workspace))
        #expect(here != PublishedAccountSummary.fingerprint(provider: .claude, signIn: Self.observation().signIn, workspaceID: WorkspaceObjectID()))
        #expect(here != PublishedAccountSummary.fingerprint(provider: .chatGPT, signIn: Self.observation().signIn, workspaceID: workspace))
        #expect(PublishedAccountSummary.fingerprint(provider: .claude, signIn: Self.observation(method: .apiKey).signIn, workspaceID: workspace) == nil)
        #expect(PublishedAccountSummary.fingerprint(provider: .claude, signIn: Self.observation(email: nil).signIn, workspaceID: workspace) == nil)
    }

    /// What travels to other Macs is the method, the plan, a digest and
    /// counts: never an address, an organization name, or a list of items.
    @Test func thePublishedStatusCarriesNoAddressOrList() throws {
        let workspace = WorkspaceObjectID()
        let summary = PublishedAccountSummary(observation: Self.observation(), workspaceID: workspace, switchesOutOfStep: 2)
        #expect(summary.count(of: .connector) == 1)
        #expect(summary.count(of: .plugin) == 0)
        #expect(summary.shellOverrides == ["ANTHROPIC_API_KEY"])
        let status = PublishedDeviceStatus(
            deviceID: WorkspaceObjectID(), name: "Studio", lastScan: nil, apps: [], pending: [],
            revisionID: WorkspaceObjectID(), accounts: [summary])
        let text = String(decoding: try AgentToolingCoding.encoder().encode(status), as: UTF8.self)
        for private_ in ["me@example.com", "Me@Example.com", "Example Org", "org-1", "Gmail", "pdf"] {
            #expect(!text.contains(private_), "\(private_) must not be published")
        }
        let decoded = try AgentToolingCoding.decoder().decode(PublishedDeviceStatus.self, from: Data(text.utf8))
        #expect(decoded.accounts == [summary])
    }

    @Test func aLightReadPublishesNoCounts() {
        let summary = PublishedAccountSummary(observation: Self.observation(contents: false), workspaceID: WorkspaceObjectID(), switchesOutOfStep: nil)
        #expect(summary.itemCounts == nil)
        #expect(summary.count(of: .connector) == nil)
    }

    /// A Mac that has not upgraded publishes no accounts, and a newer status
    /// still reads on it.
    @Test func statusesWithAndWithoutAccountsReadBothWays() throws {
        let bare = PublishedDeviceStatus(
            deviceID: WorkspaceObjectID(), name: "Old Mac", lastScan: nil, apps: [], pending: [], revisionID: WorkspaceObjectID())
        let text = String(decoding: try AgentToolingCoding.encoder().encode(bare), as: UTF8.self)
        #expect(!text.contains("accounts"))
        #expect(try AgentToolingCoding.decoder().decode(PublishedDeviceStatus.self, from: Data(text.utf8)).accounts == nil)
        #expect(PublishedDeviceStatus(
            deviceID: WorkspaceObjectID(), name: "x", lastScan: nil, apps: [], pending: [],
            revisionID: WorkspaceObjectID(), accounts: []).accounts == nil, "an empty list is not published")
    }
}
