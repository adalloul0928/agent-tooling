import AgentToolingCore
import SwiftUI

/// Shows assistant-run consent and its data-sharing consequences. New workspaces
/// start off; legacy workspaces retain prior behavior. Choices save immediately
/// and revert on error. Continue records unchanged defaults when no choice exists,
/// dismissing Home's legacy notice.
struct LaunchpadAssistantScreen: LaunchpadScreen {
    let flow: LaunchpadFlow
    @State private var focused: AssistantRunCopy.Run = .weeklyReview
    /// The card whose switch was flipped last, which a failure is shown under.
    @State private var lastFlipped: AssistantRunCopy.Run?
    @FocusState private var hasKeyboard: Bool

    init(flow: LaunchpadFlow) {
        self.flow = flow
    }

    var body: some View {
        let copy = LaunchpadCopy.Preferences.self
        VStack(alignment: .leading, spacing: 0) {
            StageHeader(.page, eyebrow: copy.eyebrow, title: copy.assistantTitle, subtitle: copy.assistantSubtitle)
            if let workspace = flow.workspace {
                assistantLine(workspace)
                cards(workspace)
                    .padding(.top, StageLayout.Assistant.cardGap)
                VStack(alignment: .leading, spacing: Space.xs) {
                    Text(AssistantRunCopy.transientNote).wrapsLines()
                    if Self.promisesFirstReview(
                        entry: flow.entry, runs: workspace.device.effectiveAssistantRuns,
                        managed: workspace.device.managedClients, hasReview: workspace.setup.checkup?.review != nil)
                    {
                        Text(copy.firstReview).wrapsLines()
                    }
                }
                .font(AgentFont.caption)
                .foregroundStyle(.secondary)
                .padding(.top, StageLayout.Assistant.cardGap)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .onAppear { hasKeyboard = true }
    }

    static func footer(_ flow: LaunchpadFlow) -> StageFooterSpec {
        StageFooterSpec(
            primary: .init(title: LaunchpadCopy.Footer.continue) {
                recordShownRuns(flow)
                flow.advance()
            })
    }

    /// With neither Claude Code nor Codex managed no assistant can run, and
    /// the step is passed over; Done says why.
    static func skipReason(_ context: LaunchpadTransitionContext) -> String? {
        context.managesAssistant ? nil : AssistantRunCopy.noAssistant
    }

    /// On a workspace made before the choice existed, the switches show the
    /// runs it has always had; Continue records them as the choice, so they
    /// go on as shown and Home's notice is answered.
    static func recordShownRuns(_ flow: LaunchpadFlow) {
        guard let workspace = flow.workspace, workspace.device.assistantRuns == nil else { return }
        let shown = workspace.device.effectiveAssistantRuns
        workspace.recordAssistantRuns(shown)
    }

    /// Whether the screen says "The first review starts when Home opens.":
    /// only when it will. The weekly review is on, an assistant can run it,
    /// none has run on this Mac yet, and handing off from this stage opens
    /// Home, whose launch starts it. A rerun or a resumed setup sits over a
    /// Home that is already open and whose launch has run, so it says
    /// nothing of the kind.
    static func promisesFirstReview(
        entry: SetupEntry, runs: AssistantRunConsent, managed: [ClientKind], hasReview: Bool
    ) -> Bool {
        guard runs.weeklyReview, AssistantRunCopy.reviewer(managed: managed) != nil, !hasReview else { return false }
        switch entry {
        case .firstRun, .continueFirstRun, .finishJoin: return true
        case .resume, .rerun, .revisit: return false
        }
    }

    // MARK: The assistant

    @ViewBuilder private func assistantLine(_ workspace: WorkspaceLaunch.Workspace) -> some View {
        let managed = workspace.device.managedClients
        if let reviewer = AssistantRunCopy.reviewer(managed: managed) {
            let signIn = AccountProvider.provider(for: reviewer).flatMap(workspace.accounts.observation)
            HStack(spacing: Space.md) {
                ClientBrandIcon(client: reviewer, size: StageLayout.Assistant.mark)
                Text(AssistantRunCopy.assistantLine(reviewer, signIn: signIn))
                    .font(AgentFont.bodyMedium)
                    .lineLimit(1)
            }
            .frame(height: StageLayout.Assistant.mark)
            .accessibilityElement(children: .combine)
        } else {
            Text(AssistantRunCopy.noAssistant)
                .font(AgentFont.bodyMedium)
                .foregroundStyle(.secondary)
                .frame(height: StageLayout.Assistant.mark)
        }
    }

    // MARK: The cards

    private func cards(_ workspace: WorkspaceLaunch.Workspace) -> some View {
        VStack(spacing: StageLayout.Assistant.cardGap) {
            ForEach(AssistantRunCopy.Run.allCases, id: \.self) { run in
                card(run, workspace: workspace)
            }
        }
        // The stage's switches are the system's mini ones, the size of the
        // mockups' switch.
        .controlSize(.mini)
        .focusable()
        .focusEffectDisabled()
        .focused($hasKeyboard)
        .onKeyPress(.upArrow) { moveFocus(by: -1) }
        .onKeyPress(.downArrow) { moveFocus(by: 1) }
        // Space flips once per press. A held key's repeats are taken and
        // change nothing: they would flip the switch back and forth, each
        // flip a write.
        .onKeyPress(.space, phases: [.down, .repeat]) { press in
            if press.phase == .down { flip(focused, workspace: workspace) }
            return .handled
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(LaunchpadCopy.Preferences.runsLabel)
    }

    private func card(_ run: AssistantRunCopy.Run, workspace: WorkspaceLaunch.Workspace) -> some View {
        let device = workspace.device
        let managed = device.managedClients
        let reviewer = AssistantRunCopy.reviewer(managed: managed)
        let signIn = reviewer.flatMap(AccountProvider.provider(for:)).flatMap(workspace.accounts.observation)
        let isEnabled = AssistantRunCopy.needsAssistant(run) ? reviewer != nil : !AssistantRunCopy.sources(managed: managed).isEmpty
        let failure = Self.failure(under: run, lastFlipped: lastFlipped, message: device.errorMessage)
        return AssistantRunRow(
            run: run, text: AssistantRunCopy.body(run, managed: managed, signIn: signIn),
            folderLine: run == .weeklyReview ? reviewer.map(AssistantRunCopy.folderLine(reviewer:)) : nil,
            isOn: Binding(
                get: { AssistantRunCopy.isOn(run, in: device.effectiveAssistantRuns) },
                set: { set(run, $0, workspace: workspace) }),
            isEnabled: isEnabled, failure: failure
        )
        // The switch takes no click of its own: a click anywhere on the
        // card flips it, once.
        .allowsHitTesting(false)
        .padding(Space.xl)
        .frame(minHeight: Self.minimumHeight(run), alignment: .top)
        .modifier(AssistantCardChrome(isFocused: focused == run))
        .contentShape(RoundedRectangle.card)
        .onTapGesture {
            focused = run
            flip(run, workspace: workspace)
        }
    }

    /// The sentence shown under `run`'s card: the stage's one sentence for a
    /// choice that did not save, under the card flipped last.
    static func failure(
        under run: AssistantRunCopy.Run, lastFlipped: AssistantRunCopy.Run?, message: String?
    ) -> String? {
        lastFlipped == run && message == LaunchpadCopy.Footer.Failures.notRecorded ? message : nil
    }

    private static func minimumHeight(_ run: AssistantRunCopy.Run) -> CGFloat {
        switch run {
        case .weeklyReview: StageLayout.Assistant.weeklyCard
        case .dailyDeepDive: StageLayout.Assistant.deepDiveCard
        case .localInsights: StageLayout.Assistant.localCard
        }
    }

    private func moveFocus(by step: Int) -> KeyPress.Result {
        let runs = AssistantRunCopy.Run.allCases
        guard let index = runs.firstIndex(of: focused) else { return .ignored }
        let next = min(max(index + step, 0), runs.count - 1)
        focused = runs[next]
        return .handled
    }

    private func flip(_ run: AssistantRunCopy.Run, workspace: WorkspaceLaunch.Workspace) {
        set(run, !AssistantRunCopy.isOn(run, in: workspace.device.effectiveAssistantRuns), workspace: workspace)
    }

    private func set(_ run: AssistantRunCopy.Run, _ isOn: Bool, workspace: WorkspaceLaunch.Workspace) {
        let device = workspace.device
        let managed = device.managedClients
        let usable =
            AssistantRunCopy.needsAssistant(run)
            ? AssistantRunCopy.reviewer(managed: managed) != nil : !AssistantRunCopy.sources(managed: managed).isEmpty
        guard usable else { return }
        lastFlipped = run
        workspace.recordAssistantRun(run, isOn)
    }
}

extension StageLayout.Assistant {
    /// The assistant's mark on its line, and the line's height.
    static let mark: CGFloat = Size.symbol
    /// From the assistant's line to the first card, between the cards, and
    /// from the last card to the notes under them.
    static let cardGap: CGFloat = Space.lg
}

/// A run's card: the stage's card, and while the keyboard is on it the soft
/// highlight, its wash between the card and the words and its ring over the
/// card's edge.
private struct AssistantCardChrome: ViewModifier {
    let isFocused: Bool
    @Environment(\.colorSchemeContrast) private var contrast

    func body(content: Content) -> some View {
        content
            .background {
                if isFocused { RoundedRectangle.card.fill(AgentTheme.selection.opacity(Opacity.selectedWash)) }
            }
            .stageCard()
            .overlay {
                if isFocused {
                    RoundedRectangle.card.strokeBorder(
                        AgentTheme.selection.opacity(contrast == .increased ? 1 : Opacity.selectedStroke),
                        lineWidth: Hairline.ring)
                }
            }
    }
}
