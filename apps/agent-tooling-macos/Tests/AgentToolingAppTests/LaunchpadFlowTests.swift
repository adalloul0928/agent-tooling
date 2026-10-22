import AgentToolingCore
import AgentToolingTestSupport
import Foundation
import Testing

@testable import AgentToolingApp

/// The setup stage's one state, walked without drawing a screen.
///
/// The transition table is a pure function, so every path is walked as a
/// table. The flow itself is driven the way the stage drives it: each step's
/// primary is the footer's own action, the read is the scripted one the
/// fixture hands in, and the library is created in a scratch support folder.
@Suite("Launchpad flow", .serialized, .timeLimit(.minutes(5)))
@MainActor
struct LaunchpadFlowTests {
    /// Juniper: three apps found and managed, two of which can run an
    /// assistant.
    private static let juniper = LaunchpadTransitionContext(
        managed: [.codex, .claude, .gemini], observed: [.codex, .claude, .gemini], managesAssistant: true)
    /// V01: the library was created with no apps.
    private static let emptyMac = LaunchpadTransitionContext(startedEmpty: true)
    /// Only Gemini CLI, which runs no assistant.
    private static let geminiOnly = LaunchpadTransitionContext(managed: [.gemini], observed: [.gemini])

    // MARK: - The transition table

    /// Every step `next` reaches from `start`, in order.
    private func walk(from start: LaunchpadStep, path: LaunchpadPath, context: LaunchpadTransitionContext) -> [LaunchpadStep] {
        var steps = [start]
        while steps.count <= LaunchpadStep.allCases.count,
            let next = LaunchpadStep.next(after: steps[steps.count - 1], path: path, context: context)
        {
            steps.append(next)
        }
        return steps
    }

