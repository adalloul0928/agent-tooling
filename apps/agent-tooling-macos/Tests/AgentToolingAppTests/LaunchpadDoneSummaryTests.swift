import AgentToolingCore
import AgentToolingTestSupport
import Foundation
import Testing

@testable import AgentToolingApp

/// Done (S22) worked out: the fragment's words for Juniper, Cedar's join,
/// the empty Mac and the ↩-through walk from the mockups' own numbers; the
/// sample world's walk as the stage leaves it; the paths that installed
/// nothing, which read Checkup from the audit Done runs; and the record Go to
/// Home writes.
@Suite("Launchpad Done summary", .serialized, .timeLimit(.minutes(5)))
@MainActor
struct LaunchpadDoneSummaryTests {
    private typealias Fixture = FinishSetupFixture

    // MARK: - The fragment's words

    @Test func juniperReadsAsTheFragment() {
        let summary = LaunchpadDoneSummary(Fixture.juniperInputs())

        #expect(
            summary.tiles.map { "\($0.client.rawValue) \($0.line)" } == [
                "Codex 0.164.0", "Claude Code 2.1.304", "Gemini CLI 0.38.2", "Kiro CLI Not found",
            ])
        #expect(summary.tiles.map(\.state) == [.read, .read, .read, .absent])
        #expect(summary.tilesLabel == "Apps: Codex, Claude Code and Gemini CLI looked after; Kiro CLI not found")
        #expect(summary.title == "Set up, with 2 things left")
        #expect(summary.subtitle == "Juniper · Saturday, October 17 · Run setup again from Settings › General.")
        #expect(
            summary.happened.map { plain($0.text) } == [
                "3 apps looked after: Codex 0.164.0, Claude Code 2.1.304, Gemini CLI 0.38.2 · Kiro CLI not found",
                "13 tools in your library (9 entries) · 2 are now yours: Release Notes, Frontend Design",
                "4 changes installed in 2 apps · 1 left alone (Frontend Design in Codex)",
                "Agent Tooling connected to Codex and Claude Code",
                "Synced just now with https://github.com/you/agent-tooling-workspace.git · ready for your other Mac",
                "Weekly checkup review on, with Claude Code · daily deep dive off",
                "After the next check, Gemini CLI also shows Release Notes, because it reads ~/.agents/skills.",
            ])
        #expect(
            summary.happened.map(\.detail) == [
                nil, "Supabase’s contents appear after the next check.", "Installed 4 changes · \(Fixture.installedTime)", nil, nil, nil,
                nil,
            ])
        #expect(summary.happened.map(\.kind) == [.done, .done, .done, .done, .done, .done, .info])
        #expect(summary.happened.last?.code == "~/.agents/skills")
        #expect(
            summary.leftForLater.map { [$0.title, $0.detail ?? ""] } == [
                ["Sign in to your connections", "Not checked yet · Sentry in Claude Code may need you to sign in"],
                [
                    "4 things left on Checkup",
                    "Webapp Testing unmanaged in Codex and in Claude Code; Context7 and Playwright each configured in two apps",
                ],
            ])
        #expect(summary.leftForLater.map(\.state) == [.pending, .attention])
        #expect(summary.suggestions == 2)
        #expect(
            summary.runs.map { "\($0.lead) \($0.text)" } == [
                "When it opens: check apps, look for updates, sync with your other Macs",
                "Weekly: the checkup review, with Claude Code",
                "After a change: sync with your other Macs, at most every 15 minutes",
            ])
    }

    /// A version stays with its app and a "·" with the words before it, so
    /// no line of What happened starts with "·".
    @Test func separatorsAndVersionsAreBoundToTheWordsBeforeThem() {
        let lines = LaunchpadDoneSummary(Fixture.juniperInputs()).happened.map(\.text)
        let glue = LaunchpadCopy.Done.glue

        #expect(lines[0].contains("Codex\(glue)0.164.0, Claude\(glue)Code\(glue)2.1.304, Gemini\(glue)CLI\(glue)0.38.2\(glue)·"))
        #expect(lines[1].contains("(9 entries)\(glue)· 2 are now yours"))
        #expect(lines[2].contains("2 apps\(glue)· 1 left alone"))
        // The address breaks only after its last slash.
        #expect(lines[4].contains("https://github.com/you/\u{200B}agent\u{2011}tooling\u{2011}workspace.git\(glue)·"))
        for line in lines { #expect(!line.contains(" ·")) }
    }

    /// The record Go to Home writes: Home's seven rows, the three done in
    /// setup ticked there, and what the card needs kept.
    @Test func juniperHandsOffSevenRowsWithThreeDoneInSetup() {
        let summary = LaunchpadDoneSummary(Fixture.juniperInputs())

        #expect(
            summary.items == [
                .makeSkillsYours, .putToolsInApps, .connectOtherMacs, .signInConnections, .lookAtCheckup, .trySkill,
                .trackProjects,
            ])
        #expect(summary.ticks.map(\.item) == [.makeSkillsYours, .putToolsInApps, .connectOtherMacs])
        #expect(summary.ticks.allSatisfy { $0.place == .setup && $0.at == Fixture.doneAt })
        #expect(
            summary.ticks.map(\.summary) == ["Release Notes and Frontend Design", "Installed 4 changes · \(Fixture.installedTime)", nil])
        #expect(summary.evidence.checkupFindingIDs == Fixture.juniperFindings.map(\.id))
        #expect(summary.evidence.trial == Fixture.releaseNotesInCodex)
        #expect(summary.evidence.mayNeedSignIn == [.init(connection: "Sentry", serverID: "plugin:sentry:sentry", client: .claude)])
        #expect(summary.evidence.projectFolderCount == 4)
        #expect(summary.evidence.personalSkillsBefore.isEmpty)
    }

    @Test func cedarsJoinReadsAsItsNote() {
        let summary = LaunchpadDoneSummary(Fixture.cedarInputs())

        #expect(summary.tiles.map(\.state) == [.read, .read, .absent, .absent])
        #expect(summary.title == "Set up, with 2 things left")
        #expect(summary.subtitle.hasPrefix("Cedar · Saturday, October 17"))
        #expect(
            summary.happened.map { plain($0.text) } == [
                "2 apps looked after: Codex 0.164.0, Claude Code 2.1.304 · Gemini CLI and Kiro CLI not found",
                "14 tools in your library (Db Migrations was found here)",
                "5 changes installed in 2 apps",
                "Synced just now with https://github.com/you/agent-tooling-workspace.git",
                "Weekly checkup review on, with Claude Code · daily deep dive off",
            ])
        #expect(
            summary.leftForLater.map { [$0.title, $0.detail ?? ""] } == [
                ["Agent Tooling is not connected to Cedar’s apps yet", ""],
                ["1 thing left on Checkup", "Db Migrations unmanaged in Claude Code"],
            ])
        // The skills that came across stay what they were before the join.
        #expect(summary.evidence.personalSkillsBefore == [Fixture.releaseNotes.id, Fixture.frontendDesign.id])
        #expect(!summary.items.contains(.makeSkillsYours))
        #expect(summary.ticks.map(\.item) == [.putToolsInApps, .connectOtherMacs])
    }

    /// The empty Mac's Done says its zeros honestly.
    @Test func anEmptyMacReadsHonestZeros() {
        let summary = LaunchpadDoneSummary(Fixture.emptyMacInputs())

        #expect(summary.tiles.allSatisfy { $0.state == .absent && $0.line == "Not found" })
        #expect(summary.title == "All set")
        #expect(
            summary.happened.map { plain($0.text) } == [
                "0 apps looked after · Codex, Claude Code, Gemini CLI and Kiro CLI not found",
                "0 tools in your library (0 entries)",
                "Nothing is put in apps: this Mac manages none yet.",
                "Agent Tooling is not connected: this Mac manages no app yet.",
            ])
        #expect(summary.happened.map(\.kind) == [.done, .done, .info, .info])
        #expect(summary.leftForLater.isEmpty)
        #expect(summary.suggestions == 2)
        #expect(summary.items == [.connectOtherMacs, .trackProjects])
        #expect(summary.ticks.isEmpty)
        #expect(summary.runs.map { "\($0.lead) \($0.text)" } == ["When it opens: check apps, look for updates"])
    }

    /// Pressing ↩ through every screen: three installs, nothing made yours,
    /// Other Macs skipped, Checkup's first-run eight left.
    @Test func theReturnThroughWalkReadsItsNumbers() {
        let summary = LaunchpadDoneSummary(Fixture.returnThroughInputs())

        #expect(summary.title == "Set up, with 2 things left")
        #expect(
            summary.happened.map { plain($0.text) }.prefix(3) == [
                "3 apps looked after: Codex 0.164.0, Claude Code 2.1.304, Gemini CLI 0.38.2 · Kiro CLI not found",
                "12 tools in your library (8 entries)",
                "3 changes installed in 3 apps",
            ])
        #expect(summary.happened.map(\.text).contains("Agent Tooling connected to Codex, Claude Code and Gemini CLI"))
        #expect(summary.leftForLater.map(\.title) == ["Sign in to your connections", "8 things left on Checkup"])
        #expect(summary.suggestions == 3)
        #expect(LaunchpadCopy.Done.homeAdds(summary.suggestions) == "Home adds 3 suggestions")
        #expect(summary.items.count == 6)
        #expect(summary.ticks.map(\.item) == [.putToolsInApps])
    }

    /// Until the audit Done runs as it appears returns, its Checkup card says
    /// so instead of a count it may not keep.
    @Test func checkupReadsCheckingUntilTheAuditReturns() {
        var inputs = Fixture.juniperInputs()
        inputs.auditSettled = false
        let later = LaunchpadDoneSummary(inputs).leftForLater.last

        #expect(later?.item == .lookAtCheckup)
        #expect(later?.title == "Checking…")
        #expect(later?.detail == nil)
        #expect(later?.state == .pending)
    }

    // MARK: - A rerun, and what has changed since

    /// A rerun's Done counts what Home will show for the record Go to Home
    /// writes: the ticks the first run's card made since stay made (D20), and
    /// a row the facts already make true is not left for later, because
    /// Home's first look ticks it.
    @Test func aRerunsDoneCountsWhatHomeShowsForTheRecordItWrites() throws {
        var first = Fixture.record(.juniper)
        first.ticks += [
            .init(item: .signInConnections, place: .home, at: Fixture.doneAt, summary: "Sentry signed in"),
            .init(item: .trySkill, place: .library, at: Fixture.doneAt, summary: "Tried Release Notes in Codex"),
        ]
        // The rerun made nothing yours, installed nothing and shared
        // nothing itself; a project has been tracked since.
        var inputs = Fixture.juniperInputs()
        inputs.path = .rerun
        inputs.decisions = LaunchpadLibraryDecisions()
        inputs.outcomes = LaunchpadOutcomes()
        inputs.looked = Fixture.juniperInputs().outcomes.read?.looked ?? []
        inputs.facts.record = first
        inputs.facts.trackedProjects = 1
        let summary = LaunchpadDoneSummary(inputs)

        let session = WorkspaceSetupProgressSession(store: StubSetupProgressStore(first))
        session.finish(items: summary.items, ticks: summary.ticks, evidence: summary.evidence, now: Fixture.doneAt)
        var facts = inputs.facts
        facts.record = session.record
        for (item, place) in FinishSetupTracker.ticks(
            FinishSetupChecklist.satisfied(facts), facts: facts, section: .overview, stagePresented: false, settled: false)
        {
            session.tick(item, place: place, now: Fixture.doneAt)
        }
        facts.record = session.record
        let card = try #require(FinishSetupChecklist.make(facts, now: Fixture.doneAt))

        #expect(summary.leftForLater.map(\.item) == [.lookAtCheckup])
        #expect(summary.title == "Set up, with 1 thing left")
        #expect(summary.suggestions == 0)
        #expect(card.left == summary.leftForLater.count + summary.suggestions)
        // The rows Home ticked stay where they were done.
        #expect(card.rows.first { $0.item == .signInConnections }?.caption == "Sentry signed in · from Home")
        #expect(card.rows.first { $0.item == .trySkill }?.caption == "Tried Release Notes in Codex · from Library")
    }

    /// Once a connection check has run, the sign-in card says what it found
    /// rather than "Not checked yet"; with nothing to sign in to, there is no
    /// card, and Home ticks the row on its first look.
    @Test func theSignInCardSaysWhatACheckFound() {
        var inputs = Fixture.juniperInputs()
        inputs.facts.connectionCheck = .init(
            checkedAt: Fixture.doneAt, signInOffers: [Fixture.sentry], needsAuthentication: [Fixture.sentry], connected: [])
        var card = LaunchpadDoneSummary(inputs).leftForLater.first
        #expect(card?.item == .signInConnections)
        #expect(card?.detail == "Sentry in Claude Code needs you to sign in")
        #expect(card?.state == .attention)

        let linear = FinishSetupFacts.Connection(name: "Linear", serverID: "linear", client: .claude)
        inputs.facts.connectionCheck = .init(
            checkedAt: Fixture.doneAt, signInOffers: [], needsAuthentication: [linear], connected: [Fixture.sentry])
        card = LaunchpadDoneSummary(inputs).leftForLater.first
        #expect(card?.detail == "Checked · Linear in Claude Code needs you to sign in from its app")

        inputs.facts.connectionCheck = .init(
            checkedAt: Fixture.doneAt, signInOffers: [], needsAuthentication: [], connected: [Fixture.sentry])
        let summary = LaunchpadDoneSummary(inputs)
        #expect(summary.leftForLater.map(\.item) == [.lookAtCheckup])
        #expect(summary.title == "Set up, with 1 thing left")
        #expect(summary.items.contains(.signInConnections))
        #expect(summary.suggestions == 2)
    }

    /// The placements setups made never read as arrivals from another Mac:
    /// Done keeps the ones kept so far that the library still holds, then
    /// adds this walk's own.
    @Test func doneKeepsEveryPlacementASetupMadeThatTheLibraryHolds() {
        let earlier = WorkspaceObjectID()
        let withdrawn = WorkspaceObjectID()
        let added = WorkspaceObjectID()
        var inputs = Fixture.juniperInputs()
        inputs.path = .rerun
        var record = Fixture.record(.juniper)
        record.evidence.placedContributionIDs = [earlier, withdrawn]
        inputs.facts.record = record
        inputs.decisions.contributionIDs = [added]

        inputs.contributionsInLibrary = [earlier, added]
        #expect(LaunchpadDoneSummary(inputs).evidence.placedContributionIDs == [earlier, added])
        // Not knowing the library, nothing kept is let go.
        inputs.contributionsInLibrary = nil
        #expect(LaunchpadDoneSummary(inputs).evidence.placedContributionIDs == [earlier, withdrawn, added])
    }

    /// A rerun that puts one more thing in an app: Go to Home keeps the
    /// first run's placements and adds the rerun's own, which S10 left for
    /// Done to record.
    @Test func aRerunsDoneKeepsTheFirstRunsPlacementsAndAddsItsOwn() async throws {
        let fixture = try await LaunchpadFixture()
        defer { fixture.remove() }
        let sample = try await fixture.sample(.afterPlace)
        let workspace = sample.workspace
        let first = try #require(workspace.setupProgress.record?.evidence)
        #expect(first.placedContributionIDs == sample.decisions.contributionIDs)
        workspace.setupProgress.finish(items: [.connectOtherMacs], evidence: first, now: ClientHomeFixture.now)

        let flow = fixture.flow(.rerun, workspace: workspace)
        let releaseNotes = try #require(sample.artifact("release-notes"))
        let more = AssignmentContribution(
            artifactID: releaseNotes.identity.id, destination: .init(surface: ClientKind.gemini.defaultSurface, scope: .user),
            reason: .manual)
        _ = try await workspace.service.applyAssignmentBatch(
            .init(expectedRevisionID: try fixture.head(of: workspace), additions: [more]))
        await workspace.library.refresh()
        flow.decisions.contributionIDs = [more.id]
        flow.go(to: .done)
        await LaunchpadDoneScreen.model(flow).appear(flow)
        LaunchpadStageView.footer(for: flow).primary?.action()

        let record = try #require(fixture.savedRecord(for: workspace))
        #expect(record.path == .startHere)
        #expect(record.evidence.placedContributionIDs == first.placedContributionIDs + [more.id])
    }

    /// A rerun writes its record only at Done, so the project folders its
    /// read named come along then (WP2's hand-off).
    @Test func aRerunsReadHandsItsProjectCountToDone() async throws {
        let fixture = try await LaunchpadFixture()
        defer { fixture.remove() }
        let workspace = try await fixture.sample(.afterRead).workspace
        #expect(fixture.savedRecord(for: workspace)?.evidence.projectFolderCount == nil)
        let flow = fixture.flow(.rerun, workspace: workspace)
        LaunchpadStageView.footer(for: flow).primary?.action()
        #expect(flow.step == .reads)
        let read = LaunchpadReadSession.of(flow)
        LaunchpadStageView.footer(for: flow).primary?.action()
        await waitUntil { read.phase == .finished }
        #expect(read.projectFolderCount == 4)

        flow.go(to: .done)
        await LaunchpadDoneScreen.model(flow).appear(flow)
        LaunchpadStageView.footer(for: flow).primary?.action()

        #expect(fixture.savedRecord(for: workspace)?.evidence.projectFolderCount == 4)
    }

    /// Hand-made: a rerun's own count replaces the one kept; none keeps it.
    @Test func aRerunsProjectCountReplacesTheOneKept() {
        var inputs = Fixture.juniperInputs()
        inputs.path = .rerun
        inputs.projectFolderCount = 7
        #expect(LaunchpadDoneSummary(inputs).evidence.projectFolderCount == 7)
        inputs.projectFolderCount = nil
        #expect(LaunchpadDoneSummary(inputs).evidence.projectFolderCount == 4)
    }

    /// Setup ticks Connect your other Macs only when this walk shared the
    /// library: its own publish went through, or its join synced. Connected
    /// with the publish not through, it shares and has not synced; a rerun
    /// on a Mac that shared already leaves the tick to Home.
    @Test func setupTicksSharingOnlyWhenItsOwnPassWentThrough() {
        var inputs = Fixture.juniperInputs()
        inputs.outcomes.sync?.publishedAt = nil
        inputs.facts.sync?.lastSynced = nil
        var summary = LaunchpadDoneSummary(inputs)
        #expect(!summary.ticks.contains { $0.item == .connectOtherMacs })
        #expect(
            summary.happened.map { plain($0.text) }.contains(
                "Shares this library with https://github.com/you/agent-tooling-workspace.git"))
        #expect(summary.runs.first?.text == "check apps, look for updates, sync with your other Macs")
        #expect(summary.suggestions == 3)

        inputs = Fixture.juniperInputs()
        inputs.path = .rerun
        inputs.outcomes.sync = nil
        summary = LaunchpadDoneSummary(inputs)
        #expect(!summary.ticks.contains { $0.item == .connectOtherMacs })
        #expect(summary.happened.map { plain($0.text) }.contains("Synced just now with https://github.com/you/agent-tooling-workspace.git"))

        #expect(LaunchpadDoneSummary(Fixture.cedarInputs()).ticks.contains { $0.item == .connectOtherMacs })
    }

    /// Agent Tooling's own connection left undone says why, when the step
    /// that could not set it up said so.
    @Test func theNotConnectedCardSaysWhy() {
        var inputs = Fixture.cedarInputs()
        inputs.outcomes.helperUnavailable = LaunchpadCopy.Helper.moveFirst
        let card = LaunchpadDoneSummary(inputs).leftForLater.first

        #expect(card?.item == .connectAgentTooling)
        #expect(card?.title == "Agent Tooling is not connected to Cedar’s apps yet")
        #expect(card?.detail == "Move Agent Tooling to Applications first, so your apps can find it.")
    }

    /// An install that did not all finish counts its changes and names the
    /// apps it stopped in, rather than counting every app it touched.
    @Test func anInstallThatDidNotAllFinishNamesWhereItStopped() {
        var inputs = Fixture.juniperInputs()
        inputs.outcomes.install = DeploymentOutcome(
            installed: [.codex], failed: [.claude: "Claude Code could not install Supabase."], succeededSteps: 2, failedSteps: 1,
            finishedAt: Fixture.installedAt)
        let summary = LaunchpadDoneSummary(inputs)
        let line = summary.happened[2]

        #expect(plain(line.text) == "2 changes installed · 1 did not finish (Claude Code)")
        #expect(line.kind == .partial)
        #expect(!summary.ticks.contains { $0.item == .putToolsInApps })
        let card = summary.leftForLater.first
        #expect(card?.item == .putToolsInApps)
        #expect(card?.detail == "1 did not finish (Claude Code)")
        #expect(card?.state == .attention)
    }

    /// An install stopped before its last steps did not finish them either:
    /// the apps it stopped in are named with them, neither failed nor counted
    /// as installed, and the row is not done in setup.
    @Test func aStoppedInstallNamesTheAppsItStoppedIn() {
        var inputs = Fixture.juniperInputs()
        inputs.outcomes.install = DeploymentOutcome.from(
            steps: [(.codex, .succeeded), (.codex, .succeeded), (.claude, .succeeded), (.claude, .notRun)],
            finishedAt: Fixture.installedAt)
        let summary = LaunchpadDoneSummary(inputs)
        let line = summary.happened[2]

        #expect(plain(line.text) == "3 changes installed · 1 did not finish (Claude Code)")
        #expect(line.kind == .partial)
        #expect(!summary.ticks.contains { $0.item == .putToolsInApps })
        let card = summary.leftForLater.first
        #expect(card?.item == .putToolsInApps)
        #expect(card?.detail == "1 did not finish (Claude Code)")
        #expect(card?.state == .attention)

        // Refused in one app, then stopped before the others: every app is
        // named, and none is counted as taking the change that went in.
        inputs.outcomes.install = DeploymentOutcome.from(
            steps: [(.codex, .succeeded), (.codex, .failed("no")), (.claude, .notRun), (.gemini, .notRun)],
            finishedAt: Fixture.installedAt)
        #expect(
            plain(LaunchpadDoneSummary(inputs).happened[2].text)
                == "1 change installed · 3 did not finish (Codex, Claude Code and Gemini CLI)")
    }

    /// Go to Home and Open Checkup wait for the audit Done runs as it
    /// appears: a press before it returns does nothing, and the record then
    /// keeps the findings Checkup shows after it.
    @Test func goToHomeWaitsForTheAuditDoneRuns() async throws {
        let fixture = try await LaunchpadFixture()
        defer { fixture.remove() }
        let (flow, sample) = try await fixture.flow(at: .afterAsk)
        flow.go(to: .done)
        let footer = LaunchpadStageView.footer(for: flow)
        #expect(footer.primary?.isEnabled == false)
        #expect(footer.secondary?.isEnabled == false)
        footer.primary?.action()
        footer.secondary?.action()
        #expect(flow.pendingHandOff == nil)
        #expect(fixture.savedRecord(for: sample.workspace)?.state == .inProgress)

        await LaunchpadDoneScreen.model(flow).appear(flow)
        let ready = LaunchpadStageView.footer(for: flow)
        #expect(ready.primary?.isEnabled == true)
        ready.primary?.action()

        #expect(flow.pendingHandOff == .overview)
        let open = (sample.workspace.setup.checkup?.openFindings ?? []).filter { $0.kind != .accountDiffersFromOtherMacs }
        #expect(fixture.savedRecord(for: sample.workspace)?.evidence.checkupFindingIDs == open.map(\.id))
    }

    // MARK: - The sample world

    /// Juniper's walk as the stage leaves it, with Other Macs' publish as
    /// that step records it. The sample world's own numbers differ from the
    /// mockups' in two places, each pinned here: its Codex reports no
    /// connection inside a plugin (12 tools, not 13); and before a check,
    /// GitHub may need a sign-in as much as Sentry (its plugin brings no
    /// credentials of its own). Checkup's 4 are the mockups' 4.
    @Test func theSampleWorldsWalkHandsOffSevenRowsAndThreeTicks() async throws {
        let fixture = try await LaunchpadFixture()
        defer { fixture.remove() }
        let (flow, sample) = try await fixture.flow(at: .afterInstall)
        flow.outcomes.sync = .init(address: Fixture.remote, publishedAt: ClientHomeFixture.now, upToDate: true)
        flow.go(to: .done)
        let model = LaunchpadDoneScreen.model(flow)
        await model.appear(flow)
        let summary = LaunchpadDoneSummary(
            try #require(LaunchpadDoneSummary.inputs(flow, model: model)))

        #expect(summary.title == "Set up, with 2 things left")
        #expect(summary.subtitle == "Juniper · Saturday, October 17 · Run setup again from Settings › General.")
        #expect(
            summary.happened.map { plain($0.text) } == [
                "3 apps looked after: Codex 0.164.0, Claude Code 2.1.304, Gemini CLI 0.38.2 · Kiro CLI not found",
                "12 tools in your library (9 entries) · 2 are now yours: Release Notes, Frontend Design",
                "4 changes installed in 2 apps · 1 left alone (Frontend Design in Codex)",
                "Agent Tooling connected to Codex and Claude Code",
                "Synced just now with https://github.com/you/agent-tooling-workspace.git · ready for your other Mac",
                "Weekly checkup review and daily deep dive off",
                "After the next check, Gemini CLI also shows Release Notes, because it reads ~/.agents/skills.",
            ])
        #expect(summary.leftForLater.map(\.title) == ["Sign in to your connections", "4 things left on Checkup"])
        #expect(
            summary.leftForLater.map(\.detail) == [
                "Not checked yet · GitHub and Sentry in Claude Code may need you to sign in",
                "Webapp Testing unmanaged in Codex and in Claude Code; Context7 and Playwright each configured in two apps",
            ])

        LaunchpadStageView.footer(for: flow).primary?.action()

        #expect(flow.pendingHandOff == .overview)
        let record = try #require(fixture.savedRecord(for: sample.workspace))
        #expect(record.state == .finished)
        #expect(record.items.count == 7)
        #expect(record.ticks.count == 3)
        #expect(record.ticks.allSatisfy { $0.place == .setup })
        #expect(record.items == summary.items)
        #expect(record.evidence.trial == Fixture.releaseNotesInCodex)
        // What the walk kept on its way stays kept.
        #expect(record.evidence.placedContributionIDs == sample.decisions.contributionIDs)
        #expect(record.evidence.checkupFindingIDs.count == 4)
    }

    /// A first run left for later after its install and resumed from Home
    /// reaches Done with a fresh walk's decisions and outcomes: what its
    /// first half did comes from the library and the receipts (plan §2.4).
    /// It hands off the same rows and ticks the uninterrupted walk does,
    /// offers the skill it made yours, and keeps no skill it made yours as
    /// one that was yours before.
    @Test func aResumedFirstRunHandsOffWhatItsFirstHalfDid() async throws {
        let fixture = try await LaunchpadFixture()
        defer { fixture.remove() }
        let sample = try await fixture.sample(.afterInstall)
        sample.workspace.setupProgress.deferSetup(at: .assistant, now: ClientHomeFixture.now)
        let flow = fixture.flow(.resume(.assistant), workspace: sample.workspace)
        #expect(flow.decisions == LaunchpadLibraryDecisions())
        #expect(flow.outcomes == LaunchpadOutcomes())
        flow.outcomes.sync = .init(address: Fixture.remote, publishedAt: ClientHomeFixture.now, upToDate: true)
        flow.go(to: .done)
        let model = LaunchpadDoneScreen.model(flow)
        await model.appear(flow)
        let summary = LaunchpadDoneSummary(try #require(LaunchpadDoneSummary.inputs(flow, model: model)))

        // The skills made yours are read from the library, by name; the
        // install from its receipts: the sample world's one real step,
        // Release Notes copied into Codex (its plugin and connection steps
        // are taken from the re-check, which writes no receipt).
        #expect(
            summary.happened.map { plain($0.text) } == [
                "3 apps looked after: Codex 0.164.0, Claude Code 2.1.304, Gemini CLI 0.38.2 · Kiro CLI not found",
                "12 tools in your library (9 entries) · 2 are now yours: Frontend Design, Release Notes",
                "1 change installed in 1 app",
                "Agent Tooling connected to Codex and Claude Code",
                "Synced just now with https://github.com/you/agent-tooling-workspace.git · ready for your other Mac",
                "Weekly checkup review and daily deep dive off",
            ])
        #expect(summary.leftForLater.map(\.item) == [.signInConnections, .lookAtCheckup])
        #expect(summary.suggestions == 2)
        LaunchpadStageView.footer(for: flow).primary?.action()

        let record = try #require(fixture.savedRecord(for: sample.workspace))
        #expect(record.state == .finished)
        #expect(record.items.count == 7)
        #expect(record.ticks.map(\.item) == [.makeSkillsYours, .putToolsInApps, .connectOtherMacs])
        #expect(record.ticks.allSatisfy { $0.place == .setup })
        #expect(record.ticks.first?.summary == "Frontend Design and Release Notes")
        // Codex keeps its own Frontend Design (the review left it alone), so
        // the skill offered is the one whose copy every app shares.
        #expect(record.evidence.trial == Fixture.releaseNotesInCodex)
        #expect(record.evidence.personalSkillsBefore.isEmpty)
    }

    /// The review cancelled: nothing installed, so putting tools in apps and
    /// Agent Tooling's own connection are left for later, and Checkup counts
    /// what the audit Done ran as it appeared found, not the last one before.
    @Test func aCancelledReviewLeavesTheInstallForLaterAndReadsThePostDoneAudit() async throws {
        let fixture = try await LaunchpadFixture()
        defer { fixture.remove() }
        let (flow, sample) = try await fixture.flow(at: .afterAsk)
        LaunchpadStageView.footer(for: flow).primary?.action()
        let review = try #require(flow.presentedReview)
        await review.prepare()
        flow.dismissReview()
        let before = sample.workspace.setup.checkup?.audit.generatedAt
        flow.go(to: .done)
        let model = LaunchpadDoneScreen.model(flow)
        await model.appear(flow)

        // The library moved since the last audit, so Done audited again.
        #expect(sample.workspace.setup.checkup?.audit.generatedAt != before)
        let open = (sample.workspace.setup.checkup?.openFindings ?? []).filter { $0.kind != .accountDiffersFromOtherMacs }
        let summary = LaunchpadDoneSummary(
            try #require(LaunchpadDoneSummary.inputs(flow, model: model)))

        #expect(!summary.happened.contains { $0.text.contains("installed in") })
        #expect(
            summary.leftForLater.map(\.item) == [.putToolsInApps, .connectAgentTooling, .signInConnections, .lookAtCheckup])
        #expect(summary.leftForLater.first?.detail == "4 changes wait for your review")
        #expect(summary.leftForLater[1].title == "Agent Tooling is not connected to Juniper’s apps yet")
        #expect(summary.leftForLater.last?.title == LaunchpadCopy.Done.leftOnCheckup(open.count))
        #expect(summary.evidence.checkupFindingIDs == open.map(\.id))
        #expect(summary.title == "Set up, with 4 things left")
        #expect(summary.ticks.map(\.item) == [.makeSkillsYours])
    }

    /// Cedar's Install later at You joined: Juniper's installs wait, counted
    /// from the plan You joined prepared.
    @Test func installLaterOnCedarLeavesItsInstallsForLater() async throws {
        let fixture = try await LaunchpadFixture(.cedar)
        defer { fixture.remove() }
        let (flow, sample) = try await fixture.flow(at: .cedarJoined)
        defer { sample.remove() }
        await sample.workspace.deployment.prepare()
        let pending = sample.workspace.deployment.pendingCount
        flow.go(to: .done)
        let model = LaunchpadDoneScreen.model(flow)
        await model.appear(flow)
        let summary = LaunchpadDoneSummary(
            try #require(LaunchpadDoneSummary.inputs(flow, model: model)))

        #expect(pending > 0)
        #expect(summary.leftForLater.first?.item == .putToolsInApps)
        #expect(summary.leftForLater.first?.detail == LaunchpadCopy.Done.waitForReview(pending))
        #expect(summary.tiles.map(\.state) == [.read, .read, .absent, .absent])
        #expect(summary.subtitle.hasPrefix("Cedar · "))
        // The skills that came across from Juniper were never made yours
        // here.
        #expect(!summary.items.contains(.makeSkillsYours))
    }

    /// A finding that this Mac and another are signed in to different
    /// accounts is never one of setup's counts (D34): not on Done, and not
    /// kept for Home's card.
    @Test func accountDifferencesAreLeftOutOfDoneAndTheCard() async throws {
        let differs = SetupFinding(
            kind: .accountDiffersFromOtherMacs, severity: .medium, client: .claude, subject: "claude",
            title: "Claude Code is signed in to another account", detail: "", evidence: [], actions: [])
        let unmanaged = SetupFinding(
            kind: .unmanagedSkill, severity: .info, client: .claude, subject: "webapp-testing",
            title: "webapp-testing is not managed by this app", detail: "", evidence: [], actions: [])
        let checkup = SetupCheckup(
            audit: SetupAuditReport(clients: [.claude], findings: [differs, unmanaged], counts: [:]))
        let fixture = try await ShellRenderFixture(setupServices: StubSetupServices(restored: checkup))
        defer { fixture.remove() }

        let facts = FinishSetupFacts.live(workspace: fixture.workspace)

        #expect(facts.openFindings?.map(\.id) == [unmanaged.id])
        // A skill the library does not hold reads as a check names it.
        #expect(facts.openFindings?.map(\.name) == ["Webapp Testing"])
        var inputs = LaunchpadDoneSummary.Inputs(path: .startHere)
        inputs.facts = facts
        #expect(LaunchpadDoneSummary(inputs).evidence.checkupFindingIDs == [unmanaged.id])
    }

    // MARK: - Helpers

    /// A line as a person reads it: the line-holding spaces and the address's
    /// break point read as what they stand for.
    private func plain(_ text: String) -> String {
        text.replacingOccurrences(of: LaunchpadCopy.Done.glue, with: " ")
            .replacingOccurrences(of: "\u{200B}", with: "")
            .replacingOccurrences(of: "\u{2011}", with: "-")
    }
}
