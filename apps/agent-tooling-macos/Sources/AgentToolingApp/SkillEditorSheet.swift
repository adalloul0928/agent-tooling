import AgentToolingCore
import AppKit
import SwiftUI

/// The five-step form a new skill is written with.
///
/// It admits one skill to this library and stops there. Where a skill is used is
/// a separate, saved choice, and putting it into an app is a reviewed step on
/// the Apps screen — so nothing on the last page of this form can install
/// anything, however far the person carries it.
struct SkillEditorSheet: View {
    @Environment(\.dismiss) private var dismiss
    /// Names already in this library, so a collision is caught on the first
    /// page rather than by a failed command on the last one.
    let existingNames: [String]
    let isBusy: Bool
    let canWrite: Bool
    let errorMessage: String?
    /// Returns true when the skill was admitted. `assign` says the person asked
    /// to choose where it is used straight afterwards.
    let onCreate: (SkillDraft, _ assign: Bool) -> Void

    @State private var draft = SkillDraft()
    @State private var step = 0

    private let steps = ["Purpose", "Triggers", "Placement", "Files", "Review"]

    var body: some View {
        VStack(spacing: 0) {
            header

            HStack(spacing: 0) {
                stepList
                    .frame(width: 205)
                Divider()
                stepContent
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }

            Divider()
            footer
        }
        .frame(width: 900, height: 650)
        .background(AgentTheme.contentBackground)
        .onAppear {
            // The form's own defaults describe the old install step, which this
            // screen no longer performs.
            draft.runCanary = false
        }
    }

