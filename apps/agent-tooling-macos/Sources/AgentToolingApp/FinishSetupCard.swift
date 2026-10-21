import AgentToolingCore
import SwiftUI

/// What Home's Finish setting up card reaches outside the app through, each
/// with its live default: where this copy runs from, and whether Raycast and
/// its extension are on this Mac. A render test hands in its own, so drawing
/// the card reads nothing of the Mac it runs on.
struct FinishSetupServices: Sendable {
    /// Where the running copy is, read from the home folder given.
    var installation: @Sendable (URL) -> AgentToolingInstallation
    /// Raycast and its extension, looked for from the home folder given.
    var raycast: @Sendable (URL) -> CompanionPresence.Raycast

    static let live = FinishSetupServices(
        installation: { home in AgentToolingInstallation.inspect(bundleURL: Bundle.main.bundleURL, homeURL: home) },
        raycast: { home in CompanionPresence.raycast(home: home) })
}

extension EnvironmentValues {
    /// How the Finish setting up card reads this Mac. A test replaces it.
    @Entry var finishSetupServices = FinishSetupServices.live
}

/// Shows completed and remaining setup steps, with one action per open row.
/// Hidden for legacy workspaces, active first runs, and user-dismissed cards.
/// Rendering starts no discovery or checks; the tracker records completion.
struct FinishSetupCard: View {
    let workspace: WorkspaceLaunch.Workspace
    @Environment(AppNavigationState.self) private var navigation
    @Environment(\.workspaceNavigate) private var navigate
    @Environment(\.openSetup) private var openSetup
    @Environment(\.skillTrialOpening) private var trialOpening
    @Environment(\.finishSetupServices) private var services
    @Environment(\.snapshotNow) private var snapshotNow
    /// Whether this copy runs from outside Applications, read once.
    @State private var installation: AgentToolingInstallation?
    @State private var showingCheck = false
    @State private var tips: CompanionPresence.Raycast?
    @State private var trial = TrialState.idle

    /// Where the trial row's Try it stands.
    enum TrialState: Equatable {
        case idle
        case checking
        /// Why the trial did not open.
        case notice(String)
    }

    /// Nothing at all where Home shows no card, so Home without one draws
    /// exactly as it did before.
    var body: some View {
        let facts = FinishSetupFacts.live(workspace: workspace, installation: installation)
        if let list = FinishSetupChecklist.make(facts, now: snapshotNow ?? .now) {
            FinishSetupCardBody(
                list: list, trial: trial, perform: perform, hide: { workspace.setupProgress.setChecklistHidden(true) },
                showingCheck: $showingCheck, tips: $tips,
                openTips: {
                    // Raycast is looked for now, as the tips open, and not
                    // before.
                    tips = services.raycast(workspace.homeRoot)
                },
                helperPath: installation.flatMap(CompanionPresence.commandLineHelper)
            ) {
                ConnectionsCheckFlow(
                    workspace: workspace, hints: FinishSetupChecklist.signInHints(facts), dismiss: { showingCheck = false })
            }
            .modifier(FinishSetupArrival())
            .task {
                // Where this copy runs from is read once the card shows, off
                // the main actor. It adds the Move row and never decides
                // whether the card shows.
                guard installation == nil else { return }
                let home = workspace.homeRoot
                let services = services
                installation = await Task.detached { services.installation(home) }.value
            }
        }
    }

    private func perform(_ action: FinishSetupChecklist.Action) {
        switch action {
        case .resume(let step): openSetup(.resume(step))
        case .moveToApplications: openSetup(.revisit(.move))
        case .connectAgentTooling: openSetup(.revisit(.ask))
        case .connectOtherMacs: openSetup(.revisit(.macs))
        case .openCheckup: navigate(.checkup)
        case .openProjects: navigate(.projects)
        case .reviewChanges:
            // The route Home's own review button takes: Apps prepares the
            // plan and opens it for review.
            navigation.showAllClients()
            navigation.openScreenRequest(.reviewChanges)
        case .checkConnections, .signIn: showingCheck = true
        case .trySkill(let target): Task { await tryOut(target) }
        }
    }

    /// Checks the apps first, so the trial runs only where the skill really
    /// is, then opens Terminal with it invoked. Where the skill is not, the
    /// row says why and opens nothing.
    private func tryOut(_ target: SetupProgressRecord.Trial) async {
        guard trial != .checking else { return }
        trial = .checking
        await workspace.device.refresh()
        let opening = trialOpening(workspace)
        let observed = SkillTrialAvailability.observedApps(of: target.skillID, in: workspace.device.observations)
        if let reason = SkillTrialAvailability.cannotTryReason(
            skillName: target.skillID, in: target.client, observedIn: observed, canOpen: opening.canTry(in: target.client))
        {
            trial = .notice(reason)
            return
        }
        do {
            _ = try await opening.tryOut(skillName: target.skillID, in: target.client)
            workspace.setupProgress.recordTrial(skillName: target.skillName, client: target.client, place: .home)
            trial = .idle
        } catch {
            trial = .notice((error as? any LocalizedError)?.errorDescription ?? error.localizedDescription)
        }
    }
}

