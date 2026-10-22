import AgentToolingCore
import AgentToolingTestSupport
import Foundation
import Testing

@testable import AgentToolingApp

/// Home's Finish setting up card from hand-made facts: each row's predicate
/// on positive evidence only, ticks that latch, the record's order with one
/// capsule per row, the rows that are not counted, the chip, and Done and
/// Home counting alike.
@Suite("Finish setting up checklist", .timeLimit(.minutes(5)))
@MainActor
struct FinishSetupChecklistTests {
    private typealias Fixture = FinishSetupFixture

    // MARK: - The card after Done

    @Test func juniperReadsThreeOfSevenWithFourRowsOpen() throws {
        let record = Fixture.record(.juniper)
        let list = try #require(FinishSetupChecklist.make(Fixture.juniperFacts(record: record), now: Fixture.doneAt))

        #expect(list.title == "Finish setting up")
        #expect(list.done == 3)
        #expect(list.total == 7)
        #expect(list.filled == [true, true, true, false, false, false, false])
        #expect(list.lead == nil)
        #expect(list.extra == nil)
        #expect(
            list.rows.map(\.title) == [
                "Make your skills yours", "Put your tools in your apps", "Connect your other Macs",
                "Sign in to your connections", "Look at 4 things on Checkup", "Try Release Notes in Codex",
                "Track your projects",
            ])
        #expect(
            list.rows.map(\.caption) == [
                "Release Notes and Frontend Design · in setup", "Installed 4 changes · \(Fixture.installedTime) · in setup",
                "Synced just now · in setup", "Not checked yet · Sentry in Claude Code may need you to sign in",
                "Webapp Testing, Context7 and Playwright", "Checks apps first, then opens Terminal running",
                "4 folders Claude Code has worked in",
            ])
        #expect(list.rows[5].command == "codex $release-notes")
        #expect(list.rows.map(\.actionTitle) == [nil, nil, nil, "Check connections…", "Open Checkup", "Try it", "Open Projects"])
        #expect(
            list.rows.compactMap(\.action) == [
                .checkConnections, .openCheckup, .trySkill(Fixture.releaseNotesInCodex), .openProjects,
            ])
        #expect(list.rows.prefix(3).map(\.donePlace) == ["in setup", "in setup", "in setup"])
    }

    /// The ↩-through walk made nothing yours, installed Agent Tooling's own
    /// connection and skipped Other Macs: one row done of six.
    @Test func theReturnThroughCardIsOneOfSix() throws {
        let record = Fixture.record(.returnThrough)
        var facts = Fixture.returnThroughInputs().facts
        facts.record = record
        let list = try #require(FinishSetupChecklist.make(facts, now: Fixture.doneAt))

        #expect(list.done == 1)
        #expect(list.total == 6)
        #expect(
            record.items == [.putToolsInApps, .connectOtherMacs, .signInConnections, .lookAtCheckup, .trySkill, .trackProjects])
        #expect(list.rows[0].caption == "Installed 3 changes · \(Fixture.installedTime) · in setup")
        #expect(list.rows[1].actionTitle == "Connect…")
        #expect(FinishSetupChecklist.leftForLater(record) == [.signInConnections, .lookAtCheckup])
        #expect(FinishSetupChecklist.suggestions(record) == [.connectOtherMacs, .trySkill, .trackProjects])
    }

    /// S22's "Left for later · 2 · Home adds 2 suggestions" and P01's four
    /// open rows are one count.
    @Test func leftForLaterAndSuggestionsAgreeWithDone() throws {
        let record = Fixture.record(.juniper)
        let summary = LaunchpadDoneSummary(Fixture.juniperInputs())
        let list = try #require(FinishSetupChecklist.make(Fixture.juniperFacts(record: record), now: Fixture.doneAt))

        #expect(FinishSetupChecklist.leftForLater(record) == [.signInConnections, .lookAtCheckup])
        #expect(FinishSetupChecklist.suggestions(record) == [.trySkill, .trackProjects])
        #expect(summary.leftForLater.map(\.item) == FinishSetupChecklist.leftForLater(record))
        #expect(summary.suggestions == FinishSetupChecklist.suggestions(record).count)
        #expect(list.left == summary.leftForLater.count + summary.suggestions)
    }

    @Test func everyRowDoneReadsSetupFinished() throws {
        let record = Fixture.record(.allDone)
        let list = try #require(FinishSetupChecklist.make(Fixture.juniperFacts(record: record), now: Fixture.doneAt))

        #expect(list.title == "Setup finished")
        #expect(list.done == list.total)
        #expect(list.rows.allSatisfy { $0.isDone })
        #expect(list.rows.allSatisfy { $0.action == nil || $0.isDone })
    }

    // MARK: - When the card shows

    @Test func theCardShowsOnlyForAHandedOffRecordOnAWritableMac() {
        let finished = Fixture.record(.juniper)
        #expect(FinishSetupChecklist.isShown(finished, isWritable: true))
        // A workspace made before Launchpad has no record and no card.
        #expect(!FinishSetupChecklist.isShown(nil, isWritable: true))
        #expect(!FinishSetupChecklist.isShown(finished, isWritable: false))
        #expect(!FinishSetupChecklist.isShown(Fixture.record(.hidden), isWritable: true))
        // A first run still on the stage shows nothing on Home.
        #expect(!FinishSetupChecklist.isShown(Fixture.startedRecord(), isWritable: true))
        // A record a newer build wrote reads as finished and shows no card.
        var newer = finished
        newer.formatVersion = SetupProgressRecord.currentFormatVersion + 1
        #expect(!FinishSetupChecklist.isShown(newer, isWritable: true))
        #expect(FinishSetupChecklist.make(Fixture.juniperFacts(record: nil), now: Fixture.doneAt) == nil)
    }

    @Test func theChipCountsWhatIsLeftOnlyWhileTheCardIsHidden() {
        #expect(FinishSetupChecklist.chipLeft(Fixture.juniperFacts(record: Fixture.record(.hidden)), now: Fixture.doneAt) == 4)
        #expect(FinishSetupChecklist.chipLeft(Fixture.juniperFacts(record: Fixture.record(.juniper)), now: Fixture.doneAt) == nil)
        var allDone = Fixture.record(.allDone)
        allDone.hiddenAt = Fixture.doneAt
        #expect(FinishSetupChecklist.chipLeft(Fixture.juniperFacts(record: allDone), now: Fixture.doneAt) == nil)
        #expect(FinishSetupChecklist.chipLeft(Fixture.juniperFacts(record: nil), now: Fixture.doneAt) == nil)
    }

    /// A first run left for later leads with Resume, which is not counted,
    /// and reads its rows from the facts until Done fixes them.
    @Test func aSetupLeftForLaterLeadsWithResumeAndCountsItsRowsLive() throws {
        let record = Fixture.record(.deferred(.place))
        let list = try #require(FinishSetupChecklist.make(Fixture.juniperFacts(record: record), now: Fixture.doneAt))

        let lead = try #require(list.lead)
        #expect(lead.title == "Resume setup — next: Put your tools in your apps")
        #expect(lead.actionTitle == "Resume")
        #expect(lead.action == .resume(.place))
        #expect(lead.item == nil)
        #expect(!list.rows.contains { $0.item == nil })
        #expect(list.rows.first?.item == .makeSkillsYours)
        #expect(list.done == 0)
    }

    /// A join left at You joined resumes there, by J02's own title.
    @Test func aJoinLeftAtYouJoinedResumesThereByItsTitle() throws {
        var record = Fixture.record(.deferred(.arrivals))
        record.path = .join
        var facts = Fixture.juniperFacts(record: record)
        facts.deviceName = "Cedar"

        let lead = try #require(FinishSetupChecklist.make(facts, now: Fixture.doneAt)?.lead)
        #expect(lead.title == "Resume setup — next: You joined as Cedar")
        #expect(lead.action == .resume(.arrivals))
    }

    // MARK: - A setup left for later

    /// A setup left for later lists Agent Tooling's own connection on any
    /// Mac with an app that takes it, so connecting it, from the card's
    /// Connect… (which reopens the stage over the shell) or before, ticks
    /// the row where it happened: the total stays and the count only goes up.
    @Test func aDeferredCardTicksAgentToolingWhenItConnects() throws {
        let session = WorkspaceSetupProgressSession(store: StubSetupProgressStore(Fixture.record(.deferred(.ask))))
        var facts = Fixture.juniperFacts(record: session.record)
        facts.helperConnectedApps = []
        let before = try #require(FinishSetupChecklist.make(facts, now: Fixture.doneAt))
        let row = try #require(before.rows.first { $0.item == .connectAgentTooling })
        #expect(!row.isDone)
        #expect(row.action == .connectAgentTooling)

        facts.helperConnectedApps = [.codex, .claude]
        let ticks = FinishSetupTracker.ticks(
            FinishSetupChecklist.satisfied(facts), facts: facts, section: .overview, stagePresented: true, settled: true)
        #expect(ticks.contains { $0.item == .connectAgentTooling && $0.place == .setup })
        for (item, place) in ticks {
            session.tick(
                item, place: place, summary: FinishSetupChecklist.summary(for: item, facts: facts, now: Fixture.doneAt),
                now: Fixture.doneAt)
        }
        facts.record = session.record
        let after = try #require(FinishSetupChecklist.make(facts, now: Fixture.doneAt))

        #expect(after.total == before.total)
        #expect(after.done == before.done + ticks.count)
        #expect(after.rows.first { $0.item == .connectAgentTooling }?.caption == "Connected to Codex and Claude Code · in setup")
    }

    /// The tracker keeps the findings a setup left for later first shows,
    /// so dealing with every one of them ticks the Checkup row rather than
    /// taking it off the card.
    @Test func fixingEveryFindingTicksTheCheckupRowOfADeferredCard() throws {
        let session = WorkspaceSetupProgressSession(store: StubSetupProgressStore(Fixture.record(.deferred(.ask))))
        var facts = Fixture.juniperFacts(record: session.record)
        let kept = try #require(FinishSetupTracker.findingsToKeep(facts))
        #expect(kept == Fixture.juniperFindings.map(\.id))
        session.recordEvidence { $0.checkupFindingIDs = kept }
        facts.record = session.record
        // Kept once: a later look keeps them as they are.
        #expect(FinishSetupTracker.findingsToKeep(facts) == nil)
        let before = try #require(FinishSetupChecklist.make(facts, now: Fixture.doneAt))
        #expect(before.rows.first { $0.item == .lookAtCheckup }?.title == "Look at 4 things on Checkup")

        facts.openFindings = []
        let ticks = FinishSetupTracker.ticks(
            FinishSetupChecklist.satisfied(facts), facts: facts, section: .checkup, stagePresented: false, settled: true)
        let checkup = try #require(ticks.first { $0.item == .lookAtCheckup })
        session.tick(
            checkup.item, place: checkup.place,
            summary: FinishSetupChecklist.summary(for: checkup.item, facts: facts, now: Fixture.doneAt), now: Fixture.doneAt)
        facts.record = session.record
        let after = try #require(FinishSetupChecklist.make(facts, now: Fixture.doneAt))

        #expect(after.total == before.total)
        #expect(after.rows.first { $0.item == .lookAtCheckup }?.caption == "All looked at · from Checkup")
        // A finished setup keeps what Done kept, and the tracker keeps none.
        #expect(FinishSetupTracker.findingsToKeep(Fixture.juniperFacts(record: Fixture.record(.juniper))) == nil)
    }

    /// A ticked row stays on the card when its evidence goes: this launch's
    /// install results cleared by the next plan, a skill leaving the
    /// library.
    @Test func aTickedRowStaysWhenItsEvidenceGoes() throws {
        var record = Fixture.record(.deferred(.assistant))
        record.ticks = [
            .init(item: .putToolsInApps, place: .apps, at: Fixture.doneAt, summary: "Installed 4 changes · 9:52 AM"),
            .init(item: .makeSkillsYours, place: .setup, at: Fixture.doneAt, summary: "Release Notes"),
        ]
        var facts = Fixture.juniperFacts(record: record)
        facts.lastInstall = nil
        facts.pendingChanges = 0
        facts.personalSkills = []

        let list = try #require(FinishSetupChecklist.make(facts, now: Fixture.doneAt))
        #expect(list.rows.first { $0.item == .putToolsInApps }?.caption == "Installed 4 changes · 9:52 AM · from Apps")
        #expect(list.rows.first { $0.item == .makeSkillsYours }?.isDone == true)
        #expect(list.done == 2)
    }

    /// What a first run did before it was left for later it did in setup,
    /// except Agent Tooling's own connection before Let your apps ask was
    /// shown: that one was made elsewhere.
    @Test func theFirstLookTicksAgentToolingInSetupOnlyOnceLetYourAppsAskWasShown() {
        func place(_ cursor: LaunchpadStep) -> FinishSetupPlace {
            FinishSetupTracker.place(
                for: .connectAgentTooling, record: Fixture.record(.deferred(cursor)), section: .overview, stagePresented: false,
                settled: false)
        }
        #expect(place(.place) == .apps)
        #expect(place(.assistant) == .setup)
    }

    /// Agent Tooling's own connection is there only where the app holds it
    /// for the person, as the planner and Let your apps ask count it: its own
    /// configuration registers it for the whole account and its last check
    /// found it outside a plugin. One only a project names, or a plugin's of
    /// that name, is not it. The files are read once per check.
    @Test func agentToolingIsConnectedOnlyWhereTheAppHoldsItForThePerson() throws {
        let home = try FixtureHome("finish-setup-presence")
        defer { home.remove() }
        let name = AgentToolingConnection.declaredName
        try home.plant(
            ".claude.json", #"{"projects":{"/Users/example/work":{"mcpServers":{"agent-tooling":{"type":"stdio","command":"/x"}}}}}"#)
        try home.plant(".codex/config.toml", "[mcp_servers.agent-tooling]\ncommand = \"/x\"\n")
        let capabilities = TargetCapabilities(
            supportsPluginInstall: false, supportsProjectScope: false, supportsLocalMarketplace: false,
            supportsMCPAuthentication: false, supportsConnectorDiscovery: false, requiresNewSession: false, requiresRestart: false,
            supportsMachineReadableOutput: false)
        func observation(_ surface: TargetSurface, _ file: String, source: String, checkedAt: Date) -> TargetObservation {
            TargetObservation(
                surface: surface, installed: true, version: "1", configurationPaths: [home.appending(file).path(percentEncoded: false)],
                discoveredMCPServers: [name], mcpMetadata: [name: .init(transport: "stdio", authentication: "None", source: source)],
                capabilities: capabilities, lastScannedAt: checkedAt)
        }
        let codex = observation(.codexCLI, ".codex/config.toml", source: "Codex configuration", checkedAt: Fixture.doneAt)

        let projectOnly = observation(.claudeCode, ".claude.json", source: "Claude Code configuration", checkedAt: Fixture.doneAt)
        #expect(FinishSetupHelperPresence.apps(in: [projectOnly, codex]) == [.codex])

        try home.plant(".claude.json", #"{"mcpServers":{"agent-tooling":{"type":"stdio","command":"/x"}}}"#)
        let later = Fixture.doneAt.addingTimeInterval(60)
        let plugin = observation(.claudeCode, ".claude.json", source: "agent-tooling@somewhere", checkedAt: later)
        #expect(FinishSetupHelperPresence.apps(in: [plugin, codex]) == [.codex])
        let own = observation(.claudeCode, ".claude.json", source: "Claude Code configuration", checkedAt: later)
        #expect(FinishSetupHelperPresence.apps(in: [own, codex]) == [.codex, .claude])
    }

    /// A check that finds a sign-in only the connection's own app can run
    /// names it, rather than leaving the row looking done.
    @Test func aCheckThatFindsASignInOnlyItsAppCanRunNamesIt() throws {
        var facts = Fixture.juniperFacts(record: Fixture.record(.juniper))
        let gmail = FinishSetupFacts.Connection(name: "Gmail", serverID: "Gmail", client: .claude)
        facts.connectionCheck = .init(checkedAt: Fixture.doneAt, signInOffers: [], needsAuthentication: [gmail], connected: [])

        let row = try #require(FinishSetupChecklist.make(facts, now: Fixture.doneAt)?.rows.first { $0.item == .signInConnections })
        #expect(row.caption == "Checked · Gmail in Claude Code needs you to sign in from its app")
        #expect(row.action == .checkConnections)
        #expect(!FinishSetupChecklist.satisfied(facts).contains(.signInConnections))
    }

    /// A copy outside Applications adds Move, which is not counted either.
    /// A copy outside Applications adds Move, which is not counted either.
    @Test func aCopyOutsideApplicationsAddsMoveUncounted() throws {
        var facts = Fixture.juniperFacts(record: Fixture.record(.juniper))
        facts.offersMove = true
        let list = try #require(FinishSetupChecklist.make(facts, now: Fixture.doneAt))

        let move = try #require(list.extra)
        #expect(move.title == "Move Agent Tooling to Applications")
        #expect(move.actionTitle == "Move…")
        #expect(move.action == .moveToApplications)
        #expect(list.total == 7)
    }

    // MARK: - Predicates, on positive evidence only

    @Test func nothingIsDoneOnMissingData() {
        var facts = FinishSetupFacts(record: Fixture.record(.juniper))
        facts.managedClients = [.codex, .claude]
        // An unread library, no install this launch, no check of the apps
        // naming the helper, no pass, no connection check, no audit and no
        // project bound: nothing is known, so nothing is done.
        #expect(FinishSetupChecklist.satisfied(facts).isEmpty)
    }

    @Test func eachRowComesTrueOnItsOwnEvidence() {
        var facts = FinishSetupFacts(record: Fixture.record(.juniper))
        var expected: Set<FinishSetupItem> = []
        func check() { #expect(FinishSetupChecklist.satisfied(facts) == expected) }

        facts.personalSkills = [Fixture.releaseNotes]
        expected.insert(.makeSkillsYours)
        check()

        facts.lastInstall = .init(changes: 2, failures: 1)
        check()
        facts.lastInstall = .init(changes: 2, failures: 0)
        expected.insert(.putToolsInApps)
        check()

        facts.helperConnectedApps = [.claude]
        expected.insert(.connectAgentTooling)
        check()

        // Connected with no pass finished yet is not shared.
        facts.sync = .init(remote: Fixture.remote, lastSynced: nil)
        check()
        facts.sync = .init(remote: Fixture.remote, lastSynced: Fixture.syncedAt)
        expected.insert(.connectOtherMacs)
        check()

        facts.connectionCheck = .init(
            checkedAt: Fixture.doneAt, signInOffers: [Fixture.sentry], needsAuthentication: [Fixture.sentry], connected: [])
        check()
        facts.connectionCheck = .init(checkedAt: Fixture.doneAt, signInOffers: [], needsAuthentication: [], connected: [Fixture.sentry])
        expected.insert(.signInConnections)
        check()

        facts.openFindings = Fixture.juniperFindings
        check()
        facts.openFindings = []
        expected.insert(.lookAtCheckup)
        check()

        facts.trackedProjects = 1
        expected.insert(.trackProjects)
        check()
        // Trying a skill is ticked by the trial itself, never by a predicate.
        #expect(!FinishSetupChecklist.satisfied(facts).contains(.trySkill))
    }

    /// Codex reads every connection's status as unknown. An unknown status
    /// is neither a sign-in to offer nor one that needs authentication, so a
    /// check that found only those leaves the sign-in row done.
    @Test func codexsUnknownStatusesNeverHoldTheSignInRowOpen() async throws {
        let fixture = try await ShellRenderFixture()
        defer { fixture.remove() }
        let health = try await FinishSetupHealthCheck.checked(
            fixture: fixture, managing: [.codex],
            answers: [
                "codex mcp list --json":
                    #"[{"name":"linear","enabled":true,"transport":{"type":"streamable_http","url":"https://mcp.linear.app/mcp"}},{"name":"playwright","enabled":true,"transport":{"type":"stdio","command":"npx"}}]"#
            ])
        #expect(!health.entries.isEmpty)
        #expect(health.entries.allSatisfy { if case .unknown = $0.status { true } else { false } })

        var facts = FinishSetupFacts(record: Fixture.record(.juniper))
        facts.connectionCheck = FinishSetupFacts.connectionCheck(health, naming: facts)

        #expect(FinishSetupChecklist.satisfied(facts).contains(.signInConnections))
        #expect(health.needsYouCount == 0)
        #expect(health.attentionCount == health.entries.count)
    }

    /// On a join, the skills that came across from the other Mac were yours
    /// before this setup, so they never make "Make your skills yours" true;
    /// one made yours here does.
    @Test func skillsThatCameAcrossOnAJoinNeverTickMakeYourSkillsYours() {
        var record = Fixture.record(.deferred(.arrivals))
        record.path = .join
        record.evidence.personalSkillsBefore = [Fixture.releaseNotes.id, Fixture.frontendDesign.id]
        var facts = FinishSetupFacts(record: record)
        facts.personalSkills = [Fixture.releaseNotes, Fixture.frontendDesign]

        #expect(!FinishSetupChecklist.satisfied(facts).contains(.makeSkillsYours))
        #expect(!FinishSetupChecklist.items(facts, handOff: nil).contains(.makeSkillsYours))

        let dbMigrations = FinishSetupFacts.Skill(id: ArtifactID(), name: "Db Migrations", declaredName: "db-migrations")
        facts.personalSkills.append(dbMigrations)
        #expect(FinishSetupChecklist.satisfied(facts).contains(.makeSkillsYours))
        #expect(FinishSetupChecklist.summary(for: .makeSkillsYours, facts: facts, now: Fixture.doneAt) == "Db Migrations")
    }

    /// Checkup's row is done when none of the findings kept at hand-off is
    /// still open: fixed (gone from the audit) or dismissed alike.
    @Test func fixedOrDismissedFindingsCloseTheCheckupRow() {
        let record = Fixture.record(.juniper)
        #expect(record.evidence.checkupFindingIDs == Fixture.juniperFindings.map(\.id))
        var facts = Fixture.juniperFacts(record: record)
        #expect(!FinishSetupChecklist.satisfied(facts).contains(.lookAtCheckup))

        // Two fixed, two still open: the title counts what is left.
        facts.openFindings = Array(Fixture.juniperFindings.suffix(2))
        #expect(!FinishSetupChecklist.satisfied(facts).contains(.lookAtCheckup))
        let open = FinishSetupChecklist.make(facts, now: Fixture.doneAt)?.rows.first { $0.item == .lookAtCheckup }
        #expect(open?.title == "Look at 2 things on Checkup")
        #expect(open?.caption == "Context7 and Playwright")

        // A new finding Done never saw does not hold the row open.
        facts.openFindings = [.init(id: "new", kind: .unmanagedSkill, name: "Db Migrations", apps: [.claude], title: "")]
        #expect(FinishSetupChecklist.satisfied(facts).contains(.lookAtCheckup))
    }

    /// Projects tick only on a folder bound on this Mac: a logical project
    /// travels between Macs; a binding does not.
    @Test func projectsTickOnlyOnALocalRootBinding() {
        var facts = Fixture.juniperFacts(record: Fixture.record(.juniper))
        #expect(!FinishSetupChecklist.satisfied(facts).contains(.trackProjects))
        facts.trackedProjects = 1
        #expect(FinishSetupChecklist.satisfied(facts).contains(.trackProjects))
        #expect(FinishSetupChecklist.summary(for: .trackProjects, facts: facts, now: Fixture.doneAt) == "1 project tracked")
    }

    // MARK: - Ticks latch

    @Test func aTickLatchesAndTheRowStaysDone() async throws {
        let store = StubSetupProgressStore(Fixture.record(.juniper))
        let session = WorkspaceSetupProgressSession(store: store)
        session.tick(.lookAtCheckup, place: .checkup, summary: "All looked at", now: Fixture.doneAt)
        session.tick(.lookAtCheckup, place: .home, summary: "Again", now: Fixture.doneAt.addingTimeInterval(60))

        let record = try #require(session.record)
        #expect(record.ticks.filter { $0.item == .lookAtCheckup }.map(\.place) == [.checkup])
        // The finding coming back does not untick the row.
        var facts = Fixture.juniperFacts(record: record)
        facts.openFindings = Fixture.juniperFindings
        let row = FinishSetupChecklist.make(facts, now: Fixture.doneAt)?.rows.first { $0.item == .lookAtCheckup }
        #expect(row?.isDone == true)
        #expect(row?.caption == "All looked at · from Checkup")
        #expect(row?.title == "Look at 4 things on Checkup")
    }

    // MARK: - The tracker

    @Test func theTrackerNamesWhereARowCameTrue() {
        let record = Fixture.record(.juniper)
        func place(_ item: FinishSetupItem, section: AppSection = .overview, stage: Bool = false, settled: Bool = true)
            -> FinishSetupPlace
        {
            FinishSetupTracker.place(for: item, record: record, section: section, stagePresented: stage, settled: settled)
        }
        #expect(place(.signInConnections, section: .overview) == .home)
        #expect(place(.lookAtCheckup, section: .checkup) == .checkup)
        #expect(place(.makeSkillsYours, section: .skills) == .library)
        #expect(place(.trackProjects, section: .projects) == .projects)
        // While the stage is open over the shell, it was done in setup.
        #expect(place(.signInConnections, stage: true) == .setup)
        // The first look after launch, and a row that comes true in the
        // background, name the row's own place.
        #expect(place(.signInConnections, settled: false) == .apps)
        #expect(place(.connectOtherMacs, section: .overview) == .settings)
        #expect(place(.putToolsInApps, section: .overview) == .apps)
    }

    /// What a first run did before it was left for later, it did in setup.
    @Test func aDeferredFirstRunsOwnStepsTickInSetupOnTheFirstLook() {
        let record = Fixture.record(.deferred(.ask))
        #expect(
            FinishSetupTracker.place(for: .makeSkillsYours, record: record, section: .overview, stagePresented: false, settled: false)
                == .setup)
        #expect(
            FinishSetupTracker.place(for: .lookAtCheckup, record: record, section: .overview, stagePresented: false, settled: false)
                == .checkup)
    }

    @Test func theTrackerTicksOnlyNewRowsOnTheCard() {
        let record = Fixture.record(.juniper)
        var facts = Fixture.juniperFacts(record: record)
        facts.trackedProjects = 1
        facts.connectionCheck = .init(checkedAt: Fixture.doneAt, signInOffers: [], needsAuthentication: [], connected: [Fixture.sentry])
        let ticks = FinishSetupTracker.ticks(
            FinishSetupChecklist.satisfied(facts), facts: facts, section: .overview, stagePresented: false, settled: true)

        // makeSkillsYours, putToolsInApps and connectOtherMacs are ticked
        // already; connectAgentTooling is not on the card.
        #expect(ticks.map(\.item) == [.signInConnections, .trackProjects])
        #expect(ticks.map(\.place) == [.home, .home])
        #expect(FinishSetupChecklist.summary(for: .signInConnections, facts: facts, now: Fixture.doneAt) == "Sentry signed in")

        // Nothing ticks for a first run still on the stage, or with no record.
        var started = facts
        started.record = Fixture.startedRecord()
        #expect(
            FinishSetupTracker.ticks([.trackProjects], facts: started, section: .overview, stagePresented: false, settled: true).isEmpty)
        started.record = nil
        #expect(
            FinishSetupTracker.ticks([.trackProjects], facts: started, section: .overview, stagePresented: false, settled: true).isEmpty)
    }

    // MARK: - Trying a skill

    @Test func aSkillCanBeTriedOnlyWhereTheLastCheckFoundIt() {
        let found = SkillTrialAvailability.cannotTryReason(
            skillName: "release-notes", in: .codex, observedIn: [.codex], canOpen: true)
        #expect(found == nil)
        #expect(
            SkillTrialAvailability.cannotTryReason(skillName: "release-notes", in: .gemini, observedIn: [.gemini], canOpen: true)
                == "Trying a skill in Gemini CLI from here is not supported yet.")
        #expect(
            SkillTrialAvailability.cannotTryReason(skillName: "release-notes", in: .codex, observedIn: [.claude], canOpen: true)
                == "The last check did not find this skill in Codex.")
        #expect(
            SkillTrialAvailability.cannotTryReason(
                skillName: "release-notes", in: .codex, observedIn: [], requestedIn: [.codex], canOpen: true)
                == "Install it in Codex first; the last check did not find it there.")
        #expect(
            SkillTrialAvailability.cannotTryReason(skillName: "release-notes", in: .codex, observedIn: [.codex], canOpen: false)
                == "Codex’s command-line tool was not found on this Mac.")
    }

    @Test func aTrialFromLibraryTicksTheTrialRowFromLibrary() throws {
        let session = WorkspaceSetupProgressSession(store: StubSetupProgressStore(Fixture.record(.juniper)))
        session.recordTrial(skillName: "Webapp Testing", client: .claude, place: .library, now: Fixture.doneAt)

        let tick = try #require(session.record?.ticks.first { $0.item == .trySkill })
        #expect(tick.place == .library)
        #expect(tick.summary == "Tried Webapp Testing in Claude Code")
        let row = FinishSetupChecklist.make(Fixture.juniperFacts(record: session.record), now: Fixture.doneAt)?.rows
            .first { $0.item == .trySkill }
        #expect(row?.caption == "Tried Webapp Testing in Claude Code · from Library")
        #expect(row?.title == "Try Release Notes in Codex")
    }

    /// With no skill made yours, Home offers the first skill Codex has, then
    /// Claude Code; never Gemini CLI, which cannot open one.
    @Test func theTrialFallsBackToTheFirstSkillCodexThenClaudeCodeHas() {
        var facts = FinishSetupFacts(record: Fixture.startedRecord())
        facts.managedClients = [.codex, .claude, .gemini]
        facts.observedSkills = [.gemini: ["frontend-design"]]
        facts.names = ["frontend-design": "Frontend Design", "webapp-testing": "Webapp Testing"]
        #expect(FinishSetupChecklist.trialTarget(facts) == nil)

        facts.observedSkills[.claude] = ["webapp-testing"]
        #expect(FinishSetupChecklist.trialTarget(facts)?.client == .claude)
        facts.observedSkills[.codex] = ["webapp-testing", "frontend-design"]
        #expect(
            FinishSetupChecklist.trialTarget(facts)
                == .init(skillName: "Frontend Design", skillID: "frontend-design", client: .codex))
    }
}
