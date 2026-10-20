import AgentToolingCore
import AgentToolingTestSupport
import AppKit
import SwiftUI
import Testing

@testable import AgentToolingApp

/// Every step's placeholder, FooterConfirm in each of its moments, and each
/// piece of the stage kit draws at the stage's size in light and dark, still
/// and at the sample world's clock. Drawing the stage before its read runs
/// nothing; content that arrives late leaves the stage's window as it was.
@Suite("Launchpad foundation renders", .serialized, .timeLimit(.minutes(5)))
@MainActor
struct LaunchpadFoundationRenderTests {
    // MARK: - Placeholders

    @Test(arguments: [RenderAppearance.light, .dark])
    func everyStepBeforeTheLibraryDraws(appearance: RenderAppearance) async throws {
        let bundle = URL(filePath: "/private/var/folders/xy/AppTranslocation/Agent Tooling.app", directoryHint: .isDirectory)
        let moving = try await LaunchpadFixture(
            installation: AgentToolingInstallation(
                bundleURL: bundle, location: .translocated(bundle),
                mcpHelperURL: bundle.appending(path: "Contents/Helpers/agent-tooling-mcp"), cliHelperURL: nil,
                isAdHocSigned: false))
        defer { moving.remove() }
        try expectDrawn(moving.stage(moving.flow()), size: WindowSize.stage, appearance: appearance)

        let fixture = try await LaunchpadFixture()
        defer { fixture.remove() }
        let flow = fixture.flow()
        for expected: LaunchpadStep in [.welcome, .apps, .reads] {
            #expect(flow.step == expected)
            try expectDrawn(fixture.stage(flow), size: WindowSize.stage, appearance: appearance)
            if flow.step != .reads { LaunchpadStageView.footer(for: flow).primary?.action() }
        }
        try expectDrawn(fixture.stage(fixture.flow(.finishJoin(WorkspaceObjectID()))), size: WindowSize.stage, appearance: appearance)

        // Drawing the stage reads nothing: only Continue on the read does.
        #expect(fixture.firstReads.started.isEmpty)
        #expect(fixture.signIn.shellProbes == 0)
        #expect(fixture.observer.fullChecks == 0)
        #expect(!fixture.hasWorkspace)
    }

    @Test(arguments: [RenderAppearance.light, .dark])
    func everyStepPastTheLibraryDraws(appearance: RenderAppearance) async throws {
        let fixture = try await LaunchpadFixture()
        defer { fixture.remove() }
        let (_, sample) = try await fixture.flow(at: .afterRead)
        for step: LaunchpadStep in [.found, .library, .place, .ask, .assistant, .behave, .macs, .done, .arrivals] {
            let flow = fixture.flow(.continueFirstRun(step), workspace: sample.workspace)
            try expectDrawn(fixture.stage(flow), size: WindowSize.stage, appearance: appearance)
        }
    }

    @Test(arguments: [RenderAppearance.light, .dark])
    func theReviewPanelDrawsOverTheStage(appearance: RenderAppearance) async throws {
        let fixture = try await LaunchpadFixture()
        defer { fixture.remove() }
        let (flow, _) = try await fixture.flow(at: .afterAsk)
        LaunchpadStageView.footer(for: flow).primary?.action()
        let review = try #require(flow.presentedReview)
        await review.prepare()
        #expect(review.listedCount == 5)

        try expectDrawn(fixture.stage(flow), size: WindowSize.stage, appearance: appearance)
    }

    @Test(arguments: [RenderAppearance.light, .dark])
    func theUnreadableScreenDraws(appearance: RenderAppearance) throws {
        try expectDrawn(LaunchpadUnreadableScreen(reason: .newerFormat), size: WindowSize.stage, appearance: appearance)
    }

    // MARK: - FooterConfirm

