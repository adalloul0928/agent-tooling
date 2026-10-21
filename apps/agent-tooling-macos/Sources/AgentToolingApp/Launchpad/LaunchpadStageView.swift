import AgentToolingCore
import SwiftUI

/// One screen of the setup stage. Each step has exactly one, in its own file
/// under `Screens/`, owned by the package that draws it.
///
/// A screen reads and calls the flow it is given and moves nothing itself.
/// Its footer is static, from the flow alone, so the stage can draw the
/// footer outside the screen's crossfade and ⎋ can find the footer's later
/// slot without drawing the screen.
@MainActor
protocol LaunchpadScreen: View {
    init(flow: LaunchpadFlow)
    /// The footer the screen shows: its note, later slot, secondary and
    /// primary. The step name, capsules and Back come from the registry.
    static func footer(_ flow: LaunchpadFlow) -> StageFooterSpec
    /// Why the step is passed over, when the transition table passes it over:
    /// Done lists it under "Not recorded, and why". Nil when the screen has
    /// nothing to say.
    static func skipReason(_ context: LaunchpadTransitionContext) -> String?
}

extension LaunchpadScreen {
    static func skipReason(_ context: LaunchpadTransitionContext) -> String? { nil }
}

/// What a screen puts in the footer.
struct StageFooterSpec {
    /// The key the primary answers to.
    enum Key: Equatable, Sendable {
        /// ↩: the stage's own things only, never an app, a repository or a
        /// sign-in.
        case `return`
        /// ⌘↩: the only key that reaches past them. Fresh presses only.
        case commandReturn
    }

    struct Primary {
        var title: String
        var key: Key = .return
        var isEnabled = true
        /// Shown in place of the title while the action runs ("Joining…").
        var busyTitle: String?
        var showsKeycap = true
        var accessibilityHint: String?
        /// What a plain ↩ says when this primary answers only ⌘↩: what the
        /// key does here ("Press ⌘↩ to join").
        var commandReturnHint: CommandReturnHint = .install
        var action: @MainActor () -> Void
    }

    /// What a plain ↩ says on a screen whose primary answers only ⌘↩, shown
    /// beside the primary and spoken, and the hint the primary carries for
    /// VoiceOver: each names what the primary does, so Join's never says
    /// install.
    struct CommandReturnHint: Equatable, Sendable {
        let shown: String
        let spoken: String
        let accessibilityHint: String

        /// The review panel's and the shared sheet's: "Press ⌘↩ to install".
        static let install = CommandReturnHint(
            shown: LaunchpadCopy.Footer.commandReturnHint, spoken: LaunchpadCopy.Footer.commandReturnSpoken,
            accessibilityHint: LaunchpadCopy.Footer.commandReturnAccessibilityHint)
        /// Your other Macs' Connect and share: "Press ⌘↩ to connect".
        static let connect = CommandReturnHint(
            shown: LaunchpadCopy.Footer.commandReturnConnectHint, spoken: LaunchpadCopy.Footer.commandReturnConnectSpoken,
            accessibilityHint: LaunchpadCopy.Footer.commandReturnConnectAccessibilityHint)
        /// Join's Join as and Finish joining: "Press ⌘↩ to join".
        static let join = CommandReturnHint(
            shown: LaunchpadCopy.Footer.commandReturnJoinHint, spoken: LaunchpadCopy.Footer.commandReturnJoinSpoken,
            accessibilityHint: LaunchpadCopy.Footer.commandReturnJoinAccessibilityHint)
    }

    struct Secondary {
        var title: String
        var help: String?
        var isEnabled = true
        var action: @MainActor () -> Void
    }

    /// The later slot, which ⎋ reaches when nothing above it is open.
    enum Later {
        /// "Set up later ⎋": FooterConfirm.
        case setUpLater
        /// "Stop ⎋": the read or the join stops, keeping nothing.
        case stop(@MainActor () -> Void)
        /// No later slot: ⎋ does nothing (Done).
        case none
    }

    var note: String?
    var later: Later = .setUpLater
    /// Whether Back shows. Nil follows the registry.
    var showsBack: Bool?
    var secondary: Secondary?
    var primary: Primary?

    init(
        note: String? = nil, later: Later = .setUpLater, showsBack: Bool? = nil, secondary: Secondary? = nil,
        primary: Primary? = nil
    ) {
        self.note = note
        self.later = later
        self.showsBack = showsBack
        self.secondary = secondary
        self.primary = primary
    }
}

