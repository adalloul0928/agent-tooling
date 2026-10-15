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
                Hairline(.vertical)
                stepContent
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }

            Hairline()
            footer
        }
        .sheetSize(SheetSize.editor)
        .background(AgentTheme.contentBackground)
        .onAppear {
            // The form's own defaults describe the old install step, which this
            // screen no longer performs.
            draft.runCanary = false
        }
    }

    private var header: some View {
        HStack(spacing: Space.lg) {
            VStack(alignment: .leading, spacing: Space.xxs) {
                Text("New skill")
                    .font(AgentFont.titleLarge)
                Text("Write the definition. Choosing where to use it comes after, and installing is reviewed separately.")
                    .font(AgentFont.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Text("Step \(step + 1) of \(steps.count)")
                .font(AgentFont.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, Space.xxxl)
        .frame(height: Size.sheetBarHeight)
    }

    private var stepList: some View {
        VStack(alignment: .leading, spacing: Space.xs) {
            ForEach(Array(steps.enumerated()), id: \.offset) { index, title in
                Button {
                    if index <= highestReachableStep { step = index }
                } label: {
                    HStack(spacing: Space.lg) {
                        Text("\(index + 1)")
                            .font(AgentFont.caption.monospacedDigit())
                            .foregroundStyle(index == step ? Color.primary : Color.secondary)
                            .frame(width: 20, alignment: .trailing)
                        Text(title).font(index == step ? AgentFont.bodySemibold : AgentFont.body)
                        Spacer()
                    }
                    .padding(.horizontal, Space.lg)
                    .frame(height: Size.rowHeight)
                    .background(
                        index == step ? AgentTheme.controlBackground : .clear,
                        in: RoundedRectangle.control)
                }
                .buttonStyle(.plain)
                .disabled(index > highestReachableStep)
            }
            Spacer()
        }
        .padding(Space.xl)
        .paneMaterial()
    }

    @ViewBuilder
    private var stepContent: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Space.xxl) {
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
            .padding(Space.xxxl)
        }
    }

    private var purposeStep: some View {
        Group {
            StepHeading(
                title: "What should this skill do?",
                message: "Keep it to one reusable capability. A narrow skill triggers more reliably.")
            FormField(title: "Skill name", help: "Lowercase words separated by hyphens") {
                TextField("my-skill-name", text: $draft.name)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityLabel("Skill name")
            }
            FormField(title: "Purpose", help: "One sentence from the user’s point of view") {
                VStack(alignment: .trailing, spacing: Space.xs) {
                    TextEditor(text: $draft.purpose)
                        .font(AgentFont.body)
                        .scrollContentBackground(.hidden)
                        .padding(Space.md)
                        .frame(height: 120)
                        .background(.quaternary.opacity(0.28), in: RoundedRectangle.control)
                        .accessibilityLabel("Purpose")
                    if draft.purpose.count > WorkspaceLibrary.maximumPurposeLength * 3 / 4 {
                        CharacterCount(current: draft.purpose.count, maximum: WorkspaceLibrary.maximumPurposeLength)
                    }
                }
            }
            if nameCollision {
                Label("A skill with this name already exists. Choose a distinctive name.", systemImage: "exclamationmark.triangle.fill")
                    .font(AgentFont.caption)
                    .foregroundStyle(.red)
            } else if !draft.name.isEmpty, !isNameValid {
                Label(nameValidationMessage, systemImage: "exclamationmark.triangle.fill")
                    .font(AgentFont.caption)
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
                    VStack(alignment: .trailing, spacing: Space.xs) {
                        TextField(triggerPlaceholder(index), text: $draft.triggers[index])
                            .textFieldStyle(.roundedBorder)
                            .accessibilityLabel("Trigger \(index + 1)")
                        if draft.triggers[index].count > WorkspaceLibrary.maximumTriggerLength {
                            CharacterCount(current: draft.triggers[index].count, maximum: WorkspaceLibrary.maximumTriggerLength)
                        }
                    }
                }
            }
            FormField(title: "Should not trigger for", help: "A nearby request that belongs elsewhere") {
                VStack(alignment: .trailing, spacing: Space.xs) {
                    TextField("e.g. Fix the failing test", text: $draft.negativeTrigger)
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
                Hairline()
                LabeledValueRow("Called") {
                    Text(normalizedName.isEmpty ? "—" : normalizedName)
                        .font(AgentFont.mono)
                }
                Hairline()
                LabeledValueRow("Shown as") { Text(SkillTemplate.displayName(for: normalizedName)) }
            }
            .standardPanel()

            AutomationToggle(
                title: "Choose where to use it next",
                detail: "Opens the assignment review as soon as the skill is created",
                isOn: $draft.syncClients
            )
            .standardPanel()

            Text(
                "Saving changes the skill in your library. Where it is installed is chosen with Install, on the skill, which writes it."
            )
            .font(AgentFont.caption)
            .foregroundStyle(.secondary)
            .wrapsLines()
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
                .padding(Space.xl)
                Hairline()
                Toggle(isOn: $draft.includeScript) {
                    FileToggleLabel(
                        symbol: "terminal",
                        title: "Shell script template",
                        detail: "Creates helper.sh in a disabled state; implement it before use"
                    )
                }
                .accessibilityLabel("Include shell script template")
                .padding(Space.xl)
                Hairline()
                Toggle(isOn: $draft.includeReference) {
                    FileToggleLabel(
                        symbol: "books.vertical", title: "Reference file",
                        detail: "Long-form guidance loaded only when needed")
                }
                .accessibilityLabel("Include reference file")
                .padding(Space.xl)
            }
            .standardPanel()
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
            HStack(alignment: .top, spacing: Space.xl) {
                VStack(spacing: 0) {
                    ReviewRow(label: "Name", value: normalizedName)
                    Hairline()
                    ReviewRow(label: "Purpose", value: draft.purpose)
                    Hairline()
                    ReviewRow(label: "Files", value: fileSummary)
                    Hairline()
                    ReviewRow(label: "Kept in", value: "Your personal library")
                    Hairline()
                    ReviewRow(
                        label: "Next", value: draft.syncClients ? "Choose where to use it" : "Nothing until you ask")
                }
                .standardPanel()

                VStack(spacing: 0) {
                    ReviewFact(title: "Definition checked", detail: "The SKILL.md is read and validated before it is stored")
                    Hairline()
                    ReviewFact(title: "Nothing is installed", detail: "No app is written to by creating a skill")
                    Hairline()
                    ReviewFact(title: "Nothing is assigned", detail: "Where it is used is saved only when you review it")
                }
                .standardPanel()
            }
        }
    }

    private var footer: some View {
        HStack {
            Button("Cancel") { dismiss() }
                .secondaryActionStyle()
                .keyboardShortcut(.cancelAction)
            Spacer()
            if isBusy { ProgressView().controlSize(.small) }
            if step > 0 {
                Button("Back") { step -= 1 }
                    .secondaryActionStyle()
            }
            if step < steps.count - 1 {
                Button("Continue") { step += 1 }
                    .primaryActionStyle()
                    .disabled(!canContinue)
            } else {
                Button("Create Skill") { onCreate(draft, draft.syncClients) }
                    .primaryActionStyle()
                    .keyboardShortcut(.defaultAction)
                    .disabled(!isDraftValid || isBusy || !canWrite)
            }
        }
        .padding(.horizontal, Space.xxxl)
        .frame(height: Size.sheetBarHeight)
    }

    /// Example phrasing for each trigger field, worded so an empty field reads
    /// as guidance rather than as content someone left behind. The list gives a
    /// distinct example per row and repeats its last one for any extra fields.
    private func triggerPlaceholder(_ index: Int) -> String {
        let examples = [
            "e.g. Summarise this pull request",
            "e.g. Write release notes for this diff",
            "e.g. Turn review comments into a checklist",
        ]
        return examples[min(index, examples.count - 1)]
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
        VStack(alignment: .leading, spacing: Space.xs) {
            Text(title).font(AgentFont.title)
            Text(message).font(AgentFont.body).foregroundStyle(.secondary)
                .wrapsLines()
        }
    }
}

