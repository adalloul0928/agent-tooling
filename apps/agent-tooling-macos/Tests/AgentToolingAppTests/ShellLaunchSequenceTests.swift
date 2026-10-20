import AgentToolingCore
import AgentToolingTestSupport
import Foundation
import Observation
import Testing

@testable import AgentToolingApp

/// Verifies shell-launch policy through recorded service calls: setup work is not
/// repeated, assistant/catalog consent is honored, existing workspaces retain their
/// behavior and sync is independent of assistant work. Checks calls, not ordering.
/// The five-minute limit accommodates parallel suites sharing the main actor.
@Suite("Shell launch sequence", .serialized, .timeLimit(.minutes(5)))
@MainActor
struct ShellLaunchSequenceTests {
    private static let weeklyOnly = AssistantRunConsent(weeklyReview: true, dailyDeepDive: false, localInsights: false)

    /// The launch work as the shell decides and runs it.
    private func launch(
        _ workspace: WorkspaceLaunch.Workspace, hints: ShellLaunchHints = ShellLaunchHints(), sync: SyncPassRecorder
    ) async {
        let policy = LaunchWorkPolicy.decide(
            status: workspace.setupProgress.status, preferences: workspace.device.preferences, hints: hints,
            checkedThisLaunch: workspace.device.hasCheckedThisLaunch)
        await policy.run(on: workspace, syncPass: { sync.passes += 1 })
    }

    // MARK: A new setup

    /// The first Home launch after the stage's hand-off: the stage has just
    /// read the apps and audited them, and every assistant run is off, so the
    /// launch checks nothing again, asks no login shell, and runs no deep
    /// dive and no review. Other Macs still get their pass.
    @Test func aNewSetupsFirstHomeLaunchReadsNothingAgain() async throws {
        let fixture = try await LaunchpadFixture()
        defer { fixture.remove() }
        let workspace = try await fixture.sample(.afterRead).workspace
        Self.finish(workspace)
        let sync = SyncPassRecorder()

        await launch(workspace, hints: ShellLaunchHints(justHandedOff: true), sync: sync)

        #expect(fixture.observer.fullChecks == 0, "the stage's read is this launch's check")
        #expect(fixture.observer.scopedChecks.isEmpty)
        #expect(fixture.setup.searchPathCalls == 0, "no login shell")
        #expect(fixture.setup.reviewCalls.isEmpty, "no review")
        #expect(fixture.insights.scanCount == 0, "no scan")
        #expect(fixture.insights.deepDiveCalls.isEmpty, "no deep dive")
        #expect(sync.passes == 1)
    }

    /// With the weekly review turned on at Let your assistant help, the first
    /// review starts when Home opens, as the screen says, still with no
    /// second check and no login shell.
    @Test func aNewSetupWithTheWeeklyReviewOnRunsItsFirstReviewAtHome() async throws {
        let fixture = try await LaunchpadFixture()
        defer { fixture.remove() }
        let workspace = try await fixture.sample(.afterRead).workspace
        await workspace.device.setAssistantRuns(Self.weeklyOnly)
        Self.finish(workspace)

        await launch(workspace, hints: ShellLaunchHints(justHandedOff: true), sync: SyncPassRecorder())

        #expect(fixture.setup.reviewCalls.count == 1)
        #expect(fixture.setup.reviewCalls.first?.purpose == .checkup)
        #expect(fixture.observer.fullChecks == 0)
        #expect(fixture.setup.searchPathCalls == 0)
        #expect(fixture.insights.deepDiveCalls.isEmpty, "the deep dive stays off")
    }

    /// A later launch of a new setup with every run off audits as usual and
    /// still runs no assistant.
    @Test func aLaterLaunchWithEveryRunOffRunsNoAssistant() async throws {
        let setup = AssistantRunSetupServices()
        let insights = AssistantRunInsightsServices(digests: [AssistantRunInsightsServices.digest(.claude)])
        let fixture = try await ShellRenderFixture(
            insightsServices: insights, setupServices: setup,
            setupProgressStore: StubSetupProgressStore(Self.record(.finished, seen: LaunchpadStep.allCases)),
            assistantRuns: .off)
        defer { fixture.remove() }

        await launch(fixture.workspace, sync: SyncPassRecorder())

        #expect(setup.searchPathCalls == 1, "the audit runs, with the login shell")
        #expect(setup.reviewCalls == 0)
        #expect(insights.scannedClients.isEmpty)
        #expect(insights.deepDives.isEmpty)
    }

