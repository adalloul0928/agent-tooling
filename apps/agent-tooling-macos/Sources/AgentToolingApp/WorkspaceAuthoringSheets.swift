import AgentToolingCore
import AppKit
import SwiftUI

/// Attaching a folder you already author in.
///
/// Two steps on purpose: choose the folder, then see what was read out of it
/// before agreeing. The folder is never written to, in either step.
struct WorkspaceAttachFolderSheet: View {
    let session: WorkspaceAuthoringSession
    @Environment(\.dismiss) private var dismiss
    @State private var displayName = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Attach a folder you author").font(AgentFont.title)
                Spacer()
                Button("Done") { dismiss() }.buttonStyle(.glass).keyboardShortcut(.cancelAction)
            }.padding(Space.xxl)
            Hairline()
            VStack(alignment: .leading, spacing: Space.xl) {
                Text("Your folder stays where it is and stays the only copy you edit. Agent Tooling records that it exists and where each app should find it. Nothing is copied into your library and nothing is written back into the folder.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if let message = session.errorMessage {
                    AttentionBanner(title: "That folder could not be used", message: message)
                }
                if let candidate = session.candidate {
                    VStack(alignment: .leading, spacing: Space.lg) {
                        LabeledContent("Folder") {
                            Text(candidate.directory.path).textSelection(.enabled).lineLimit(2)
                        }
                        LabeledContent("Skill name in the folder") { Text(candidate.declaredName) }
                        LabeledContent("Files") { Text("\(candidate.fileCount)") }
                        LabeledContent("Show it as") {
                            TextField(candidate.displayName, text: $displayName)
                                .textFieldStyle(.roundedBorder).frame(maxWidth: 280)
                        }
                    }
                    .padding(Space.xl).standardPanel()
                    if !session.canWrite {
                        Text("This workspace is open for reading only.")
                            .font(AgentFont.body).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                } else {
                    Text("Pick the folder that holds the skill's own SKILL.md — not a whole plugin.")
                        .font(AgentFont.body).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(Space.xxl)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)

            Hairline()
            // One footer, one place: the primary changes its words with the
            // state, never its position.
            HStack(spacing: Space.lg) {
                if session.candidate != nil {
                    Button("Choose a different folder…") { choose() }.disabled(session.isBusy)
                }
                Spacer()
                if session.candidate == nil {
                    Button("Choose Folder…") { choose() }
                        .primaryActionStyle()
                        .keyboardShortcut(.defaultAction)
                        .disabled(session.isBusy)
                } else {
                    Button("Attach This Folder") {
                        Task {
                            await session.attach(displayName: displayName)
                            if session.errorMessage == nil { dismiss() }
                        }
                    }
                    .primaryActionStyle()
                    .keyboardShortcut(.defaultAction)
                    .disabled(session.isBusy || !session.canWrite)
                }
            }
            .padding(.horizontal, Space.xxl)
            .padding(.vertical, Space.xl)
        }
        .sheetSize(SheetSize.medium)
        .background(AgentTheme.contentBackground)
        .onDisappear { session.discard() }
    }

    private func choose() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Use Folder"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        displayName = ""
        Task { await session.inspect(url.standardizedFileURL) }
    }
}

/// Writing one item out as a plain folder, with what each app on this Mac could
/// actually do with it.
struct WorkspacePackageExportSheet: View {
    let session: WorkspacePackageExportSession
    let itemName: String
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Export \(itemName)").font(AgentFont.title)
                Spacer()
                Button("Done") { dismiss() }.buttonStyle(.glass).keyboardShortcut(.cancelAction)
            }.padding(Space.xxl)
            Hairline()
            ScrollView {
                VStack(alignment: .leading, spacing: Space.xxl) {
                    if let message = session.errorMessage {
                        AttentionBanner(title: "Export needs attention", message: message)
                    }
                    if let path = session.writtenPath {
                        VStack(alignment: .leading, spacing: Space.sm) {
                            Label("Written", systemImage: "checkmark.circle")
                                .font(AgentFont.bodyMedium)
                            Text(path).foregroundStyle(.secondary).textSelection(.enabled).lineLimit(3)
                        }
                    }
                    if let preview = session.preview {
                        contents(preview)
                        compatibility(preview)
                    } else if session.isBusy {
                        ProgressView("Reading the approved content…")
                    }
                }
                .padding(Space.xxl)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            Hairline()
            HStack {
                Text("The exported folder is a copy. Editing it does not change your library.")
                    .font(AgentFont.body).foregroundStyle(.secondary)
                Spacer()
                Button("Write to folder…") { choose() }
                    .primaryActionStyle()
                    .disabled(session.isBusy || session.preview == nil)
            }.padding(Space.xxl)
        }
        .sheetSize(SheetSize.large)
        .background(AgentTheme.contentBackground)
        .onDisappear { session.discard() }
    }

    private func contents(_ preview: WorkspacePackageExport) -> some View {
        VStack(alignment: .leading, spacing: Space.lg) {
            Text("What would be written").font(AgentFont.title)
            LabeledContent("Folder name") { Text(preview.declaredName) }
            LabeledContent("Files") { Text("\(preview.fileCount)") }
            LabeledContent("Size") {
                Text(preview.totalFileBytes.formatted(.byteCount(style: .file)))
            }
            DisclosureGroup("Every file") {
                VStack(alignment: .leading, spacing: Space.xxs) {
                    ForEach(preview.relativePaths, id: \.self) { path in
                        Text(path).font(AgentFont.mono)
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, Space.sm)
            }
        }
        .padding(Space.xl).standardPanel()
    }

    @ViewBuilder private func compatibility(_ preview: WorkspacePackageExport) -> some View {
        if preview.compatibility.isEmpty {
            Text("This Mac has not checked what your apps support yet, so nothing can be said about where this package would work.")
                .foregroundStyle(.secondary)
        } else {
            VStack(alignment: .leading, spacing: Space.lg) {
                Text("What your apps could do with it").font(AgentFont.title)
                ForEach(preview.compatibility, id: \.surface) { report in
                    VStack(alignment: .leading, spacing: Space.sm) {
                        Label(report.surface.displayName,
                              systemImage: report.isFullySupported ? "checkmark.circle" : "exclamationmark.circle")
                            .font(AgentFont.bodyMedium)
                        if report.notes.isEmpty {
                            Text("Nothing in this package is a problem for this app.")
                                .foregroundStyle(.secondary)
                        }
                        ForEach(Array(report.notes.enumerated()), id: \.offset) { _, note in
                            HStack(alignment: .firstTextBaseline, spacing: Space.md) {
                                Text("•").foregroundStyle(.secondary)
                                VStack(alignment: .leading, spacing: Space.xxs) {
                                    Text(note.detail).foregroundStyle(.secondary)
                                    if let path = note.relativePath {
                                        Text(path).font(AgentFont.mono)
                                            .foregroundStyle(.tertiary)
                                    }
                                }
                            }
                        }
                    }
                    .padding(.vertical, Space.xs)
                }
            }
            .padding(Space.xl).standardPanel()
        }
    }

    private func choose() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.prompt = "Export Here"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task { await session.write(to: url.standardizedFileURL) }
    }
}