    @Test(arguments: [RenderAppearance.light, .dark])
    func footerConfirmDrawsInEachMoment(appearance: RenderAppearance) async throws {
        let fixture = try await LaunchpadFixture()
        defer { fixture.remove() }
        let workspace = try await fixture.sample(.afterRead).workspace

        let before = fixture.flow()
        before.requestClose()
        #expect(before.leaveMoment == .beforeCommit)
        try expectDrawn(fixture.stage(before), size: WindowSize.stage, appearance: appearance)

        let after = fixture.flow(.continueFirstRun(.library), workspace: workspace)
        after.requestClose()
        #expect(after.leaveMoment == .afterCommit)
        try expectDrawn(fixture.stage(after), size: WindowSize.stage, appearance: appearance)

        let rerun = fixture.flow(.rerun, workspace: workspace)
        rerun.requestClose()
        #expect(rerun.leaveMoment == .rerun)
        try expectDrawn(fixture.stage(rerun), size: WindowSize.stage, appearance: appearance)

        let finishing = fixture.flow(.continueFirstRun(.macs), workspace: workspace)
        _ = finishing.model(for: .macs) { FinishingModel() }
        finishing.requestClose()
        #expect(finishing.leaveMoment == .finishing(LaunchpadCopy.Footer.publishing))
        try expectDrawn(fixture.stage(finishing), size: WindowSize.stage, appearance: appearance)
    }

    /// FooterConfirm arriving after the stage laid out takes the footer's
    /// place and leaves the stage's window exactly as it was.
    @Test func footerConfirmArrivingLateKeepsTheStageInItsWindow() async throws {
        let fixture = try await LaunchpadFixture()
        defer { fixture.remove() }
        let flow = fixture.flow()

        let layout = try await LateContentHarness.heightAfterChange(
            fixture.stage(flow), windowSize: WindowSize.stage, styleMask: LateContentHarness.stageWindowStyle
        ) {
            flow.requestClose()
        }

        #expect(flow.isConfirmingLeave)
        #expect(layout.hostHeight == layout.windowHeight)
    }

    // MARK: - ⌘↩ screens

    /// FooterConfirm coming and going over a screen whose primary answers ⌘↩
    /// leaves the screen standing: the stage switches the screen's ⌘↩ off and
    /// on and never rebuilds it, so what the screen holds (its fields, its
    /// focus, its scroll, its running task) is still there after Keep going.
    @Test func aCommandReturnScreenStandsWhileFooterConfirmComesAndGoes() async throws {
        let fixture = try await LaunchpadFixture()
        defer { fixture.remove() }
        let flow = fixture.flow(.finishJoin(WorkspaceObjectID()))
        #expect(LaunchpadStageView.footer(for: flow).primary?.key == .commandReturn)
        let stage = HostedStage(fixture.stage(flow))
        defer { stage.close() }
        let field = try #require(stage.textFields.first, "J01 has its address field")

        flow.requestClose()
        stage.settle()
        #expect(flow.isConfirmingLeave)
        #expect(stage.textFields.first === field)

        flow.keepGoing()
        stage.settle()
        #expect(!flow.isConfirmingLeave)
        #expect(stage.textFields.first === field)
    }

    /// The binding itself: switched off and on, and made ready, it leaves
    /// what it wraps as it was, appeared once and holding its own state.
    @Test func switchingCommandReturnOffAndOnLeavesTheViewAsItWas() throws {
        let probe = CommandReturnProbe()
        let hosted = HostedStage(CommandReturnProbeView(probe: probe))
        defer { hosted.close() }
        let identity = try #require(probe.identities.first)

        for (isActive, isReady) in [(false, false), (true, false), (true, true), (false, true), (true, true)] {
            probe.isActive = isActive
            probe.isReady = isReady
            hosted.settle()
        }

        #expect(probe.identities == [identity])
    }

    // MARK: - The kit

    @Test(arguments: [RenderAppearance.light, .dark])
    func theStageKitDraws(appearance: RenderAppearance) throws {
        try expectDrawn(KitSheet.poster.environment(\.stageMotion, .still), size: WindowSize.stage, appearance: appearance)
        try expectDrawn(KitSheet.tiles.environment(\.stageMotion, .still), size: WindowSize.stage, appearance: appearance)
        try expectDrawn(KitSheet.manifest.environment(\.stageMotion, .still), size: WindowSize.stage, appearance: appearance)
        try expectDrawn(KitSheet.cards.environment(\.stageMotion, .still), size: WindowSize.stage, appearance: appearance)
    }
}