/// The stage: the current step's screen, its footer, and the review panel
/// over both when one is up.
///
/// The apps, the read and what was found are one screen (the tile sequence),
/// kept on screen across those steps so its tiles never move; every other
/// step crossfades in. The footer is drawn outside the crossfade, so it stays
/// put while the content changes. While the review panel is up the footer is
/// not mounted, and from the first frame of its fade it takes no clicks, so
/// there is one action bar and one primary.
struct LaunchpadStageView: View {
    let flow: LaunchpadFlow
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let motion = flow.environment.motion.resolved(reduceMotion: reduceMotion)
        let spec = Self.footer(for: flow)
        SetupStage(managedClients: managedClients) {
            screen
                .id(flow.info.group)
                .transition(.opacity)
                .modifier(CommandReturnScreen(spec: spec, flow: flow))
                .allowsHitTesting(flow.presentedReview == nil)
                .environment(\.hoverSuppressed, flow.presentedReview != nil)
        } footer: {
            if flow.presentedReview == nil {
                StageFooterBar(
                    info: flow.info, spec: spec, isConfirmingLeave: flow.isConfirmingLeave,
                    leaveMoment: flow.leaveMoment, commandReturnHint: flow.commandReturnHint,
                    flash: flow.commandReturnFlash,
                    back: { flow.goBack() }, later: { flow.escape() }, keepGoing: { flow.keepGoing() },
                    leave: { flow.leave() }
                )
                // Under the panel it fades out inert from its first frame, so
                // a click or a key during the fade reaches no second primary.
                .transition(
                    .asymmetric(
                        insertion: .opacity,
                        removal: .opacity.combined(with: .modifier(active: Inert(isOn: true), identity: Inert(isOn: false)))))
            }
        } overlay: {
            if let review = flow.presentedReview {
                ZStack(alignment: .topLeading) {
                    AgentTheme.stageScrim
                        .ignoresSafeArea()
                        .transition(.opacity)
                    LaunchpadReviewPanel(flow: flow, review: review)
                }
            }
        }
        .environment(\.stageMotion, motion)
        .animation(motion.contentChange, value: flow.info.group)
        .animation(motion == .still ? nil : AgentMotion.actionBar, value: flow.presentedReview == nil)
    }

    private var managedClients: [ClientKind] {
        if let workspace = flow.workspace { return workspace.device.managedClients }
        return ClientKind.allCases.filter { flow.seedOverride?.chosen.contains($0) ?? true }
    }

    @ViewBuilder private var screen: some View {
        switch flow.step {
        case .move: LaunchpadMoveScreen(flow: flow)
        case .welcome: LaunchpadWelcomeScreen(flow: flow)
        case .apps, .reads, .found: LaunchpadTileSequenceScreen(flow: flow)
        case .library: LaunchpadLibraryScreen(flow: flow)
        case .place: LaunchpadPlaceScreen(flow: flow)
        case .ask: LaunchpadAskScreen(flow: flow)
        case .assistant: LaunchpadAssistantScreen(flow: flow)
        case .behave: LaunchpadBehaveScreen(flow: flow)
        case .macs: LaunchpadMacsScreen(flow: flow)
        case .done: LaunchpadDoneScreen(flow: flow)
        case .join: LaunchpadJoinScreen(flow: flow)
        case .arrivals: LaunchpadArrivalsScreen(flow: flow)
        }
    }

    /// The current step's footer, from its screen.
    static func footer(for flow: LaunchpadFlow) -> StageFooterSpec {
        switch flow.step {
        case .move: LaunchpadMoveScreen.footer(flow)
        case .welcome: LaunchpadWelcomeScreen.footer(flow)
        case .apps, .reads, .found: LaunchpadTileSequenceScreen.footer(flow)
        case .library: LaunchpadLibraryScreen.footer(flow)
        case .place: LaunchpadPlaceScreen.footer(flow)
        case .ask: LaunchpadAskScreen.footer(flow)
        case .assistant: LaunchpadAssistantScreen.footer(flow)
        case .behave: LaunchpadBehaveScreen.footer(flow)
        case .macs: LaunchpadMacsScreen.footer(flow)
        case .done: LaunchpadDoneScreen.footer(flow)
        case .join: LaunchpadJoinScreen.footer(flow)
        case .arrivals: LaunchpadArrivalsScreen.footer(flow)
        }
    }

    /// Why `step` is passed over, from its screen.
    static func skipReason(for step: LaunchpadStep, context: LaunchpadTransitionContext) -> String? {
        switch step {
        case .move: LaunchpadMoveScreen.skipReason(context)
        case .welcome: LaunchpadWelcomeScreen.skipReason(context)
        case .apps, .reads, .found: LaunchpadTileSequenceScreen.skipReason(context)
        case .library: LaunchpadLibraryScreen.skipReason(context)
        case .place: LaunchpadPlaceScreen.skipReason(context)
        case .ask: LaunchpadAskScreen.skipReason(context)
        case .assistant: LaunchpadAssistantScreen.skipReason(context)
        case .behave: LaunchpadBehaveScreen.skipReason(context)
        case .macs: LaunchpadMacsScreen.skipReason(context)
        case .done: LaunchpadDoneScreen.skipReason(context)
        case .join: LaunchpadJoinScreen.skipReason(context)
        case .arrivals: LaunchpadArrivalsScreen.skipReason(context)
        }
    }
}

/// On a screen whose primary answers ⌘↩, binds it over the whole screen and
/// turns a plain ↩ into the hint, while nothing is over the screen.
///
/// It is applied to every screen and only switched on and off, never added
/// and taken away: a screen keeps its identity, and with it its state, as
/// FooterConfirm or a review panel comes and goes or its primary changes key.
private struct CommandReturnScreen: ViewModifier {
    let spec: StageFooterSpec
    let flow: LaunchpadFlow

    func body(content: Content) -> some View {
        content.commandReturnAction(
            isActive: spec.primary?.key == .commandReturn && !flow.isConfirmingLeave && flow.presentedReview == nil,
            isReady: spec.primary?.isEnabled ?? false, perform: { spec.primary?.action() },
            onPlainReturn: { flow.showCommandReturnHint() },
            spokenHint: (spec.primary?.commandReturnHint ?? .install).spoken)
    }
}

/// Takes no clicks and no keys: what it is applied to while it fades away.
private struct Inert: ViewModifier {
    let isOn: Bool

    func body(content: Content) -> some View {
        content
            .disabled(isOn)
            .allowsHitTesting(!isOn)
    }
}
