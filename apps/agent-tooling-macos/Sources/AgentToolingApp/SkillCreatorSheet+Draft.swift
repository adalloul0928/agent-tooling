import AgentToolingCore
import AppKit
import SwiftUI

/// Which draft file is open and which have been read.
///
/// The sheet owns this; lifting it out keeps the selection rules — which file
/// opens first, whether every file has been read, how much is left — in one
/// place that a test can drive without a view. Saving is gated on every file
/// having been opened, so "all reviewed" is a rule, not a convenience.
struct SkillCreatorReviewSelection: Equatable {
    var selectedPath = ""
    var reviewedPaths: Set<String> = []

    /// A fresh package is a fresh read: nothing selected, nothing reviewed.
    mutating func reset() {
        selectedPath = ""
        reviewedPaths = []
    }

    /// Opens the generated definition and counts it as read, leaving every
    /// other file to be opened before the draft can be saved. Does nothing once
    /// a file is already selected, so re-rendering does not reset the reading.
    mutating func selectInitial(from files: [SkillDraftFile]) {
        guard !files.isEmpty, selectedPath.isEmpty else { return }
        let initialPath =
            files.first { $0.relativePath.hasSuffix("/SKILL.md") }?.relativePath
            ?? files[0].relativePath
        selectedPath = initialPath
        reviewedPaths = [initialPath]
    }

    /// Marks a file open and read.
    mutating func select(_ relativePath: String) {
        selectedPath = relativePath
        reviewedPaths.insert(relativePath)
    }

    func selectedFile(in result: SkillDraftResult) -> SkillDraftFile? {
        result.files.first { $0.relativePath == selectedPath }
    }

    /// The content for the open file. The generated definition shows the
    /// skill's own markdown; any other file shows its captured text.
    func selectedContent(in result: SkillDraftResult) -> String? {
        guard let file = selectedFile(in: result) else { return nil }
        if file.relativePath.hasSuffix("/SKILL.md") {
            return result.skillMarkdown
        }
        return file.textContent
    }

    func allReviewed(in result: SkillDraftResult) -> Bool {
        result.files.allSatisfy { reviewedPaths.contains($0.relativePath) }
    }

    func progress(for result: SkillDraftResult) -> String {
        let remaining = result.files.filter { !reviewedPaths.contains($0.relativePath) }.count
        return remaining == 0
            ? "Every generated file has been opened for review."
            : "Open \(remaining) more generated \(CountNoun("file").word(for: remaining)) before saving."
    }
}

/// The draft folder's files on the right of the creator: the generated package
/// listed for review once there is one, or what is still missing before there
/// is.
struct SkillCreatorDraftPane: View {
    let result: SkillDraftResult?
    let draftIssue: String?
    let hasConversation: Bool
    let client: ClientKind
    @Binding var selection: SkillCreatorReviewSelection

    var body: some View {
        if let result {
            review(result)
        } else {
            VStack(spacing: 0) {
                HStack {
                    Text("Draft")
                        .font(AgentFont.heading)
                    Spacer()
                }
                .padding(.horizontal, Space.xxl)
                .frame(height: Size.rowHeightTall)
                Hairline()
                if let draftIssue {
                    EmptyStateView(
                        symbol: "doc.badge.ellipsis",
                        title: "The draft is not ready to review",
                        message: "\(draftIssue) Ask \(client.rawValue) to fix it, or start over.")
                } else if hasConversation {
                    EmptyStateView(
                        symbol: "doc.text",
                        title: "Nothing written yet",
                        message: "\(client.rawValue) has not written the skill yet. Answer its questions and the files will appear here.")
                } else {
                    EmptyStateView(
                        symbol: "doc.text",
                        title: "The draft appears here",
                        message:
                            "Every file \(client.rawValue) writes into the draft folder is listed here after each turn, so you can read exactly what would be saved."
                    )
                }
            }
        }
    }