    @Test func startHereShowsEveryStepInOrder() {
        #expect(
            walk(from: .welcome, path: .startHere, context: Self.juniper) == [
                .welcome, .apps, .reads, .found, .library, .place, .ask, .assistant, .behave, .macs, .done,
            ])
    }

    @Test func beforeYouStartLeadsToWelcomeAndWelcomeWaitsForTheFork() {
        #expect(LaunchpadStep.next(after: .move, path: nil, context: Self.juniper) == .welcome)
        #expect(LaunchpadStep.next(after: .welcome, path: nil, context: Self.juniper) == nil)
        #expect(LaunchpadStep.next(after: .done, path: .startHere, context: Self.juniper) == nil)
    }

    @Test func joinGoesToYouJoinedThenThisMac() {
        #expect(
            walk(from: .welcome, path: .join, context: Self.juniper) == [
                .welcome, .join, .arrivals, .assistant, .behave, .done,
            ])
    }

    @Test func aRerunStartsAtYourAppsWithNoFork() {
        #expect(
            walk(from: .apps, path: .rerun, context: Self.juniper) == [
                .apps, .reads, .found, .library, .place, .ask, .assistant, .behave, .macs, .done,
            ])
    }

    /// V01: Continue without apps commits an empty library; there is nothing
    /// to read, place or connect, and no assistant to run.
    @Test func anEmptyMacGoesFromYourAppsToTheCatalogs() {
        #expect(walk(from: .welcome, path: .startHere, context: Self.emptyMac) == [.welcome, .apps, .library, .behave, .macs, .done])
    }

    /// A rerun reads whatever is turned on as it leaves Your apps: with
    /// nothing on it has nothing to read either, and with one app on it walks
    /// the whole way.
    @Test func aRerunReadsWhatIsTurnedOn() {
        let nothingOn = LaunchpadTransitionContext(startedEmpty: true)
        #expect(walk(from: .apps, path: .rerun, context: nothingOn) == [.apps, .library, .behave, .macs, .done])
        let claudeOn = LaunchpadTransitionContext(managed: [.claude], managesAssistant: true)
        #expect(
            walk(from: .apps, path: .rerun, context: claudeOn) == [
                .apps, .reads, .found, .library, .place, .ask, .assistant, .behave, .macs, .done,
            ])
    }

    @Test func withNoAssistantAppLetYourAssistantHelpIsPassedOver() {
        #expect(
            walk(from: .found, path: .startHere, context: Self.geminiOnly) == [
                .found, .library, .place, .ask, .behave, .macs, .done,
            ])
        #expect(walk(from: .arrivals, path: .join, context: Self.geminiOnly) == [.arrivals, .behave, .done])
    }

    @Test func withNoAppManagedThereIsNothingToPlaceOrConnect() {
        let none = LaunchpadTransitionContext(observed: [.codex])
        #expect(walk(from: .found, path: .startHere, context: none) == [.found, .library, .behave, .macs, .done])
    }

    @Test func backOnStartHereNeverWalksBehindTheLibrary() {
        let expected: [(LaunchpadStep, LaunchpadStep?)] = [
            (.move, nil), (.welcome, nil), (.apps, .welcome), (.reads, .apps), (.found, nil), (.library, .found),
            (.place, .library), (.ask, .place), (.assistant, .ask), (.behave, .assistant), (.macs, .behave), (.done, nil),
        ]
        for (step, back) in expected {
            #expect(LaunchpadStep.back(from: step, path: .startHere, context: Self.juniper) == back, "Back from \(step)")
        }
    }

    @Test func backPassesOverWhatWasSkipped() {
        // V01's library is the first step past the commit point.
        #expect(LaunchpadStep.back(from: .library, path: .startHere, context: Self.emptyMac) == nil)
        #expect(LaunchpadStep.back(from: .behave, path: .startHere, context: Self.emptyMac) == .library)
        #expect(LaunchpadStep.back(from: .behave, path: .startHere, context: Self.geminiOnly) == .ask)
    }

    @Test func backOnJoinAndOnItsDetour() {
        let expected: [(LaunchpadStep, LaunchpadStep?)] = [
            (.join, .welcome), (.arrivals, nil), (.assistant, .arrivals), (.behave, .assistant), (.done, nil),
        ]
        for (step, back) in expected {
            #expect(LaunchpadStep.back(from: step, path: .join, context: Self.juniper) == back, "Back from \(step)")
        }
        #expect(LaunchpadStep.back(from: .ask, path: .join, context: Self.juniper, isDetour: true) == .arrivals)
    }

    @Test func aRerunHasNoBackFromYourApps() {
        let expected: [(LaunchpadStep, LaunchpadStep?)] = [(.apps, nil), (.reads, .apps), (.found, nil), (.library, .found)]
        for (step, back) in expected {
            #expect(LaunchpadStep.back(from: step, path: .rerun, context: Self.juniper) == back, "Back from \(step)")
        }
    }

    @Test func theRegistryNamesEachStartHereStepAndCountsItsCapsules() {
        let expected: [(LaunchpadStep, String, Int?)] = [
            (.move, "Before you start", nil), (.welcome, "Welcome", nil), (.apps, "Your apps", 1), (.reads, "Your apps", 1),
            (.found, "Your library", 2), (.library, "Your library", 2), (.place, "Put in apps", 3), (.ask, "Put in apps", 3),
            (.assistant, "Preferences", 4), (.behave, "Preferences", 4), (.macs, "Other Macs", 5), (.done, "Done", 5),
        ]
        for (step, name, reached) in expected {
            let info = LaunchpadStepInfo.of(step, path: .startHere, entry: .firstRun, context: Self.juniper)
            #expect(info.footerName == name, "\(step)")
            #expect(info.capsules == reached.map { .init(reached: $0, total: 5) }, "\(step)")
        }
    }

    /// D23: on the detour from You joined, Let your apps ask keeps Arrivals'
    /// name and capsules.
    @Test func joinCountsThreeCapsulesAndItsDetourKeepsArrivals() {
        let expected: [(LaunchpadStep, Bool, String, Int?)] = [
            (.join, false, "Join", 1), (.arrivals, false, "Arrivals", 2), (.ask, true, "Arrivals", 2),
            (.assistant, false, "This Mac", 3), (.behave, false, "This Mac", 3), (.done, false, "Done", 3),
        ]
        for (step, isDetour, name, reached) in expected {
            let info = LaunchpadStepInfo.of(step, path: .join, entry: .firstRun, context: Self.juniper, isDetour: isDetour)
            #expect(info.footerName == name, "\(step)")
            #expect(info.capsules == reached.map { .init(reached: $0, total: 3) }, "\(step)")
        }
    }

    @Test func aRevisitShowsOneStepWithNoCapsulesAndNoBack() {
        let info = LaunchpadStepInfo.of(.behave, path: .startHere, entry: .revisit(.behave), context: Self.juniper)
        #expect(info.capsules == nil)
        #expect(info.back == nil)
        #expect(info.footerName == "Preferences")
    }

    @Test func yourAppsTheReadAndWhatWasFoundAreOneView() {
        for step in LaunchpadStep.allCases {
            let expected: LaunchpadTransitionGroup = [.apps, .reads, .found].contains(step) ? .tiles : .single(step)
            #expect(step.transitionGroup == expected, "\(step)")
        }
    }

    @Test func theLibraryExistsFromYourLibraryAsReadAndFromYouJoined() {
        let before: Set<LaunchpadStep> = [.move, .welcome, .apps, .reads, .join]
        for step in LaunchpadStep.allCases {
            #expect(step.isPostCommit == !before.contains(step), "\(step)")
        }
    }

    // MARK: - Entries

    @Test func aFirstRunOpensOnWelcomeWithNothingWritten() async throws {
        let fixture = try await LaunchpadFixture()
        defer { fixture.remove() }
        let flow = fixture.flow()

        #expect(flow.step == .welcome)
        #expect(flow.path == nil)
        #expect(!flow.isPostCommit)
        #expect(flow.info.capsules == nil)
        #expect(flow.leaveMoment == .beforeCommit)
        #expect(!fixture.hasWorkspace)
    }

    @Test func aCopyThatShouldMoveOpensOnBeforeYouStart() async throws {
        let bundle = URL(filePath: "/private/var/folders/xy/AppTranslocation/Agent Tooling.app", directoryHint: .isDirectory)
        let fixture = try await LaunchpadFixture(
            installation: AgentToolingInstallation(
                bundleURL: bundle, location: .translocated(bundle),
                mcpHelperURL: bundle.appending(path: "Contents/Helpers/agent-tooling-mcp"), cliHelperURL: nil,
                isAdHocSigned: false))
        defer { fixture.remove() }
        let flow = fixture.flow()

        #expect(flow.step == .move)
        // Keep it here goes on to Welcome; the primary moves this copy, which
        // `MoveToApplicationsTests` rehearses.
        let keep = try #require(LaunchpadStageView.footer(for: flow).secondary)
        keep.action()
        #expect(flow.step == .welcome)
    }

    @Test func eachEntryOpensWhereItSays() async throws {
        let fixture = try await LaunchpadFixture()
        defer { fixture.remove() }
        let workspace = try await fixture.sample(.afterRead).workspace

        let continued = fixture.flow(.continueFirstRun(.library), workspace: workspace)
        #expect(continued.step == .library)
        #expect(continued.path == .startHere)
        let resumed = fixture.flow(.resume(.place), workspace: workspace)
        #expect(resumed.step == .place)
        #expect(resumed.path == .startHere)
        let rerun = fixture.flow(.rerun, workspace: workspace)
        #expect(rerun.step == .apps)
        #expect(rerun.path == .rerun)
        #expect(rerun.info.back == nil)
        let revisit = fixture.flow(.revisit(.behave), workspace: workspace)
        #expect(revisit.step == .behave)
        #expect(revisit.info.capsules == nil)
        let finishJoin = fixture.flow(.finishJoin(WorkspaceObjectID()))
        #expect(finishJoin.step == .join)
        #expect(finishJoin.path == .join)
    }

    // MARK: - The interim walk

    /// The acceptance walk: every placeholder's primary, from Welcome to Done,
    /// on Juniper. The read is the scripted one, the library is created from
    /// it, and the record on disk reads finished.
    @Test func theInterimFlowWalksFromWelcomeToDoneAndTheRecordReadsFinished() async throws {
        let fixture = try await LaunchpadFixture()
        defer { fixture.remove() }
        let flow = fixture.flow()

        try pressPrimary(flow)
        #expect(flow.step == .apps)
        #expect(flow.path == .startHere)
        try pressPrimary(flow)
        #expect(flow.step == .reads)
        #expect(flow.seedOverride?.chosen == fixture.world.found)
        try await readThenContinue(flow)
        await waitUntil { flow.step == .found }

        let workspace = try #require(flow.workspace)
        #expect(fixture.firstReads.started == [.codex, .claude, .gemini])
        // The library is made from the read itself: nothing is scanned again.
        #expect(fixture.observer.fullChecks == 0)
        #expect(workspace.device.observations.count == 3)
        #expect(fixture.savedRecord(for: workspace)?.cursor == .found)
        for expected: LaunchpadStep in [.library, .place, .ask] {
            // Put in apps reads its grid as it appears, and Continue saves it
            // before moving on.
            if flow.step == .place { await LaunchpadPlaceScreen.placement(for: flow)?.load(decisions: flow.decisions) }
            try pressPrimary(flow)
            await waitUntil { flow.step == expected }
            #expect(fixture.savedRecord(for: workspace)?.cursor == expected)
        }

        try pressPrimary(flow)
        let review = try #require(flow.presentedReview)
        await review.prepare()
        #expect(review.listedCount == 0)
        #expect(LaunchpadReviewPanel.result(of: review) == "Nothing to install.")
        flow.advance()
        #expect(flow.presentedReview == nil)
        #expect(flow.step == .assistant)
        for expected: LaunchpadStep in [.behave, .macs, .done] {
            try pressPrimary(flow)
            #expect(flow.step == expected)
        }

        // Done hands off once the audit it runs as it appears has returned.
        await LaunchpadDoneScreen.model(flow).appear(flow)
        try pressPrimary(flow)
        #expect(flow.pendingHandOff == .overview)
        let record = try #require(fixture.savedRecord(for: workspace))
        #expect(record.state == .finished)
        #expect(record.path == .startHere)
        #expect(record.cursor == .done)
        #expect(record.finishedAt == ClientHomeFixture.now)
        // Done fixes Home's rows from what the walk did: it made nothing
        // yours and installed nothing, so the card starts at connecting Agent
        // Tooling, with sharing, the sign-in, Checkup, a trial and projects.
        #expect(
            record.items == [
                .connectAgentTooling, .connectOtherMacs, .signInConnections, .lookAtCheckup, .trySkill, .trackProjects,
            ])
        #expect(record.seen == Set(LaunchpadStep.sequence(for: .startHere)))
        #expect(SetupStatus(record) == .finished(path: .startHere, seenPreferences: true))
    }

    /// What Done keeps for Home's card (the findings left at hand-off among
    /// it) goes in with the write that finishes the record, on a rerun that
    /// had no record before Done as on any other.
    @Test func doneKeepsItsEvidenceInTheWriteThatFinishes() async throws {
        let fixture = try await LaunchpadFixture()
        defer { fixture.remove() }
        let workspace = try await WorkspaceLaunch.create(
            observations: fixture.orderedObservations, preferences: fixture.seed.preferences, supportRoot: fixture.support,
            homeRoot: fixture.home, beforeRecord: { _ in }, services: fixture.environment.sessions)
        let flow = fixture.flow(.rerun, workspace: workspace)
        flow.go(to: .done)
        let evidence = SetupProgressRecord.Evidence(checkupFindingIDs: ["finding-1", "finding-2"], projectFolderCount: 4)

        flow.finish(handOffTo: .overview, evidence: evidence)

        let record = try #require(fixture.savedRecord(for: workspace))
        #expect(record.state == .finished)
        #expect(record.path == .rerun)
        #expect(record.evidence == evidence)
        #expect(flow.pendingHandOff == .overview)
    }

    @Test func doneHandsOffToCheckupFromItsSecondary() async throws {
        let fixture = try await LaunchpadFixture()
        defer { fixture.remove() }
        let workspace = try await fixture.sample(.afterRead).workspace
        let flow = fixture.flow(.continueFirstRun(.done), workspace: workspace)
        await LaunchpadDoneScreen.model(flow).appear(flow)

        let secondary = try #require(LaunchpadStageView.footer(for: flow).secondary)
        secondary.action()

        #expect(flow.pendingHandOff == .checkup)
        #expect(fixture.savedRecord(for: workspace)?.state == .finished)
    }

    // MARK: - Commit or adopt

    /// C1.8: whether the library exists decides what a read does, never the
    /// entry. A resumed setup that reads again adopts the read.
    @Test func aReadAfterTheCommitPointAdoptsInsteadOfCreating() async throws {
        let fixture = try await LaunchpadFixture()
        defer { fixture.remove() }
        let workspace = try await fixture.sample(.afterRead).workspace
        let flow = fixture.flow(.resume(.reads), workspace: workspace)

        try await readThenContinue(flow)
        await waitUntil { flow.step == .found }

        #expect(flow.workspace?.store.databaseURL == workspace.store.databaseURL)
        #expect(fixture.firstReads.started == [.codex, .claude, .gemini])
        #expect(fixture.observer.fullChecks == 0)
        #expect(workspace.device.observations.count == 3)
        #expect(LaunchpadTileSequenceScreen.read(flow).failure == nil)
    }

    @Test func aRerunReadAdoptsAndCreatesNothing() async throws {
        let fixture = try await LaunchpadFixture()
        defer { fixture.remove() }
        let workspace = try await fixture.sample(.afterRead).workspace
        let flow = fixture.flow(.rerun, workspace: workspace)

        try pressPrimary(flow)
        #expect(flow.step == .reads)
        try await readThenContinue(flow)
        await waitUntil { flow.step == .found }

        #expect(flow.workspace?.store.databaseURL == workspace.store.databaseURL)
        #expect(fixture.firstReads.started == [.codex, .claude, .gemini])
        #expect(LaunchpadTileSequenceScreen.read(flow).failure == nil)
    }

    /// V01: Continue without apps commits an empty library and goes to the
    /// catalogs; nothing is read.
    @Test func anEmptyMacCommitsAnEmptyLibraryAndGoesToTheCatalogs() async throws {
        let fixture = try await LaunchpadFixture(.emptyMac)
        defer { fixture.remove() }
        let flow = fixture.flow()

        try pressPrimary(flow)
        try pressPrimary(flow)
        await waitUntil { flow.step == .library }

        let workspace = try #require(flow.workspace)
        #expect(fixture.hasWorkspace)
        #expect(fixture.firstReads.started.isEmpty)
        #expect(flow.transitionContext.startedEmpty)
        #expect(flow.info.back == nil)
        #expect(fixture.savedRecord(for: workspace)?.cursor == .library)
        try pressPrimary(flow)
        #expect(flow.step == .behave)

        // Opened again at its cursor, the first run still has nothing to
        // read, place or connect.
        let continued = fixture.flow(.continueFirstRun(.library), workspace: workspace)
        #expect(continued.transitionContext.startedEmpty)
        try pressPrimary(continued)
        #expect(continued.step == .behave)
    }

    /// The main reason to run setup again: a library made with Continue
    /// without apps, then an app turned on at Your apps. The rerun reads it,
    /// and the library takes what it found.
    @Test func aRerunOverAnEmptyLibraryReadsTheAppTurnedOn() async throws {
        let fixture = try await LaunchpadFixture()
        defer { fixture.remove() }
        let workspace = try await WorkspaceLaunch.create(
            observations: [], preferences: LaunchpadSeed(chosen: []).preferences, supportRoot: fixture.support,
            homeRoot: fixture.home, beforeRecord: { _ in }, services: fixture.environment.sessions)
        let flow = fixture.flow(.rerun, workspace: workspace)
        #expect(flow.transitionContext.startedEmpty)

        await workspace.device.setEnabled(.claude, true)
        #expect(!flow.transitionContext.startedEmpty)
        try pressPrimary(flow)
        #expect(flow.step == .reads)
        try await readThenContinue(flow)
        await waitUntil { flow.step == .found }

        #expect(fixture.firstReads.started == [.claude])
        #expect(workspace.device.observations.map(\.surface) == [.claudeCode])
        #expect(fixture.observer.fullChecks == 0)
        try pressPrimary(flow)
        #expect(flow.step == .library)
        try pressPrimary(flow)
        #expect(flow.step == .place)
    }

    // MARK: - Leaving

    @Test func beforeTheCommitPointLeavingQuitsAndWritesNothing() async throws {
        let fixture = try await LaunchpadFixture()
        defer { fixture.remove() }
        let flow = fixture.flow()
        try pressPrimary(flow)

        flow.requestClose()
        #expect(flow.isConfirmingLeave)
        #expect(flow.leaveMoment == .beforeCommit)
        flow.leave()

        #expect(flow.quitRequested)
        #expect(flow.pendingHandOff == nil)
        #expect(!flow.isConfirmingLeave)
        #expect(!fixture.hasWorkspace)
    }

    @Test func afterTheCommitPointLeavingDefersAtTheCursor() async throws {
        let fixture = try await LaunchpadFixture()
        defer { fixture.remove() }
        let workspace = try await fixture.sample(.afterRead).workspace
        let flow = fixture.flow(.continueFirstRun(.found), workspace: workspace)
        try pressPrimary(flow)
        #expect(flow.step == .library)

        flow.requestClose()
        #expect(flow.leaveMoment == .afterCommit)
        flow.leave()

        #expect(flow.pendingHandOff == .overview)
        #expect(!flow.quitRequested)
        let record = try #require(fixture.savedRecord(for: workspace))
        #expect(record.state == .deferred)
        #expect(record.cursor == .library)
        #expect(SetupStatus(record) == .deferred(.library, path: .startHere, seenPreferences: false))
    }

    /// D20: resuming a setup left for later keeps it deferred, moves its
    /// cursor, and finishes it at Done.
    @Test func aResumedSetupStaysDeferredUntilDone() async throws {
        let fixture = try await LaunchpadFixture()
        defer { fixture.remove() }
        let workspace = try await fixture.sample(.afterRead).workspace
        workspace.setupProgress.deferSetup(at: .found, now: ClientHomeFixture.now)
        let flow = fixture.flow(.resume(.found), workspace: workspace)

        try pressPrimary(flow)
        #expect(fixture.savedRecord(for: workspace)?.state == .deferred)
        #expect(fixture.savedRecord(for: workspace)?.cursor == .library)
        flow.requestClose()
        #expect(flow.leaveMoment == .afterCommit)
        flow.leave()
        #expect(fixture.savedRecord(for: workspace)?.state == .deferred)
        #expect(fixture.savedRecord(for: workspace)?.cursor == .library)

        let again = fixture.flow(.resume(.library), workspace: workspace)
        again.go(to: .done)
        await LaunchpadDoneScreen.model(again).appear(again)
        try pressPrimary(again)
        #expect(fixture.savedRecord(for: workspace)?.state == .finished)
    }

    /// D20 and D27: a rerun on a workspace made before Launchpad writes no
    /// record as it walks, leaving early writes nothing, and only Done
    /// creates one, finished, on the rerun path.
    @Test func aRerunWritesNoRecordUntilDone() async throws {
        let fixture = try await LaunchpadFixture()
        defer { fixture.remove() }
        let workspace = try await WorkspaceLaunch.create(
            observations: fixture.orderedObservations, preferences: fixture.seed.preferences, supportRoot: fixture.support,
            homeRoot: fixture.home, beforeRecord: { _ in }, services: fixture.environment.sessions)
        #expect(workspace.setupProgress.status == .legacy)

        let left = fixture.flow(.rerun, workspace: workspace)
        try pressPrimary(left)
        left.requestClose()
        #expect(left.leaveMoment == .rerun)
        left.leave()
        #expect(left.pendingHandOff == .overview)
        #expect(fixture.savedRecord(for: workspace) == nil)

        let flow = fixture.flow(.rerun, workspace: workspace)
        try pressPrimary(flow)
        try await readThenContinue(flow)
        await waitUntil { flow.step == .found }
        for _ in 0..<3 {
            if flow.step == .place { await LaunchpadPlaceScreen.placement(for: flow)?.load(decisions: flow.decisions) }
            let from = flow.step
            try pressPrimary(flow)
            await waitUntil { flow.step != from }
        }
        #expect(flow.step == .ask)
        #expect(fixture.savedRecord(for: workspace) == nil)
        flow.go(to: .done)
        #expect(fixture.savedRecord(for: workspace) == nil)
        await LaunchpadDoneScreen.model(flow).appear(flow)
        try pressPrimary(flow)

        let record = try #require(fixture.savedRecord(for: workspace))
        #expect(record.state == .finished)
        #expect(record.path == .rerun)
        #expect(record.startedAt == ClientHomeFixture.now)
        #expect(SetupStatus(record) == .finished(path: .rerun, seenPreferences: false))
    }

    /// A revisit opens one step; its primary hands off and writes nothing.
    @Test func aRevisitHandsOffFromItsPrimaryAndWritesNothing() async throws {
        let fixture = try await LaunchpadFixture()
        defer { fixture.remove() }
        let workspace = try await fixture.sample(.afterRead).workspace
        let before = fixture.savedRecord(for: workspace)
        let flow = fixture.flow(.revisit(.behave), workspace: workspace)

        try pressPrimary(flow)

        #expect(flow.step == .behave)
        #expect(flow.pendingHandOff == .overview)
        #expect(flow.leaveMoment == .rerun)
        #expect(fixture.savedRecord(for: workspace) == before)
    }

    // MARK: - Escape

    @Test func escapeClosesAPopoverThenAsksThenKeepsGoing() async throws {
        let fixture = try await LaunchpadFixture()
        defer { fixture.remove() }
        let flow = fixture.flow()
        flow.openPopover = "What it reads"

        flow.escape()
        #expect(flow.openPopover == nil)
        #expect(!flow.isConfirmingLeave)
        flow.escape()
        #expect(flow.isConfirmingLeave)
        flow.escape()
        #expect(!flow.isConfirmingLeave)
        #expect(flow.step == .welcome)
    }

    @Test func escapeOnDoneDoesNothing() async throws {
        let fixture = try await LaunchpadFixture()
        defer { fixture.remove() }
        let workspace = try await fixture.sample(.afterRead).workspace
        let flow = fixture.flow(.continueFirstRun(.done), workspace: workspace)

        flow.escape()

        #expect(!flow.isConfirmingLeave)
        #expect(flow.step == .done)
    }

    @Test func escapeStopsTheReadAndKeepsNothing() async throws {
        let gate = GatedCommandRunner()
        let fixture = try await LaunchpadFixture(readGate: gate)
        defer { fixture.remove() }
        let flow = fixture.flow()
        try pressPrimary(flow)
        try pressPrimary(flow)
        try pressPrimary(flow)
        await gate.waitUntilCalled()
        let read = LaunchpadTileSequenceScreen.read(flow)
        #expect(flow.interruption == .stoppable)

        flow.escape()
        await waitUntil { read.phase == .idle && !read.isStopping }

        #expect(flow.step == .reads)
        #expect(flow.workspace == nil)
        #expect(!fixture.hasWorkspace)
        // Every app is read at once, and every read that reached its command
        // was stopped there.
        #expect(gate.cancelledCalls >= 1)
        #expect(gate.cancelledCalls == gate.launches.count)
        #expect(flow.interruption == .idle)
    }

    @Test func escapeAndCloseCancelTheReviewFirst() async throws {
        let fixture = try await LaunchpadFixture()
        defer { fixture.remove() }
        let workspace = try await fixture.sample(.afterRead).workspace
        let flow = fixture.flow(.continueFirstRun(.ask), workspace: workspace)

        try pressPrimary(flow)
        #expect(flow.presentedReview != nil)
        flow.escape()
        #expect(flow.presentedReview == nil)
        #expect(!flow.isConfirmingLeave)

        try pressPrimary(flow)
        flow.requestClose()
        #expect(flow.presentedReview == nil)
        #expect(!flow.isConfirmingLeave)
        #expect(flow.step == .ask)
    }

    // MARK: - Finishing

    /// D31: while something is finishing, nothing moves, nothing is left, and
    /// FooterConfirm says only what is finishing.
    @Test func nothingMovesWhileSomethingFinishes() async throws {
        let fixture = try await LaunchpadFixture()
        defer { fixture.remove() }
        let workspace = try await fixture.sample(.afterRead).workspace
        let flow = fixture.flow(.continueFirstRun(.library), workspace: workspace)
        let publish = flow.model(for: .macs) { HeldModel(.finishing(LaunchpadCopy.Footer.publishing)) }

        #expect(flow.interruption == .finishing(LaunchpadCopy.Footer.publishing))
        #expect(flow.leaveMoment == .finishing(LaunchpadCopy.Footer.publishing))
        flow.advance()
        flow.goBack()
        flow.go(to: .done)
        flow.finish(handOffTo: .overview)
        #expect(flow.step == .library)
        #expect(flow.pendingHandOff == nil)
        flow.escape()
        #expect(!flow.isConfirmingLeave)
        flow.requestClose()
        flow.leave()
        #expect(flow.pendingHandOff == nil)
        #expect(fixture.savedRecord(for: workspace)?.state == .inProgress)

        publish.interruption = .idle
        flow.keepGoing()
        try pressPrimary(flow)
        #expect(flow.step == .place)
    }

    @Test func finishingWinsOverStoppable() async throws {
        let fixture = try await LaunchpadFixture()
        defer { fixture.remove() }
        let flow = fixture.flow()
        let read = flow.model(for: .reads) { HeldModel(.stoppable) }
        #expect(flow.interruption == .stoppable)
        let join = flow.model(for: .join) { HeldModel(.finishing(LaunchpadCopy.Footer.finishingJoin)) }
        #expect(flow.interruption == .finishing(LaunchpadCopy.Footer.finishingJoin))
        join.interruption = .idle
        #expect(flow.interruption == .stoppable)
        read.interruption = .idle
        #expect(flow.interruption == .idle)
    }

    /// The commit itself is finishing: from the moment the read hands over
    /// until the library exists, the walk cannot be left or moved.
    @Test func theCommitIsWaitedOut() async throws {
        let fixture = try await LaunchpadFixture()
        defer { fixture.remove() }
        let flow = fixture.flow()
        try pressPrimary(flow)
        try pressPrimary(flow)
        try pressPrimary(flow)

        await waitUntil { flow.isCommitting }
        #expect(flow.interruption == .finishing(LaunchpadCopy.Footer.creatingLibrary))
        flow.goBack()
        flow.requestClose()
        flow.leave()
        #expect(flow.step == .reads)
        #expect(!flow.quitRequested)

        // The library is made and the read waits: nothing advances on its own.
        let read = LaunchpadTileSequenceScreen.read(flow)
        await waitUntil { read.phase == .finished }
        #expect(flow.step == .reads)
        try pressPrimary(flow)
        await waitUntil { flow.step == .found }
        // The sign-in reads the commit never waits for can still be stopped
        // until they land.
        await read.signIn.waitUntilFinished()
        #expect(flow.interruption == .idle)
    }

    @Test func aQuitStopsWhatCanStop() async throws {
        let fixture = try await LaunchpadFixture()
        defer { fixture.remove() }
        let flow = fixture.flow()
        let read = flow.model(for: .reads) { HeldModel(.stoppable) }
        let idle = flow.model(for: .join) { HeldModel(.idle) }

        await flow.prepareToQuit()

        #expect(read.interrupts == 1)
        #expect(idle.interrupts == 0)
        #expect(flow.interruption == .idle)
    }

    /// A stop that never ends does not hold the quit past the grace.
    @Test func aQuitWaitsForAStopAtMostTheGrace() async throws {
        let fixture = try await LaunchpadFixture()
        defer { fixture.remove() }
        let flow = fixture.flow()
        let stuck = flow.model(for: .reads) { HeldModel(.stoppable, holdsInterrupt: true) }

        let clock = ContinuousClock()
        let started = clock.now
        await flow.prepareToQuit()
        let waited = clock.now - started

        #expect(stuck.interrupts == 1)
        #expect(waited >= LaunchpadFlow.stopGrace)
        stuck.letGo()
    }

    @Test func aQuitWaitsOutWhatIsFinishing() async throws {
        let fixture = try await LaunchpadFixture()
        defer { fixture.remove() }
        let flow = fixture.flow()
        let join = flow.model(for: .join) { HeldModel(.finishing(LaunchpadCopy.Footer.finishingJoin)) }
        let read = flow.model(for: .reads) { HeldModel(.stoppable) }

        await flow.finishPendingWork()

        #expect(join.interrupts == 1)
        #expect(read.interrupts == 0)
    }

    // MARK: - Join

    /// D23: You joined, its detour to Let your apps ask, and the way back.
    @Test func aJoinHandsOverAtYouJoinedAndItsDetourComesBack() async throws {
        let fixture = try await LaunchpadFixture()
        defer { fixture.remove() }
        let joined = try await fixture.sample(.afterRead).workspace
        let flow = fixture.flow(.finishJoin(joined.store.workspaceID))

        await flow.didJoin(joined)
        #expect(flow.step == .arrivals)
        #expect(flow.path == .join)
        #expect(flow.info.capsules == .init(reached: 2, total: 3))
        #expect(flow.info.back == nil)

        // You joined's Connect it here too.
        LaunchpadArrivalsScreen.connectHere(flow)
        #expect(flow.step == .ask)
        #expect(flow.isDetour)
        #expect(flow.info.footerName == LaunchpadCopy.Footer.stepArrivals)
        #expect(flow.info.capsules == .init(reached: 2, total: 3))
        #expect(flow.info.back == .arrivals)
        flow.advance()
        #expect(flow.step == .arrivals)
        #expect(!flow.isDetour)

        flow.go(to: .ask)
        flow.goBack()
        #expect(flow.step == .arrivals)
        #expect(!flow.isDetour)

        flow.go(to: .ask)
        try pressPrimary(flow)
        #expect(flow.reviewReturn == .arrivals)
        flow.advance()
        #expect(flow.step == .arrivals)
        #expect(flow.presentedReview == nil)

        // You joined reads what arrived as it appears; with nothing from
        // another Mac, its primary is Continue.
        await LaunchpadArrivalsScreen.arrivals(for: flow)?.load()
        try pressPrimary(flow)
        #expect(flow.step == .assistant)
        #expect(flow.info.footerName == LaunchpadCopy.Footer.stepThisMac)
    }

    // MARK: - ⌘↩

    @Test func aPlainReturnWhereOnlyCommandReturnActsShowsTheHint() async throws {
        let fixture = try await LaunchpadFixture()
        defer { fixture.remove() }
        let flow = fixture.flow(.finishJoin(WorkspaceObjectID()))
        #expect(LaunchpadStageView.footer(for: flow).primary?.key == .commandReturn)

        flow.showCommandReturnHint()
        flow.showCommandReturnHint()

        #expect(flow.commandReturnHint)
        #expect(flow.commandReturnFlash == 2)
        flow.requestClose()
        flow.keepGoing()
        flow.go(to: .welcome)
        #expect(!flow.commandReturnHint)
    }

    // MARK: - Helpers

    /// Continue on What Agent Tooling reads starts the read; once the
    /// library holds it, Continue goes on to Your library. Nothing advances
    /// on its own (S05).
    private func readThenContinue(_ flow: LaunchpadFlow, sourceLocation: SourceLocation = #_sourceLocation) async throws {
        try pressPrimary(flow, sourceLocation: sourceLocation)
        let read = LaunchpadTileSequenceScreen.read(flow)
        await waitUntil { read.phase == .finished || read.failure != nil }
        #expect(read.phase == .finished, sourceLocation: sourceLocation)
        #expect(flow.step == .reads, sourceLocation: sourceLocation)
        try pressPrimary(flow, sourceLocation: sourceLocation)
    }

    /// Presses the current step's primary, as the footer's button does.
    private func pressPrimary(_ flow: LaunchpadFlow, sourceLocation: SourceLocation = #_sourceLocation) throws {
        let primary = try #require(LaunchpadStageView.footer(for: flow).primary, sourceLocation: sourceLocation)
        #expect(primary.isEnabled, "\(flow.step)'s primary is disabled", sourceLocation: sourceLocation)
        primary.action()
    }
}

