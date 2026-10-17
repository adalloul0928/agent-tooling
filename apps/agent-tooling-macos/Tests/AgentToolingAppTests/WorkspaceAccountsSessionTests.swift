import Foundation
import SwiftUI
import Testing

@testable import AgentToolingApp
@testable import AgentToolingCore

/// Answers Claude from this fixture's own `~/.claude/settings.json`, the way
/// the real reader does, so applying a choice and reading again agree. ChatGPT
/// answers from a script.
final class SettingsFileAccountReader: AccountSurfaceReading, @unchecked Sendable {
    let home: URL
    let chatGPT: AccountObservation?
    private let lock = NSLock()
    private var count = 0

    init(home: URL, chatGPT: AccountObservation? = nil) {
        self.home = home
        self.chatGPT = chatGPT
    }

    var readCount: Int { lock.withLock { count } }

    static let items: [AccountItem] = [
        .init(
            provider: .claude, kind: .connector, key: "Gmail", name: "Gmail", state: .init(tone: .ready, label: "Connected"),
            setting: .connector),
        .init(
            provider: .claude, kind: .connector, key: "Google Calendar", name: "Google Calendar",
            state: .init(tone: .attention, label: "Needs sign-in on claude.ai"), setting: .connector),
        .init(provider: .claude, kind: .plugin, key: "design", name: "design", state: .init(tone: .ready, label: "On"), setting: .plugin),
        .init(provider: .claude, kind: .skill, key: "pdf", name: "pdf", state: .init(tone: .ready, label: "Synced")),
    ]

    func read(_ providers: [AccountProvider], depth: AccountSurfaceProbe.Depth, now: Date) async -> [AccountObservation] {
        lock.withLock { count += 1 }
        return providers.map { provider in
            switch provider {
            case .claude:
                let text = (try? String(contentsOf: home.appending(path: ".claude/settings.json"), encoding: .utf8)) ?? ""
                let file = ClaudeAccountParsing.settings(fromJSON: text).switches
                return AccountObservation(
                    provider: .claude, observedAt: now, clientVersion: "2.1.300",
                    signIn: .init(method: .subscription, email: "me@example.com", organizationID: "org-1", plan: "max"),
                    items: depth == .contents ? Self.items : [], switches: file, fileValues: file,
                    contentsRead: depth == .contents)
            case .chatGPT:
                var observation = chatGPT ?? AccountObservation(provider: .chatGPT, unavailableReason: "Codex was not found.")
                observation.observedAt = now
                return observation
            }
        }
    }
}