    // MARK: Before setup recorded anything

    /// A workspace made before setup recorded anything keeps every run it
    /// had: the check, the audit with the login shell, the deep dive, the
    /// weekly review, the update check over the network and the sync pass.
    @Test func anOlderWorkspaceKeepsEveryRunItHad() async throws {
        let observer = CountingDeviceObserver([
            ShellRenderFixture.observation(.claudeCode, installed: true, commandAvailable: true, version: "2.1.304")
        ])
        let catalog = StubMarketplaceProvider()
        let setup = AssistantRunSetupServices()
        let insights = AssistantRunInsightsServices(digests: [AssistantRunInsightsServices.digest(.claude)])
        let fixture = try await ShellRenderFixture(
            deviceObserver: observer, marketplaceProviders: [catalog], insightsServices: insights, setupServices: setup)
        defer { fixture.remove() }
        #expect(fixture.workspace.setupProgress.status == .legacy)
        let sync = SyncPassRecorder()

        await launch(fixture.workspace, sync: sync)

        #expect(observer.fullChecks == 1)
        #expect(setup.searchPathCalls == 1)
        #expect(insights.deepDives == [.claude])
        #expect(setup.reviewCalls == 1)
        #expect(await catalog.lastQuery != nil, "the update check asked the catalog")
        #expect(sync.passes == 1)
    }

    /// The same main window opened again in the same launch checks nothing
    /// a second time.
    @Test func aWindowOpenedAgainDoesNotCheckAgain() async throws {
        let observer = CountingDeviceObserver([
            ShellRenderFixture.observation(.claudeCode, installed: true, commandAvailable: true, version: "2.1.304")
        ])
        let fixture = try await ShellRenderFixture(deviceObserver: observer, setupServices: AssistantRunSetupServices())
        defer { fixture.remove() }

        await launch(fixture.workspace, sync: SyncPassRecorder())
        await launch(fixture.workspace, sync: SyncPassRecorder())

        #expect(observer.fullChecks == 1)
    }

    // MARK: Held back

    /// A first run left for later before How Agent Tooling behaves asks no
    /// catalog over the network; everything else runs.
    @Test func aFirstRunLeftBeforeItsPreferencesAsksNoCatalog() async throws {
        let catalog = StubMarketplaceProvider()
        let fixture = try await ShellRenderFixture(
            marketplaceProviders: [catalog], setupServices: AssistantRunSetupServices(),
            setupProgressStore: StubSetupProgressStore(
                Self.record(.deferred, seen: [.welcome, .apps, .reads, .found, .library])),
            assistantRuns: .off)
        defer { fixture.remove() }
        let sync = SyncPassRecorder()

        await launch(fixture.workspace, sync: sync)

        #expect(await catalog.lastQuery == nil)
        #expect(sync.passes == 1, "other Macs are not held back")
        #expect(!LaunchWorkPolicy.allowsNetworkCatalogs(status: fixture.workspace.setupProgress.status), "nor is Home's refresh")
    }

    @Test func aFirstRunStillOnTheStageStartsNothing() async throws {
        let observer = CountingDeviceObserver([])
        let catalog = StubMarketplaceProvider()
        let setup = AssistantRunSetupServices()
        let fixture = try await ShellRenderFixture(
            deviceObserver: observer, marketplaceProviders: [catalog], setupServices: setup,
            setupProgressStore: StubSetupProgressStore(Self.record(.inProgress, seen: [.welcome, .apps, .reads, .found])))
        defer { fixture.remove() }
        let sync = SyncPassRecorder()

        await launch(fixture.workspace, sync: sync)

        #expect(observer.fullChecks == 0)
        #expect(setup.searchPathCalls == 0)
        #expect(setup.reviewCalls == 0)
        #expect(await catalog.lastQuery == nil)
        #expect(sync.passes == 0)
    }

