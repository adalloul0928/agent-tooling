import AgentToolingCore
import AgentToolingTestSupport
import Foundation
import Testing

@testable import AgentToolingApp

/// Join your library (J01, V08) and Finish joining, on the sample world: Cedar
/// joins the library Juniper published, through the stage's own model, with
/// real Git against a repository on this Mac and every app's command scripted.
///
/// A Stop before Registering leaves no store and no locator; from the store
/// on, the join is waited out, a quit included; a join that stopped after its
/// store existed is finished with Finish joining, in the same session or at
/// the next launch; and a typo stops at the check that found it, with Try
/// again checking afresh.
@Suite("Launchpad join", .serialized, .timeLimit(.minutes(5)))
@MainActor
struct LaunchpadJoinTests {
    /// The acceptance walk: the four checks pass, Join as Cedar runs, and the
    /// stage lands on You joined with the registered name and 5 arrivals.
    @Test func cedarPassesItsFourChecksAndLandsOnYouJoined() async throws {
        let juniper = try await JoinPublishedJuniper.make()
        defer { juniper.remove() }
        let cedar = try await JoinCedar()
        defer { cedar.remove() }
        let (flow, model) = await cedar.joinStage()

        model.update(address: juniper.address)
        await model.check.checkNow(model.request)
        #expect(Set(model.check.checks.keys) == Set(GitRemotePreflight.Check.allCases))
        #expect(model.check.checks.values.allSatisfy { $0 == .passed })
        #expect(model.primary == .join("Cedar"))
        #expect(model.passed?.deviceNames == ["Juniper"])
        // Nothing was read from the apps, or written, by the checks.
        #expect(cedar.fixture.firstReads.started.isEmpty)
        #expect(cedar.fixture.signIn.shellProbes == 0)
        #expect(!cedar.fixture.hasWorkspace)

        let primary = try #require(LaunchpadStageView.footer(for: flow).primary)
        #expect(primary.key == .commandReturn)
        #expect(primary.title == "Join as Cedar")
        primary.action()
        await waitUntil { flow.step == .arrivals }

        let workspace = try #require(flow.workspace)
        #expect(flow.path == .join)
        #expect(cedar.fixture.hasWorkspace)
        // The observe step read each chosen app with the stage's own read,
        // in the app order, and how they sign in, during step 3.
        #expect(cedar.fixture.firstReads.started == [.codex, .claude])
        #expect(Set(cedar.fixture.signIn.reads) == [.chatGPT, .claude])
        #expect(cedar.fixture.signIn.shellProbes == 1)
        await waitUntil { workspace.accounts.observations.count == 2 }
        #expect(workspace.accounts.observations[.claude]?.signIn?.plan == "max")
        // The choices a join records (D16, D17).
        #expect(workspace.device.managedClients == [.codex, .claude])
        #expect(workspace.device.assistantRuns == .off)
        #expect(workspace.device.findsProjectsFromClaudeHistory == false)
        // The record the store was marked with, moved on to You joined, with
        // the skills that were already yours.
        let record = try #require(cedar.fixture.savedRecord(for: workspace))
        #expect(record.state == .inProgress)
        #expect(record.path == .join)
        #expect(record.cursor == .arrivals)
        #expect(record.evidence.personalSkillsBefore.count == 2)
        #expect(flow.outcomes.sync?.address == juniper.address)
        #expect(workspace.sync?.thisDevice?.name == "Cedar")
        for step in WorkspaceJoin.Step.allCases { #expect(model.steps[step] == .done, "\(step)") }

        // You joined: the registered name, and 5 arrivals waiting for one review.
        let arrivals = try #require(LaunchpadArrivalsScreen.arrivals(for: flow))
        await arrivals.load()
        #expect(arrivals.thisMacName == "Cedar")
        #expect(arrivals.installCount == 5)
        #expect(LaunchpadStageView.footer(for: flow).primary?.title == "Review 5 changes…")
        // The skills' files arrived where the sessions read them.
        for row in arrivals.rows where row.kind == .skill {
            let digest = try #require(
                workspace.library.state?.snapshot.document.artifacts.first { $0.identity.id == row.artifactID }?.contentDigest)
            #expect(try await workspace.contentStore?.read(digest) != nil, "\(row.name)'s files came across")
        }
    }

