import AgentToolingCore
import SwiftUI

/// A lossless editor for packages that were not produced by the five-step
/// template form. The original remains visible beside the editable complete
/// source, so changes are reviewable and auxiliary files are never projected
/// into lossy toggles.
struct SkillSourceEditorSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(AppModel.self) private var model

    let existingSkill: Skill
    let onSave: (String) -> Bool

    @State private var original = ""
    @State private var edited = ""
    @State private var isLoading = true

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top, spacing: 14) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Edit \(existingSkill.displayName) source")
                        .font(.title2.weight(.semibold))
                    Text("Edit the complete SKILL.md. Every script, reference, asset, and package file is preserved.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if !isLoading {
                    Text(changeSummary)
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
            .padding(22)

            Divider()

            if isLoading {
                ProgressView("Opening managed source…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                HSplitView {
                    sourcePane(title: "Original", text: original, editable: false)
                        .frame(minWidth: 360)
                    sourcePane(title: "Edited", text: edited, editable: true)
                        .frame(minWidth: 420)
                }
            }

            Divider()
            HStack {
                Label("The saved source is validated before it replaces the managed copy.", systemImage: "checkmark.shield")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Cancel") { dismiss() }
                    .buttonStyle(.bordered)
                    .keyboardShortcut(.cancelAction)
                Button("Save Source") {
                    if onSave(edited) { dismiss() }
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(isLoading || edited == original || edited.isEmpty || edited.utf8.count > 1_048_576)
            }
            .padding(.horizontal, 22)
            .frame(height: 72)
        }
        .frame(width: 980, height: 720)
        .background(AgentTheme.contentBackground)
        .task(id: existingSkill.id) {
            guard let source = model.skillSource(id: existingSkill.id) else {
                dismiss()
                return
            }
            original = source
            edited = source
            isLoading = false
        }
    }

    @ViewBuilder
    private func sourcePane(title: String, text: String, editable: Bool) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(title).font(.subheadline.weight(.semibold))
                Spacer()
                Text("\(text.split(separator: "\n", omittingEmptySubsequences: false).count) lines")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            if editable {
                TextEditor(text: $edited)
                    .font(.system(.body, design: .monospaced))
                    .scrollContentBackground(.hidden)
                    .padding(8)
                    .background(AgentTheme.controlBackground, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .accessibilityLabel("Edited complete SKILL.md source")
            } else {
                ScrollView([.vertical, .horizontal]) {
                    Text(text)
                        .font(.system(.body, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                        .padding(10)
                }
                .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .accessibilityLabel("Original complete SKILL.md source")
            }
        }
        .padding(16)
    }

    private var changeSummary: String {
        let oldLines = original.split(separator: "\n", omittingEmptySubsequences: false)
        let newLines = edited.split(separator: "\n", omittingEmptySubsequences: false)
        let shared = zip(oldLines, newLines).count { $0 != $1 }
        let delta = newLines.count - oldLines.count
        let lineDelta = delta == 0 ? "same line count" : delta > 0 ? "+\(delta) lines" : "\(delta) lines"
        return "\(shared) changed · \(lineDelta)"
    }
}