    // MARK: Two lanes

    /// Other Macs get their pass while the weekly review is still reading:
    /// a review that takes minutes never holds up a sync.
    @Test func otherMacsAreNotHeldBehindTheReview() async throws {
        let setup = AssistantRunSetupServices(holdsReviews: true)
        let fixture = try await ShellRenderFixture(setupServices: setup)
        defer { fixture.remove() }
        let sync = SyncPassRecorder()

        let running = Task { await launch(fixture.workspace, sync: sync) }
        await setup.waitUntilAReviewIsHeld()
        await waitUntil { sync.passes == 1 }
        #expect(fixture.workspace.setup.isReviewing, "the review is still reading")

        setup.releaseReviews()
        await running.value
        #expect(setup.reviewCalls == 1)
        #expect(!fixture.workspace.setup.isReviewing)
    }

    /// After the hand-off, a main window closed and opened again in the same
    /// launch checks nothing either: the stage's read is still this launch's
    /// check.
    @Test func aWindowOpenedAgainAfterTheHandOffChecksNothing() async throws {
        let fixture = try await LaunchpadFixture()
        defer { fixture.remove() }
        let workspace = try await fixture.sample(.afterRead).workspace
        Self.finish(workspace)

        await launch(workspace, hints: ShellLaunchHints(justHandedOff: true), sync: SyncPassRecorder())
        await launch(workspace, sync: SyncPassRecorder())

        #expect(fixture.observer.fullChecks == 0, "the stage's read is this launch's check")
        #expect(fixture.observer.scopedChecks.isEmpty)
    }

    /// A main window opened again while the first launch's deep dive is still
    /// reading waits for it: one review, after the dive, never beside it.
    @Test func aWindowOpenedAgainDuringTheDeepDiveWaitsForIt() async throws {
        let insights = AssistantRunInsightsServices(
            digests: [AssistantRunInsightsServices.digest(.claude)], holdsDeepDives: true)
        let setup = AssistantRunSetupServices(alongside: insights)
        let fixture = try await ShellRenderFixture(insightsServices: insights, setupServices: setup)
        defer { fixture.remove() }

        let first = Task { await launch(fixture.workspace, sync: SyncPassRecorder()) }
        await insights.waitUntilHeld()
        let reopenedSync = SyncPassRecorder()
        let reopened = Task { await launch(fixture.workspace, sync: reopenedSync) }
        // Other Macs still get the reopened window's pass, and the review
        // still waits.
        await waitUntil { reopenedSync.passes == 1 }
        for _ in 0..<20 { await Task.yield() }
        #expect(setup.reviewCalls == 0, "no review beside the deep dive")

        insights.releaseHeld()
        await first.value
        await reopened.value
        #expect(insights.deepDives == [.claude], "one deep dive")
        #expect(setup.reviewCalls == 1, "one review")
        #expect(setup.reviewsBesideADive == 0)
    }

    /// A launch stopped while its deep dive reads (its main window closed)
    /// lets the dive answer and starts no review after it, so the review is
    /// still due when the next launch opens.
    @Test func aLaunchStoppedDuringTheDeepDiveStartsNoReview() async throws {
        let insights = AssistantRunInsightsServices(
            digests: [AssistantRunInsightsServices.digest(.claude)], holdsDeepDives: true)
        let setup = AssistantRunSetupServices()
        let fixture = try await ShellRenderFixture(insightsServices: insights, setupServices: setup)
        defer { fixture.remove() }

        let running = Task { await launch(fixture.workspace, sync: SyncPassRecorder()) }
        await insights.waitUntilHeld()
        running.cancel()
        insights.releaseHeld()
        await running.value

        #expect(fixture.workspace.insights.report?.deepDive != nil, "the deep dive answered")
        #expect(setup.reviewCalls == 0)
        #expect(fixture.workspace.setup.isReviewDue(consent: .existingBehaviour), "still due for the next launch")
    }

