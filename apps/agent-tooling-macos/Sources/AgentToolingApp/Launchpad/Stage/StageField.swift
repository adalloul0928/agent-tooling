import SwiftUI

extension StageLayout.Macs {
    /// The focus ring a stage field draws outside its edge, as the system's
    /// own text fields draw theirs.
    static let fieldFocusRing: CGFloat = 3
}

extension AgentTheme {
    /// A stage field's face: near-white on a light card, a brightening over
    /// a dark one.
    static let stageFieldGround = dynamic(light: 0xFFFFFF, dark: 0xFFFFFF, lightAlpha: 0.80, darkAlpha: 0.06)
    /// Its resting edge: the system bezel's in light, a hairline in dark.
    static let stageFieldEdge = dynamic(light: 0x000000, dark: 0xFFFFFF, lightAlpha: 0.16, darkAlpha: 0.10)
}

/// A 36 pt text field on the setup stage (S17, J01): the control height and
/// the control radius, a quiet face, and the system's accent edge and focus
/// ring while it has the keyboard.
///
/// It is the system text field underneath, with its editing, its
/// accessibility and its undo; only its frame is drawn here. Locked, it shows
/// its value in secondary and takes no edits: the address a join is joining.
struct StageField: View {
    /// What VoiceOver calls it: the label beside it.
    let label: String
    var placeholder = ""
    @Binding var text: String
    var isLocked = false
    /// Takes the keyboard when it first appears.
    var focusesFirst = false
    var onSubmit: () -> Void = {}
    @FocusState private var focused: Bool

    var body: some View {
        // The prompt keeps its own quiet face, never the value's.
        TextField(label, text: $text, prompt: Text(placeholder).foregroundStyle(.tertiary))
            .labelsHidden()
            .textFieldStyle(.plain)
            .font(AgentFont.body)
            .foregroundStyle(isLocked ? .secondary : .primary)
            .lineLimit(1)
            .disabled(isLocked)
            .focused($focused)
            .onSubmit(onSubmit)
            .padding(.horizontal, Space.lg)
            .frame(height: Size.controlHeight)
            .background(AgentTheme.stageFieldGround, in: RoundedRectangle.control)
            .overlay {
                RoundedRectangle.control.strokeBorder(
                    isFocused
                        ? AnyShapeStyle(Color(nsColor: .controlAccentColor))
                        : AnyShapeStyle(HairlineStyle(base: AgentTheme.stageFieldEdge)),
                    lineWidth: Hairline.width)
            }
            .overlay {
                if isFocused {
                    RoundedRectangle(cornerRadius: Radius.md + StageLayout.Macs.fieldFocusRing, style: .continuous)
                        .strokeBorder(Color(nsColor: .keyboardFocusIndicatorColor), lineWidth: StageLayout.Macs.fieldFocusRing)
                        .padding(-StageLayout.Macs.fieldFocusRing)
                        .allowsHitTesting(false)
                }
            }
            .accessibilityLabel(label)
            .defaultFocus($focused, focusesFirst && !isLocked)
    }

    private var isFocused: Bool { focused && !isLocked }
}

/// The line under a field: a 12 pt glyph and a caption, "An HTTPS address"
/// beside a green check, or why the address cannot be used, with the button
/// that mends it when there is one.
struct StageFieldHelp<Action: View>: View {
    enum Tone: Sendable {
        case ok
        case problem
    }

    let tone: Tone
    let text: String
    let action: Action

    init(_ tone: Tone, _ text: String, @ViewBuilder action: () -> Action) {
        self.tone = tone
        self.text = text
        self.action = action()
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Space.xs) {
            Image(systemName: symbol)
                .font(.system(size: Size.glyphSmall))
                .foregroundStyle(tint)
                .accessibilityHidden(true)
            Text(text)
                .foregroundStyle(tone == .problem ? AnyShapeStyle(AgentTheme.failure) : AnyShapeStyle(.secondary))
                .wrapsLines()
            action
        }
        .font(AgentFont.caption)
        .accessibilityElement(children: .combine)
    }

    private var symbol: String {
        switch tone {
        case .ok: "checkmark.circle.fill"
        case .problem: "xmark.circle.fill"
        }
    }

    private var tint: AnyShapeStyle {
        switch tone {
        case .ok: AnyShapeStyle(AgentTheme.ok)
        case .problem: AnyShapeStyle(AgentTheme.failure)
        }
    }
}

extension StageFieldHelp where Action == EmptyView {
    /// A line with nothing to press.
    init(_ tone: Tone, _ text: String) {
        self.init(tone, text) { EmptyView() }
    }
}
