import AppKit
import SwiftUI

// MARK: - Keycaps

/// Decorative keycap matching its button's shortcut, enabled state, and accent
/// style. VoiceOver reads the button binding, so the cap is accessibility-hidden.
struct Keycap: View {
    enum Key: Hashable, Sendable {
        case command
        case shift
        case option
        case control
        case returnKey
        case escape
        case character(String)

        /// The key as a person names it, for a hint or an announcement.
        var spokenName: String {
            switch self {
            case .command: "Command"
            case .shift: "Shift"
            case .option: "Option"
            case .control: "Control"
            case .returnKey: "Return"
            case .escape: "Escape"
            case .character(let character): character
            }
        }
    }

    let key: Key
    @Environment(\.keycapOnAccent) private var onAccent
    @Environment(\.isEnabled) private var isEnabled

    init(_ key: Key) {
        self.key = key
    }

    private var accented: Bool { onAccent && isEnabled }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Radius.sm, style: .continuous)
        label
            .font(AgentFont.microSemibold)
            .foregroundStyle(accented ? AgentTheme.onSelection.opacity(Opacity.keycapLabel) : Color.secondary)
            .padding(.horizontal, Space.xs)
            .frame(minWidth: Size.chipHeight)
            .frame(height: Size.chipHeight)
            .background(accented ? AgentTheme.onSelection.opacity(Opacity.keycapWash) : AgentTheme.fillStrong, in: shape)
            .overlay {
                shape.strokeBorder(
                    accented ? AnyShapeStyle(AgentTheme.onSelection.opacity(Opacity.keycapStroke)) : AnyShapeStyle(HairlineStyle()),
                    lineWidth: Hairline.width)
            }
            .accessibilityHidden(true)
    }

    @ViewBuilder private var label: some View {
        switch key {
        case .command: Image(systemName: "command")
        case .shift: Image(systemName: "shift")
        case .option: Image(systemName: "option")
        case .control: Image(systemName: "control")
        case .returnKey: Image(systemName: "return")
        case .escape: Text("esc")
        case .character(let character): Text(character)
        }
    }
}

/// The keys of one shortcut as caps, `Space.xxs` apart: ⌘ ↩ is two caps.
struct KeyCombo: View {
    let keys: [Keycap.Key]

    init(_ keys: [Keycap.Key]) {
        self.keys = keys
    }

    /// The caps for exactly the shortcut a button binds, so a cap can never
    /// name a different key from the one that works.
    init(shortcut: KeyboardShortcut) {
        self.init(Self.keys(of: shortcut))
    }

    var body: some View {
        HStack(spacing: Space.xxs) {
            ForEach(Array(keys.enumerated()), id: \.offset) { _, key in
                Keycap(key)
            }
        }
        .accessibilityHidden(true)
    }

    /// The modifiers in the order macOS menus draw them, then the key.
    static func keys(of shortcut: KeyboardShortcut) -> [Keycap.Key] {
        var keys: [Keycap.Key] = []
        if shortcut.modifiers.contains(.control) { keys.append(.control) }
        if shortcut.modifiers.contains(.option) { keys.append(.option) }
        if shortcut.modifiers.contains(.shift) { keys.append(.shift) }
        if shortcut.modifiers.contains(.command) { keys.append(.command) }
        switch shortcut.key {
        case .return: keys.append(.returnKey)
        case .escape: keys.append(.escape)
        default: keys.append(.character(String(shortcut.key.character).uppercased()))
        }
        return keys
    }

    /// The shortcut as VoiceOver says it: "Command-Return".
    static func spoken(_ shortcut: KeyboardShortcut) -> String {
        keys(of: shortcut).map(\.spokenName).joined(separator: "-")
    }
}

extension EnvironmentValues {
    /// True inside the accent-filled primary, where a keycap takes the
    /// on-accent face.
    @Entry var keycapOnAccent = false
}

/// Dims what it wraps once, at `quick`, each time `trigger` changes: a
/// primary's keycaps saying "this is the key" after a plain ↩ reached a
/// screen where only ⌘↩ acts. The stage's footer, its review panel and the
/// shared review sheet all flash this way. A still stage never flashes.
struct KeycapFlash: ViewModifier {
    let trigger: Int
    @State private var dimmed = false
    @Environment(\.stageMotion) private var motion

    func body(content: Content) -> some View {
        content
            .opacity(dimmed ? Opacity.inactive : 1)
            .onChange(of: trigger) {
                guard motion != .still else { return }
                withAnimation(AgentMotion.quick) {
                    dimmed = true
                } completion: {
                    withAnimation(AgentMotion.quick) { dimmed = false }
                }
            }
    }
}

// MARK: - Step capsules