    /// A Stop before Registering keeps nothing: no store, no locator, no
    /// record. The checkout folder may stay; the next join sets it aside.
    @Test func aStopBeforeRegisteringLeavesNoStoreAndNoLocator() async throws {
        let juniper = try await JoinPublishedJuniper.make()
        defer { juniper.remove() }
        let gate = GatedCommandRunner()
        let cedar = try await JoinCedar(readGate: gate)
        defer { cedar.remove() }
        let (flow, model) = await cedar.joinStage()
        model.update(address: juniper.address)
        await model.check.checkNow(model.request)

        try #require(LaunchpadStageView.footer(for: flow).primary).action()
        await gate.waitUntilCalled()
        await waitUntil { model.reading == [.codex, .claude] }
        #expect(model.phase == .joining)
        #expect(flow.interruption == .stoppable)
        #expect(model.steps[.checkingApps] == .running)
        #expect(model.steps[.readingLibrary] == .done)
        // ⎋ reads Stop while the join can still be stopped.
        guard case .stop(let stop) = LaunchpadStageView.footer(for: flow).later else {
            Issue.record("the later slot is not Stop while joining")
            return
        }
        stop()
        await waitUntil { model.phase == .editing }

        #expect(!cedar.fixture.hasWorkspace)
        #expect(cedar.storeFolders.isEmpty)
        #expect(flow.workspace == nil)
        #expect(flow.step == .join)
        #expect(model.steps.values.allSatisfy { $0 == .waiting })
        #expect(model.reading.isEmpty)
        #expect(model.primary == .join("Cedar"))
        // The sign-in read stopped with it, and kept nothing.
        #expect(model.signIn.isFinished)
        #expect(model.signIn.landed.isEmpty)

        // Joining again starts from a fresh checkout and completes.
        gate.release()
        try #require(LaunchpadStageView.footer(for: flow).primary).action()
        await waitUntil { flow.step == .arrivals }
        #expect(cedar.fixture.hasWorkspace)
    }

    /// A retry starts from a fresh checkout: a clone of another repository
    /// that an earlier attempt left in Agent Tooling's own checkout is set
    /// aside, and the join goes on (V08's retry).
    @Test func aRetryStartsFromAFreshCheckout() async throws {
        let juniper = try await JoinPublishedJuniper.make()
        defer { juniper.remove() }
        let cedar = try await JoinCedar()
        defer { cedar.remove() }
        let other = try GitLibraryFixture("wp8b-stale")
        defer { other.remove() }
        let stale = cedar.fixture.support.appending(path: "sync-checkout", directoryHint: .isDirectory)
        try GitTestFixture.git(
            ["clone", "--quiet", other.remote.path(percentEncoded: false), stale.path(percentEncoded: false)],
            in: cedar.fixture.support, checkingStatus: true)
        let (flow, model) = await cedar.joinStage()
        model.update(address: juniper.address)
        await model.check.checkNow(model.request)

        try #require(LaunchpadStageView.footer(for: flow).primary).action()
        await waitUntil { flow.step == .arrivals }

        #expect(cedar.fixture.hasWorkspace)
        let setAside = try FileManager.default.contentsOfDirectory(atPath: cedar.fixture.support.path(percentEncoded: false))
            .filter { $0.hasPrefix("set-aside-") }
        #expect(setAside.count == 1)
        let sync = try #require(flow.workspace?.sync)
        sync.load()
        #expect(sync.enrollment?.remote == juniper.address)
    }

    /// Back while the join can be stopped stops it first: nothing is kept.
    @Test func backStopsTheJoinFirst() async throws {
        let juniper = try await JoinPublishedJuniper.make()
        defer { juniper.remove() }
        let gate = GatedCommandRunner()
        let cedar = try await JoinCedar(readGate: gate)
        defer { cedar.remove() }
        let (flow, model) = await cedar.joinStage()
        model.update(address: juniper.address)
        await model.check.checkNow(model.request)
        try #require(LaunchpadStageView.footer(for: flow).primary).action()
        await gate.waitUntilCalled()

        // ⌘[ moves to Welcome; the screen going away stops the join.
        flow.goBack()
        #expect(flow.step == .welcome)
        model.stop()
        await waitUntil { model.phase == .editing }
        #expect(!cedar.fixture.hasWorkspace)
        #expect(cedar.storeFolders.isEmpty)
    }

