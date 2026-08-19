import AgentToolingCore
import AppKit
import SwiftUI

struct SkillEditorSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(AppModel.self) private var model
    let mode: SkillEditorMode
    let existingSkill: Skill?
    let onSave: (SkillDraft) -> Bool

    @State private var draft: SkillDraft
    @State private var step = 0

    private let steps = ["Purpose", "Triggers", "Placement", "Files", "Review"]

    init(mode: SkillEditorMode, existingSkill: Skill?, onSave: @escaping (SkillDraft) -> Bool) {
        self.mode = mode
        self.existingSkill = existingSkill
        self.onSave = onSave
        var initial = SkillDraft()
        if let existingSkill {
            initial.name = existingSkill.name
            initial.purpose = existingSkill.summary
            initial.triggers = existingSkill.triggers + Array(repeating: "", count: max(0, 3 - existingSkill.triggers.count))
            initial.negativeTrigger = existingSkill.negativeTrigger
            initial.includeScript = existingSkill.files.contains { $0.hasPrefix("scripts/") }
            initial.includeReference = existingSkill.files.contains { $0.hasPrefix("references/") }
            initial.selectedTargets = Set(existingSkill.clients.map(\.client))
            initial.scope = ToolingScope.allCases.first(where: { $0.displayName == existingSkill.scope }) ?? .user
            initial.projectRoot = existingSkill.projectRoot ?? ""
            initial.syncClients = false
            initial.runCanary = false
        }
        _draft = State(initialValue: initial)
    }

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
        .onChange(of: draft.syncClients) { _, enabled in
            if !enabled { draft.runCanary = false }
        }
    }

    private var header: some View {
        HStack(spacing: 13) {
            VStack(alignment: .leading, spacing: 2) {
                Text(mode == .new ? "New skill" : "Edit skill")
                    .font(.title2.weight(.semibold))
                Text("Create once in the managed local library, then review each target installation.")
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
                        index == step ? AgentTheme.controlBackground : .clear, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
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
        VStack(alignment: .leading, spacing: 18) {
            switch step {
            case 0: purposeStep
            case 1: triggersStep
            case 2: placementStep
            case 3: filesStep
            default: reviewStep
            }
            Spacer()
        }
        .padding(26)
    }

    private var purposeStep: some View {
        Group {
            StepHeading(
                title: "What should this skill do?", message: "Keep it to one reusable capability. A narrow skill triggers more reliably.")
            FormField(title: "Skill name", help: "Lowercase words separated by hyphens") {
                TextField("release-readiness", text: $draft.name)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityLabel("Skill name")
                    .disabled(mode == .edit)
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
                        CharacterCount(current: draft.negativeTrigger.count, maximum: WorkspaceLibrary.maximumNegativeTriggerLength)
                    }
                }
            }
        }
    }

    private var placementStep: some View {
        Group {
            StepHeading(
                title: "Where should it live?",
                message: "The portable source is stored in Agent Tooling's local library. Git backup is optional and comes later.")
            LabeledValueRow("Managed package") {
                Text("local-\(normalizedName)")
                    .font(.system(.caption, design: .monospaced))
            }
            .standardPanel(cornerRadius: 13)

            FormField(title: "Install targets", help: "Each target gets a separate reviewable installation") {
                VStack(spacing: 0) {
                    ForEach(Array(ClientKind.allCases.enumerated()), id: \.element) { index, client in
                        TargetSelectionRow(client: client, selected: targetBinding(client))
                        if index < ClientKind.allCases.count - 1 { Divider() }
                    }
                }
                .standardPanel(cornerRadius: 13)
            }
            Picker("Scope", selection: $draft.scope) {
                ForEach([ToolingScope.user, .project]) { scope in
                    Text(scope.displayName).tag(scope)
                }
            }
            .pickerStyle(.segmented)
            .accessibilityLabel("Installation scope")

            if draft.scope == .project {
                FormField(title: "Project folder", help: "Installs only inside this project's native skill folders") {
                    HStack(spacing: 8) {
                        TextField("Choose a project folder", text: $draft.projectRoot)
                            .textFieldStyle(.roundedBorder)
                            .accessibilityLabel("Project folder")
                        Button("Choose…") { chooseProjectFolder() }
                            .buttonStyle(.bordered)
                    }
                }
                if !draft.projectRoot.isEmpty, !isProjectRootValid {
                    Label("Choose an existing folder.", systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }
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
                    FileToggleLabel(symbol: "books.vertical", title: "Reference file", detail: "Long-form guidance loaded only when needed")
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
                title: "Ready to create", message: "Review the definition and choose how far the automatic workflow should continue.")
            HStack(alignment: .top, spacing: 14) {
                VStack(spacing: 0) {
                    ReviewRow(label: "Name", value: normalizedName)
                    Divider()
                    ReviewRow(label: "Purpose", value: draft.purpose)
                    Divider()
                    ReviewRow(label: "Placement", value: "Local library/packages/local-\(normalizedName)/skills/\(normalizedName)")
                    Divider()
                    ReviewRow(label: "Install scope", value: draft.scope == .project ? draft.projectRoot : "This Mac")
                    Divider()
                    ReviewRow(
                        label: "Verification", value: draft.runCanary ? "Fresh client session after install" : "Definition checks only")
                }
                .standardPanel(cornerRadius: 13)

                VStack(spacing: 0) {
                    ReviewFact(title: "Definition validation", detail: "Always checks the canonical SKILL.md before saving")
                    Divider()
                    AutomationToggle(
                        title: "Prepare install plan", detail: "Show client-specific writes before changing anything",
                        isOn: $draft.syncClients
                    )
                    .disabled(draft.selectedTargets.isEmpty)
                    Divider()
                    AutomationToggle(
                        title: "Require fresh-session check", detail: "Confirm discovery after target installation", isOn: $draft.runCanary
                    )
                    .disabled(!draft.syncClients)
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
            if step > 0 {
                Button("Back") { step -= 1 }
                    .buttonStyle(.bordered)
            }
            if step < steps.count - 1 {
                Button("Continue") { step += 1 }
                    .buttonStyle(.borderedProminent)
                    .disabled(!canContinue)
            } else {
                Button(saveButtonTitle) {
                    if onSave(draft) { dismiss() }
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(!isDraftValid)
            }
        }
        .padding(.horizontal, 22)
        .frame(height: 78)
    }

    private var normalizedName: String {
        (try? WorkspaceLibrary.normalizedIdentifier(draft.name))
            ?? draft.name.lowercased().trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: " ", with: "-")
    }

    private var isNameValid: Bool {
        (try? WorkspaceLibrary.normalizedIdentifier(draft.name)) != nil
    }

    private var isProjectRootValid: Bool {
        guard draft.scope == .project else { return true }
        let path = draft.projectRoot.trimmingCharacters(in: .whitespacesAndNewlines)
        var isDirectory: ObjCBool = false
        return !path.isEmpty
            && path.count <= WorkspaceLibrary.maximumProjectPathLength
            && path.hasPrefix("/")
            && FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory)
            && isDirectory.boolValue
    }

    private var nameCollision: Bool {
        guard mode == .new else { return false }
        return model.skills.contains { $0.name.caseInsensitiveCompare(normalizedName) == .orderedSame }
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
        if !isProjectRootValid { return 2 }
        return 4
    }

    private var canContinue: Bool {
        switch step {
        case 0: isNameValid && isPurposeValid && !nameCollision
        case 1: areTriggersValid && isNegativeTriggerValid
        case 2: isProjectRootValid
        default: true
        }
    }

    private var isDraftValid: Bool {
        isNameValid
            && isPurposeValid
            && areTriggersValid
            && isNegativeTriggerValid
            && (!draft.syncClients || !draft.selectedTargets.isEmpty)
            && isProjectRootValid
            && !nameCollision
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

    private var saveButtonTitle: String {
        switch (mode, draft.syncClients) {
        case (.new, true): "Create and Review Install"
        case (.new, false): "Create Skill"
        case (.edit, true): "Save and Review Install"
        case (.edit, false): "Save Changes"
        }
    }

    private func targetBinding(_ client: ClientKind) -> Binding<Bool> {
        Binding(
            get: { draft.selectedTargets.contains(client) },
            set: { isSelected in
                if isSelected { draft.selectedTargets.insert(client) } else { draft.selectedTargets.remove(client) }
            }
        )
    }

    private func chooseProjectFolder() {
        let panel = NSOpenPanel()
        panel.title = "Choose a project folder"
        panel.prompt = "Choose"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = false
        if !draft.projectRoot.isEmpty {
            panel.directoryURL = URL(fileURLWithPath: draft.projectRoot)
        }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        draft.projectRoot = url.standardizedFileURL.path(percentEncoded: false)
    }
}

private struct StepHeading: View {
    let title: String
    let message: String
    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title).font(.title3.weight(.semibold))
            Text(message).font(.callout).foregroundStyle(.secondary)
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

private struct TargetSelectionRow: View {
    @Environment(AppModel.self) private var model
    let client: ClientKind
    @Binding var selected: Bool

    var body: some View {
        Toggle(isOn: $selected) {
            HStack(spacing: 10) {
                ClientBrandIcon(client: client, size: 22)
                    .frame(width: 30, height: 30)
                VStack(alignment: .leading, spacing: 2) {
                    Text(client.rawValue).font(.callout.weight(.medium))
                    Text(detail).font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .accessibilityLabel("Install for \(client.rawValue)")
        .padding(12)
    }

    private var detail: String {
        guard isInstalled else { return "CLI not found; install the skill files now or after installing the app" }
        switch client {
        case .claude: return "Install into Claude Code's native skill folder"
        case .codex: return "Install into Codex's native skill folder"
        case .gemini: return "Install into Gemini CLI's native skill folder"
        }
    }

    private var isInstalled: Bool {
        guard !model.targetObservations.isEmpty else { return true }
        return model.targetObservations.contains { observation in
            guard observation.isCommandAvailable else { return false }
            switch (client, observation.surface) {
            case (.claude, .claudeCode), (.claude, .claudeDesktop), (.claude, .claudeCloud),
                (.codex, .codexCLI), (.codex, .codexDesktop), (.codex, .codexCloud),
                (.gemini, .geminiCLI), (.gemini, .geminiIDE), (.gemini, .geminiCloud):
                return true
            default: return false
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