/// The card drawn from its checklist alone: the header with its count and
/// capsules, Resume and Move when they apply, the rows, and the foot. Every
/// action is handed back to whoever draws it, so the gallery and a render
/// test draw it from a hand-made checklist and nothing runs.
struct FinishSetupCardBody<CheckPopover: View>: View {
    let list: FinishSetupChecklist
    var trial = FinishSetupCard.TrialState.idle
    var perform: (FinishSetupChecklist.Action) -> Void = { _ in }
    var hide: () -> Void = {}
    /// The connection check's confirmation, over the sign-in row's button.
    var showingCheck: Binding<Bool> = .constant(false)
    /// The tips, over the foot's link, once Raycast was looked for.
    var tips: Binding<CompanionPresence.Raycast?> = .constant(nil)
    var openTips: () -> Void = {}
    var helperPath: String?
    @ViewBuilder var checkPopover: () -> CheckPopover
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let copy = LaunchpadCopy.FinishSetup.self
        // Each row is 44 with its hairline drawn inside it, along its top at
        // the text column, so seven rows are 308 whatever lies between them.
        let leading = list.lead.map { [$0] } ?? []
        let extra = list.extra.map { [$0] } ?? []
        VStack(spacing: 0) {
            header
            Hairline()
            ForEach(Array((leading + extra).enumerated()), id: \.element.id) { index, row in
                FinishSetupRow(row: row, isDefault: row.id == list.lead?.id, trial: .idle, perform: perform)
                    .overlay(alignment: .top) { if index > 0 { Hairline(indent: StageLayout.FinishSetup.rowIndent) } }
            }
            ForEach(Array(list.rows.enumerated()), id: \.element.id) { index, row in
                FinishSetupRow(
                    row: row, trial: row.item == .trySkill ? trial : .idle, perform: perform,
                    isPresented: checkBinding(for: row), popover: checkPopover
                )
                .overlay(alignment: .top) {
                    if index > 0 || !(leading + extra).isEmpty { Hairline(indent: StageLayout.FinishSetup.rowIndent) }
                }
            }
            foot
                .overlay(alignment: .top) { Hairline() }
        }
        .standardPanel(cornerRadius: Radius.xl)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(copy.cardLabel(list.title, done: list.done, of: list.total))
        .animation(reduceMotion ? nil : AgentMotion.selection, value: list.filled)
    }

    private var header: some View {
        let copy = LaunchpadCopy.FinishSetup.self
        return HStack(spacing: Space.md) {
            Image(systemName: "slider.horizontal.3")
                .resizable()
                .scaledToFit()
                .frame(width: Size.symbol, height: Size.symbol)
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            Text(list.title)
                .font(AgentFont.heading)
                .lineLimit(1)
                .accessibilityAddTraits(.isHeader)
            Text(copy.count(done: list.done, of: list.total))
                .font(AgentFont.caption)
                .foregroundStyle(.secondary)
                .monospacedDigit()
                .contentTransition(reduceMotion ? .identity : .numericText())
                .lineLimit(1)
            // The header already says how many are done, so the capsules
            // stay hidden from VoiceOver.
            StepCapsules(filled: list.filled)
                .padding(.leading, Space.xs)
            Spacer(minLength: Space.md)
            Button(action: hide) {
                // Its own size: on Home the card sits under the page's larger
                // ambient font, which a plain button would otherwise take.
                Text(copy.hide)
                    .font(AgentFont.body)
                    .padding(.horizontal, Space.xs)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
        }
        .padding(.leading, Space.xl)
        .padding(.trailing, Space.md)
        .frame(height: Size.headerHeight)
    }

    private var foot: some View {
        let copy = LaunchpadCopy.FinishSetup.self
        // The link keeps the system accent, as a link does; only the words
        // after it are secondary.
        return HStack(spacing: Space.md) {
            Button(copy.useFromRaycastOrTerminal, action: openTips)
                .inlineActionStyle()
                .font(AgentFont.captionMedium)
                .foregroundStyle(Color.accentColor)
                .popover(isPresented: tipsBinding, arrowEdge: .top) {
                    CompanionTipsPopover(raycast: tips.wrappedValue ?? .absent, helperPath: helperPath)
                }
            Text(verbatim: "·")
                .foregroundStyle(.tertiary)
                .accessibilityHidden(true)
            Text(copy.runSetupAgain)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Spacer(minLength: 0)
        }
        .font(AgentFont.caption)
        .padding(.horizontal, Space.xl)
        .frame(height: StageLayout.FinishSetup.footRow)
    }

    private var tipsBinding: Binding<Bool> {
        Binding(get: { tips.wrappedValue != nil }, set: { if !$0 { tips.wrappedValue = nil } })
    }

    /// The connection check's popover stands on the sign-in row's button.
    private func checkBinding(for row: FinishSetupChecklist.Row) -> Binding<Bool> {
        Binding(
            get: { showingCheck.wrappedValue && row.item == .signInConnections },
            set: { if !$0 { showingCheck.wrappedValue = false } })
    }
}