    /// From the store on, the join is finishing: a quit stops nothing and
    /// waits for it, and the library is whole when it ends.
    @Test func aQuitWaitsOutAJoinPastItsStore() async throws {
        let juniper = try await JoinPublishedJuniper.make()
        defer { juniper.remove() }
        let pushes = GatedCommandRunner()
        let cedar = try await JoinCedar(pushGate: pushes)
        defer { cedar.remove() }
        let (flow, model) = await cedar.joinStage()
        model.update(address: juniper.address)
        await model.check.checkNow(model.request)
        try #require(LaunchpadStageView.footer(for: flow).primary).action()

        await pushes.waitUntilCalled()
        await waitUntil { model.phase == .finishing }
        #expect(flow.interruption == .finishing(LaunchpadCopy.Footer.finishingJoin))
        #expect(flow.leaveMoment == .finishing(LaunchpadCopy.Footer.finishingJoin))
        // Nothing stoppable is left: the quit's first half stops nothing.
        await flow.prepareToQuit()
        #expect(model.phase == .finishing)
        // ⎋, ⌘W and Back do nothing while it finishes.
        flow.escape()
        flow.goBack()
        #expect(flow.step == .join)
        #expect(LaunchpadStageView.footer(for: flow).primary?.isEnabled == false)

        let quit = Task { await flow.finishPendingWork() }
        pushes.release()
        await quit.value
        await waitUntil { flow.step == .arrivals }
        #expect(cedar.fixture.hasWorkspace)
        #expect(flow.interruption == .idle)
    }

    /// A join that fails after its store exists offers Finish joining, with
    /// the §6 words; the store is marked as an unfinished join, as a launch
    /// looks for it; and Finish joining completes it.
    @Test func aJoinThatStoppedAfterItsStoreIsFinishedInTheSameSession() async throws {
        let juniper = try await JoinPublishedJuniper.make()
        defer { juniper.remove() }
        let cedar = try await JoinCedar()
        defer { cedar.remove() }
        cedar.runner.refusesPushes = true
        let (flow, model) = await cedar.joinStage()
        model.update(address: juniper.address)
        await model.check.checkNow(model.request)
        try #require(LaunchpadStageView.footer(for: flow).primary).action()
        await waitUntil { model.phase == .editing }

        guard case .finish(let workspaceID) = model.mode else {
            Issue.record("a late failure did not offer Finish joining: \(String(describing: model.banner))")
            return
        }
        #expect(model.banner?.title == "Joining stopped before it finished")
        #expect(model.banner?.message == "Finish joining completes it; nothing in your apps changes.")
        #expect(
            "\(model.banner?.title ?? ""). \(model.banner?.message ?? "")"
                == WorkspaceJoinError.lateFailure(workspaceID: workspaceID).errorDescription)
        #expect(model.primary == .finish)
        let primary = try #require(LaunchpadStageView.footer(for: flow).primary)
        #expect(primary.title == "Finish joining")
        #expect(primary.key == .commandReturn)
        #expect(!cedar.fixture.hasWorkspace)
        let record = try #require(cedar.record(of: workspaceID))
        #expect(record.state == .inProgress)
        #expect(record.path == .join)
        #expect(record.cursor == .join)
        // The record is the one the next launch looks for (D32).
        #expect(AppLaunchState.orphanedJoin(supportRoot: cedar.fixture.support) == workspaceID)
        // The fields keep the address the join was joining, locked.
        #expect(!model.isEditable)

