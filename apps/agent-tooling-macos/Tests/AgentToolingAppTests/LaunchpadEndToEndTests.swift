import AgentToolingCore
import AgentToolingTestSupport
import Foundation
import Testing

@testable import AgentToolingApp

/// Walks first-run, default, join, empty-home and rerun flows through their actual
/// models and primary actions. Scripted clients and local Git fixtures isolate
/// host apps, shell and network. Assertions use the fixture's observed counts.
@Suite("Launchpad end to end", .serialized, .timeLimit(.minutes(5)))
@MainActor
struct LaunchpadEndToEndTests {
    // MARK: - Juniper

    @Test func juniperWalksFromWelcomeToHomeWithTheMockupsNumbers() async throws {
        let stage = try await EndToEndStage.juniper()
        defer { stage.remove() }
        let flow = stage.flow

        // Welcome, Your apps, What Agent Tooling reads, the read.
        try stage.press()
        #expect(flow.step == .apps)
        try stage.press()
        #expect(flow.step == .reads)
        try await stage.readThenContinue()
        let workspace = try #require(flow.workspace)

        // Your library, as read (S06): the stage audit's count.
        #expect(LibraryRowPresence.thingsToLookAt(workspace.setup.checkup) == 8)
        #expect(LaunchpadCopy.Found.thingsToLookAt(8) == "8 things to look at, later on Checkup")
        try stage.press()
        #expect(flow.step == .library)

        // Start your library (S08): Release Notes and Frontend Design, from
        // Claude Code's newer copy, made yours; Supabase added.
        try await stage.startYourLibrary { library in
            let notes = try #require(library.rows.first { $0.name == "Release Notes" })
            let design = try #require(library.rows.first { $0.name == "Frontend Design" })
            let claudesCopy = try #require(design.copies.first { $0.readers == [.claude] })
            library.toggle(notes.id)
            library.choose(claudesCopy.path, for: design.id)
            library.togglePick(EndToEndStage.supabase)
            #expect(library.primaryTitle == "Add 3 to library")
        }

        // Put in apps (S10), as it opens.
        try await stage.putInApps { _ in #expect(LaunchpadStageView.footer(for: flow).note == "2 changes so far") }

        // Let your apps ask (S11): Gemini CLI unticked, as the fragment draws.
        let review = try await stage.letYourAppsAsk { hookUp in
            hookUp.toggle(.gemini)
            #expect(hookUp.primaryTitle == "Review 4 changes…")
        }

        // The review (S12).
        #expect(review.title == "Install 4 changes")
        #expect(review.subtitle == "Into 2 apps on this Mac. Each step shows what it runs; Cancel writes nothing.")
        #expect(review.chip == "This Mac · Juniper")
        #expect(review.libraryLine == "· 7 decisions · these touch no app")
        #expect(flow.decisions.count == 7)
        #expect(review.listedCount == 5)
        #expect(review.runnableCount == 4)
        #expect(
            review.beforeYouApprove
                == "3 steps run a command · 1 step is left alone. Release Notes was checked for risky content; nothing was flagged.")
        try await stage.install(review, runner: stage.fixture.reviewRunner()) {
            try await stage.fixture.reviewObservationsAfterInstall()
        }
        #expect(LaunchpadReviewPanel.result(of: review) == "Installed to Claude Code and Codex.")
        flow.advance()
        #expect(flow.step == .assistant)

        // Let your assistant help (S15): the weekly review, with Claude Code.
        await workspace.recordAssistantRun(.weeklyReview, true).value
        try stage.press()
        #expect(flow.step == .behave)
        try stage.press()
        #expect(flow.step == .macs)

        // Your other Macs (S17): shared through a repository of its own.
        try await stage.connectAndShare()
        #expect(flow.step == .done)

        // Done (S22).
        let summary = try await stage.done()
        #expect(summary.title == "Set up, with 2 things left")
        #expect(summary.subtitle == "Juniper · Saturday, October 17 · Run setup again from Settings › General.")
        #expect(
            summary.happened.map { EndToEndStage.plain($0.text) } == [
                "3 apps looked after: Codex 0.164.0, Claude Code 2.1.304, Gemini CLI 0.38.2 · Kiro CLI not found",
                "12 tools in your library (9 entries) · 2 are now yours: Release Notes, Frontend Design",
                "4 changes installed in 2 apps · 1 left alone (Frontend Design in Codex)",
                "Agent Tooling connected to Codex and Claude Code",
                "Synced just now with \(stage.repositoryAddress) · ready for your other Mac",
                "Weekly checkup review on, with Claude Code · daily deep dive off",
                "After the next check, Gemini CLI also shows Release Notes, because it reads ~/.agents/skills.",
            ])
        #expect(summary.leftForLater.map(\.title) == ["Sign in to your connections", "4 things left on Checkup"])
        #expect(
            summary.leftForLater.map(\.detail) == [
                "Not checked yet · GitHub and Sentry in Claude Code may need you to sign in",
                "Webapp Testing unmanaged in Codex and in Claude Code; Context7 and Playwright each configured in two apps",
            ])
        #expect(LaunchpadCopy.Done.homeAdds(summary.suggestions) == "Home adds 2 suggestions")

        // Go to Home: the record, then Home's card (P01).
        try stage.press()
        #expect(flow.pendingHandOff == .overview)
        let record = try #require(stage.fixture.savedRecord(for: workspace))
        #expect(record.state == .finished)
        #expect(record.path == .startHere)
        #expect(record.items.count == 7)
        #expect(record.ticks.map(\.item) == [.makeSkillsYours, .putToolsInApps, .connectOtherMacs])
        #expect(record.ticks.allSatisfy { $0.place == .setup })
        try stage.expectHomesCard(
            done: ["Make your skills yours", "Put your tools in your apps", "Connect your other Macs"],
            open: ["Sign in to your connections", "Look at 4 things on Checkup", "Try Release Notes in Codex", "Track your projects"])
        let card = try #require(stage.card())
        #expect(card.rows.first { $0.item == .lookAtCheckup }?.caption == "Webapp Testing, Context7 and Playwright")
        #expect(card.rows.first { $0.item == .trackProjects }?.caption == "4 folders Claude Code has worked in")
        // Nothing on it came true in the hand-off itself: the tracker's first
        // look ticks nothing more.
        #expect(stage.firstLookTicks().isEmpty)
        // Home's own count of what Checkup holds agrees.
        #expect(workspace.setup.checkup.map(LibraryRowPresence.thingsToLookAt) == 4)
        // With Agent Tooling's own connection in the library now, Your
        // library's header still counts only what its list shows (D10).
        let state = try #require(workspace.library.state)
        #expect(state.library.holdingsSentence == "It holds 12 tools. 3 of them come inside plugins.")
        let listed = LibraryRowPresence.rows(
            in: state, observations: workspace.device.observations, managed: workspace.device.managedClients)
        #expect(listed.count == state.library.entryCount)
        #expect(state.library.entryCount == 9)
    }

    // MARK: - ↩ through

    /// Every step's primary, nothing changed: no skill is made yours, nothing
    /// is put in apps, Agent Tooling is connected to all three apps, sharing
    /// is skipped. Done counts 3 changes in 3 apps and Checkup's 8.
    @Test func returnThroughEveryStepTakesEveryDefault() async throws {
        let stage = try await EndToEndStage.juniper()
        defer { stage.remove() }
        let flow = stage.flow

        try stage.press()
        try stage.press()
        try await stage.readThenContinue()
        let workspace = try #require(flow.workspace)
        #expect(LibraryRowPresence.thingsToLookAt(workspace.setup.checkup) == 8)
        try stage.press()
        try await stage.startYourLibrary { library in #expect(library.primaryTitle == "Continue") }
        try await stage.putInApps { _ in }
        let review = try await stage.letYourAppsAsk { hookUp in #expect(hookUp.primaryTitle == "Review 3 changes…") }
        #expect(review.title == "Install 3 changes")
        #expect(review.runnableCount == 3)
        let apps: Set<ClientKind> = [.codex, .claude, .gemini]
        try await stage.install(review, runner: stage.helperRunner(for: apps)) {
            try await stage.fixture.endToEndObservations(afterConnecting: apps)
        }
        #expect(LaunchpadReviewPanel.result(of: review) == "Installed to Claude Code, Codex and Gemini CLI.")
        flow.advance()
        try stage.press()
        try stage.press()
        #expect(flow.step == .macs)
        let skip = try #require(LaunchpadStageView.footer(for: flow).primary)
        #expect(skip.title == "Skip for now")
        skip.action()
        #expect(flow.step == .done)

        let summary = try await stage.done()
        #expect(summary.title == "Set up, with 2 things left")
        let happened = summary.happened.map { EndToEndStage.plain($0.text) }
        #expect(happened.contains("3 changes installed in 3 apps"))
        #expect(happened.contains("Agent Tooling connected to Codex, Claude Code and Gemini CLI"))
        #expect(summary.leftForLater.map(\.title) == ["Sign in to your connections", "8 things left on Checkup"])
        #expect(summary.suggestions == 3)
        #expect(LaunchpadCopy.Done.homeAdds(summary.suggestions) == "Home adds 3 suggestions")

        try stage.press()
        let record = try #require(stage.fixture.savedRecord(for: workspace))
        #expect(record.state == .finished)
        // Agent Tooling's own connection is done, so it is no row of the
        // card; nothing was made yours, so neither is that. 1 of 6.
        #expect(record.ticks.map(\.item) == [.putToolsInApps])
        let card = try #require(stage.card())
        #expect(card.done == 1)
        #expect(card.total == 6)
        #expect(card.left == summary.leftForLater.count + summary.suggestions)
        #expect(card.rows.first { $0.item == .lookAtCheckup }?.title == "Look at 8 things on Checkup")
    }

    // MARK: - Cedar, with the detour

    /// Cedar joins the library Juniper shares, takes Connect it here too to
    /// Let your apps ask and back, installs what arrived, and finishes on the
    /// join's three steps.
    @Test func cedarJoinsConnectsAgentToolingHereTooAndFinishes() async throws {
        let juniper = try await JoinPublishedJuniper.make()
        defer { juniper.remove() }
        var cedar = try await JoinCedar()
        defer { cedar.remove() }
        try cedar.fixture.installHelperInApplications()
        let (flow, join) = await cedar.joinStage()
        let stage = EndToEndStage(fixture: cedar.fixture, flow: flow, repository: nil)

        // Join (J01): the four checks, then Join as Cedar ⌘↩.
        join.update(address: juniper.address)
        await join.check.checkNow(join.request)
        let joinAs = try #require(LaunchpadStageView.footer(for: flow).primary)
        #expect(joinAs.title == "Join as Cedar")
        #expect(joinAs.key == .commandReturn)
        joinAs.action()
        await waitUntil { flow.step == .arrivals }
        let workspace = try #require(flow.workspace)
        #expect(flow.path == .join)

        // You joined (J02): what Juniper shares, and its own connection,
        // set up on Juniper only.
        let arrivals = try #require(LaunchpadArrivalsScreen.arrivals(for: flow))
        await arrivals.load()
        #expect(arrivals.thisMacName == "Cedar")
        #expect(arrivals.installCount == 5)
        #expect(arrivals.helper != nil)
        #expect(LaunchpadStageView.footer(for: flow).primary?.title == "Review 5 changes…")

        // The detour: Let your apps ask, for Cedar, and its review, then back.
        LaunchpadArrivalsScreen.connectHere(flow)
        #expect(flow.step == .ask)
        #expect(flow.isDetour)
        #expect(flow.info.footerName == LaunchpadCopy.Footer.stepArrivals)
        #expect(flow.info.capsules == .init(reached: 2, total: 3))
        let helperReview = try await stage.letYourAppsAsk { hookUp in
            #expect(hookUp.primaryTitle == "Review 2 changes…")
        }
        #expect(flow.reviewReturn == .arrivals)
        #expect(helperReview.title == "Install 2 changes")
        try await stage.install(helperReview, runner: stage.helperRunner(for: [.codex, .claude])) {
            try await stage.fixture.endToEndObservations(afterConnecting: [.codex, .claude])
        }
        #expect(LaunchpadReviewPanel.result(of: helperReview) == "Installed to Claude Code and Codex.")
        flow.advance()
        #expect(flow.step == .arrivals)
        #expect(!flow.isDetour)

        // Back on You joined: the five arrivals, reviewed and installed.
        await arrivals.load()
        #expect(arrivals.installCount == 5)
        try stage.press()
        await waitUntil { flow.presentedReview != nil }
        let review = try #require(flow.presentedReview)
        await review.prepare()
        #expect(review.title == "Install 5 changes")
        #expect(review.chip == "This Mac · Cedar")
        let runner = AnsweringRunner()
        try await stage.install(review, runner: runner) {
            try await stage.fixture.endToEndObservations(afterConnecting: [], supabaseInClaudeCode: true)
        }
        #expect(LaunchpadReviewPanel.result(of: review) == "Installed to Claude Code and Codex.")
        #expect(runner.commands == ["claude plugin install supabase@claude-plugins-official --scope user"])
        flow.advance()
        #expect(flow.step == .assistant)
        #expect(flow.info.footerName == LaunchpadCopy.Footer.stepThisMac)
        try stage.press()
        #expect(flow.step == .behave)
        try stage.press()
        #expect(flow.step == .done)

        // Done, on the join's last capsule.
        #expect(flow.info.capsules == .init(reached: 3, total: 3))
        let summary = try await stage.done()
        let happened = summary.happened.map { EndToEndStage.plain($0.text) }
        #expect(happened.first == "2 apps looked after: Codex 0.164.0, Claude Code 2.1.304 · Gemini CLI and Kiro CLI not found")
        #expect(happened.contains("5 changes installed in 2 apps"))
        #expect(happened.contains("Agent Tooling connected to Codex and Claude Code"))
        #expect(summary.leftForLater.map(\.title) == ["1 thing left on Checkup"])
        #expect(summary.leftForLater.map(\.detail) == ["Db Migrations unmanaged in Claude Code"])
        #expect(summary.title == "Set up, with 1 thing left")

        try stage.press()
        #expect(flow.pendingHandOff == .overview)
        let record = try #require(stage.fixture.savedRecord(for: workspace))
        #expect(record.state == .finished)
        #expect(record.path == .join)
        // What came across from Juniper is no arrival on Cedar's Home: the
        // plan holds nothing more from another Mac.
        await workspace.incoming.review(installingAutomatically: false)
        #expect(workspace.incoming.lastChecked != nil, "the review read a plan")
        #expect(workspace.incoming.waiting.isEmpty)
    }

    // MARK: - An empty Mac (V01)

    /// No app found: Continue without apps makes an empty library, then the
    /// catalogs, how Agent Tooling behaves, other Macs, and Done.
    @Test func anEmptyMacGoesFromYourAppsToDone() async throws {
        let fixture = try await LaunchpadFixture(.emptyMac)
        defer { fixture.remove() }
        let stage = EndToEndStage(fixture: fixture, flow: fixture.flow(), repository: nil)
        let flow = stage.flow

        try stage.press()
        #expect(flow.step == .apps)
        try stage.press()
        await waitUntil { flow.step == .library }
        let workspace = try #require(flow.workspace)
        #expect(fixture.firstReads.started.isEmpty)
        try await stage.startYourLibrary { library in #expect(!library.showsSkills) }
        #expect(flow.step == .behave)
        try stage.press()
        #expect(flow.step == .macs)
        try stage.press()
        #expect(flow.step == .done)

        let summary = try await stage.done()
        #expect(summary.title == "All set")
        // What the table passed over, each with its reason: the read and
        // what it found, putting in apps, Agent Tooling's own connection and
        // the assistant.
        #expect(Set(flow.outcomes.skipped.keys) == [.reads, .found, .place, .ask, .assistant])
        try stage.press()
        let record = try #require(fixture.savedRecord(for: workspace))
        #expect(record.state == .finished)
        #expect(record.seen.isSuperset(of: [.apps, .library, .behave, .macs, .done]))
    }

    // MARK: - A rerun on a workspace made before Launchpad

    /// Left after Put in apps, a rerun writes no record (D20), yet what it
    /// placed is this Mac's own and never an arrival from another Mac; the
    /// projects choice What Agent Tooling reads took is this Mac's.
    @Test func aRerunLeftEarlyWritesNoRecordAndKeepsItsPlacementsItsOwn() async throws {
        let stage = try await EndToEndStage.legacy()
        defer { stage.remove() }
        let flow = stage.flow
        let workspace = try #require(flow.workspace)
        #expect(workspace.setupProgress.status == .legacy)
        #expect(AssistantRunsNotice.shows(for: workspace.device))

        // Your apps, with no Back, then What Agent Tooling reads, with the
        // project history turned off this time.
        #expect(flow.step == .apps)
        #expect(flow.info.back == nil)
        try stage.press()
        #expect(flow.step == .reads)
        LaunchpadTileSequenceScreen.setFindsProjects(false, flow: flow)
        try await stage.readThenContinue()
        // The read is adopted, and its projects choice with it.
        #expect(workspace.device.findsProjectsFromClaudeHistory == false)
        try stage.press()
        try await stage.startYourLibrary { library in
            let notes = try #require(library.rows.first { $0.name == "Release Notes" })
            library.toggle(notes.id)
        }
        try await stage.putInApps { _ in }
        #expect(flow.step == .ask)
        let placed = flow.decisions.contributionIDs
        #expect(!placed.isEmpty)

        // Go to Home from FooterConfirm.
        flow.requestClose()
        #expect(flow.leaveMoment == .rerun)
        flow.leave()
        #expect(flow.pendingHandOff == .overview)
        #expect(stage.fixture.savedRecord(for: workspace) == nil, "a rerun left early writes no record")
        #expect(workspace.setupProgress.placementsMadeHere.isSuperset(of: placed))

        // What it placed waits on Home as this Mac's own, never as from
        // another Mac, now and after a relaunch.
        await workspace.incoming.review(installingAutomatically: false)
        #expect(workspace.incoming.lastChecked != nil, "the review read a plan")
        #expect(workspace.incoming.waiting.isEmpty)
        // Without the exclusion they would be arrivals: the plan installs
        // what was placed, as every Mac's intent, and nothing else marks it
        // as this Mac's own.
        let plan = try #require(workspace.deployment.plan)
        let library = try #require(workspace.library.state).library
        #expect(
            !WorkspaceIncomingSession.arrivals(in: plan, library: library, thisDevice: workspace.library.deviceID).isEmpty,
            "without the exclusion they would be arrivals")
        let reopened = WorkspaceLaunch.sessions(
            store: workspace.store, homeRoot: stage.fixture.home, isFirstRun: false, services: stage.fixture.environment.sessions)
        #expect(reopened.setupProgress.placementsMadeHere.isSuperset(of: placed))
        await reopened.incoming.review(installingAutomatically: false)
        #expect(reopened.incoming.lastChecked != nil, "the review read a plan")
        #expect(reopened.incoming.waiting.isEmpty)
        #expect(reopened.setupProgress.record == nil)
        #expect(reopened.device.findsProjectsFromClaudeHistory == false)
    }

    /// Walked to Done, a rerun on a workspace made before Launchpad writes a
    /// finished record on the rerun path, and Let your assistant help
    /// records the runs it showed, which ends Home's notice.
    @Test func aRerunWalkedToDoneWritesARerunRecordAndEndsTheNotice() async throws {
        let stage = try await EndToEndStage.legacy()
        defer { stage.remove() }
        let flow = stage.flow
        let workspace = try #require(flow.workspace)
        #expect(AssistantRunsNotice.shows(for: workspace.device))

        try stage.press()
        try await stage.readThenContinue()
        try stage.press()
        try await stage.startYourLibrary { _ in }
        try await stage.putInApps { _ in }
        let review = try await stage.letYourAppsAsk { hookUp in hookUp.toggle(.gemini) }
        let apps: Set<ClientKind> = [.codex, .claude]
        try await stage.install(review, runner: stage.helperRunner(for: apps)) {
            try await stage.fixture.endToEndObservations(afterConnecting: apps)
        }
        flow.advance()
        #expect(flow.step == .assistant)
        // Let your assistant help shows the runs the workspace always had;
        // Continue records them as this Mac's choice.
        #expect(workspace.device.assistantRuns == nil)
        try stage.press()
        await waitUntil { workspace.device.assistantRuns != nil }
        #expect(workspace.device.assistantRuns == .existingBehaviour)
        #expect(!AssistantRunsNotice.shows(for: workspace.device))
        try stage.press()
        #expect(flow.step == .macs)
        try stage.press()
        #expect(flow.step == .done)
        #expect(stage.fixture.savedRecord(for: workspace) == nil, "nothing is written before Done")

        _ = try await stage.done()
        try stage.press()
        let record = try #require(stage.fixture.savedRecord(for: workspace))
        #expect(record.state == .finished)
        #expect(record.path == .rerun)
        #expect(record.evidence.projectFolderCount == 4, "the rerun's read counted Claude Code's project folders")
        #expect(SetupStatus(record) == .finished(path: .rerun, seenPreferences: true))
        #expect(!AssistantRunsNotice.shows(for: workspace.device))
    }
}

// MARK: - The walk

/// One walk's stage: the sample world, a copy of Agent Tooling in the
/// fixture's own Applications folder with its helper, Git run for real over
/// the file transport, and an empty repository to share to.
@MainActor
struct EndToEndStage {
    var fixture: LaunchpadFixture
    let flow: LaunchpadFlow
    let repository: MacsRepository?

    /// Supabase's card on Start your library.
    static let supabase = "claude:supabase@claude-plugins-official"

    static func juniper() async throws -> EndToEndStage {
        var fixture = try await LaunchpadFixture(.juniper)
        do {
            try fixture.installHelperInApplications()
            let runner = JoinGitRunner(tools: fixture.world.scriptedRunner(), homeURL: fixture.home)
            fixture.environment.makeRunner = { _ in runner }
            let repository = try MacsRepository(in: fixture.world.home.root)
            return EndToEndStage(fixture: fixture, flow: fixture.flow(), repository: repository)
        } catch {
            fixture.remove()
            throw error
        }
    }

    /// A workspace Juniper made before Launchpad: the library from its read,
    /// no setup record, the assistant's runs never chosen; and the stage
    /// opened on it to run setup again.
    static func legacy() async throws -> EndToEndStage {
        var fixture = try await LaunchpadFixture(.juniper)
        do {
            try fixture.installHelperInApplications()
            var preferences = fixture.seed.preferences
            preferences.assistantRuns = nil
            preferences.findsProjectsFromClaudeHistory = nil
            let workspace = try await WorkspaceLaunch.create(
                observations: fixture.orderedObservations, preferences: preferences, supportRoot: fixture.support,
                homeRoot: fixture.home, beforeRecord: { _ in }, services: fixture.environment.sessions)
            await workspace.library.refresh()
            return EndToEndStage(fixture: fixture, flow: fixture.flow(.rerun, workspace: workspace), repository: nil)
        } catch {
            fixture.remove()
            throw error
        }
    }

    var repositoryAddress: String { repository?.address ?? "" }

    func remove() { fixture.remove() }

    /// The current step's primary, as its button or its key presses it.
    func press(sourceLocation: SourceLocation = #_sourceLocation) throws {
        let primary = try #require(LaunchpadStageView.footer(for: flow).primary, sourceLocation: sourceLocation)
        #expect(primary.isEnabled, "\(flow.step)'s primary is disabled", sourceLocation: sourceLocation)
        primary.action()
    }

    /// What Agent Tooling reads: Continue starts the read, and once the
    /// library holds it, Continue goes on to Your library.
    func readThenContinue(sourceLocation: SourceLocation = #_sourceLocation) async throws {
        try press(sourceLocation: sourceLocation)
        let read = LaunchpadTileSequenceScreen.read(flow)
        await waitUntil { read.phase == .finished || read.failure != nil }
        #expect(read.phase == .finished, sourceLocation: sourceLocation)
        try press(sourceLocation: sourceLocation)
        await waitUntil { flow.step == .found }
    }

    /// Start your library: the shelf read as the screen reads it, `change`d,
    /// then its primary, which adds and moves on.
    func startYourLibrary(_ change: (LaunchpadLibraryAdditions) async throws -> Void) async throws {
        #expect(flow.step == .library)
        let library = LaunchpadLibraryAdditions.of(flow)
        library.services = LaunchpadLibraryAdditionsTests.services(fetches: LibraryFetchLog())
        await library.load()
        try await change(library)
        try press()
        await waitUntil { flow.step != .library }
    }

    /// Put in apps: the grid read as the screen reads it, `change`d, then
    /// Continue, which saves it and moves on.
    func putInApps(_ change: (LaunchpadPlacement) async throws -> Void) async throws {
        #expect(flow.step == .place)
        let placement = try #require(LaunchpadPlaceScreen.placement(for: flow))
        await placement.load(decisions: LaunchpadPlaceScreen.decisions(for: flow))
        try await change(placement)
        try press()
        await waitUntil { flow.step != .place }
    }

    /// Let your apps ask: the rows read, `change`d, then the primary, which
    /// records the choice and opens the review; the review, read.
    func letYourAppsAsk(_ change: (AgentToolingHookUp) async throws -> Void) async throws -> ScopedPlanReview {
        #expect(flow.step == .ask)
        let hookUp = AgentToolingHookUp.of(flow)
        await hookUp.load(decisions: flow.decisions)
        try await change(hookUp)
        try press()
        await waitUntil { flow.presentedReview != nil }
        let review = try #require(flow.presentedReview)
        await review.prepare()
        return review
    }

    /// The panel's ⌘↩: each app's own tool answered by `runner`, and the
    /// re-check after it answered with `observations`, read once the apps'
    /// files are written.
    func install(
        _ review: ScopedPlanReview, runner: some CommandRunning,
        observations: () async throws -> [TargetObservation]
    ) async throws {
        let workspace = try #require(flow.workspace)
        fixture.scriptReviewCommands(in: workspace, runner: runner)
        fixture.observer.answer(with: try await observations())
        #expect(LaunchpadReviewPanel.awaitsCommandReturn(review))
        let installing = try #require(LaunchpadReviewPanel.install(review, flow: flow))
        await installing.value
        #expect(flow.outcomes.install != nil)
    }

    /// Each of `apps` answering its own add of Agent Tooling's helper.
    func helperRunner(for apps: Set<ClientKind>) -> ScriptedCommandRunner {
        let helper = fixture.helperPath
        var byTool: [String: [[String]: ScriptedCommandRunner.Reply]] = [:]
        for app in apps {
            byTool[ClientExecutableLocator.executableName(for: app), default: [:]][
                AgentToolingConnection.previewArguments(client: app, helperPath: helper)] = .standardOutput("")
        }
        return ScriptedCommandRunner(byTool: byTool)
    }

    /// Your other Macs: the repository's address, its check, and Connect and
    /// share ⌘↩; then Continue.
    func connectAndShare() async throws {
        let workspace = try #require(flow.workspace)
        let repository = try #require(repository)
        let support = fixture.support
        let model = flow.model(for: .macs) {
            LaunchpadSyncConnect(
                workspace: workspace, environment: flow.environment, checkDelay: .zero,
                discardStaleCheckout: { try JoinCedar.setAside($0, in: support) })
        }
        await model.load()
        model.update(address: repository.address)
        await model.check.checkNow(model.request)
        let primary = try #require(LaunchpadStageView.footer(for: flow).primary)
        #expect(primary.title == "Connect and share")
        primary.action()
        await waitUntil { model.phase == .connected(.shared) }
        try press()
    }

    /// Done as it appears: its audit and what it reads in, then its summary.
    func done() async throws -> LaunchpadDoneSummary {
        #expect(flow.step == .done)
        let model = LaunchpadDoneScreen.model(flow)
        await model.appear(flow)
        return LaunchpadDoneSummary(try #require(LaunchpadDoneSummary.inputs(flow, model: model)))
    }

    /// Home's Finish setting up card as it stands.
    func card() -> FinishSetupChecklist? {
        guard let workspace = flow.workspace else { return nil }
        return FinishSetupChecklist.make(FinishSetupFacts.live(workspace: workspace), now: fixture.environment.now())
    }

    /// The card's rows, done and open, by title, in order.
    func expectHomesCard(done: [String], open: [String], sourceLocation: SourceLocation = #_sourceLocation) throws {
        let shown = try #require(card(), sourceLocation: sourceLocation)
        #expect(shown.title == "Finish setting up", sourceLocation: sourceLocation)
        #expect(shown.done == done.count, sourceLocation: sourceLocation)
        #expect(shown.total == done.count + open.count, sourceLocation: sourceLocation)
        #expect(shown.rows.filter(\.isDone).map(\.title) == done, sourceLocation: sourceLocation)
        #expect(shown.rows.filter { !$0.isDone }.map(\.title) == open, sourceLocation: sourceLocation)
        #expect(shown.rows.filter(\.isDone).allSatisfy { $0.donePlace == "in setup" }, sourceLocation: sourceLocation)
    }

    /// What the shell's tracker ticks on its first look at Home.
    func firstLookTicks() -> [FinishSetupItem] {
        guard let workspace = flow.workspace else { return [] }
        let facts = FinishSetupFacts.live(workspace: workspace)
        return FinishSetupTracker.ticks(
            FinishSetupChecklist.satisfied(facts), facts: facts, section: .overview, stagePresented: false, settled: false
        ).map(\.item)
    }

    /// Done's words with the glue and the break hints taken out.
    static func plain(_ text: String) -> String {
        text.replacingOccurrences(of: LaunchpadCopy.Done.glue, with: " ")
            .replacingOccurrences(of: "\u{200B}", with: "")
            .replacingOccurrences(of: "\u{2011}", with: "-")
    }
}

extension LaunchpadFixture {
    /// This copy of Agent Tooling in the fixture's own Applications folder,
    /// its helper a runnable file, so S11 can hand it to apps.
    mutating func installHelperInApplications() throws {
        let applications = world.home.root.appending(path: "Applications", directoryHint: .isDirectory)
        environment.installation = { HelperBundle.inApplications(applications) }
        try write(URL(filePath: helperPath), "#!/bin/sh\nexit 0\n")
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: helperPath)
    }

    /// What the re-check after an install reads once `apps` each registered
    /// Agent Tooling's own connection, and nothing else: each app's own
    /// configuration file gains the registration its tool writes, and Codex
    /// lists it. Every other app keeps its last check.
    ///
    /// `supabaseInClaudeCode` adds what Claude Code's own install of Supabase
    /// leaves: its plugin folder, its setting, and the plugin list naming it.
    func endToEndObservations(afterConnecting apps: Set<ClientKind>, supabaseInClaudeCode: Bool = false) async throws
        -> [TargetObservation]
    {
        let home = world.home
        let name = AgentToolingConnection.declaredName
        let encoder = JSONEncoder()
        encoder.outputFormatting = .withoutEscapingSlashes
        let helper = String(decoding: try encoder.encode(helperPath), as: UTF8.self)
        var replies = world.replies
        if supabaseInClaudeCode {
            let supabase = "supabase@claude-plugins-official"
            let folder = ".claude/plugins/cache/claude-plugins-official/supabase/1.0.0"
            try home.plant("\(folder)/.claude-plugin/plugin.json", #"{"name":"supabase","version":"1.0.0"}"# + "\n")
            let settingsURL = home.url.appending(path: ".claude/settings.json")
            var settings = (try? JSONSerialization.jsonObject(with: Data(contentsOf: settingsURL))) as? [String: Any] ?? [:]
            var enabled = settings["enabledPlugins"] as? [String: Any] ?? [:]
            enabled[supabase] = true
            settings["enabledPlugins"] = enabled
            let settingsData = try JSONSerialization.data(withJSONObject: settings, options: [.sortedKeys, .withoutEscapingSlashes])
            try home.plant(".claude/settings.json", String(decoding: settingsData, as: UTF8.self) + "\n")
            var plugins =
                try JSONSerialization.jsonObject(with: Data((world.answers(for: .claude)[["plugin", "list", "--json"]] ?? "[]").utf8))
                as? [Any] ?? []
            plugins.append([
                "id": supabase, "version": "1.0.0", "scope": "user", "enabled": true,
                "installPath": "\(ProjectPath.canonical(home.url))/\(folder)",
            ])
            let pluginData = try JSONSerialization.data(withJSONObject: plugins, options: [.sortedKeys, .withoutEscapingSlashes])
            replies[ClientExecutableLocator.executableName(for: .claude)]?[["plugin", "list", "--json"]] =
                .standardOutput(String(decoding: pluginData, as: UTF8.self) + "\n")
        }
        for app in apps {
            switch app {
            case .claude:
                try endToEndMerge(into: ".claude.json", server: name)
            case .gemini:
                try endToEndMerge(into: ".gemini/settings.json", server: name)
            case .codex:
                let config = home.url.appending(path: ".codex/config.toml")
                let existing = (try? String(contentsOf: config, encoding: .utf8)) ?? ""
                try home.plant(".codex/config.toml", existing + "\n[mcp_servers.\(name)]\ncommand = \(helper)\nargs = []\n")
                let codexServers = world.answers(for: .codex)[["mcp", "list", "--json"]] ?? "[]"
                var listed = try JSONSerialization.jsonObject(with: Data(codexServers.utf8)) as? [Any] ?? []
                listed.append([
                    "name": name, "enabled": true, "transport": ["type": "stdio", "command": helperPath, "args": [String]()],
                    "auth_status": "unsupported",
                ])
                let data = try JSONSerialization.data(withJSONObject: listed, options: [.sortedKeys, .withoutEscapingSlashes])
                replies[ClientExecutableLocator.executableName(for: .codex)]?[["mcp", "list", "--json"]] =
                    .standardOutput(String(decoding: data, as: UTF8.self) + "\n")
            case .kiro:
                break
            }
        }
        let runner = ScriptedCommandRunner(
            byTool: replies,
            missingTools: Set(
                ClientKind.allCases.filter { !world.found.contains($0) }.map(ClientExecutableLocator.executableName(for:))))
        let rechecked = await world.registry.scanAll(
            homeURL: home.url, runner: runner, clients: apps.union(supabaseInClaudeCode ? [.claude] : []))
        let surfaces = Set(rechecked.map(\.surface))
        let kept = orderedObservations.filter { !surfaces.contains($0.surface) }
        return ClientKind.allCases.flatMap { client in (kept + rechecked).filter { $0.surface.client == client } }
    }

    /// Adds the helper's registration under `server` to the JSON
    /// configuration file at `relative`, keeping what it holds.
    private func endToEndMerge(into relative: String, server: String) throws {
        let url = world.home.url.appending(path: relative)
        var object = (try? JSONSerialization.jsonObject(with: Data(contentsOf: url))) as? [String: Any] ?? [:]
        var servers = object["mcpServers"] as? [String: Any] ?? [:]
        servers[server] = ["type": "stdio", "command": helperPath, "args": [String]()]
        object["mcpServers"] = servers
        let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])
        try world.home.plant(relative, String(decoding: data, as: UTF8.self) + "\n")
    }
}

/// Every app's own tool answering whatever it is asked, with each command
/// kept, by the tool's name, in order: for an install whose commands a test
/// reads afterwards.
final class AnsweringRunner: CommandRunning, @unchecked Sendable {
    private let lock = NSLock()
    private var made: [String] = []

    var commands: [String] { lock.withLock { made } }

    func run(executable: String, arguments: [String], currentDirectory: URL?) async throws -> CommandOutput {
        lock.withLock { made.append(([URL(filePath: executable).lastPathComponent] + arguments).joined(separator: " ")) }
        return CommandOutput(status: 0, standardOutput: "", standardError: "")
    }
}
