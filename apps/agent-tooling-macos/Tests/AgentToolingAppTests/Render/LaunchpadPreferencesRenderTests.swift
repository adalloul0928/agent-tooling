import AgentToolingCore
import AgentToolingTestSupport
import AppKit
import Observation
import QuartzCore
import SwiftUI
import Testing

@testable import AgentToolingApp

/// Renders setup preferences and corresponding Settings/Home controls in light
/// and dark. Verifies persistence, appearance transitions, side-effect-free
/// rendering and stable window size after late content. The five-minute limit
/// allows for shared main-actor contention in parallel tests.
@Suite("Launchpad preferences renders", .serialized, .timeLimit(.minutes(5)))
@MainActor
struct LaunchpadPreferencesRenderTests {
    // MARK: Let your assistant help

    /// One state per case: each builds a sample world, and five in one case
    /// outrun the time limit when every suite runs at once.
    @Test(arguments: [RenderAppearance.light, .dark], PreferencesGalleryState.assistantStateNames)
    func letYourAssistantHelpDrawsInEachStateAndRunsNothing(appearance: RenderAppearance, state name: String) async throws {
        let state = try #require(PreferencesGalleryState.assistantState(named: name))
        let fixture = try await LaunchpadFixture()
        defer { fixture.remove() }
        let flow = try await state.flow(fixture)
        #expect(flow.step == .assistant)
        let checks = fixture.observer.fullChecks
        let reviews = fixture.setup.reviewCalls.count
        let scans = fixture.insights.scanCount

        try expectDrawn(
            PreferencesGalleryState.isolated(fixture.stage(flow), in: fixture.support), size: WindowSize.stage,
            appearance: appearance)

        #expect(fixture.observer.fullChecks == checks, "drawing checked the apps")
        #expect(fixture.setup.reviewCalls.count == reviews, "drawing ran a review")
        #expect(fixture.insights.scanCount == scans, "drawing scanned history")
        #expect(fixture.insights.deepDiveCalls.isEmpty)
    }

    @Test func everyDrawnStateIsNamedOnce() {
        #expect(PreferencesGalleryState.assistantStates.map(\.name) == PreferencesGalleryState.assistantStateNames)
    }

    /// Each drawn state says "The first review starts when Home opens." only
    /// where Home will start it: with the weekly review on during a first
    /// run, never as the screen opens with every run off, never with Codex
    /// and every run off, and never on a rerun, which sits over an open Home.
    @Test(arguments: PreferencesGalleryState.assistantStateNames)
    func theFirstReviewLineFollowsEachState(state name: String) async throws {
        let promised: Set<String> = ["weekly review on", "API-key sign-in"]
        let state = try #require(PreferencesGalleryState.assistantState(named: name))
        let fixture = try await LaunchpadFixture()
        defer { fixture.remove() }
        let flow = try await state.flow(fixture)
        let workspace = try #require(flow.workspace)
        let promises = LaunchpadAssistantScreen.promisesFirstReview(
            entry: flow.entry, runs: workspace.device.effectiveAssistantRuns, managed: workspace.device.managedClients,
            hasReview: workspace.setup.checkup?.review != nil)
        #expect(promises == promised.contains(name))
    }

    /// A new setup's switches start off, and ↩ alone keeps them off: nothing
    /// is written by Continue.
    @Test func aNewSetupsContinueRecordsNothing() async throws {
        let fixture = try await LaunchpadFixture()
        defer { fixture.remove() }
        let (flow, sample) = try await fixture.flow(at: .afterInstall)
        defer { sample.remove() }
        let device = sample.workspace.device
        #expect(device.assistantRuns == .off)
        let head = sample.workspace.library.state?.snapshot.document.revision.id

        LaunchpadStageView.footer(for: flow).primary?.action()

        #expect(flow.step == .behave)
        #expect(device.assistantRuns == .off)
        #expect(sample.workspace.library.state?.snapshot.document.revision.id == head, "nothing was written")
    }