        cedar.runner.refusesPushes = false
        primary.action()
        await waitUntil { flow.step == .arrivals }
        #expect(cedar.fixture.hasWorkspace)
        #expect(flow.workspace?.sync?.thisDevice?.name == "Cedar")
        #expect(cedar.fixture.savedRecord(for: try #require(flow.workspace))?.cursor == .arrivals)
    }

    /// At a launch that finds the unfinished join's container (D32), the
    /// stage opens J01 in its Finish joining state, with the repository the
    /// join was joining, and Finish joining completes it without reading an
    /// app.
    @Test func aLaunchFindsTheUnfinishedJoinAndFinishesIt() async throws {
        let juniper = try await JoinPublishedJuniper.make()
        defer { juniper.remove() }
        let cedar = try await JoinCedar()
        defer { cedar.remove() }
        cedar.runner.refusesPushes = true
        let (first, firstModel) = await cedar.joinStage()
        firstModel.update(address: juniper.address)
        await firstModel.check.checkNow(firstModel.request)
        try #require(LaunchpadStageView.footer(for: first).primary).action()
        await waitUntil { firstModel.phase == .editing }
        guard case .finish(let workspaceID) = firstModel.mode else {
            Issue.record("a late failure did not offer Finish joining")
            return
        }
        cedar.runner.refusesPushes = false
        let readsBefore = cedar.fixture.firstReads.started

        // The next launch.
        let flow = cedar.fixture.flow(.finishJoin(workspaceID))
        #expect(flow.step == .join)
        let model = cedar.model(in: flow)
        await model.load()
        #expect(model.address == juniper.address)
        #expect(model.banner?.title == "Joining stopped before it finished")
        #expect(LaunchpadStageView.footer(for: flow).primary?.title == "Finish joining")

        try #require(LaunchpadStageView.footer(for: flow).primary).action()
        #expect(model.phase == .finishing)
        #expect(flow.interruption == .finishing(LaunchpadCopy.Footer.finishingJoin))
        await waitUntil { flow.step == .arrivals }
        #expect(cedar.fixture.hasWorkspace)
        #expect(cedar.fixture.firstReads.started == readsBefore)
        let workspace = try #require(flow.workspace)
        #expect(workspace.store.workspaceID == workspaceID)
        #expect(cedar.fixture.savedRecord(for: workspace)?.evidence.personalSkillsBefore.count == 2)
    }

    /// Finish joining over a container with nothing to finish goes back to
    /// the join form, and says so.
    @Test func nothingToFinishGoesBackToTheForm() async throws {
        let cedar = try await JoinCedar()
        defer { cedar.remove() }
        let flow = cedar.fixture.flow(.finishJoin(WorkspaceObjectID()))
        let model = cedar.model(in: flow)
        await model.load()
        try #require(LaunchpadStageView.footer(for: flow).primary).action()
        await waitUntil { model.phase == .editing }

        #expect(model.mode == .join)
        #expect(model.banner?.title == "There is nothing to finish")
        #expect(model.banner?.message == WorkspaceJoinError.nothingToFinish.errorDescription)
        #expect(model.isEditable)
    }

    /// V08: a one-letter typo stops at the second check and says which;
    /// nothing is read or written; Try again ↩ checks the corrected address
    /// afresh, and it passes.
    @Test func aTypoStopsAtTheSecondCheckAndTryAgainChecksAfresh() async throws {
        let juniper = try await JoinPublishedJuniper.make()
        defer { juniper.remove() }
        let cedar = try await JoinCedar()
        defer { cedar.remove() }
        let (flow, model) = await cedar.joinStage()
        let typo = juniper.remote.deletingLastPathComponent().appending(path: "agent-tooling-workspce.git").path(percentEncoded: false)

        model.update(address: typo)
        await model.check.checkNow(model.request)
        #expect(model.check.checks[.gitInstalled] == .passed)
        #expect(model.check.checks[.reachable] == .failed)
        #expect(model.check.checks[.holdsLibrary] == nil)
        #expect(model.check.checks[.readable] == nil)
        #expect(model.checkProblem == .notFound(host: nil))
        #expect(model.primary == .tryAgain)
        let primary = try #require(LaunchpadStageView.footer(for: flow).primary)
        #expect(primary.title == "Try again")
        #expect(primary.key == .return)
        #expect(!cedar.fixture.hasWorkspace)
        #expect(cedar.fixture.firstReads.started.isEmpty)

        // Try again checks afresh, reading only the remote: still a typo.
        let checksBefore = cedar.runner.launches.count
        primary.action()
        await waitUntil { model.check.phase != .checking && cedar.runner.launches.count > checksBefore }
        #expect(model.checkProblem == .notFound(host: nil))
        #expect(!cedar.fixture.hasWorkspace)

        // Mended, it passes, and the join can run.
        model.update(address: juniper.address)
        await waitUntil { model.passed != nil }
        #expect(model.primary == .join("Cedar"))
        #expect(model.banner == nil)
    }

    /// This Mac's name read after the address was pasted keeps the check
    /// that passed: the name is no part of what the check is matched to, and
    /// Join as names it once it is read. Until then nothing joins.
    @Test func aNameReadAfterTheAddressKeepsTheCheckThatPassed() async throws {
        let juniper = try await JoinPublishedJuniper.make()
        defer { juniper.remove() }
        let name = GatedCommandRunner()
        let cedar = try await JoinCedar(nameGate: name)
        defer {
            name.release()
            cedar.remove()
        }
        let flow = cedar.fixture.flow()
        flow.choosePath(.join)
        let model = cedar.model(in: flow)
        let loading = Task { await model.load() }
        await name.waitUntilCalled()

        model.update(address: juniper.address)
        await model.check.checkNow(model.request)
        #expect(model.passed != nil)
        #expect(model.deviceName.isEmpty)
        #expect(model.joinName == nil)
        #expect(model.primary == .notReady(nil))
        let waiting = try #require(LaunchpadStageView.footer(for: flow).primary)
        #expect(waiting.title == "Join")
        #expect(!waiting.isEnabled)
        #expect(LaunchpadCopy.Join.consent(mac: nil).contains("hold on this Mac,"))
        let launches = cedar.runner.launches.count

        name.release()
        await loading.value
        #expect(model.deviceName == "Cedar")
        #expect(model.passed != nil)
        #expect(model.primary == .join("Cedar"))
        #expect(model.check.checks.values.allSatisfy { $0 == .passed })
        // Nothing was checked again.
        #expect(!model.check.isChecking)
        #expect(cedar.runner.launches.count == launches)
    }

    /// Join as names this Mac the way the join numbers it: by the same rule
    /// the repository check applies to the Macs it found.
    @Test func joinAsNumbersTheNameAsTheJoinDoes() async throws {
        let juniper = try await JoinPublishedJuniper.make()
        defer { juniper.remove() }
        let cedar = try await JoinCedar()
        defer { cedar.remove() }
        let scratch = cedar.fixture.support.appending(path: "scratch", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)

        // The repository check, asked about a name another Mac uses.
        let checked = try await GitRemotePreflight.run(
            remote: juniper.address, deviceName: "Juniper", runner: cedar.runner, scratch: scratch)
        guard case .success(let result) = checked else {
            Issue.record("the check did not pass: \(checked)")
            return
        }
        #expect(result.deviceNames == ["Juniper"])
        #expect(result.suggestedName == "Juniper 2")
        #expect(LaunchpadJoin.uniqueName("Juniper", among: result.deviceNames) == result.suggestedName)
        #expect(LaunchpadJoin.uniqueName("Cedar", among: result.deviceNames) == "Cedar")
        #expect(LaunchpadJoin.uniqueName("juniper", among: ["Juniper", "juniper 2"]) == "juniper 3")
        #expect(LaunchpadJoin.requestedName("  Cedar \n") == "Cedar")
        #expect(LaunchpadJoin.requestedName(" ") == "Mac")
    }

    /// A Mac whose join wrote its library record but not yet the record's
    /// move to You joined (the app ended in between). The next launch opens
    /// You joined, which keeps what the join keeps; and J01, if it is ever
    /// shown on that library, goes on there itself rather than offering a
    /// join this Mac can no longer make.
    @Test func aRecordStillAtJoinOnAJoinedMacGoesOnToYouJoined() async throws {
        let juniper = try await JoinPublishedJuniper.make()
        defer { juniper.remove() }
        let cedar = try await JoinCedar()
        defer { cedar.remove() }
        let (joining, model) = await cedar.joinStage()
        model.update(address: juniper.address)
        await model.check.checkNow(model.request)
        try #require(LaunchpadStageView.footer(for: joining).primary).action()
        await waitUntil { joining.step == .arrivals }
        let container = try #require(joining.workspace).store.databaseURL.deletingLastPathComponent()
        /// The library as the app left it: the store and its locator record,
        /// with the setup record still at Join and nothing kept yet.
        func leftAtJoin() async throws -> WorkspaceLaunch.Workspace {
            try LiveSetupProgressStore(container: container).save(
                .started(path: .join, cursor: .join, now: ClientHomeFixture.now))
            return try await WorkspaceLaunch.open(
                supportRoot: cedar.fixture.support, homeRoot: cedar.fixture.home,
                services: cedar.fixture.environment.sessions)
        }

        // The launch's own decision opens You joined, which keeps the skills
        // that were already yours.
        var reopened = try await leftAtJoin()
        let decided = AppLaunchState.decide(
            WorkspaceLaunch.recordState(supportRoot: cedar.fixture.support),
            progress: { LiveSetupProgressStore(container: $0).load() }, orphanJoin: { nil })
        #expect(decided.phase == .setup)
        #expect(decided.entry == .continueFirstRun(.arrivals))
        let launched = cedar.fixture.flow(decided.entry, workspace: reopened)
        #expect(launched.step == .arrivals)
        await LaunchpadArrivalsScreen.arrivals(for: launched)?.load()
        #expect(cedar.fixture.savedRecord(for: reopened)?.evidence.personalSkillsBefore.count == 2)

        // J01 on that library goes on to You joined, and so does its record.
        reopened = try await leftAtJoin()
        let flow = cedar.fixture.flow(.continueFirstRun(.join), workspace: reopened)
        #expect(flow.step == .join)
        #expect(flow.isPostCommit)
        let footer = LaunchpadStageView.footer(for: flow)
        #expect(footer.primary?.title == "Continue")
        #expect(footer.primary?.key == .return)
        await LaunchpadJoinScreen.join(for: flow).carryOn(flow: flow)

        #expect(flow.step == .arrivals)
        let record = try #require(cedar.fixture.savedRecord(for: reopened))
        #expect(record.state == .inProgress)
        #expect(record.cursor == .arrivals)
        #expect(record.evidence.personalSkillsBefore.count == 2)
        #expect(flow.outcomes.sync?.address == juniper.address)
    }

    /// Where a join that ended in an error leaves this Mac. Once its store
    /// exists, a join is finished whatever stopped it: a Stop that came after
    /// its last chance to stop, and failed late, still offers Finish joining.
    @Test func aJoinThatFailedAfterItsStoreIsFinishedWhateverStoppedIt() {
        let workspaceID = WorkspaceObjectID()
        let late = WorkspaceJoinError.lateFailure(workspaceID: workspaceID)
        #expect(LaunchpadJoin.ending(of: late, wasCancelled: true) == .finishJoining(workspaceID))
        #expect(LaunchpadJoin.ending(of: late, wasCancelled: false) == .finishJoining(workspaceID))
        #expect(LaunchpadJoin.ending(of: CancellationError(), wasCancelled: false) == .stopped)
        #expect(LaunchpadJoin.ending(of: WorkspaceJoinError.remote(.notALibrary), wasCancelled: true) == .stopped)
        #expect(LaunchpadJoin.ending(of: WorkspaceJoinError.nothingToFinish, wasCancelled: false) == .nothingToFinish)
        #expect(LaunchpadJoin.ending(of: WorkspaceJoinError.remote(.notALibrary), wasCancelled: false) == .failed)
    }

    /// The check that runs as an address is typed reads the remote, so a
    /// quit stops it too, and nothing is kept.
    @Test func aQuitStopsTheCheckUnderWay() async throws {
        let juniper = try await JoinPublishedJuniper.make()
        defer { juniper.remove() }
        let cedar = try await JoinCedar()
        defer { cedar.remove() }
        let listings = GatedCommandRunner()
        cedar.runner.holdsListings = listings
        let (flow, model) = await cedar.joinStage()

        model.update(address: juniper.address)
        await listings.waitUntilCalled()
        #expect(model.check.isChecking)
        #expect(flow.interruption == .stoppable)

        await flow.prepareToQuit()

        #expect(!model.check.isChecking)
        #expect(flow.interruption == .idle)
        #expect(model.passed == nil)
        #expect(!cedar.fixture.hasWorkspace)
    }

    /// The scp form is refused by the field, before anything runs, with the
    /// HTTPS form to use instead (V9).
    @Test func theScpFormOffersItsHTTPSForm() async throws {
        let cedar = try await JoinCedar()
        defer { cedar.remove() }
        let (_, model) = await cedar.joinStage()

        model.update(address: "git@github.com:you/agent-tooling-workspace.git")
        #expect(
            model.addressProblem
                == .invalidAddress(suggestion: "https://github.com/you/agent-tooling-workspace.git", carriesSignIn: true))
        #expect(model.addressProblem?.errorDescription == "Enter a repository address without a user name or password in it.")
        #expect(model.check.phase == .idle)
        model.useSuggestion()
        #expect(model.address == "https://github.com/you/agent-tooling-workspace.git")
        #expect(model.addressProblem == nil)
    }

    /// App choices determine which locations and commands the join lists.
    @Test func theStripChoosesWhatTheJoinReads() async throws {
        let cedar = try await JoinCedar()
        defer { cedar.remove() }
        let (_, model) = await cedar.joinStage()

        #expect(model.found == [.codex, .claude])
        #expect(model.chosen == [.codex, .claude])
        #expect(model.manifest.placeCount == 9)
        #expect(model.manifest.commandCount == 8)
        model.toggle(.claude)
        #expect(model.chosen == [.codex])
        #expect(model.manifest.placeCount == 4)
        #expect(model.manifest.commandCount == 5)
        model.toggle(.claude)
        #expect(model.manifest.placeCount == 9)
    }
}