/// How far a walk through steps has got: one short capsule per step, filled
/// in the accent once it is reached and on the track before. The setup
/// stage's footer and Home's Finish setting up card draw it.
///
/// It is spoken only where its text is not already said beside it: the
/// stage's footer says "Step 2 of 5"; a card whose header reads "3 of 7
/// done" keeps it hidden.
struct StepCapsules: View {
    /// Whether each capsule is filled, in order.
    let filled: [Bool]
    /// What VoiceOver says for it, or nil to keep it hidden.
    var spokenLabel: String?

    init(reached: Int, total: Int, spokenLabel: String? = nil) {
        self.init(filled: (0..<max(total, 0)).map { $0 < reached }, spokenLabel: spokenLabel)
    }

    /// One capsule per row of a checklist, each filled once its own row is
    /// done, so a row that ticks fills its own capsule wherever it stands.
    init(filled: [Bool], spokenLabel: String? = nil) {
        self.filled = filled
        self.spokenLabel = spokenLabel
    }

    var body: some View {
        HStack(spacing: Space.xs) {
            ForEach(filled.indices, id: \.self) { index in
                Capsule()
                    .fill(filled[index] ? AgentTheme.selection : Color.secondary.opacity(Opacity.track))
                    .frame(width: Size.stepCapsuleWidth, height: Size.stepCapsuleHeight)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(spokenLabel ?? "")
        .accessibilityHidden(spokenLabel == nil)
    }
}

// MARK: - The stage's own shortcuts

/// The keys the setup stage binds beyond the system's default and cancel
/// actions, each named once: a button binds the value and the keycaps beside
/// it are drawn from the same value (`KeyCombo(shortcut:)`), so a cap can
/// never name a different key from the one that works.
@MainActor
enum StageShortcut {
    /// ⌘[: Back, where a walk offers one.
    static let back = KeyboardShortcut("[", modifiers: .command)
    /// ⌘↩: the only key that reaches past Agent Tooling's own things.
    static let commandReturn = KeyboardShortcut(.return, modifiers: .command)
}

// MARK: - ⌘↩

extension View {
    /// Binds external actions to a fresh ⌘Return press only when active and ready.
    /// Plain Return announces `spokenHint` and never performs the action. Repeats
    /// are ignored; the visible button invokes the same action for clicks.
    /// Inactive bindings pass keys through and take no focus. Keep the modifier's
    /// structure stable when toggling it so screen state and tasks survive; restore
    /// focus only when this binding held it before deactivation.
    func commandReturnAction(
        isActive: Bool = true, isReady: Bool, perform: @escaping () -> Void, onPlainReturn: @escaping () -> Void,
        spokenHint: String = LaunchpadCopy.Footer.commandReturnSpoken
    ) -> some View {
        modifier(
            CommandReturnActionModifier(
                isActive: isActive, isReady: isReady, perform: perform, onPlainReturn: onPlainReturn, spokenHint: spokenHint))
    }
}

private struct CommandReturnActionModifier: ViewModifier {
    let isActive: Bool
    let isReady: Bool
    let perform: () -> Void
    let onPlainReturn: () -> Void
    let spokenHint: String
    @FocusState private var focused: Bool
    /// Whether the view had the keyboard while the binding was last on, so
    /// coming back on gives the keyboard back only to a view that had it, and
    /// never takes it from a field someone is typing in.
    @State private var hadFocus = false

    func body(content: Content) -> some View {
        // Every modifier is applied whether or not the binding is on, and only
        // its values change: a branch here would give what this wraps a new
        // identity each time the binding switched, and rebuild it.
        content
            .background {
                // The binding itself, in a button nobody sees or clicks: a key
                // equivalent reaches it wherever focus is in the window.
                Button("") {
                    act(withCommand: true, isRepeat: LaunchpadKeyRouter.isRepeatKeyEvent())
                }
                .keyboardShortcut(StageShortcut.commandReturn)
                .buttonStyle(.plain)
                .disabled(!isActive)
                .opacity(0)
                .frame(width: 0, height: 0)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
            }
            .focusable(isActive)
            .focusEffectDisabled()
            .focused($focused)
            .defaultFocus($focused, isActive)
            .onChange(of: focused) { _, now in
                if isActive { hadFocus = now }
            }
            .onChange(of: isActive) { _, active in
                // Back from under FooterConfirm or a panel: the keyboard comes
                // back here, so a plain ↩ still reaches the binding.
                if active, hadFocus { focused = true }
            }
            .onKeyPress(.return, phases: .down) { press in
                // ⌘↩ is the button's; while the binding is off, Return is
                // whoever's is next.
                guard isActive, !press.modifiers.contains(.command) else { return .ignored }
                act(withCommand: false, isRepeat: false)
                return .handled
            }
    }

    /// Does what the router decides for one press.
    private func act(withCommand: Bool, isRepeat: Bool) {
        guard isActive else { return }
        switch LaunchpadKeyRouter.commandReturn(withCommand: withCommand, isRepeat: isRepeat, isReady: isReady) {
        case .perform:
            perform()
        case .hint:
            AccessibilityNotification.Announcement(spokenHint).post()
            onPlainReturn()
        case .ignore:
            break
        }
    }
}