@Suite("Accounts · the session behind the tab")
@MainActor
struct WorkspaceAccountsSessionTests {
    static func write(_ url: URL, _ text: String) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }

    struct Opened: Sendable {
        private let lock = NSLock()
        private let box = Box()
        final class Box: @unchecked Sendable { var urls: [URL] = [] }
        func record(_ url: URL) { lock.withLock { box.urls.append(url) } }
        var urls: [URL] { lock.withLock { box.urls } }
    }

    @MainActor struct Fixture {
        let shell: ShellRenderFixture
        let reader: SettingsFileAccountReader
        let session: WorkspaceAccountsSession
        let opened = Opened()

        init(chatGPT: AccountObservation? = nil, codexInstalled: Bool = false) async throws {
            let probe = SettingsFileAccountReader(home: URL(filePath: "/nonexistent"))
            shell = try await ShellRenderFixture(
                deviceObserver: StubDeviceObserver(observations: [
                    ShellRenderFixture.observation(.claudeCode, installed: true, commandAvailable: true, version: "2.1.300"),
                    ShellRenderFixture.observation(
                        .codexCLI, installed: codexInstalled, commandAvailable: codexInstalled, version: "0.162.1"),
                ]),
                accountReader: probe)
            reader = SettingsFileAccountReader(home: shell.home, chatGPT: chatGPT)
            let opened = self.opened
            session = WorkspaceAccountsSession(
                library: shell.workspace.library, device: shell.workspace.device, service: shell.workspace.service,
                store: shell.store, sync: nil, homeRoot: shell.home, reader: reader,
                openURL: { opened.record($0) })
        }

        var settingsURL: URL { shell.home.appending(path: ".claude/settings.json") }

        func settings() throws -> [String: Any] {
            let text = try String(contentsOf: settingsURL, encoding: .utf8)
            return try #require(try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
        }

        func remove() { shell.remove() }
    }

    @Test func eachManagedAccountIsReadOnceAndClaudeComesFirst() async throws {
        let fixture = try await Fixture()
        defer { fixture.remove() }
        #expect(fixture.session.providers == [.claude, .chatGPT])
        await fixture.session.read()
        #expect(fixture.reader.readCount == 1)
        #expect(fixture.session.observation(.claude)?.items.count == 4)
        #expect(fixture.session.observation(.chatGPT)?.unavailableReason == "Codex was not found.")
        #expect(fixture.session.plan(.claude)?.isEmpty == true, "nothing is shared yet")
        await fixture.session.readIfNeverRead(depth: .signInOnly)
        #expect(fixture.reader.readCount == 1, "Checkup reuses a reading it already has")
    }

    @Test func anAccountWhoseAppIsNotManagedIsNotRead() async throws {
        let fixture = try await Fixture()
        defer { fixture.remove() }
        await fixture.shell.workspace.device.setEnabled(.codex, false)
        #expect(fixture.session.providers == [.claude])
        await fixture.session.read()
        #expect(fixture.session.observation(.chatGPT) == nil)
    }

    /// Choosing records the choice in the portable document, for every Mac,
    /// and changes no file here until the plan it leaves is reviewed.
    @Test func aChoiceIsRecordedForEveryMacAndChangesNoFileYet() async throws {
        let fixture = try await Fixture()
        defer { fixture.remove() }
        await fixture.session.read()
        let saved = await fixture.session.setChoice(.init(.connector, subject: "Gmail"), to: .off)
        #expect(saved)
        #expect(fixture.session.sharedValue(.init(.connector, subject: "Gmail")) == .off)
        let document = try #require(fixture.shell.workspace.library.state?.snapshot.document)
        #expect(document.schemaVersion == 6)
        #expect(document.accountPreferences?.entries == [.init(.init(.connector, subject: "Gmail"), value: .off)])
        #expect(!FileManager.default.fileExists(atPath: fixture.settingsURL.path(percentEncoded: false)))
        let plan = try #require(fixture.session.plan(.claude))
        #expect(plan.changes.map(\.key) == [.init(.connector, subject: "Gmail")])
        #expect(
            fixture.session.findings.contains {
                $0.kind == .accountChoicesNotFollowed && $0.actions == [.applyAccountChoices(provider: .claude)]
            })
        #expect(fixture.session.attentionFindings.contains { $0.kind == .accountChoicesNotFollowed })

        #expect(await fixture.session.setChoice(.init(.connector, subject: "Gmail"), to: nil))
        #expect(fixture.session.plan(.claude)?.isEmpty == true, "letting it go leaves nothing to apply")
    }

    @Test func applyingWritesTheReviewedEditAndThenFollows() async throws {
        let fixture = try await Fixture()
        defer { fixture.remove() }
        try Self.write(fixture.settingsURL, #"{"theme":"dark"}"#)
        await fixture.session.read()
        await fixture.session.setChoice(.init(.skillSync), to: .off)
        await fixture.session.setChoice(.init(.plugin, subject: "design"), to: .off)
        let reviewed = try #require(fixture.session.plan(.claude))
        #expect(fixture.session.operationPlan(.claude)?.steps.count == 2)

        let message = try #require(await fixture.session.apply(.claude, reviewed: reviewed))
        #expect(message.contains("2 shared choices"))
        #expect(fixture.session.errorMessage == nil)
        let settings = try fixture.settings()
        #expect(settings["theme"] as? String == "dark")
        #expect(settings["syncClaudeAiSkills"] as? Bool == false)
        #expect((settings["enabledPlugins"] as? [String: Bool]) == ["design@synced": false])
        #expect(fixture.session.plan(.claude)?.isEmpty == true, "read again, this Mac follows")
        #expect(!fixture.session.findings.contains { $0.kind == .accountChoicesNotFollowed })
    }

    /// What runs is what was shown: a choice saved after the review (here, or
    /// arriving from another Mac) means reviewing again.
    @Test func aPlanThatChangedAfterReviewIsNotRun() async throws {
        let fixture = try await Fixture()
        defer { fixture.remove() }
        await fixture.session.read()
        await fixture.session.setChoice(.init(.skillSync), to: .off)
        let reviewed = try #require(fixture.session.plan(.claude))
        await fixture.session.setChoice(.init(.pluginSync), to: .off)

        #expect(await fixture.session.apply(.claude, reviewed: reviewed) == nil)
        #expect(fixture.session.errorMessage?.contains("changed since you reviewed it") == true)
        #expect(!FileManager.default.fileExists(atPath: fixture.settingsURL.path(percentEncoded: false)))
    }

    /// A file that can no longer be read once the change was reviewed, here
    /// one grown past the size limit, holds the change when the plan is made
    /// again to apply it. That is a refusal with the read's own reason, not
    /// "already follows", and nothing is written.
    @Test func aReviewedChangeWhoseFileCanNoLongerBeReadIsRefused() async throws {
        let fixture = try await Fixture()
        defer { fixture.remove() }
        try Self.write(fixture.settingsURL, #"{"theme":"dark"}"#)
        await fixture.session.read()
        await fixture.session.setChoice(.init(.skillSync), to: .off)
        let reviewed = try #require(fixture.session.plan(.claude))
        #expect(reviewed.changes.count == 1)
        try Self.growPastTheConfigurationLimit(fixture.settingsURL)
        let before = try Data(contentsOf: fixture.settingsURL)

        #expect(await fixture.session.apply(.claude, reviewed: reviewed) == nil)
        #expect(fixture.session.lastApplyMessage == nil)
        #expect(fixture.session.errorMessage?.contains("4 MB limit") == true, "\(fixture.session.errorMessage ?? "no error")")
        #expect(try Data(contentsOf: fixture.settingsURL) == before)
    }

    /// Checkup applies the plan it showed without passing it back. The same
    /// refusal reaches it, so its step fails with the reason instead of
    /// reporting a choice followed.
    @Test func applyingFromCheckupAfterTheFileBecameUnreadableIsRefused() async throws {
        let fixture = try await Fixture()
        defer { fixture.remove() }
        try Self.write(fixture.settingsURL, #"{"theme":"dark"}"#)
        await fixture.session.read()
        await fixture.session.setChoice(.init(.skillSync), to: .off)
        try Self.growPastTheConfigurationLimit(fixture.settingsURL)

        #expect(await fixture.session.apply(.claude) == nil)
        #expect(fixture.session.errorMessage?.contains("4 MB limit") == true, "\(fixture.session.errorMessage ?? "no error")")
    }

    /// Rewrites the settings file with a value long enough to put it past the
    /// limit every client configuration read shares, so the next read of it
    /// refuses it.
    private static func growPastTheConfigurationLimit(_ url: URL) throws {
        let padding = String(repeating: "x", count: BoundedFileAccess.maximumConfigurationBytes)
        try Self.write(url, #"{"theme":"dark","padding":"\#(padding)"}"#)
    }

    @Test func applyingWithNothingToDoSaysSo() async throws {
        let fixture = try await Fixture()
        defer { fixture.remove() }
        await fixture.session.read()
        let message = await fixture.session.apply(.claude)
        #expect(message?.contains("already follows") == true)
    }

    /// The first Mac set up by hand can hand its settings to the others.
    @Test func thisMacsOwnSettingsCanBeShared() async throws {
        let fixture = try await Fixture()
        defer { fixture.remove() }
        try Self.write(
            fixture.settingsURL,
            """
            {"syncClaudeAiPlugins": false,
             "enabledPlugins": {"notes@synced": false, "tool@vendor": false},
             "deniedMcpServers": [{"serverName": "claude.ai Gmail"}, {"serverName": "filesystem"}]}
            """)
        await fixture.session.read()
        let shareable = fixture.session.shareableSettings(.claude)
        #expect(
            shareable == [
                .init(.init(.pluginSync), value: .off),
                .init(.init(.plugin, subject: "notes"), value: .off),
                .init(.init(.connector, subject: "Gmail"), value: .off),
            ])
        #expect(await fixture.session.shareThisMacsSettings(.claude))
        #expect(fixture.session.preferences.entries.count == 3)
        #expect(fixture.session.shareableSettings(.claude).isEmpty)
        #expect(fixture.session.plan(.claude)?.isEmpty == true, "this Mac already follows what it shared")
        #expect(await fixture.session.shareThisMacsSettings(.claude) == false, "nothing left to share")
    }

    @Test func whatThisMacPublishesIsTheSummaryOfWhatItCouldRead() async throws {
        let fixture = try await Fixture()
        defer { fixture.remove() }
        await fixture.session.read()
        let summaries = fixture.session.publishedSummaries()
        #expect(summaries.map(\.provider) == [.claude], "an account that could not be read publishes nothing")
        #expect(summaries.first?.signInMethod == .subscription)
        #expect(summaries.first?.accountFingerprint != nil)
        #expect(summaries.first?.count(of: .connector) == 2)
        #expect(summaries.first?.switchesOutOfStep == 0)
    }

    @Test func theVendorsPagesOpenWithoutTouchingAFile() async throws {
        let fixture = try await Fixture()
        defer { fixture.remove() }
        await fixture.session.read()
        fixture.session.openSite(.claude, kind: .connector)
        let item = try #require(fixture.session.observation(.claude)?.items.first)
        fixture.session.open(item)
        #expect(
            fixture.opened.urls.map(\.absoluteString) == [
                "https://claude.ai/customize/connectors", "https://claude.ai/customize/connectors",
            ])
    }

    func checkup(_ fixture: Fixture) async throws -> [SetupFinding] {
        let setup = WorkspaceSetupSession(
            service: fixture.shell.workspace.service, library: fixture.shell.workspace.library,
            device: fixture.shell.workspace.device, insights: fixture.shell.workspace.insights,
            store: fixture.shell.store, homeRoot: fixture.shell.home, services: StubSetupServices(),
            accounts: fixture.session)
        await setup.audit()
        return try #require(setup.checkup?.audit.findings)
    }

    /// Checkup gets the same findings as the tab, from the same reading.
    @Test func checkupIncludesTheAccountFindings() async throws {
        let fixture = try await Fixture(
            chatGPT: AccountObservation(provider: .chatGPT, signIn: .init(method: .thirdParty, provider: "bedrock")),
            codexInstalled: true)
        defer { fixture.remove() }
        let findings = try await checkup(fixture)
        #expect(findings.contains { $0.kind == .accountSignIn && $0.client == .codex })
        #expect(!findings.contains { $0.kind == .accountSignIn && $0.client == .claude })
        #expect(!findings.contains { $0.kind == .accountConnectorNeedsSignIn }, "a light read never claims a connector's state")
        #expect(fixture.reader.readCount == 1)
    }

    /// An app this Mac does not have is not one Checkup asks to sign in.
    @Test func anAppThatIsNotInstalledRaisesNoAccountFinding() async throws {
        let fixture = try await Fixture(
            chatGPT: AccountObservation(provider: .chatGPT, signIn: .init(method: .thirdParty, provider: "bedrock")),
            codexInstalled: false)
        defer { fixture.remove() }
        let findings = try await checkup(fixture)
        #expect(!findings.contains { $0.client == .codex && $0.kind == .accountSignIn })
    }
}

// MARK: - Checkup rows

@Suite("Accounts · Checkup rows")
struct AccountCheckupTriageTests {
    static func finding(_ kind: SetupFinding.Kind, _ client: ClientKind, actions: [SetupAction], severity: SetupFinding.Severity = .low)
        -> SetupFinding
    {
        SetupFinding(
            kind: kind, severity: severity, client: client, subject: client.rawValue, title: "t", detail: "d", evidence: [],
            actions: actions)
    }

    @Test func choicesThatCanBeAppliedAreAFixWithAnApplyButton() throws {
        let checkup = SetupCheckup(
            audit: .init(
                clients: [.claude, .codex],
                findings: [
                    Self.finding(.accountChoicesNotFollowed, .claude, actions: [.applyAccountChoices(provider: .claude)])
                ], counts: [:]))
        let item = try #require(CheckupTriage.items(from: checkup).first)
        #expect(item.bucket == .fix)
        #expect(item.primaryTitle == "Apply")
        #expect(item.changesFiles)
        #expect(item.opens == .accounts)
    }

    @Test func choicesThatCannotBeAppliedOpenTheTab() throws {
        let checkup = SetupCheckup(
            audit: .init(
                clients: [.claude],
                findings: [
                    Self.finding(.accountChoicesNotFollowed, .claude, actions: [.openAccounts(provider: .claude)])
                ], counts: [:]))
        let item = try #require(CheckupTriage.items(from: checkup).first)
        #expect(item.bucket == .decide)
        #expect(item.primaryTitle == "Open Accounts")
        #expect(!item.changesFiles)
    }

    @Test(arguments: [SetupFinding.Kind.accountSignIn, .accountShellOverride, .accountDiffersFromOtherMacs, .accountConnectorNeedsSignIn])
    func whatIsChangedOutsideTheAppIsTheirsToDecide(kind: SetupFinding.Kind) throws {
        let checkup = SetupCheckup(
            audit: .init(
                clients: [.claude, .codex],
                findings: [
                    Self.finding(kind, .claude, actions: [.openAccounts(provider: .claude)], severity: .medium),
                    Self.finding(kind, .codex, actions: [.openAccounts(provider: .chatGPT)], severity: .medium),
                ], counts: [:]))
        let items = CheckupTriage.items(from: checkup)
        #expect(items.count == 2, "grouped per app")
        #expect(items.allSatisfy { $0.bucket == .decide && $0.opens == .accounts && !$0.changesFiles })
        #expect(!CheckupTriage.groupTitle(kind, count: 2).isEmpty)
        #expect(!CheckupTriage.groupDetail(kind, client: .claude).isEmpty)
    }
}

// MARK: - The screen

@Suite("Apps · Accounts renders")
@MainActor
struct AccountsSectionRenderTests {
    private func render(_ fixture: ShellRenderFixture) -> some View {
        AccountsView(session: fixture.workspace.accounts, library: fixture.workspace.library)
            .environment(\.workspaceSelection, AppSection.accounts)
            .environment(\.workspaceNavigate, { _ in })
            .frame(width: shellWindowSize.width, height: shellWindowSize.height)
    }

    static func claude(items: [AccountItem]) -> AccountObservation {
        AccountObservation(
            provider: .claude, clientVersion: "2.1.300",
            signIn: .init(method: .subscription, email: "me@example.com", organizationName: "Example", plan: "max"),
            items: items, fileValues: [.init(.skillSync): .off], contentsRead: true)
    }

    @Test func bothAccountsDrawWithTheirContents() async throws {
        let reader = StubAccountReader(answers: [
            .claude: Self.claude(items: SettingsFileAccountReader.items),
            .chatGPT: AccountObservation(
                provider: .chatGPT, clientVersion: "0.162.1", signIn: .init(method: .subscription, plan: "plus"),
                items: [
                    .init(
                        provider: .chatGPT, kind: .app, key: "github", name: "GitHub", state: .init(tone: .ready, label: "On"),
                        setting: .app)
                ],
                directoryCount: 12, contentsRead: true),
        ])
        let fixture = try await ShellRenderFixture(accountReader: reader)
        defer { fixture.remove() }
        await fixture.workspace.accounts.read()
        await fixture.workspace.accounts.setChoice(.init(.connector, subject: "Gmail"), to: .off)
        try expectDrawn(render(fixture))
        try expectDrawn(renderShell(.accounts, fixture: fixture))
    }

    @Test func aMacSignedInAnotherWayDrawsItsBanner() async throws {
        let reader = StubAccountReader(answers: [
            .claude: AccountObservation(
                provider: .claude, signIn: .init(method: .thirdParty, provider: "bedrock"),
                shellOverrides: [.claudeBedrock])
        ])
        let fixture = try await ShellRenderFixture(accountReader: reader)
        defer { fixture.remove() }
        await fixture.workspace.accounts.read()
        try expectDrawn(render(fixture))
    }

    @Test func noManagedAccountDrawsTheEmptyState() async throws {
        let fixture = try await ShellRenderFixture()
        defer { fixture.remove() }
        await fixture.workspace.device.setEnabled(.claude, false)
        await fixture.workspace.device.setEnabled(.codex, false)
        #expect(fixture.workspace.accounts.providers.isEmpty)
        try expectDrawn(render(fixture))
    }

    @Test func accountsThatCouldNotBeReadDrawTheirReason() async throws {
        let fixture = try await ShellRenderFixture()
        defer { fixture.remove() }
        await fixture.workspace.accounts.read()
        #expect(fixture.workspace.accounts.observation(.claude)?.unavailableReason == "Not read in tests.")
        try expectDrawn(render(fixture))
    }

    @Test func theLibraryStripDraws() async throws {
        let reader = StubAccountReader(answers: [.claude: Self.claude(items: SettingsFileAccountReader.items)])
        let fixture = try await ShellRenderFixture(accountReader: reader)
        defer { fixture.remove() }
        await fixture.workspace.accounts.read()
        for kinds: [AccountItemKind] in [[.skill], [.plugin], [.connector, .app]] {
            try expectDrawn(
                AccountContentsStrip(session: fixture.workspace.accounts, kinds: kinds)
                    .environment(\.workspaceNavigate, { _ in })
                    .frame(width: 600))
        }
    }
}

// MARK: - Reads that overlap

/// Holds every light read until released, so a test can start a second read
/// while the first is still running.
final class GatedAccountReader: AccountSurfaceReading, @unchecked Sendable {
    let started: AsyncStream<Void>
    private let startedContinuation: AsyncStream<Void>.Continuation
    private let lock = NSLock()
    private var waiting: [CheckedContinuation<Void, Never>] = []
    private var isOpen = false
    private var reads: [AccountSurfaceProbe.Depth] = []

    init() { (started, startedContinuation) = AsyncStream.makeStream() }

    var depths: [AccountSurfaceProbe.Depth] { lock.withLock { reads } }

    func open() {
        let released = lock.withLock { () -> [CheckedContinuation<Void, Never>] in
            isOpen = true
            defer { waiting = [] }
            return waiting
        }
        for continuation in released { continuation.resume() }
    }

    func read(_ providers: [AccountProvider], depth: AccountSurfaceProbe.Depth, now: Date) async -> [AccountObservation] {
        lock.withLock { reads.append(depth) }
        if depth == .signInOnly {
            startedContinuation.yield()
            await withCheckedContinuation { continuation in
                let resumeNow = lock.withLock { () -> Bool in
                    if isOpen { return true }
                    waiting.append(continuation)
                    return false
                }
                if resumeNow { continuation.resume() }
            }
        }
        return providers.map {
            AccountObservation(provider: $0, observedAt: now, signIn: .init(method: .subscription), contentsRead: depth == .contents)
        }
    }
}

@Suite("Accounts · reads that overlap")
@MainActor
struct AccountReadOverlapTests {
    /// Checkup's light read can still be running when the tab opens. The tab
    /// waits for it and then reads the contents, instead of skipping the
    /// accounts that were busy and showing them empty.
    @Test func theTabsFirstReadWaitsForCheckupsAndThenReadsContents() async throws {
        let reader = GatedAccountReader()
        let fixture = try await ShellRenderFixture(accountReader: reader)
        defer { fixture.remove() }
        let session = fixture.workspace.accounts
        let light = Task { await session.read([.claude], depth: .signInOnly) }
        for await _ in reader.started { break }
        #expect(session.isReading)

        let contents = Task { await session.readContentsIfMissing() }
        for _ in 0..<5 { await Task.yield() }
        #expect(reader.depths == [.signInOnly], "nothing starts beside the read in flight")

        reader.open()
        await light.value
        await contents.value
        #expect(reader.depths == [.signInOnly, .contents])
        #expect(session.providers.allSatisfy { session.observation($0)?.contentsRead == true })
        #expect(!session.isReading)
    }

    @Test func checkupUsesAReadAlreadyRunning() async throws {
        let reader = GatedAccountReader()
        let fixture = try await ShellRenderFixture(accountReader: reader)
        defer { fixture.remove() }
        let session = fixture.workspace.accounts
        let first = Task { await session.read(depth: .signInOnly) }
        for await _ in reader.started { break }
        let second = Task { await session.readIfNeverRead(depth: .signInOnly) }
        for _ in 0..<5 { await Task.yield() }
        reader.open()
        await first.value
        await second.value
        #expect(reader.depths == [.signInOnly], "one read answers both")
        #expect(session.providers.allSatisfy { session.observation($0) != nil })
    }

    @Test func aVisitWithContentsAlreadyReadDoesNotReadAgain() async throws {
        let reader = GatedAccountReader()
        let fixture = try await ShellRenderFixture(accountReader: reader)
        defer { fixture.remove() }
        await fixture.workspace.accounts.read(depth: .contents)
        await fixture.workspace.accounts.readContentsIfMissing()
        #expect(reader.depths == [.contents])
    }
}