// MARK: - The sample world's two Macs, joined over Git

/// Juniper after Let your apps ask, registered as Juniper and published,
/// with its status, to a repository inside its own fixture. Its status says
/// it published six minutes before the sample world's clock.
@MainActor
struct JoinPublishedJuniper {
    let fixture: LaunchpadFixture
    let workspace: WorkspaceLaunch.Workspace
    /// The bare repository.
    let remote: URL

    /// The repository's address, as the join is given it.
    var address: String { remote.path(percentEncoded: false) }

    static let publishedAt = ClientHomeFixture.now.addingTimeInterval(-6 * 60)

    /// Juniper's library published; with `sharing`, that many more skills
    /// of its own, each put in Codex on every Mac, so a Mac that joins takes
    /// them all as well.
    static func make(sharing extraSkills: Int = 0) async throws -> JoinPublishedJuniper {
        let fixture = try await LaunchpadFixture(.juniper)
        do {
            let remote = fixture.world.home.root.appending(path: "library.git", directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: remote, withIntermediateDirectories: true)
            try GitTestFixture.git(
                ["init", "--quiet", "--bare", "--initial-branch", "main", remote.path(percentEncoded: false)], in: remote,
                checkingStatus: true)
            let workspace = try await fixture.sample(.afterAsk).workspace
            try await share(extraSkills, from: workspace, fixture: fixture)
            _ = try await workspace.service.registerDevice(
                .init(expectedRevisionID: try fixture.head(of: workspace), deviceID: workspace.store.deviceID, name: "Juniper"))
            await workspace.library.refresh()
            let transport = try await GitWorkspaceTransport.enroll(
                remote: remote.path(percentEncoded: false),
                checkout: fixture.world.home.root.appending(path: "juniper-checkout", directoryHint: .isDirectory),
                runner: JoinGitRunner(tools: fixture.world.scriptedRunner(), homeURL: fixture.home))
            let device = workspace.device
            let library = workspace.library
            let deployment = workspace.deployment
            let coordinator = WorkspaceSyncCoordinator(
                store: workspace.store, transport: transport, writerID: WorkspaceObjectID(), contentStore: workspace.contentStore,
                status: {
                    await MainActor.run {
                        guard var status = PublishedDeviceStatus.current(device: device, library: library, deployment: deployment)
                        else { return nil }
                        status.publishedAt = publishedAt
                        return status
                    }
                })
            guard case .published = try await coordinator.sync() else { throw JoinFixtureError.notPublished }
            return JoinPublishedJuniper(fixture: fixture, workspace: workspace, remote: remote)
        } catch {
            fixture.remove()
            throw error
        }
    }