/// The sample world's snapshots, as the lanes build their screens on them.
@Suite("Launchpad sample world", .serialized, .timeLimit(.minutes(5)))
@MainActor
struct LaunchpadSampleWorldTests {
    @Test func afterTheReadTheLibraryHoldsWhatWasReadAndNothingRan() async throws {
        let fixture = try await LaunchpadFixture()
        defer { fixture.remove() }
        let sample = try await fixture.sample(.afterRead)
        let workspace = sample.workspace

        #expect(workspace.device.managedClients == [.codex, .claude, .gemini])
        #expect(workspace.device.observations.count == 3)
        #expect(workspace.device.lastCheckedAt == ClientHomeFixture.now)
        #expect(workspace.device.assistantRuns == AssistantRunConsent.off)
        #expect(workspace.device.findsProjectsFromClaudeHistory == true)
        #expect(sample.artifact("release-notes")?.authority == .trackedOnly)
        #expect(sample.artifact("frontend-design") != nil)
        #expect(Set(workspace.accounts.observations.keys) == [.chatGPT, .claude])
        #expect(fixture.savedRecord(for: workspace)?.cursor == .found)
        #expect(sample.outcomes.read?.looked.map(\.version) == ["0.164.0", "2.1.304", "0.38.2"])
        #expect(sample.outcomes.read?.notFound == [.kiro])
        // D34: the stage audit asked no shell, scanned nothing and read no
        // account.
        #expect(fixture.observer.fullChecks == 0)
        #expect(fixture.setup.searchPathCalls == 0)
        #expect(workspace.setup.checkup != nil)
    }