/// The stage kit's pieces, laid out on the stage for the render test and the
/// gallery.
@MainActor
enum KitSheet {
    /// Welcome's poster under a hero header.
    static var poster: some View {
        SetupStage {
            VStack(spacing: StageLayout.Poster.titleGap) {
                StagePoster()
                Text("Welcome to Agent Tooling").font(AgentFont.hero)
                NoteLine(symbol: "info.circle", text: "Nothing is read or written until you choose.")
            }
        } footer: {
            StageFooterBar(
                info: LaunchpadStepInfo.of(.welcome, path: nil, entry: .firstRun),
                spec: StageFooterSpec(
                    showsBack: false, secondary: .init(title: "Join") {}, primary: .init(title: "Start here") {}))
        } overlay: {
            EmptyView()
        }
    }

    /// The hero well with a tile in every state, a name and a chip under each.
    static var tiles: some View {
        let states: [ClientKind: StageAgentTile.State] = [.codex: .managed, .claude: .read, .gemini: .ghost, .kiro: .absent]
        return SetupStage {
            VStack(alignment: .leading, spacing: 0) {
                StageHeader(
                    .hero, eyebrow: "Your coding agents", title: "Your apps",
                    subtitle: "Agent Tooling looks after the apps you choose, here and on your other Macs.")
                HeroWell(height: StageLayout.Well.agentsHeight) { client in
                    VStack(spacing: StageLayout.Well.nameGap) {
                        StageAgentTile(client: client, state: states[client] ?? .place)
                        Text(client.rawValue).font(AgentFont.bodySemibold)
                        Chip(
                            text: client == .kiro ? "Not found" : "2 copies · same content", style: client == .claude ? .warning : .neutral)
                    }
                }
                HStack(spacing: Space.xl) {
                    StageAgentTile(client: .codex, state: .reading)
                    StageAgentTile(client: .claude, state: .absentManaged)
                    StageAgentTile(client: .gemini, state: .place)
                    StageAgentTile(client: .codex, state: .managed, compact: true)
                    StageAgentTile(client: .kiro, state: .absent, compact: true)
                    AgentToolingAppMark()
                    AgentToolingAppMark(size: Size.tileSmall)
                    StepCapsules(reached: 2, total: 5, spokenLabel: LaunchpadCopy.Footer.stepOf(2, 5))
                    KeyCombo([.command, .returnKey])
                }
                .padding(.top, Space.xl)
            }
        } footer: {
            StageFooterBar(
                info: LaunchpadStepInfo.of(.apps, path: .startHere, entry: .firstRun),
                spec: StageFooterSpec(note: "3 of 4 found", primary: .init(title: LaunchpadCopy.Footer.continue) {}))
        } overlay: {
            EmptyView()
        }
    }

    /// The manifest columns in every line state.
    static var manifest: some View {
        SetupStage {
            VStack(alignment: .leading, spacing: 0) {
                StageHeader(.hero, eyebrow: "Before anything is read", title: "What Agent Tooling reads")
                HeroWell(height: StageLayout.Well.readsHeight) { client in
                    VStack(spacing: StageLayout.Well.nameGap) {
                        StageAgentTile(client: client, state: client == .kiro ? .absent : .reading)
                        ManifestColumn(
                            reads: [
                                .init(id: "a", text: "~/.\(client.rawValue.lowercased())/config", state: .read),
                                .init(id: "b", text: "~/.agents/skills", state: .linked),
                                .init(id: "c", text: "~/.\(client.rawValue.lowercased())/skills", state: .reading),
                                .init(id: "d", text: "~/.\(client.rawValue.lowercased())/plugins", state: .idle),
                            ],
                            runs: [
                                .init(id: "e", text: "\(client.rawValue.lowercased()) --version", state: .read),
                                .init(id: "f", text: "~/unlisted", state: .unlisted),
                            ])
                    }
                }
            }
        } footer: {
            StageFooterBar(
                info: LaunchpadStepInfo.of(.reads, path: .startHere, entry: .firstRun),
                spec: StageFooterSpec(
                    later: .stop({}), primary: .init(title: LaunchpadCopy.Footer.continue, isEnabled: false) {}))
        } overlay: {
            EmptyView()
        }
    }