    func remove() { fixture.remove() }

    /// `count` skills written into Juniper's library, as S08's Write your
    /// own… writes one, then put in Codex on every Mac.
    private static func share(_ count: Int, from workspace: WorkspaceLaunch.Workspace, fixture: LaunchpadFixture) async throws {
        guard count > 0 else { return }
        var additions: [AssignmentContribution] = []
        for number in 1...count {
            var draft = SkillDraft()
            draft.name = "shared-skill-\(number)"
            draft.purpose = "One more skill Juniper shares, number \(number)."
            let identifier = try WorkspaceLibrary.normalizedIdentifier(draft.name)
            let prepared = try WorkspaceSkillPreparation.personal(
                tree: try SkillTemplate.tree(identifier: identifier, draft: draft))
            let command = StandaloneSkillIntakeCommand(
                expectedRevisionID: try fixture.head(of: workspace), displayName: SkillTemplate.displayName(for: identifier),
                prepared: prepared)
            _ = try await workspace.service.intakeStandaloneSkill(command, prepared: prepared)
            additions.append(
                AssignmentContribution(
                    artifactID: command.artifactID, destination: .init(surface: ClientKind.codex.defaultSurface, scope: .user),
                    reason: .manual))
        }
        _ = try await workspace.service.applyAssignmentBatch(
            .init(expectedRevisionID: try fixture.head(of: workspace), additions: additions))
        await workspace.library.refresh()
    }
}