    private var header: some View {
        HStack(spacing: 13) {
            VStack(alignment: .leading, spacing: 2) {
                Text("New skill")
                    .font(.title2.weight(.semibold))
                Text("Write the definition. Choosing where to use it comes after, and installing is reviewed separately.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Text("Step \(step + 1) of \(steps.count)")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 22)
        .frame(height: 82)
    }

    private var stepList: some View {
        VStack(alignment: .leading, spacing: 5) {
            ForEach(Array(steps.enumerated()), id: \.offset) { index, title in
                Button {
                    if index <= highestReachableStep { step = index }
                } label: {
                    HStack(spacing: 10) {
                        Text("\(index + 1)")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(index == step ? Color.primary : Color.secondary)
                            .frame(width: 20, alignment: .trailing)
                        Text(title).font(.callout.weight(index == step ? .semibold : .regular))
                        Spacer()
                    }
                    .padding(.horizontal, 10)
                    .frame(height: 42)
                    .background(
                        index == step ? AgentTheme.controlBackground : .clear,
                        in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                }
                .buttonStyle(.plain)
                .disabled(index > highestReachableStep)
            }
            Spacer()
        }
        .padding(16)
        .paneMaterial()
    }

    @ViewBuilder
    private var stepContent: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                switch step {
                case 0: purposeStep
                case 1: triggersStep
                case 2: placementStep
                case 3: filesStep
                default: reviewStep
                }
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(26)
        }
    }

    private var purposeStep: some View {
        Group {
            StepHeading(
                title: "What should this skill do?",
                message: "Keep it to one reusable capability. A narrow skill triggers more reliably.")
            FormField(title: "Skill name", help: "Lowercase words separated by hyphens") {
                TextField("release-readiness", text: $draft.name)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityLabel("Skill name")
            }
            FormField(title: "Purpose", help: "One sentence from the user’s point of view") {
                VStack(alignment: .trailing, spacing: 5) {
                    TextEditor(text: $draft.purpose)
                        .font(.body)
                        .scrollContentBackground(.hidden)
                        .padding(8)
                        .frame(height: 120)
                        .background(.quaternary.opacity(0.28), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                        .accessibilityLabel("Purpose")
                    if draft.purpose.count > WorkspaceLibrary.maximumPurposeLength * 3 / 4 {
                        CharacterCount(current: draft.purpose.count, maximum: WorkspaceLibrary.maximumPurposeLength)
                    }
                }
            }
            if nameCollision {
                Label("A skill with this name already exists. Choose a distinctive name.", systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.red)
            } else if !draft.name.isEmpty, !isNameValid {
                Label(nameValidationMessage, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
    }

    private var triggersStep: some View {
        Group {
            StepHeading(
                title: "When should it appear?",
                message: "Use the actual phrases you expect to type, plus one case that should not trigger it.")
            ForEach(draft.triggers.indices, id: \.self) { index in
                FormField(title: "Trigger \(index + 1)", help: index == 0 ? "The most natural invocation" : nil) {
                    VStack(alignment: .trailing, spacing: 5) {
                        TextField("Check release readiness", text: $draft.triggers[index])
                            .textFieldStyle(.roundedBorder)
                            .accessibilityLabel("Trigger \(index + 1)")
                        if draft.triggers[index].count > WorkspaceLibrary.maximumTriggerLength {
                            CharacterCount(current: draft.triggers[index].count, maximum: WorkspaceLibrary.maximumTriggerLength)
                        }
                    }
                }
            }
            FormField(title: "Should not trigger for", help: "A nearby request that belongs elsewhere") {
                VStack(alignment: .trailing, spacing: 5) {
                    TextField("Building an unrelated feature", text: $draft.negativeTrigger)
                        .textFieldStyle(.roundedBorder)
                        .accessibilityLabel("Should not trigger for")
                    if draft.negativeTrigger.count > WorkspaceLibrary.maximumNegativeTriggerLength {
                        CharacterCount(
                            current: draft.negativeTrigger.count, maximum: WorkspaceLibrary.maximumNegativeTriggerLength)
                    }
                }
            }
        }
    }

    private var placementStep: some View {
        Group {
            StepHeading(
                title: "Where should it live?",
                message: "The source is kept in your personal library. Apps get a copy only after you review one.")
            VStack(spacing: 0) {
                LabeledValueRow("Kept in") { Text("Your personal library").fontWeight(.medium) }
                Divider()
                LabeledValueRow("Called") {
                    Text(normalizedName.isEmpty ? "—" : normalizedName)
                        .font(.system(.caption, design: .monospaced))
                }
                Divider()
                LabeledValueRow("Shown as") { Text(SkillTemplate.displayName(for: normalizedName)) }
            }
            .standardPanel(cornerRadius: 13)

            AutomationToggle(
                title: "Choose where to use it next",
                detail: "Opens the assignment review as soon as the skill is created",
                isOn: $draft.syncClients
            )
            .standardPanel(cornerRadius: 13)

            Text(
                "Where a skill is used is a saved choice, not an installation. Putting it into an app is reviewed separately on the Apps screen."
            )
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var filesStep: some View {
        Group {
            StepHeading(
                title: "Does it need bundled files?",
                message: "Most skills need only SKILL.md. Add files only when the workflow actually reads them.")
            VStack(spacing: 0) {
                HStack {
                    FileToggleLabel(symbol: "doc.text", title: "SKILL.md", detail: "Required portable definition")
                    Spacer()
                    Image(systemName: "checkmark")
                        .foregroundStyle(.secondary)
                        .accessibilityLabel("Included")
                }
                .padding(14)
                Divider()
                Toggle(isOn: $draft.includeScript) {
                    FileToggleLabel(
                        symbol: "terminal",
                        title: "Shell script template",
                        detail: "Creates helper.sh in a disabled state; implement it before use"
                    )
                }
                .accessibilityLabel("Include shell script template")
                .padding(14)
                Divider()
                Toggle(isOn: $draft.includeReference) {
                    FileToggleLabel(
                        symbol: "books.vertical", title: "Reference file",
                        detail: "Long-form guidance loaded only when needed")
                }
                .accessibilityLabel("Include reference file")
                .padding(14)
            }
            .standardPanel(cornerRadius: 13)
        }
    }

    private var reviewStep: some View {
        Group {
            StepHeading(
                title: "Ready to create",
                message: "Review the definition and what happens once it is in your library.")
            if let errorMessage {
                AttentionBanner(title: "That could not be created", message: errorMessage)
            }
            HStack(alignment: .top, spacing: 14) {
                VStack(spacing: 0) {
                    ReviewRow(label: "Name", value: normalizedName)
                    Divider()
                    ReviewRow(label: "Purpose", value: draft.purpose)
                    Divider()
                    ReviewRow(label: "Files", value: fileSummary)
                    Divider()
                    ReviewRow(label: "Kept in", value: "Your personal library")
                    Divider()
                    ReviewRow(
                        label: "Next", value: draft.syncClients ? "Choose where to use it" : "Nothing until you ask")
                }
                .standardPanel(cornerRadius: 13)

                VStack(spacing: 0) {
                    ReviewFact(title: "Definition checked", detail: "The SKILL.md is read and validated before it is stored")
                    Divider()
                    ReviewFact(title: "Nothing is installed", detail: "No app is written to by creating a skill")
                    Divider()
                    ReviewFact(title: "Nothing is assigned", detail: "Where it is used is saved only when you review it")
                }
                .standardPanel(cornerRadius: 13)
            }
        }
    }

    private var footer: some View {
        HStack {
            Button("Cancel") { dismiss() }
                .buttonStyle(.bordered)
                .keyboardShortcut(.cancelAction)
            Spacer()
            if isBusy { ProgressView().controlSize(.small) }
            if step > 0 {
                Button("Back") { step -= 1 }
                    .buttonStyle(.bordered)
            }
            if step < steps.count - 1 {
                Button("Continue") { step += 1 }
                    .buttonStyle(.borderedProminent)
                    .tint(AgentTheme.selection)
                    .disabled(!canContinue)
            } else {
                Button("Create Skill") { onCreate(draft, draft.syncClients) }
                    .buttonStyle(.borderedProminent)
                    .tint(AgentTheme.selection)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!isDraftValid || isBusy || !canWrite)
            }
        }
        .padding(.horizontal, 22)
        .frame(height: 78)
    }

    private var normalizedName: String {
        (try? WorkspaceLibrary.normalizedIdentifier(draft.name))
            ?? draft.name.lowercased().trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: " ", with: "-")
    }

    private var fileSummary: String {
        var parts = ["SKILL.md"]
        if draft.includeScript { parts.append("scripts/helper.sh") }
        if draft.includeReference { parts.append("references/reference.md") }
        return parts.joined(separator: ", ")
    }

    private var isNameValid: Bool {
        (try? WorkspaceLibrary.normalizedIdentifier(draft.name)) != nil
    }

    private var nameCollision: Bool {
        guard isNameValid else { return false }
        let candidate = SkillTemplate.displayName(for: normalizedName)
        return existingNames.contains {
            $0.caseInsensitiveCompare(normalizedName) == .orderedSame || $0.caseInsensitiveCompare(candidate) == .orderedSame
        }
    }

    private var nameValidationMessage: String {
        if normalizedName.count > WorkspaceLibrary.maximumIdentifierLength {
            return "Use at most \(WorkspaceLibrary.maximumIdentifierLength) characters."
        }
        return "Use lowercase letters, numbers, and single hyphens."
    }

    private var highestReachableStep: Int {
        if !isNameValid || !isPurposeValid || nameCollision { return 0 }
        if !areTriggersValid || !isNegativeTriggerValid { return 1 }
        return 4
    }

    private var canContinue: Bool {
        switch step {
        case 0: isNameValid && isPurposeValid && !nameCollision
        case 1: areTriggersValid && isNegativeTriggerValid
        default: true
        }
    }

    private var isDraftValid: Bool {
        isNameValid && isPurposeValid && areTriggersValid && isNegativeTriggerValid && !nameCollision
    }

    private var isPurposeValid: Bool {
        let value = draft.purpose.trimmingCharacters(in: .whitespacesAndNewlines)
        return !value.isEmpty && value.count <= WorkspaceLibrary.maximumPurposeLength
    }

    private var areTriggersValid: Bool {
        let values = draft.triggers
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        return !values.isEmpty
            && values.count <= WorkspaceLibrary.maximumTriggerCount
            && values.allSatisfy { $0.count <= WorkspaceLibrary.maximumTriggerLength }
    }

    private var isNegativeTriggerValid: Bool {
        let value = draft.negativeTrigger.trimmingCharacters(in: .whitespacesAndNewlines)
        return !value.isEmpty && value.count <= WorkspaceLibrary.maximumNegativeTriggerLength
    }
}

private struct StepHeading: View {
    let title: String
    let message: String
    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title).font(.title3.weight(.semibold))
            Text(message).font(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

private struct CharacterCount: View {
    let current: Int
    let maximum: Int

    var body: some View {
        Text("\(current.formatted()) of \(maximum.formatted()) characters")
            .font(.caption2.monospacedDigit())
            .foregroundStyle(current > maximum ? Color.red : Color.secondary)
    }
}

private struct FormField<Content: View>: View {
    let title: String
    let help: String?
    @ViewBuilder let content: Content

    init(title: String, help: String? = nil, @ViewBuilder content: () -> Content) {
        self.title = title
        self.help = help
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack {
                Text(title).font(.callout.weight(.medium))
                if let help { Text(help).font(.caption).foregroundStyle(.secondary) }
            }
            content
        }
    }
}

private struct FileToggleLabel: View {
    let symbol: String
    let title: String
    let detail: String
    var body: some View {
        HStack(spacing: 10) {
            SymbolTile(symbol: symbol, size: 32)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.callout.weight(.medium))
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

private struct ReviewFact: View {
    let title: String
    let detail: String

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "checkmark")
                .foregroundStyle(.secondary)
                .frame(width: 16)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.callout.weight(.medium))
                Text(detail).font(.caption2).foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(10)
    }
}

private struct ReviewRow: View {
    let label: String
    let value: String
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.callout.weight(.medium)).lineLimit(2)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct AutomationToggle: View {
    let title: String
    let detail: String
    @Binding var isOn: Bool
    var body: some View {
        Toggle(isOn: $isOn) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.callout.weight(.medium))
                Text(detail).font(.caption2).foregroundStyle(.secondary)
            }
        }
        .accessibilityLabel(title)
        .accessibilityHint(detail)
        .padding(10)
    }
}
