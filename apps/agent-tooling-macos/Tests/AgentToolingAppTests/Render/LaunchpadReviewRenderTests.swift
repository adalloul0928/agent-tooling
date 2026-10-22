import AgentToolingCore
import AgentToolingTestSupport
import AppKit
import SwiftUI
import Testing

@testable import AgentToolingApp

/// The review panel draws over the stage in every state, in light and dark,
/// still and at the sample world's clock: read, with the plain-↩ hint,
/// mid-install, installed, installed with a failure, stale, nothing to
/// install, a step that will not run, and You joined's five steps on Cedar.
/// Drawing it runs no command. A real click on Install installs and a real
/// click on Continue goes on. The
/// plan arriving after the panel laid out leaves the stage's window as it
/// was, and the shared sheet draws its held-back step in place.
@Suite("Launchpad review renders", .serialized, .timeLimit(.minutes(5)))
@MainActor
struct LaunchpadReviewRenderTests {
    @Test(arguments: [RenderAppearance.light, .dark])
    func everyStateDraws(appearance: RenderAppearance) async throws {
        let fixture = try await LaunchpadFixture()
        defer { fixture.remove() }
        let (flow, review) = try await Self.presented(fixture)
        let workspace = try #require(flow.workspace)
        let gate = GatedCommandRunner()
        fixture.scriptReviewCommands(in: workspace, runner: gate)

        try expectDrawn(fixture.stage(flow), size: WindowSize.stage, appearance: appearance)
        #expect(gate.launches.isEmpty, "drawing the review ran a command")
        flow.showCommandReturnHint()
        try expectDrawn(fixture.stage(flow), size: WindowSize.stage, appearance: appearance)

        let install = Task { await review.install() }
        await gate.waitUntilCalled()
        #expect(review.isBusy)
        try expectDrawn(fixture.stage(flow), size: WindowSize.stage, appearance: appearance)
        gate.release()
        await install.value
        #expect(LaunchpadReviewPanel.result(of: review) == "Installed to Claude Code and Codex.")
        try expectDrawn(fixture.stage(flow), size: WindowSize.stage, appearance: appearance)
    }

    @Test(arguments: [RenderAppearance.light, .dark])
    func theStatesThatEndWithoutAnInstallDraw(appearance: RenderAppearance) async throws {
        let fixture = try await LaunchpadFixture()
        defer { fixture.remove() }
        let (flow, sample) = try await fixture.flow(at: .afterAsk)
        let workspace = sample.workspace

        // Nothing to install.
        let empty = ScopedPlanReview(workspace: workspace, scope: .artifacts([]), deviceName: "Juniper")
        flow.presentReview(empty, returnTo: nil)
        await empty.prepare()
        #expect(LaunchpadReviewPanel.result(of: empty) == "Nothing to install.")
        try expectDrawn(fixture.stage(flow), size: WindowSize.stage, appearance: appearance)

        // Claude Code's tool is nowhere this Mac looks: its steps will not run.
        let world = fixture.world
        workspace.deployment.commandServices = DeploymentCommandServices(
            runner: { RefusingCommandRunner() }, locate: { client, _ in client == .claude ? nil : world.locate(client) })
        let partial = ScopedPlanReview(
            workspace: workspace, scope: .wholePlan, deviceName: "Juniper", libraryDecisions: flow.decisions)
        flow.presentReview(partial, returnTo: nil)
        await partial.prepare()
        #expect(partial.runnableCount == 2)
        try expectDrawn(fixture.stage(flow), size: WindowSize.stage, appearance: appearance)

        // The library moved while the panel was open.
        _ = try await workspace.service.registerDevice(
            .init(expectedRevisionID: try fixture.head(of: workspace), deviceID: workspace.store.deviceID, name: "Juniper"))
        await partial.install()
        #expect(partial.phase == .stale)
        try expectDrawn(fixture.stage(flow), size: WindowSize.stage, appearance: appearance)
    }