enum JoinFixtureError: Error {
    case notPublished
}

/// Cedar, with Codex and Claude Code, whose stage runs Git for real.
@MainActor
struct JoinCedar {
    var fixture: LaunchpadFixture
    let runner: JoinGitRunner

    /// `nameGate` holds the read of this Mac's name until the test lets it
    /// go, as a slow computer-name lookup would; `signInGate` holds every
    /// sign-in read.
    init(
        readGate: GatedCommandRunner? = nil, pushGate: GatedCommandRunner? = nil, nameGate: GatedCommandRunner? = nil,
        signInGate: GatedCommandRunner? = nil
    ) async throws {
        var fixture = try await LaunchpadFixture(.cedar, readGate: readGate, signInGate: signInGate)
        let runner = JoinGitRunner(tools: fixture.world.scriptedRunner(), homeURL: fixture.home, pushGate: pushGate)
        fixture.environment.makeRunner = { _ in runner }
        if let nameGate {
            fixture.environment.deviceName = {
                _ = try? await nameGate.run(executable: "/usr/sbin/scutil", arguments: ["--get", "ComputerName"], currentDirectory: nil)
                return "Cedar"
            }
        }
        self.fixture = fixture
        self.runner = runner
    }

    /// Welcome's Join taken, and the step's model made the way the screen
    /// makes it, except that it checks the moment it is asked and sets a
    /// stale checkout aside inside the fixture.
    func joinStage() async -> (LaunchpadFlow, LaunchpadJoin) {
        let flow = fixture.flow()
        flow.choosePath(.join)
        let model = model(in: flow)
        await model.load()
        return (flow, model)
    }

    /// J01's model for `flow`, made before the screen makes its own.
    func model(in flow: LaunchpadFlow) -> LaunchpadJoin {
        let aside = fixture.support
        return flow.model(for: .join) {
            LaunchpadJoin(
                entry: flow.entry, environment: flow.environment, checkDelay: .zero,
                discardStaleCheckout: { try JoinCedar.setAside($0, in: aside) })
        }
    }