    @Test func afterYourLibraryTwoSkillsAreYoursAndSupabaseIsAdded() async throws {
        let fixture = try await LaunchpadFixture()
        defer { fixture.remove() }
        let sample = try await fixture.sample(.afterLibrary)

        #expect(sample.artifact("release-notes")?.authority == .centralPersonal)
        #expect(sample.artifact("frontend-design")?.authority == .centralPersonal)
        #expect(sample.artifact("supabase@claude-plugins-official")?.authority == .nativeOwned)
        #expect(
            sample.decisions.lines == [
                "Made Release Notes yours", "Made Frontend Design yours, from Claude Code’s copy",
                "Added Supabase, from Claude Code’s catalog",
            ])
        #expect(sample.outcomes.addedPluginsAwaitingCheck == ["Supabase"])
        #expect(fixture.savedRecord(for: sample.workspace)?.cursor == .place)
    }

    @Test func afterPutInAppsEachItemGoesToEveryMac() async throws {
        let fixture = try await LaunchpadFixture()
        defer { fixture.remove() }
        let sample = try await fixture.sample(.afterPlace)
        let assignments = try #require(sample.workspace.library.state?.snapshot.document.assignments)

        #expect(assignments.count == 5)
        #expect(assignments.allSatisfy { $0.destination.deviceIDs == nil })
        #expect(
            sample.decisions.lines.suffix(3) == [
                "Release Notes goes to Codex and Claude Code on every Mac",
                "Frontend Design goes to Codex and Claude Code on every Mac", "Supabase goes to Claude Code on every Mac",
            ])
        #expect(fixture.savedRecord(for: sample.workspace)?.evidence.placedContributionIDs == sample.decisions.contributionIDs)
    }

    /// S12: five steps listed, four run, and Frontend Design in Codex is left
    /// alone because Codex has a copy Agent Tooling did not put there.
    @Test func afterLetYourAppsAskTheReviewListsFiveAndRunsFour() async throws {
        let fixture = try await LaunchpadFixture()
        defer { fixture.remove() }
        let (flow, sample) = try await fixture.flow(at: .afterAsk)
        let review = ScopedPlanReview(
            workspace: sample.workspace, scope: .wholePlan, deviceName: "Juniper", libraryDecisions: flow.decisions)

        await review.prepare()

        #expect(review.phase == .ready)
        #expect(review.listedCount == 5)
        #expect(review.runnableCount == 4)
        #expect(review.title == "Install 4 changes")
        #expect(review.subtitle == "Into 2 apps on this Mac. Each step shows what it runs; Cancel writes nothing.")
        #expect(review.groups.map(\.summary) == ["2 changes · 1 left alone", "2 changes"])
        #expect(review.groups.map(\.client) == [.codex, .claude])
        #expect(review.groups.first?.steps.filter { $0.state == .leftAlone }.count == 1)
        // Each app's steps in the order they run, by name, with the step left
        // alone after them: the same plan always reads the same way.
        let names = Dictionary(
            uniqueKeysWithValues: (sample.workspace.library.state?.snapshot.document.artifacts ?? []).map {
                ($0.identity.id, $0.identity.displayName)
            })
        #expect(
            review.groups.map { $0.steps.map { names[$0.id.artifactID] ?? "?" } } == [
                ["Release Notes", "Agent Tooling", "Frontend Design"], ["Supabase", "Agent Tooling"],
            ])
        #expect(
            review.beforeYouApprove
                == "3 steps run a command · 1 step is left alone. Release Notes was checked for risky content; nothing was flagged.")
        #expect(review.chip == "This Mac · Juniper")
        #expect(flow.step == .ask)
        #expect(flow.decisions.count == 7)
        #expect(flow.decisions.lines.last == "Agent Tooling’s own connection, for Codex and Claude Code on this Mac only")
        let helper = try #require(
            sample.workspace.library.state?.snapshot.document.artifacts.first {
                $0.identity.id == sample.decisions.helperArtifactID
            })
        let definitions = sample.workspace.library.state?.snapshot.document.mcpDefinitions ?? []
        #expect(AgentToolingConnection.isOwnConnection(helper, definitions: definitions))
    }

    /// A second ⌘↩ or click handled before the first install's own work
    /// begins finds the review already running: nothing installs twice.
    @Test func anInstallIsUnderWayFromTheMomentItIsAskedFor() async throws {
        let fixture = try await LaunchpadFixture()
        defer { fixture.remove() }
        let (flow, sample) = try await fixture.flow(at: .afterAsk)
        // Release Notes alone: a copy into Codex, the one step here that runs
        // no app's own tool.
        let releaseNotes = try #require(sample.decisions.adopted.first?.artifactID)
        let review = ScopedPlanReview(
            workspace: sample.workspace, scope: .artifacts([releaseNotes]), deviceName: "Juniper",
            libraryDecisions: flow.decisions)
        await review.prepare()
        #expect(review.runnableCount == 1)
        #expect(review.canInstall)

        // Two presses, the second handled before the first's own work has
        // begun: the second finds the review running and does nothing.
        let first = Task { await review.install() }
        let second = Task { await review.install() }
        await second.value
        #expect(review.isBusy)
        #expect(!review.canInstall)
        await first.value

        guard case .finished(let outcome) = review.phase else {
            Issue.record("The install did not finish: \(review.phase)")
            return
        }
        #expect(outcome.succeededSteps == 1)
        #expect(outcome.installed == [.codex])
    }

    @Test func afterTheInstallTheReCheckFindsWhatTheAppsInstalled() async throws {
        let fixture = try await LaunchpadFixture()
        defer { fixture.remove() }
        let sample = try await fixture.sample(.afterInstall)
        let workspace = sample.workspace

        #expect(FileManager.default.fileExists(atPath: fixture.home.appending(path: ".agents/skills/release-notes/SKILL.md").path))
        let claude = try #require(workspace.device.observations.first { $0.surface == .claudeCode })
        let codex = try #require(workspace.device.observations.first { $0.surface == .codexCLI })
        #expect(claude.discoveredPlugins.contains("supabase@claude-plugins-official"))
        #expect(claude.discoveredMCPServers.contains(AgentToolingConnection.declaredName))
        #expect(codex.discoveredMCPServers.contains(AgentToolingConnection.declaredName))
        // D29: only the apps the install touched were checked again.
        #expect(fixture.observer.scopedChecks == [[.codex, .claude]])
        #expect(fixture.observer.fullChecks == 0)
        let install = try #require(sample.outcomes.install)
        #expect(install.summary == "Installed to Claude Code and Codex.")
        #expect(install.receiptLine == "Installed 4 changes · \(install.finishedAt.formatted(date: .omitted, time: .shortened))")
        #expect(install.leftAlone.count == 1)
        #expect(fixture.savedRecord(for: workspace)?.cursor == .assistant)
    }

    /// Cedar joins what Juniper published: the library, both of Juniper's own
    /// skills' files, and Juniper's name; Agent Tooling's connection stays
    /// Juniper's.
    @Test func cedarJoinsTheLibraryJuniperShares() async throws {
        let fixture = try await LaunchpadFixture(.cedar)
        defer { fixture.remove() }
        let (flow, sample) = try await fixture.flow(at: .cedarJoined)
        defer { sample.remove() }
        let document = try #require(sample.workspace.library.state?.snapshot.document)

        #expect(flow.step == .arrivals)
        #expect(flow.path == .join)
        #expect(Set(document.deviceRegistry.map(\.name)) == ["Juniper", "Cedar"])
        #expect(sample.artifact("release-notes")?.authority == .centralPersonal)
        #expect(sample.artifact("frontend-design")?.authority == .centralPersonal)
        #expect(sample.artifact(AgentToolingConnection.declaredName) != nil)
        #expect(sample.workspace.device.managedClients == [.codex, .claude])
        #expect(fixture.savedRecord(for: sample.workspace)?.path == .join)
        for name in ["release-notes", "frontend-design"] {
            let digest = try #require(sample.artifact(name)?.contentDigest)
            #expect(try await sample.workspace.contentStore?.read(digest) != nil, "\(name)'s files came across")
        }
        // Juniper's connection is bound on Juniper only.
        #expect(sample.workspace.library.state?.snapshot.device.mcpBindings?.isEmpty ?? true)
    }
}

/// A model a step keeps, with whatever interruption a test gives it.
@MainActor
private final class HeldModel: LaunchpadInterruptible {
    var interruption: LaunchpadInterruption
    private(set) var interrupts = 0
    private let holdsInterrupt: Bool
    private var held: [CheckedContinuation<Void, Never>] = []

    /// `holdsInterrupt` keeps `interrupt()` from returning until `letGo()`.
    init(_ interruption: LaunchpadInterruption, holdsInterrupt: Bool = false) {
        self.interruption = interruption
        self.holdsInterrupt = holdsInterrupt
    }

    func interrupt() async {
        interrupts += 1
        if holdsInterrupt { await withCheckedContinuation { held.append($0) } }
        interruption = .idle
    }

    func letGo() {
        let waiting = held
        held = []
        for continuation in waiting { continuation.resume() }
    }
}