    /// On a rerun of a workspace made before the choice existed, the switches
    /// show the runs it always had, and Continue records them: they go on as
    /// shown, and Home's notice is answered.
    @Test func aRerunsContinueRecordsTheRunsItShowed() async throws {
        let fixture = try await LaunchpadFixture()
        defer { fixture.remove() }
        let workspace = try await PreferencesGalleryState.legacyWorkspace(fixture)
        let flow = fixture.flow(.rerun, workspace: workspace)
        flow.go(to: .assistant)
        #expect(workspace.device.assistantRuns == nil)
        #expect(AssistantRunsNotice.shows(for: workspace.device))

        LaunchpadStageView.footer(for: flow).primary?.action()

        #expect(flow.step == .behave)
        await waitUntil { workspace.device.assistantRuns != nil }
        #expect(workspace.device.assistantRuns == .existingBehaviour)
        #expect(!AssistantRunsNotice.shows(for: workspace.device))
    }

    /// On the join path the two screens are This Mac's, the third capsule,
    /// and How Agent Tooling behaves goes straight to Done.
    @Test func onTheJoinPathTheScreensAreThisMacs() async throws {
        let fixture = try await LaunchpadFixture(.cedar)
        defer { fixture.remove() }
        let (flow, sample) = try await fixture.flow(at: .cedarJoined)
        defer { sample.remove() }
        flow.go(to: .assistant)
        for step: LaunchpadStep in [.assistant, .behave] {
            #expect(flow.step == step)
            #expect(flow.info.footerName == "This Mac")
            #expect(flow.info.capsules == LaunchpadStepInfo.Capsules(reached: 3, total: 3))
            try expectDrawn(PreferencesGalleryState.isolated(fixture.stage(flow), in: fixture.support), size: WindowSize.stage)
            LaunchpadStageView.footer(for: flow).primary?.action()
        }
        #expect(flow.step == .done)
    }

    // MARK: How Agent Tooling behaves

    @Test(arguments: [RenderAppearance.light, .dark], AppAppearance.allCases)
    func howAgentToolingBehavesDrawsAndRunsNothing(appearance: RenderAppearance, chosen: AppAppearance) async throws {
        let fixture = try await LaunchpadFixture()
        defer { fixture.remove() }
        let (flow, sample) = try await fixture.flow(at: .afterInstall)
        defer { sample.remove() }
        flow.advance()
        #expect(flow.step == .behave)

        try expectDrawn(
            PreferencesGalleryState.isolated(fixture.stage(flow), in: fixture.support, appearance: chosen),
            size: WindowSize.stage, appearance: appearance)

        #expect(fixture.observer.fullChecks == 0)
        #expect(sample.workspace.device.automaticallyCheckHealth, "check on open starts on")
        #expect(sample.workspace.device.updatePolicy == UpdatePolicy(), "every default kept")
    }