    /// Moves `item` beside the support folder's other files under a new
    /// name: what the Trash does live, without the Trash.
    nonisolated static func setAside(_ item: URL, in folder: URL) throws {
        try FileManager.default.moveItem(
            at: item, to: folder.appending(path: "set-aside-\(UUID().uuidString.lowercased())", directoryHint: .isDirectory))
    }

    /// The store folders in the support folder.
    var storeFolders: [URL] {
        let workspaces = fixture.support.appending(path: "workspaces-v1", directoryHint: .isDirectory)
        return (try? FileManager.default.contentsOfDirectory(at: workspaces, includingPropertiesForKeys: nil)) ?? []
    }

    /// The setup record in `workspaceID`'s container, as a launch reads it.
    func record(of workspaceID: WorkspaceObjectID) -> SetupProgressRecord? {
        let container = fixture.support.appending(path: "workspaces-v1/\(workspaceID.rawValue.uuidString.lowercased())")
        return LiveSetupProgressStore(container: container).load()
    }

    func remove() { fixture.remove() }
}

/// A join's runner in these tests: the system's own tools run for real
/// against repositories on this Mac, and never the network (Git is told to
/// refuse every transport but a file), and every app's command is answered
/// from the sample world's script. A test can make pushes fail, or hold them
/// until it lets them go.
final class JoinGitRunner: CommandRunning, @unchecked Sendable {
    let tools: ScriptedCommandRunner
    let homeURL: URL
    private let pushGate: GatedCommandRunner?
    private let lock = NSLock()
    private var refusing = false
    private var cannotReach = false
    private var listingGate: GatedCommandRunner?
    private var asked: [CommandLaunch] = []

    init(tools: ScriptedCommandRunner, homeURL: URL, pushGate: GatedCommandRunner? = nil) {
        self.tools = tools
        self.homeURL = homeURL
        self.pushGate = pushGate
    }

    /// When true, every push is refused, as a host that does not let this
    /// Mac's sign-in write answers.
    var refusesPushes: Bool {
        get { lock.withLock { refusing } }
        set { lock.withLock { refusing = newValue } }
    }

    /// When true, every `git ls-remote` fails as a host this Mac cannot
    /// reach answers: no network.
    var cannotReachHost: Bool {
        get { lock.withLock { cannotReach } }
        set { lock.withLock { cannotReach = newValue } }
    }

    /// When set, each `git ls-remote` waits for it: a check held at its
    /// second step.
    var holdsListings: GatedCommandRunner? {
        get { lock.withLock { listingGate } }
        set { lock.withLock { listingGate = newValue } }
    }

    /// Every system command run, in order.
    var launches: [CommandLaunch] { lock.withLock { asked } }

    /// Git's options that let it reach repositories on this Mac and nothing
    /// else.
    static let offline = ["-c", "protocol.allow=never", "-c", "protocol.file.allow=always"]

    func run(executable: String, arguments: [String], currentDirectory: URL?) async throws -> CommandOutput {
        guard executable.hasPrefix("/usr/bin/") else {
            return try await tools.run(executable: executable, arguments: arguments, currentDirectory: currentDirectory)
        }
        lock.withLock { asked.append(CommandLaunch(executable: executable, arguments: arguments)) }
        guard executable == JoinGitPath.git else {
            return try await Self.system.run(executable: executable, arguments: arguments, currentDirectory: currentDirectory)
        }
        if arguments.contains("ls-remote"), let listingGate = holdsListings {
            _ = try await listingGate.run(executable: executable, arguments: arguments, currentDirectory: currentDirectory)
        }
        if arguments.contains("ls-remote"), cannotReachHost {
            return CommandOutput(
                status: 128, standardOutput: "",
                standardError: "fatal: unable to access 'https://github.com/you/agent-tooling-workspace.git/': "
                    + "Could not resolve host: github.com\n")
        }
        if arguments.contains("push") {
            if let pushGate {
                _ = try await pushGate.run(executable: executable, arguments: arguments, currentDirectory: currentDirectory)
            }
            if refusesPushes {
                return CommandOutput(
                    status: 128, standardOutput: "",
                    standardError: "remote: Permission to you/agent-tooling-workspace.git denied to you.\n"
                        + "fatal: The requested URL returned error: 403\n")
            }
        }
        return try await ProcessCommandRunner(timeout: .seconds(60), homeURL: homeURL)
            .run(executable: executable, arguments: Self.offline + arguments, currentDirectory: currentDirectory)
    }

    private static let system = ProcessCommandRunner(timeout: .seconds(60))
}

/// Where the transport finds Git.
private enum JoinGitPath {
    static let git = "/usr/bin/git"
}