extension FinishSetupCardBody where CheckPopover == EmptyView {
    /// The card with nothing over it: what the gallery and a render test draw.
    init(list: FinishSetupChecklist, trial: FinishSetupCard.TrialState = .idle) {
        self.init(list: list, trial: trial) { EmptyView() }
    }
}

/// One row of the card: a 20 pt slot with the done check or the empty ring,
/// the title over a caption, and the open row's one button, which may open a
/// popover from where it stands.
struct FinishSetupRow<Popover: View>: View {
    let row: FinishSetupChecklist.Row
    /// The Resume row's button answers ↩.
    var isDefault = false
    let trial: FinishSetupCard.TrialState
    let perform: (FinishSetupChecklist.Action) -> Void
    var isPresented: Binding<Bool>
    @ViewBuilder var popover: () -> Popover
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(
        row: FinishSetupChecklist.Row, isDefault: Bool = false, trial: FinishSetupCard.TrialState,
        perform: @escaping (FinishSetupChecklist.Action) -> Void, isPresented: Binding<Bool>,
        @ViewBuilder popover: @escaping () -> Popover
    ) {
        self.row = row
        self.isDefault = isDefault
        self.trial = trial
        self.perform = perform
        self.isPresented = isPresented
        self.popover = popover
    }

    var body: some View {
        let copy = LaunchpadCopy.FinishSetup.self
        HStack(spacing: Space.lg) {
            lead
                .frame(width: Size.glyphSlot, height: Size.glyphSlot)
            VStack(alignment: .leading, spacing: Space.xxs) {
                Text(row.title)
                    .font(AgentFont.bodyMedium)
                    .foregroundStyle(row.isDone ? Color.secondary : Color.primary)
                    .lineLimit(1)
                if let caption = shownCaption {
                    Text(caption)
                        .font(AgentFont.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if !row.isDone, let action = row.action, let title = row.actionTitle {
                Button {
                    perform(action)
                } label: {
                    HStack(spacing: Space.xs) {
                        Text(trial == .checking ? copy.checkingApps : title)
                        // Resume answers ↩, and says so.
                        if isDefault { KeyCombo(shortcut: .defaultAction) }
                    }
                }
                .buttonStyle(.glass)
                .disabled(trial == .checking)
                .modifier(DefaultAction(isOn: isDefault))
                .popover(isPresented: isPresented, arrowEdge: .bottom, content: popover)
            }
        }
        .padding(.horizontal, Space.xl)
        .frame(height: Size.rowHeight)
        .accessibilityElement(children: .combine)
        .accessibilityValue(row.item == nil ? "" : (row.isDone ? copy.doneValue(row.donePlace ?? "") : copy.notDone))
    }

    @ViewBuilder private var lead: some View {
        if row.isDone {
            StatusGlyph(state: .healthy, size: Size.glyphLarge)
                .transition(reduceMotion ? AnyTransition.opacity : AnyTransition(.symbolEffect(.drawOn)))
        } else if row.item != nil {
            AbsentMark(size: Size.glyphLarge, lineWidth: Hairline.ring, inset: 0)
        } else {
            // Resume and Move are not counted, so they carry no ring; their
            // slot stays, so every title starts at the text column.
            Color.clear
        }
    }

    /// The caption, with a trial's reason in its place when the trial could
    /// not open, and the command it runs in the monospaced face.
    private var shownCaption: AttributedString? {
        if case .notice(let reason) = trial { return AttributedString(reason) }
        guard let caption = row.caption else { return nil }
        var text = AttributedString(caption)
        if let command = row.command {
            var code = AttributedString(" " + command)
            code.font = AgentFont.monoMicro
            text += code
        }
        return text
    }
}

extension FinishSetupRow where Popover == EmptyView {
    /// A row whose button opens nothing over the card.
    init(
        row: FinishSetupChecklist.Row, isDefault: Bool = false, trial: FinishSetupCard.TrialState,
        perform: @escaping (FinishSetupChecklist.Action) -> Void
    ) {
        self.init(row: row, isDefault: isDefault, trial: trial, perform: perform, isPresented: .constant(false)) {
            EmptyView()
        }
    }
}

/// The card arriving on Home: it fades in from a little smaller, at
/// selection. Under Reduce Motion, or where nothing moves, it is simply
/// there.
private struct FinishSetupArrival: ViewModifier {
    @Environment(\.stageMotion) private var motion
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var arrived = false

    func body(content: Content) -> some View {
        let moving = motion.resolved(reduceMotion: reduceMotion).animatesDetails
        let shown = arrived || !moving
        content
            .opacity(shown ? 1 : 0)
            .scaleEffect(shown ? 1 : AgentMotion.appearScale)
            .onAppear {
                guard moving, !arrived else { return }
                withAnimation(AgentMotion.selection) { arrived = true }
            }
    }
}

/// ↩ for the one button on Home that takes it: Resume.
private struct DefaultAction: ViewModifier {
    let isOn: Bool

    func body(content: Content) -> some View {
        if isOn {
            content.keyboardShortcut(.defaultAction)
        } else {
            content
        }
    }
}