    @Test(arguments: [RenderAppearance.light, .dark])
    func anInstallWithAFailureDraws(appearance: RenderAppearance) async throws {
        let fixture = try await LaunchpadFixture()
        defer { fixture.remove() }
        let (flow, review) = try await Self.presented(fixture)
        // Claude Code refuses both of its steps; Codex's go through.
        let helper = fixture.helperPath
        fixture.scriptReviewCommands(
            in: try #require(flow.workspace),
            runner: ScriptedCommandRunner(byTool: ["codex": [["mcp", "add", "agent-tooling", "--", helper]: .standardOutput("")]]))

        await review.install()

        guard case .finished(let outcome) = review.phase else {
            Issue.record("The install did not end: \(review.phase)")
            return
        }
        #expect(outcome.summary == "Installed to 1 of 2 apps.")
        try expectDrawn(fixture.stage(flow), size: WindowSize.stage, appearance: appearance)
    }

    /// An install stopped before its first step: nothing ran, and the bar
    /// says so beside Review again.
    @Test(arguments: [RenderAppearance.light, .dark])
    func aReviewThatDidNotRunDraws(appearance: RenderAppearance) async throws {
        let fixture = try await LaunchpadFixture()
        defer { fixture.remove() }
        let (flow, review) = try await Self.presented(fixture)
        let runner = fixture.reviewRunner()
        fixture.scriptReviewCommands(in: try #require(flow.workspace), runner: runner)

        let installing = review.begin()
        review.stop()
        await installing?.value

        #expect(review.phase == .notRun("The install was stopped before it began. Nothing was changed."))
        #expect(await runner.launches.isEmpty)
        #expect(review.groups.flatMap(\.steps).map(\.state) == [.waiting, .waiting, .leftAlone, .waiting, .waiting])
        try expectDrawn(fixture.stage(flow), size: WindowSize.stage, appearance: appearance)
    }

    /// Every step listed is left alone: there is nothing to approve, so the
    /// bar says so and offers Continue, which writes nothing and goes on. ⌘↩
    /// is not the panel's.
    @Test func whenNothingCanRunContinueGoesOn() async throws {
        let fixture = try await LaunchpadFixture()
        defer { fixture.remove() }
        let (flow, sample) = try await fixture.flow(at: .afterAsk)
        let frontendDesign = try #require(sample.artifact("frontend-design"))
        let review = ScopedPlanReview(
            workspace: sample.workspace, scope: .artifacts([frontendDesign.identity.id]), deviceName: "Juniper",
            libraryDecisions: flow.decisions)
        flow.presentReview(review, returnTo: nil)
        await review.prepare()

        #expect(review.listedCount == 1)
        #expect(review.runnableCount == 0)
        #expect(review.hasNothingToRun)
        #expect(!LaunchpadReviewPanel.awaitsCommandReturn(review))
        #expect(LaunchpadReviewPanel.result(of: review) == "Nothing here can run yet.")
        for appearance in [RenderAppearance.light, .dark] {
            try expectDrawn(fixture.stage(flow), size: WindowSize.stage, appearance: appearance)
        }
        let before = try fixture.head(of: sample.workspace)
        let stage = StageWindow(fixture.stage(flow))
        defer { stage.close() }

        try stage.click(at: StageWindow.barPrimary)

        #expect(flow.presentedReview == nil)
        #expect(flow.step == .assistant)
        #expect(try fixture.head(of: sample.workspace) == before)
    }

    /// The panel takes the keyboard from the step under it: after a click on
    /// one of S11's rows gave S11's list the keyboard, Space opens the
    /// panel's library row, a plain ↩ asks for ⌘↩, and S11's rows stay as
    /// they were.
    @Test func thePanelTakesTheKeyboardFromTheStepUnderIt() async throws {
        var fixture = try await LaunchpadFixture()
        defer { fixture.remove() }
        let applications = fixture.world.home.root.appending(path: "Applications", directoryHint: .isDirectory)
        fixture.environment.installation = { HelperBundle.inApplications(applications) }
        let (flow, _) = try await fixture.flow(at: .afterAsk)
        let stage = StageWindow(fixture.stage(flow), titled: true)
        defer { stage.close() }
        let hookUp = AgentToolingHookUp.of(flow)
        await waitUntil { hookUp.rows.contains(where: \.canTick) }
        stage.settle()

        // A row, clicked twice: the list has the keyboard, the ticks are as
        // they were.
        let ticks = hookUp.rows.map(\.isTicked)
        // S11's checkboxes sit in the column just inside its rows' padding.
        let checkboxes = StageLayout.Grid.sideInset + Space.xl + StageLayout.Ask.checkSlot / 2
        let row = try #require(try stage.firstPoint(atX: checkboxes) { hookUp.focused != nil })
        try stage.click(at: row)
        #expect(hookUp.focused != nil)
        #expect(hookUp.rows.map(\.isTicked) == ticks)

        try #require(LaunchpadAskScreen.footer(flow).primary).action()
        await waitUntil { flow.presentedReview?.phase == .ready }
        stage.settle()
        let review = try #require(flow.presentedReview)
        #expect(review.libraryLine != nil)

        try stage.press(.space)
        #expect(review.isLibraryExpanded)
        #expect(hookUp.rows.map(\.isTicked) == ticks)

        try stage.pressReturn(command: false)
        #expect(flow.commandReturnHint)
        #expect(review.phase == .ready)
        #expect(hookUp.rows.map(\.isTicked) == ticks)
    }

    /// You joined's review installs what it lists on Cedar: every app's own
    /// tool answers, so both apps take every change.
    @Test func youJoinedsReviewInstallsToBothApps() async throws {
        let fixture = try await LaunchpadFixture(.cedar)
        defer { fixture.remove() }
        let (flow, sample) = try await fixture.flow(at: .cedarJoined)
        defer { sample.remove() }
        let workspace = sample.workspace
        let world = fixture.world
        await workspace.deployment.prepare()
        let plan = try #require(workspace.deployment.plan)
        let snapshot = try #require(workspace.library.state?.snapshot)
        let commands = WorkspaceDeploymentSession.commandPlans(
            plan: plan, snapshot: snapshot, homeRoot: workspace.homeRoot, locate: { client, _ in world.locate(client) })
        var replies: [String: [[String]: ScriptedCommandRunner.Reply]] = [:]
        for (tool, arguments) in commands.plugins.map({ ($0.executableURL.lastPathComponent, $0.arguments) })
            + commands.connections.map({ ($0.executableURL.lastPathComponent, $0.arguments) })
        {
            replies[tool, default: [:]][arguments] = .standardOutput("")
        }
        let runner = ScriptedCommandRunner(byTool: replies)
        fixture.scriptReviewCommands(in: workspace, runner: runner)
        let review = ScopedPlanReview(workspace: workspace, scope: .wholePlan, deviceName: "Cedar")
        flow.presentReview(review, returnTo: nil)
        await review.prepare()
        #expect(review.title == "Install 5 changes")

        await review.install()

        guard case .finished(let outcome) = review.phase else {
            Issue.record("The install did not finish: \(review.phase)")
            return
        }
        #expect(outcome.summary == "Installed to Claude Code and Codex.")
        #expect(outcome.succeededSteps == 5)
        #expect(review.groups.flatMap(\.steps).allSatisfy { $0.state == .done })
    }

    @Test(arguments: [RenderAppearance.light, .dark])
    func youJoinedsFiveStepReviewDrawsOnCedar(appearance: RenderAppearance) async throws {
        let fixture = try await LaunchpadFixture(.cedar)
        defer { fixture.remove() }
        let (flow, sample) = try await fixture.flow(at: .cedarJoined)
        defer { sample.remove() }
        let review = ScopedPlanReview(workspace: sample.workspace, scope: .wholePlan, deviceName: "Cedar")
        flow.presentReview(review, returnTo: nil)
        await review.prepare()

        #expect(review.title == "Install 5 changes")
        #expect(review.libraryLine == nil)
        try expectDrawn(fixture.stage(flow), size: WindowSize.stage, appearance: appearance)
    }

    // MARK: - Clicks

    /// A real click on Install installs, and a real click on Continue, whose
    /// repeat guard reads the event being handled (D25), goes on to the next
    /// step.
    @Test func clickingInstallInstallsAndClickingContinueGoesOn() async throws {
        let fixture = try await LaunchpadFixture()
        defer { fixture.remove() }
        let (flow, review) = try await Self.presented(fixture)
        let workspace = try #require(flow.workspace)
        fixture.scriptReviewCommands(in: workspace, runner: fixture.reviewRunner())
        let stage = StageWindow(fixture.stage(flow))
        defer { stage.close() }

        try stage.click(at: StageWindow.barPrimary)
        await waitUntil {
            if case .finished = review.phase { true } else { false }
        }
        stage.settle()
        try stage.click(at: StageWindow.barPrimary)

        #expect(flow.presentedReview == nil)
        #expect(flow.step == .assistant)
        #expect(flow.outcomes.install?.installed == [.codex, .claude])
    }

    /// Real keys (D9): a plain ↩ on the panel writes nothing and asks for ⌘↩;
    /// ⌘↩ installs.
    @Test func aPlainReturnAsksAndCommandReturnInstalls() async throws {
        let fixture = try await LaunchpadFixture()
        defer { fixture.remove() }
        let (flow, review) = try await Self.presented(fixture)
        let runner = fixture.reviewRunner()
        fixture.scriptReviewCommands(in: try #require(flow.workspace), runner: runner)
        let stage = StageWindow(fixture.stage(flow), titled: true)
        defer { stage.close() }

        try stage.pressReturn(command: false)
        #expect(flow.commandReturnHint)
        #expect(review.phase == .ready)
        #expect(await runner.launches.isEmpty)

        try stage.pressReturn(command: true)
        await waitUntil {
            if case .finished = review.phase { true } else { false }
        }
        #expect(await runner.launches.count == 3)
    }

    // MARK: - Late content

    /// The plan arrives after the panel laid out (the panel reads it as it
    /// appears): the stage's window stays exactly as it was.
    @Test func thePlanArrivingLateKeepsTheStageInItsWindow() async throws {
        let fixture = try await LaunchpadFixture()
        defer { fixture.remove() }
        let (flow, sample) = try await fixture.flow(at: .afterAsk)
        let review = ScopedPlanReview(
            workspace: sample.workspace, scope: .wholePlan, deviceName: "Juniper", libraryDecisions: flow.decisions)
        flow.presentReview(review, returnTo: nil)

        let layout = try await LateContentHarness.heightAfterChange(
            fixture.stage(flow), windowSize: WindowSize.stage, styleMask: LateContentHarness.stageWindowStyle
        ) {
            await waitUntil { review.phase == .ready }
        }

        #expect(layout.hostHeight == layout.windowHeight)
        #expect(review.listedCount == 5)
    }

    // MARK: - The shared sheet

    @Test(arguments: [RenderAppearance.light, .dark])
    func theSharedSheetDrawsItsHeldBackStepInPlace(appearance: RenderAppearance) async throws {
        let fixture = try await LaunchpadFixture()
        defer { fixture.remove() }
        let sample = try await fixture.sample(.afterAsk)
        await sample.workspace.deployment.prepare()
        let plan = try #require(sample.workspace.deployment.plan)
        let review = ScopedPlanReview(workspace: sample.workspace, reviewing: plan)

        // Listed before it is read, the step left alone in its app's group.
        #expect(review.groups.first?.steps.map(\.state).contains(.leftAlone) == true)
        #expect(review.listedCount == 5)
        try expectDrawn(
            PlanReviewSheet(workspace: sample.workspace, plan: plan), size: SheetSize.xlarge, appearance: appearance)
    }

    /// The shared sheet once it has read its plan: the commands in their
    /// wells, Before you approve as one neutral line, and the scopes the plan
    /// is in named before the apps.
    @Test(arguments: [RenderAppearance.light, .dark])
    func theSharedSheetDrawsTheReadPlan(appearance: RenderAppearance) async throws {
        let fixture = try await LaunchpadFixture()
        defer { fixture.remove() }
        let sample = try await fixture.sample(.afterAsk)
        fixture.scriptReviewCommands(in: sample.workspace, runner: RefusingCommandRunner())
        await sample.workspace.deployment.prepare()
        let review = ScopedPlanReview(workspace: sample.workspace, reviewing: try #require(sample.workspace.deployment.plan))

        await review.prepare()

        #expect(review.phase == .ready)
        #expect(review.scopes == [.user])
        #expect(
            review.beforeYouApprove
                == "3 steps run a command · 1 step is left alone. Release Notes was checked for risky content; nothing was flagged.")
        try expectDrawn(
            PlanReviewSheet(workspace: sample.workspace, review: review), size: SheetSize.xlarge, appearance: appearance)
    }

    /// The stage at Let your apps ask, its review up and read.
    private static func presented(_ fixture: LaunchpadFixture) async throws -> (LaunchpadFlow, ScopedPlanReview) {
        let (flow, sample) = try await fixture.flow(at: .afterAsk)
        let review = ScopedPlanReview(
            workspace: sample.workspace, scope: .wholePlan, deviceName: "Juniper", libraryDecisions: flow.decisions)
        flow.presentReview(review, returnTo: nil)
        await review.prepare()
        return (flow, review)
    }
}

/// The stage in a window of its own, on screen, that a test clicks into the
/// way a person does.
@MainActor
private struct StageWindow {
    let window: NSWindow
    let host: NSHostingView<AnyView>

    /// `titled` gives the window a title bar, so it takes the keyboard and
    /// the stage's focus lands where it would.
    init(_ view: some View, titled: Bool = false) {
        host = NSHostingView(rootView: AnyView(view.frame(width: WindowSize.stage.width, height: WindowSize.stage.height)))
        host.frame = CGRect(origin: .zero, size: WindowSize.stage)
        window = NSWindow(
            contentRect: host.frame, styleMask: titled ? [.titled, .closable] : [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        if titled { window.makeKeyAndOrderFront(nil) } else { window.orderFrontRegardless() }
        settle()
    }

    /// ↩, or ⌘↩, as the keyboard sends it: a plain key to whoever has the
    /// keyboard, a key with ⌘ as a key equivalent.
    func pressReturn(command: Bool) throws {
        let flags: NSEvent.ModifierFlags = command ? [.command] : []
        let events = try [NSEvent.EventType.keyDown, .keyUp].map { type in
            try #require(
                NSEvent.keyEvent(
                    with: type, location: .zero, modifierFlags: flags, timestamp: ProcessInfo.processInfo.systemUptime,
                    windowNumber: window.windowNumber, context: nil, characters: "\r", charactersIgnoringModifiers: "\r",
                    isARepeat: false, keyCode: Self.returnKeyCode))
        }
        if command {
            _ = window.performKeyEquivalent(with: events[0])
        } else {
            for event in events { window.sendEvent(event) }
        }
        settle()
    }

    /// The Return key's virtual key code.
    private static let returnKeyCode: UInt16 = 36

    /// A key the keyboard sends to whoever has it.
    enum Key {
        case space

        var characters: String { " " }
        var keyCode: UInt16 { 49 }
    }

    /// `key`, pressed and let go, as the keyboard sends it.
    func press(_ key: Key) throws {
        for type in [NSEvent.EventType.keyDown, .keyUp] {
            let event = try #require(
                NSEvent.keyEvent(
                    with: type, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                    windowNumber: window.windowNumber, context: nil, characters: key.characters,
                    charactersIgnoringModifiers: key.characters, isARepeat: false, keyCode: key.keyCode))
            window.sendEvent(event)
        }
        settle()
    }

    /// The first point down the stage at `x`, from its content's top to its
    /// footer, where a click makes `hit` true: a control whose height this
    /// test does not otherwise know. Nil when no click there does.
    func firstPoint(atX x: CGFloat, where hit: () -> Bool) throws -> CGPoint? {
        for y in stride(from: StageLayout.Grid.contentTop, to: StageLayout.Grid.lastLine, by: Space.md) {
            let point = CGPoint(x: x, y: y)
            try click(at: point)
            if hit() { return point }
        }
        return nil
    }

    func settle() {
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        host.layoutSubtreeIfNeeded()
    }

    /// A point inside the review bar's primary, whatever it says: a little in
    /// from its trailing end, halfway down the bar, in stage points from the
    /// stage's top-left.
    static let barPrimary = CGPoint(
        x: StageLayout.ReviewPanel.origin.x + StageLayout.ReviewPanel.size.width - Space.xxxl - Space.xl,
        y: StageLayout.ReviewPanel.origin.y + StageLayout.ReviewPanel.size.height - Size.sheetBarHeight / 2)

    /// Clicks the stage at `stagePoint`, in stage points from its top-left:
    /// a mouse down and a mouse up, delivered to the window as AppKit
    /// delivers a person's click.
    func click(at stagePoint: CGPoint) throws {
        let point = CGPoint(x: stagePoint.x, y: WindowSize.stage.height - stagePoint.y)
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            let event = try #require(
                NSEvent.mouseEvent(
                    with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                    windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
            window.sendEvent(event)
        }
        settle()
    }

    func close() { window.orderOut(nil) }
}