private struct CharacterCount: View {
    let current: Int
    let maximum: Int

    var body: some View {
        Text("\(current.formatted()) of \(maximum.formatted()) characters")
            .font(AgentFont.micro.monospacedDigit())
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
        VStack(alignment: .leading, spacing: Space.sm) {
            HStack {
                Text(title).font(AgentFont.bodyMedium)
                if let help { Text(help).font(AgentFont.caption).foregroundStyle(.secondary) }
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
        HStack(spacing: Space.lg) {
            SymbolTile(symbol: symbol, size: Size.discLarge)
            VStack(alignment: .leading, spacing: Space.xxs) {
                Text(title).font(AgentFont.bodyMedium)
                Text(detail).font(AgentFont.caption).foregroundStyle(.secondary)
            }
        }
    }
}

private struct ReviewFact: View {
    let title: String
    let detail: String

    var body: some View {
        HStack(alignment: .top, spacing: Space.lg) {
            Image(systemName: "checkmark")
                .foregroundStyle(.secondary)
                .frame(width: Size.glyphSlot)
            VStack(alignment: .leading, spacing: Space.xxs) {
                Text(title).font(AgentFont.bodyMedium)
                Text(detail).font(AgentFont.micro).foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(Space.lg)
    }
}

private struct ReviewRow: View {
    let label: String
    let value: String
    var body: some View {
        VStack(alignment: .leading, spacing: Space.xs) {
            Text(label).font(AgentFont.caption).foregroundStyle(.secondary)
            Text(value).font(AgentFont.bodyMedium).lineLimit(2)
        }
        .padding(Space.lg)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct AutomationToggle: View {
    let title: String
    let detail: String
    @Binding var isOn: Bool
    var body: some View {
        Toggle(isOn: $isOn) {
            VStack(alignment: .leading, spacing: Space.xxs) {
                Text(title).font(AgentFont.bodyMedium)
                Text(detail).font(AgentFont.micro).foregroundStyle(.secondary)
            }
        }
        .accessibilityLabel(title)
        .accessibilityHint(detail)
        .padding(Space.lg)
    }
}