    /// A two-column card, a page header and the confirm in the footer.
    static var cards: some View {
        SetupStage {
            VStack(alignment: .leading, spacing: Space.xl) {
                StageHeader(.page, eyebrow: "Your other Macs", title: "Use your library on your other Macs")
                StageTwoColumnCard(trailingWidth: StageLayout.Macs.staysColumn) {
                    VStack(alignment: .leading, spacing: Space.sm) {
                        StageListLabel("What travels")
                        Text("Your library, and what each Mac is asked to hold.").font(AgentFont.body)
                    }
                    .padding(Space.xl)
                } trailing: {
                    VStack(alignment: .leading, spacing: Space.sm) {
                        StageListLabel("What stays")
                        Text("Sign-ins, history and this Mac’s own settings.").font(AgentFont.body)
                    }
                    .padding(Space.xl)
                }
                HStack(spacing: Space.md) {
                    Chip(text: "This Mac · Juniper", style: .outline)
                    CheckBadge(tint: AgentTheme.ok)
                    CheckBadge(tint: AgentTheme.selection)
                }
            }
        } footer: {
            StageFooterBar(
                info: LaunchpadStepInfo.of(.macs, path: .startHere, entry: .firstRun),
                spec: StageFooterSpec(primary: .init(title: LaunchpadCopy.Footer.continue) {}), isConfirmingLeave: true,
                leaveMoment: .afterCommit)
        } overlay: {
            EmptyView()
        }
    }
}

/// A publish under way, for FooterConfirm's finishing moment.
@MainActor
private final class FinishingModel: LaunchpadInterruptible {
    var interruption: LaunchpadInterruption { .finishing(LaunchpadCopy.Footer.publishing) }
    func interrupt() async {}
}

/// What a view wrapped in a switchable ⌘↩ binding reports: the identity its
/// own state held, each time it appeared.
@MainActor @Observable
private final class CommandReturnProbe {
    var isActive = true
    var isReady = false
    @ObservationIgnored var identities: [UUID] = []
}

private struct CommandReturnProbeView: View {
    let probe: CommandReturnProbe

    var body: some View {
        StateHolder(probe: probe)
            .commandReturnAction(isActive: probe.isActive, isReady: probe.isReady, perform: {}, onPlainReturn: {})
    }

    /// A view with state of its own, which a rebuild would mint afresh.
    private struct StateHolder: View {
        let probe: CommandReturnProbe
        @State private var identity = UUID()

        var body: some View {
            Color.clear
                .frame(width: WindowSize.stage.width, height: WindowSize.stage.height)
                .onAppear { probe.identities.append(identity) }
        }
    }
}

/// A view in a real window at the stage's size, so a test can watch what the
/// window holds as the flow moves: which platform views stand in it, and
/// whether they are the same ones as before.
@MainActor
private final class HostedStage {
    private let window: NSWindow
    private let host: NSView

    init(_ view: some View) {
        window = NSWindow(
            contentRect: CGRect(origin: .zero, size: WindowSize.stage), styleMask: LateContentHarness.stageWindowStyle,
            backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        host = NSHostingView(rootView: AnyView(view))
        window.contentView = host
        window.orderFrontRegardless()
        settle()
    }

    /// Lets the window take in what changed and lay it out.
    func settle() {
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        host.layoutSubtreeIfNeeded()
    }

    /// Every text field in the window, in view order.
    var textFields: [NSTextField] { Self.views(in: host) }

    func close() {
        window.orderOut(nil)
    }

    private static func views<View: NSView>(in root: NSView) -> [View] {
        root.subviews.flatMap { subview in ((subview as? View).map { [$0] } ?? []) + views(in: subview) }
    }
}
