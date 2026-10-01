import AgentToolingCore
import SwiftUI

/// A lossless editor for the skills this library maintains.
///
/// The stored version stays visible beside the editable one, so a change is
/// reviewable before it is saved, and every script, reference and asset in the
/// package is carried through rather than projected into lossy toggles.
struct SkillSourceEditorSheet: View {
    @Environment(\.dismiss) private var dismiss

    let skill: SkillEntry
    let session: SkillContentSession

    @State private var original = ""
    @State private var edited = ""

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top, spacing: Space.xl) {
                VStack(alignment: .leading, spacing: Space.xs) {
                    Text("Edit \(skill.displayName) source")
                        .font(AgentFont.titleLarge)
                    Text("Edit the complete SKILL.md. Every script, reference, asset, and package file is preserved.")
                        .font(AgentFont.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if !isLoading {
                    Text(changeSummary)
                        .font(AgentFont.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
            .padding(Space.xxxl)

            Hairline()

            if isLoading {
                ProgressView("Opening the stored source…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if original.isEmpty {
                EmptyStateView(
                    symbol: "doc.text.magnifyingglass", title: "No stored source",
                    message: session.errorMessage
                        ?? "This library does not hold this skill's files, so there is nothing here to edit.")
            } else {
                HSplitView {
                    sourcePane(title: "Stored", text: original, editable: false)
                        .frame(minWidth: 360)
                    sourcePane(title: "Edited", text: edited, editable: true)
                        .frame(minWidth: 420)
                }
            }

            Hairline()
            HStack {
                Label("The saved source is checked before it replaces the stored copy.", systemImage: "checkmark.shield")
                    .font(AgentFont.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                if session.isBusy { ProgressView().controlSize(.small) }
                Button("Cancel") { dismiss() }
                    .secondaryActionStyle()
                    .keyboardShortcut(.cancelAction)
                Button("Save Source") {
                    Task {
                        if await session.saveSource(edited, for: skill) { dismiss() }
                    }
                }
                .primaryActionStyle()
                .keyboardShortcut(.defaultAction)
                .disabled(!canSave)
            }
            .padding(.horizontal, Space.xxxl)
            .frame(height: Size.sheetBarHeight)
        }
        .sheetSize(SheetSize.editor)
        .background(AgentTheme.contentBackground)
        .task(id: skill.id) {
            await session.load(skill)
            let stored = session.storedSource(for: skill) ?? ""
            original = stored
            edited = stored
        }
    }

    private var isLoading: Bool { session.isLoading }

    private var canSave: Bool {
        !isLoading && !session.isBusy && session.canWrite && skill.ownership == .centralPersonal
            && !original.isEmpty && edited != original && !edited.isEmpty && edited.utf8.count <= 1_048_576
    }

    @ViewBuilder
    private func sourcePane(title: String, text: String, editable: Bool) -> some View {
        VStack(alignment: .leading, spacing: Space.md) {
            HStack {
                Text(title).font(AgentFont.heading)
                Spacer()
                Text("\(text.split(separator: "\n", omittingEmptySubsequences: false).count) lines")
                    .font(AgentFont.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            if editable {
                TextEditor(text: $edited)
                    .font(AgentFont.monoBody)
                    .scrollContentBackground(.hidden)
                    .padding(Space.md)
                    .background(AgentTheme.controlBackground, in: RoundedRectangle.control)
                    .accessibilityLabel("Edited complete SKILL.md source")
            } else {
                ScrollView([.vertical, .horizontal]) {
                    Text(text)
                        .font(AgentFont.monoBody)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                        .padding(Space.lg)
                }
                .background(AgentTheme.fillSubtle, in: RoundedRectangle.control)
                .accessibilityLabel("Stored complete SKILL.md source")
            }
        }
        .padding(Space.xl)
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