    private func review(_ result: SkillDraftResult) -> some View {
        HSplitView {
            VStack(alignment: .leading, spacing: 0) {
                VStack(alignment: .leading, spacing: Space.sm) {
                    Text(result.skillName)
                        .font(AgentFont.title)
                    Text(result.description)
                        .font(AgentFont.body)
                        .foregroundStyle(.secondary)
                        .wrapsLines()
                }
                .padding(.horizontal, Space.xxl)
                .padding(.vertical, Space.xl)

                Hairline()

                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(result.files, id: \.relativePath) { file in
                            Button {
                                selection.select(file.relativePath)
                            } label: {
                                HStack(spacing: Space.lg) {
                                    Image(systemName: file.isExecutable ? "terminal" : "doc")
                                        .foregroundStyle(file.isExecutable ? Color.orange : Color.secondary)
                                        .frame(width: Size.glyphSlot)
                                    VStack(alignment: .leading, spacing: Space.xxs) {
                                        Text(file.relativePath)
                                            .font(AgentFont.bodyMedium)
                                            .lineLimit(1)
                                            .truncationMode(.middle)
                                        Text(ByteCountFormatter.string(fromByteCount: Int64(file.byteCount), countStyle: .file))
                                            .font(AgentFont.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    if file.isExecutable {
                                        Text("Executable")
                                            .font(AgentFont.caption)
                                            .foregroundStyle(.orange)
                                    }
                                    if selection.reviewedPaths.contains(file.relativePath) {
                                        Image(systemName: "checkmark")
                                            .font(AgentFont.caption)
                                            .foregroundStyle(.secondary)
                                            .accessibilityLabel("Reviewed")
                                    }
                                }
                                .padding(.horizontal, Space.xl)
                                .frame(minHeight: Size.rowHeight)
                                .contentShape(Rectangle())
                                .background(
                                    selection.selectedPath == file.relativePath
                                        ? AgentTheme.controlBackground
                                        : Color.clear
                                )
                            }
                            .buttonStyle(.plain)
                            Hairline()
                        }
                    }
                }
            }
            .frame(
                minWidth: Size.creatorFileListMin, idealWidth: Size.creatorFileListIdeal,
                maxWidth: Size.creatorFileListMax, maxHeight: .infinity
            )
            .background(AgentTheme.controlBackground.opacity(Opacity.paneShade))

            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    Text(selection.selectedFile(in: result)?.relativePath ?? "Select a file")
                        .font(AgentFont.heading)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer()
                    Button {
                        guard let file = selection.selectedFile(in: result) else { return }
                        NSWorkspace.shared.activateFileViewerSelecting([
                            result.packageURL.appending(path: file.relativePath, directoryHint: .notDirectory)
                        ])
                    } label: {
                        Label("Reveal", systemImage: "folder")
                    }
                    .labelStyle(.iconOnly)
                    .secondaryActionStyle()
                    .controlSize(.small)
                    .help("Show in Finder")
                    .disabled(selection.selectedFile(in: result) == nil)

                    Button {
                        guard let content = selection.selectedContent(in: result) else { return }
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(content, forType: .string)
                    } label: {
                        Label("Copy", systemImage: "doc.on.doc")
                    }
                    .labelStyle(.iconOnly)
                    .secondaryActionStyle()
                    .controlSize(.small)
                    .help("Copy")
                    .disabled(selection.selectedContent(in: result) == nil)
                }
                .padding(.horizontal, Space.xxl)
                .frame(height: Size.rowHeightTall)

                Hairline()

                if let content = selection.selectedContent(in: result) {
                    ScrollView([.horizontal, .vertical]) {
                        Text(content)
                            .font(AgentFont.monoBody)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .topLeading)
                            .padding(Space.xxl)
                    }
                    .background(AgentTheme.contentBackground)
                } else {
                    EmptyStateView(
                        symbol: "doc.questionmark",
                        title: "Preview unavailable",
                        message: "Reveal this file in Finder to inspect its contents."
                    )
                }
            }
            .frame(minWidth: Size.creatorPreviewMin, maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}
