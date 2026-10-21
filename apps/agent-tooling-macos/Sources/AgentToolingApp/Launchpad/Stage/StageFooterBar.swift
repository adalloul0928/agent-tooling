import SwiftUI

/// Setup navigation and its single primary action. Shortcuts belong to buttons;
/// decorative keycaps stay hidden from VoiceOver. Primary labels never truncate:
/// notes and step names yield first. Leave confirmation replaces both clusters.
struct StageFooterBar: View {
    let info: LaunchpadStepInfo
    let spec: StageFooterSpec
    var isConfirmingLeave = false
    var leaveMoment = LaunchpadLeaveMoment.beforeCommit
    /// A plain ↩ reached a screen where only ⌘↩ acts.
    var commandReturnHint = false
    /// Bumped once per such press, to flash the primary's keycaps.
    var flash = 0
    var back: () -> Void = {}
    /// The later slot's key and click: the flow's ⎋.
    var later: () -> Void = {}
    var keepGoing: () -> Void = {}
    var leave: () -> Void = {}
    @Environment(\.stageMotion) private var motion
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            if isConfirmingLeave {
                FooterConfirm(moment: leaveMoment, keepGoing: keepGoing, leave: leave)
                    .transition(.opacity)
            } else {
                clusters
                    .transition(.opacity)
            }
        }
        .animation(motion.resolved(reduceMotion: reduceMotion) == .still ? nil : AgentMotion.actionBar, value: isConfirmingLeave)
        .padding(.leading, StageLayout.Grid.sideInset)
        .padding(.trailing, Space.md)
        .frame(maxWidth: .infinity)
        .frame(height: StageLayout.Grid.footerHeight)
        .background(AgentTheme.fillSubtle)
        .overlay(alignment: .top) { Hairline() }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(LaunchpadCopy.Footer.groupLabel)
    }

    private var clusters: some View {
        HStack(spacing: Space.md) {
            leftCluster
                .layoutPriority(-1)
            Spacer(minLength: Space.md)
            rightCluster
                .fixedSize()
                .layoutPriority(1)
        }
        .controlSize(.large)
        .buttonBorderShape(.capsule)
    }

    private var leftCluster: some View {
        HStack(spacing: Space.lg) {
            Text(info.footerName)
                .font(AgentFont.bodyMedium)
                .lineLimit(1)
                .layoutPriority(1)
            if let capsules = info.capsules {
                StepCapsules(
                    reached: capsules.reached, total: capsules.total,
                    spokenLabel: LaunchpadCopy.Footer.stepOf(capsules.reached, capsules.total))
            }
            if let note = spec.note {
                Text(note)
                    .font(AgentFont.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            laterButton
        }
    }

    @ViewBuilder private var laterButton: some View {
        switch spec.later {
        case .setUpLater:
            separator
            laterLabel(LaunchpadCopy.Footer.setUpLater)
        case .stop:
            separator
            laterLabel(LaunchpadCopy.Footer.stop)
        case .none:
            EmptyView()
        }
    }

    private var separator: some View {
        Hairline(.vertical)
            .frame(height: Size.glyphLarge)
    }

    private func laterLabel(_ title: String) -> some View {
        Button(action: later) {
            HStack(spacing: Space.sm) {
                Text(title)
                KeyCombo(shortcut: .cancelAction)
            }
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .font(AgentFont.body)
        .keyboardShortcut(.cancelAction)
        .fixedSize()
    }

    private var rightCluster: some View {
        HStack(spacing: Space.md) {
            if commandReturnHint {
                Text((spec.primary?.commandReturnHint ?? .install).shown)
                    .font(AgentFont.caption)
                    .foregroundStyle(.secondary)
                    .transition(.opacity)
            }
            if spec.showsBack ?? (info.back != nil) {
                Button(action: back) {
                    HStack(spacing: Space.sm) {
                        Text(LaunchpadCopy.Footer.back)
                        KeyCombo(shortcut: StageShortcut.back)
                    }
                }
                .buttonStyle(.glass)
                .keyboardShortcut(StageShortcut.back)
            }
            if let secondary = spec.secondary {
                Button(secondary.title) { secondary.action() }
                    .buttonStyle(.glass)
                    .disabled(!secondary.isEnabled)
                    .help(secondary.help ?? "")
            }
            if let primary = spec.primary {
                primaryButton(primary)
            }
        }
    }

    @ViewBuilder private func primaryButton(_ primary: StageFooterSpec.Primary) -> some View {
        let label = HStack(spacing: Space.sm) {
            Text(primary.isEnabled ? primary.title : (primary.busyTitle ?? primary.title))
            if primary.showsKeycap && (primary.isEnabled || primary.busyTitle == nil) {
                KeyCombo(shortcut: primary.key == .commandReturn ? StageShortcut.commandReturn : .defaultAction)
                    .modifier(KeycapFlash(trigger: flash))
            }
        }
        .environment(\.keycapOnAccent, true)
        switch primary.key {
        case .return:
            Button {
                // A held ↩ must not race through screens.
                guard !LaunchpadKeyRouter.isRepeatKeyEvent() else { return }
                primary.action()
            } label: {
                label
            }
            .primaryActionStyle()
            .keyboardShortcut(.defaultAction)
            .disabled(!primary.isEnabled)
            .accessibilityHint(primary.accessibilityHint ?? "")
        case .commandReturn:
            // ⌘↩ itself is bound by the stage over the whole screen, so a
            // plain ↩ anywhere on it can say what to press instead.
            Button {
                primary.action()
            } label: {
                label
            }
            .primaryActionStyle()
            .disabled(!primary.isEnabled)
            .accessibilityHint(primary.accessibilityHint ?? primary.commandReturnHint.accessibilityHint)
        }
    }
}

/// What ⎋, ⌘W and the close button ask, in the footer's place: Keep going ⎋
/// beside the way out ↩. Before the commit point the way out is Quit setup;
/// after it, Go to Home. While something is finishing it shows only what is
/// finishing, and cannot be left.
///
/// When it appears, and whenever what it says changes, it says its sentence
/// to VoiceOver and puts the keyboard on Keep going, so a second stray ⎋
/// keeps going rather than leaving; ↩ still takes the way out.
struct FooterConfirm: View {
    let moment: LaunchpadLeaveMoment
    let keepGoing: () -> Void
    let leave: () -> Void
    @FocusState private var keepGoingFocused: Bool
    @AccessibilityFocusState private var keepGoingVoiceOver: Bool

    var sentence: String {
        switch moment {
        case .beforeCommit: LaunchpadCopy.Footer.beforeCommit
        case .unfinishedJoin: LaunchpadCopy.Footer.unfinishedJoin
        case .afterCommit: LaunchpadCopy.Footer.afterCommit
        case .rerun: LaunchpadCopy.Footer.rerunLeave
        case .finishing(let running): running
        }
    }

    var leaveTitle: String {
        moment == .beforeCommit || moment == .unfinishedJoin ? LaunchpadCopy.Footer.quitSetup : LaunchpadCopy.Footer.goToHome
    }

    private var isFinishing: Bool {
        if case .finishing = moment { true } else { false }
    }

    var body: some View {
        HStack(spacing: Space.md) {
            if isFinishing {
                ProgressView().controlSize(.small)
            }
            Text(sentence)
                .font(AgentFont.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
                .layoutPriority(-1)
            Spacer(minLength: Space.md)
            if !isFinishing {
                Button(action: keepGoing) {
                    HStack(spacing: Space.sm) {
                        Text(LaunchpadCopy.Footer.keepGoing)
                        KeyCombo(shortcut: .cancelAction)
                    }
                }
                .buttonStyle(.glass)
                .keyboardShortcut(.cancelAction)
                .focused($keepGoingFocused)
                .accessibilityFocused($keepGoingVoiceOver)
                Button {
                    guard !LaunchpadKeyRouter.isRepeatKeyEvent() else { return }
                    leave()
                } label: {
                    HStack(spacing: Space.sm) {
                        Text(leaveTitle)
                        KeyCombo(shortcut: .defaultAction)
                    }
                    .environment(\.keycapOnAccent, true)
                }
                .primaryActionStyle()
                .keyboardShortcut(.defaultAction)
            }
        }
        .controlSize(.large)
        .buttonBorderShape(.capsule)
        .onAppear(perform: announceAndFocus)
        // One FooterConfirm carries every moment while it stays up (the read
        // lands, the commit finishes): each new one is said again, and the
        // keyboard goes back to Keep going.
        .onChange(of: moment) { announceAndFocus() }
    }

    private func announceAndFocus() {
        AccessibilityNotification.Announcement(sentence).post()
        keepGoingFocused = true
        keepGoingVoiceOver = true
    }
}