    // MARK: Turning a run off

    /// The daily deep dive switched off in Settings › General while the
    /// launch's keyword pass is reading stops the run there: no summary goes
    /// to the assistant, and the weekly review, still on, runs after it.
    @Test func theDeepDiveTurnedOffInSettingsDuringItsScanNeverStarts() async throws {
        let setup = AssistantRunSetupServices()
        let insights = AssistantRunInsightsServices(
            digests: [AssistantRunInsightsServices.digest(.claude)], holdsScans: true)
        let fixture = try await ShellRenderFixture(insightsServices: insights, setupServices: setup)
        defer { fixture.remove() }

        let running = Task { await launch(fixture.workspace, sync: SyncPassRecorder()) }
        await insights.waitUntilHeld()
        // What the deep dive's switch in Settings › General does.
        await fixture.workspace.recordAssistantRun(.dailyDeepDive, false).value
        #expect(!fixture.workspace.insights.isScanning, "the scheduled pass stopped as the switch flipped")
        insights.releaseHeld()
        await running.value

        #expect(insights.deepDives.isEmpty, "no summary went to the assistant")
        #expect(fixture.workspace.device.assistantRuns == Self.weeklyOnly)
        #expect(setup.reviewCalls == 1, "the weekly review, still on, ran")
    }

    /// The deep dive asks this Mac's choice again once its keyword pass is
    /// done, so a choice recorded any other way than a switch still keeps its
    /// summaries on this Mac.
    @Test func theDeepDiveAsksTheChoiceAgainBeforeItsSummariesGo() async throws {
        let insights = AssistantRunInsightsServices(
            digests: [AssistantRunInsightsServices.digest(.claude)], holdsScans: true)
        let fixture = try await ShellRenderFixture(insightsServices: insights, setupServices: AssistantRunSetupServices())
        defer { fixture.remove() }

        let running = Task { await launch(fixture.workspace, sync: SyncPassRecorder()) }
        await insights.waitUntilHeld()
        await fixture.workspace.device.setAssistantRuns(.off)
        #expect(fixture.workspace.insights.isScanning, "nothing stopped the keyword pass")
        insights.releaseHeld()
        await running.value

        #expect(insights.deepDives.isEmpty)
        #expect(fixture.workspace.insights.report != nil, "the keyword pass, which stays on this Mac, landed")
    }

    /// The runs turned off while the launch is under way (from Home's
    /// notice) stay off for the rest of it.
    @Test func runsTurnedOffDuringTheLaunchStayOff() async throws {
        let setup = AssistantRunSetupServices()
        let insights = AssistantRunInsightsServices(
            digests: [AssistantRunInsightsServices.digest(.claude)], holdsDeepDives: true)
        let fixture = try await ShellRenderFixture(insightsServices: insights, setupServices: setup)
        defer { fixture.remove() }

        let running = Task { await launch(fixture.workspace, sync: SyncPassRecorder()) }
        await insights.waitUntilHeld()
        await AssistantRunsNotice.turnOff(fixture.workspace).value
        await running.value

        #expect(setup.reviewCalls == 0, "the review after the dive did not start")
        #expect(fixture.workspace.insights.report?.deepDive == nil)
    }

    // MARK: Helpers

    /// Marks `workspace`'s setup finished, as Done does.
    private static func finish(_ workspace: WorkspaceLaunch.Workspace) {
        workspace.setupProgress.finish(
            items: FinishSetupItem.allCases, seen: Set(LaunchpadStep.sequence(for: .startHere)), now: ClientHomeFixture.now)
    }

    private static func record(_ state: SetupProgressRecord.State, seen: [LaunchpadStep]) -> SetupProgressRecord {
        SetupProgressRecord(
            state: state, path: .startHere, cursor: seen.last, seen: Set(seen), startedAt: ClientHomeFixture.now,
            updatedAt: ClientHomeFixture.now)
    }
}

/// How many sync passes the launch work ran, observed so a test can wait on
/// it.
@MainActor @Observable
final class SyncPassRecorder {
    var passes = 0
}