    /// Choosing Light or Dark re-tints the stage's window at once and
    /// crossfades its content at `AgentMotion.quick`'s length; without a
    /// window the choice is still kept.
    @Test func anAppearanceChoiceCrossfadesTheStage() throws {
        let window = NSWindow(
            contentRect: CGRect(origin: .zero, size: WindowSize.stage), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        // The stage's content is a hosting view, which draws into a layer
        // once its window is on screen.
        window.contentView = NSHostingView(rootView: Color.clear)
        window.orderFrontRegardless()
        defer { window.orderOut(nil) }
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        let fade = StageAppearanceFade()
        fade.window = window
        var kept: [AppAppearance] = []

        fade.apply(.dark) { kept.append(.dark) }

        #expect(kept == [.dark])
        #expect(window.appearance?.name == .darkAqua)
        let transition = try #require(window.contentView?.layer?.animation(forKey: StageAppearanceFade.transitionKey) as? CATransition)
        #expect(transition.type == .fade)
        #expect(transition.duration == StageLayout.Behave.appearanceFade)
        // Core Animation cannot read a SwiftUI animation's length, so the
        // fade keeps its own copy: held to `AgentMotion.quick` here, curve
        // and all, so the two cannot drift apart.
        #expect(AgentMotion.quick == .easeOut(duration: StageLayout.Behave.appearanceFade))

        fade.apply(.system) { kept.append(.system) }
        #expect(window.appearance == nil, "System follows macOS")

        let unanchored = StageAppearanceFade()
        unanchored.apply(.light) { kept.append(.light) }
        #expect(kept == [.dark, .system, .light])
    }

    /// The stage finds its window through the anchor in its background.
    @Test func theAnchorTellsTheFadeItsWindow() throws {
        let fade = StageAppearanceFade()
        let host = NSHostingView(rootView: Color.clear.background(StageAppearanceFade.Anchor(fade: fade)))
        let window = NSWindow(
            contentRect: CGRect(origin: .zero, size: WindowSize.stage), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.orderFrontRegardless()
        defer { window.orderOut(nil) }
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        host.layoutSubtreeIfNeeded()
        #expect(fade.window === window)
    }

    // MARK: Settings › General and the notice

    @Test(arguments: [RenderAppearance.light, .dark])
    func settingsGeneralDrawsItsAssistantCard(appearance: RenderAppearance) async throws {
        let fixture = try await ShellRenderFixture()
        defer { fixture.remove() }
        await fixture.workspace.accounts.seed(PreferencesGalleryState.juniperSignIns)
        try expectDrawn(renderShell(.settings, fixture: fixture), appearance: appearance)

        let noAssistant = try await ShellRenderFixture()
        defer { noAssistant.remove() }
        await noAssistant.workspace.device.setEnabled(.claude, false)
        await noAssistant.workspace.device.setEnabled(.codex, false)
        try expectDrawn(renderShell(.settings, fixture: noAssistant), appearance: appearance)
    }

    @Test(arguments: [RenderAppearance.light, .dark])
    func theNoticeDraws(appearance: RenderAppearance) async throws {
        let fixture = try await ShellRenderFixture()
        defer { fixture.remove() }
        try expectDrawn(
            AssistantRunsNotice(workspace: fixture.workspace).padding(Space.xxxl), size: shellWindowSize, appearance: appearance)
    }

    /// D27: the notice shows on a workspace whose runs were never chosen,
    /// while Claude Code or Codex is managed, and never once a choice is
    /// recorded.
    @Test func theNoticeShowsOnlyWhereItsRunsReallyRunUnchosen() async throws {
        let legacy = try await ShellRenderFixture()
        defer { legacy.remove() }
        #expect(AssistantRunsNotice.shows(for: legacy.workspace.device))
        await legacy.workspace.device.setEnabled(.claude, false)
        await legacy.workspace.device.setEnabled(.codex, false)
        #expect(!AssistantRunsNotice.shows(for: legacy.workspace.device), "nothing runs without an assistant")

        let chosen = try await ShellRenderFixture(assistantRuns: .off)
        defer { chosen.remove() }
        #expect(!AssistantRunsNotice.shows(for: chosen.workspace.device))
    }

    @Test func keepThemOnRecordsTodaysRuns() async throws {
        let fixture = try await ShellRenderFixture()
        defer { fixture.remove() }
        await AssistantRunsNotice.keepOn(fixture.workspace).value
        #expect(fixture.workspace.device.assistantRuns == .existingBehaviour)
        #expect(!AssistantRunsNotice.shows(for: fixture.workspace.device))
    }

    /// Turn them off records every run off and stops the scheduled review
    /// already reading.
    @Test func turnThemOffStopsTheRunsUnderWay() async throws {
        let restored = ShellRenderFixture.setupCheckup(home: URL(filePath: "/Users/example"), review: false)
        let setup = AssistantRunSetupServices(restored: restored, holdsReviews: true)
        let fixture = try await ShellRenderFixture(setupServices: setup)
        defer { fixture.remove() }
        let scheduled = Task { await fixture.workspace.setup.runScheduledReviewIfDue(consent: .existingBehaviour) }
        await setup.waitUntilAReviewIsHeld()

        await AssistantRunsNotice.turnOff(fixture.workspace).value
        await scheduled.value

        #expect(fixture.workspace.device.assistantRuns == .off)
        #expect(setup.cancelledReviews == 1)
        #expect(fixture.workspace.setup.checkup?.review == nil)
        #expect(!AssistantRunsNotice.shows(for: fixture.workspace.device))
    }

    // MARK: Late content

    @Test func theNoticeArrivingLateKeepsHomeInTheWindow() async throws {
        let fixture = try await ShellRenderFixture()
        defer { fixture.remove() }
        let shown = PreferencesLateShown()
        let layout = try await LateContentHarness.heightAfterChange(
            PreferencesLateHome(shown: shown, workspace: fixture.workspace)
        ) {
            shown.value = true
        }
        #expect(layout.hostHeight == layout.windowHeight)
    }

    @Test func aFailureArrivingUnderARunKeepsSettingsInTheWindow() async throws {
        let shown = PreferencesLateShown()
        let layout = try await LateContentHarness.heightAfterChange(PreferencesLateRows(shown: shown, stage: false)) {
            shown.value = true
        }
        #expect(layout.hostHeight == layout.windowHeight)
    }

    @Test func aFailureArrivingUnderARowKeepsTheStageItsSize() async throws {
        let shown = PreferencesLateShown()
        let layout = try await LateContentHarness.heightAfterChange(
            PreferencesLateRows(shown: shown, stage: true), windowSize: WindowSize.stage,
            styleMask: LateContentHarness.stageWindowStyle
        ) {
            shown.value = true
        }
        #expect(layout.windowHeight == WindowSize.stage.height)
    }
}

@MainActor @Observable
final class PreferencesLateShown {
    var value = false
}

/// Home's column as the notice arrives in it: the notice over a scrolling
/// page.
private struct PreferencesLateHome: View {
    let shown: PreferencesLateShown
    let workspace: WorkspaceLaunch.Workspace

    var body: some View {
        VStack(spacing: 0) {
            if shown.value { AssistantRunsNotice(workspace: workspace).padding(Space.xxxl) }
            ScrollView {
                VStack(spacing: Space.lg) {
                    ForEach(0..<40, id: \.self) { index in Text("Row \(index)").frame(maxWidth: .infinity, alignment: .leading) }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// A run's row, or one of How Agent Tooling behaves's rows on the stage, as
/// the sentence for a choice that did not save arrives under it.
private struct PreferencesLateRows: View {
    let shown: PreferencesLateShown
    let stage: Bool

    var body: some View {
        let failure = shown.value ? LaunchpadCopy.Footer.Failures.notRecorded : nil
        VStack(alignment: .leading, spacing: 0) {
            if stage {
                VStack(spacing: 0) {
                    InfoRow(LaunchpadCopy.Preferences.checkOnOpen, detail: LaunchpadCopy.Preferences.checkOnOpenDetail) {
                        Image(systemName: "stethoscope")
                    }
                    if let failure { SaveFailureLine(text: failure).padding(.leading, StageLayout.Behave.rowIndent) }
                }
                .stageCard()
                Spacer(minLength: 0)
            } else {
                ScrollView {
                    AssistantRunRow(
                        run: .weeklyReview, text: AssistantRunCopy.weeklyBody(reviewer: .claude, sources: [.codex, .claude]),
                        folderLine: AssistantRunCopy.folderLine(reviewer: .claude), isOn: .constant(true), failure: failure
                    )
                    .padding(Space.xl)
                    .standardPanel()
                }
            }
        }
        .padding(Space.huge)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }
}
