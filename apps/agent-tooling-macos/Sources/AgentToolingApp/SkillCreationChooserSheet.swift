import AgentToolingCore
import SwiftUI

/// How a new skill gets written: in conversation with Claude Code, in
/// conversation with Codex, or by hand.
///
/// The two assistants are offered only when this Mac manages that app; the
/// manual form is always there. Choosing here decides nothing durable — the
/// creator that opens next stages a draft, and the library changes only when
/// that draft is saved.
struct SkillCreationChooserSheet: View {
    @Environment(\.dismiss) private var dismiss

    /// The apps this Mac manages, in the registry's order.
    let managedClients: [ClientKind]
    let onChoose: (SkillCreationMethod) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: Space.xs) {
                Text("How do you want to create this skill?")
                    .font(AgentFont.titleLarge)
                Text("An assistant writes the draft with you in a conversation and never saves anything until you do. Writing it yourself opens the form.")
                    .font(AgentFont.body)
                    .foregroundStyle(.secondary)
                    .wrapsLines()
            }
            .padding(.horizontal, Space.xxxl)
            .padding(.top, Space.xxxl)
            .padding(.bottom, Space.xxl)

            VStack(spacing: Space.lg) {
                option(.assistant(.claude))
                option(.assistant(.codex))
                option(.manual)
            }
            .padding(.horizontal, Space.xxxl)

            Spacer(minLength: Space.xxl)
            Hairline()
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
            .padding(.horizontal, Space.xxxl)
            .frame(height: Size.sheetBarHeight)
        }
        .sheetSize(SheetSize.small)
        .background(AgentTheme.contentBackground)
    }

    private func option(_ method: SkillCreationMethod) -> some View {
        let unavailableReason = unavailableReason(for: method)
        return Button {
            onChoose(method)
            dismiss()
        } label: {
            HStack(spacing: Space.xl) {
                Group {
                    switch method {
                    case .assistant(let client):
                        ClientBrandIcon(client: client, size: Size.tile)
                    case .manual:
                        Image(systemName: "square.and.pencil")
                            .font(.system(size: Size.heroSymbol, weight: .medium))
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(width: Size.discLarge, height: Size.discLarge)
                .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: Space.xxs) {
                    Text(method.title)
                        .font(AgentFont.bodySemibold)
                    Text(unavailableReason ?? method.detail)
                        .font(AgentFont.caption)
                        .foregroundStyle(.secondary)
                        .wrapsLines()
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(AgentFont.captionSemibold)
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, Space.xl)
            .padding(.vertical, Space.lg)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .background(AgentTheme.controlBackground, in: RoundedRectangle.card)
            .overlay {
                RoundedRectangle.card
                    .strokeBorder(AgentTheme.hairlineStroke, lineWidth: Hairline.width)
            }
        }
        .buttonStyle(.plain)
        .disabled(unavailableReason != nil)
        .opacity(unavailableReason == nil ? 1 : 0.55)
        .accessibilityLabel(method.title)
        .accessibilityHint(unavailableReason ?? method.detail)
    }

    /// Why an option cannot be chosen, when it cannot. An assistant this Mac
    /// does not manage is not offered; whether its skill creator is installed
    /// is the creator's own question, asked once it opens.
    private func unavailableReason(for method: SkillCreationMethod) -> String? {
        guard case .assistant(let client) = method, !managedClients.contains(client) else { return nil }
        return "This Mac is not managing \(client.rawValue). Turn it on in Choose apps to create skills with it."
    }
}

/// The three ways the chooser offers.
enum SkillCreationMethod: Hashable {
    case assistant(ClientKind)
    case manual

    var title: String {
        switch self {
        case .assistant(let client): "Create with \(client.rawValue)"
        case .manual: "Write it yourself"
        }
    }

    var detail: String {
        switch self {
        case .assistant(.claude):
            "Uses your signed-in Claude Code and its skill-creator plugin. You describe the skill, it asks questions and writes the draft."
        case .assistant(.codex):
            "Uses your signed-in Codex and its built-in skill creator. You describe the skill, it asks questions and writes the draft."
        case .assistant(let client):
            "Uses your signed-in \(client.rawValue)."
        case .manual:
            "Fill in the name, description, and instructions in a form. No assistant is involved."
        }
    }
}
