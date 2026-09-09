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
                Text("Attach a folder you author").font(.title3.weight(.semibold))
                Spacer()
                Button("Done") { dismiss() }.buttonStyle(.glass).keyboardShortcut(.cancelAction)
            }.padding(20)
            Divider()
            VStack(alignment: .leading, spacing: 16) {
                Text("Your folder stays where it is and stays the only copy you edit. Agent Tooling records that it exists and where each app should find it. Nothing is copied into your library and nothing is written back into the folder.")
                    .foregroundStyle(.secondary)
                if let message = session.errorMessage {
                    AttentionBanner(title: "That folder could not be used", message: message)
                }
                if let candidate = session.candidate {
                    VStack(alignment: .leading, spacing: 12) {
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
                    .padding(16).standardPanel(cornerRadius: 12)
                    HStack(spacing: 12) {
                        Button("Attach this folder") {
                            Task {
                                await session.attach(displayName: displayName)
                                if session.errorMessage == nil { dismiss() }
                            }
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(session.isBusy || !session.canWrite)
                        Button("Choose a different folder…") { choose() }.disabled(session.isBusy)
                        if !session.canWrite {
                            Text("This workspace is open for reading only.")
                                .font(.callout).foregroundStyle(.secondary)
                        }
                    }
                } else {
                    Button("Choose folder…") { choose() }
                        .buttonStyle(.borderedProminent).disabled(session.isBusy)
                    Text("Pick the folder that holds the skill's own SKILL.md — not a whole plugin.")
                        .font(.callout).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
            .padding(20)
        }
        .frame(width: 620, height: 460)
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
                Text("Export \(itemName)").font(.title3.weight(.semibold))
                Spacer()
                Button("Done") { dismiss() }.buttonStyle(.glass).keyboardShortcut(.cancelAction)
            }.padding(20)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    if let message = session.errorMessage {
                        AttentionBanner(title: "Export needs attention", message: message)
                    }
                    if let path = session.writtenPath {
                        VStack(alignment: .leading, spacing: 6) {
                            Label("Written", systemImage: "checkmark.circle")
                                .font(.system(size: 14, weight: .medium))
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
                .padding(20)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            Divider()
            HStack {
                Text("The exported folder is a copy. Editing it does not change your library.")
                    .font(.callout).foregroundStyle(.secondary)
                Spacer()
                Button("Write to folder…") { choose() }
                    .buttonStyle(.borderedProminent)
                    .disabled(session.isBusy || session.preview == nil)
            }.padding(20)
        }
        .frame(width: 680, height: 560)
        .background(AgentTheme.contentBackground)
        .onDisappear { session.discard() }
    }

    private func contents(_ preview: WorkspacePackageExport) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("What would be written").font(.title3.weight(.semibold))
            LabeledContent("Folder name") { Text(preview.declaredName) }
            LabeledContent("Files") { Text("\(preview.fileCount)") }
            LabeledContent("Size") {
                Text(preview.totalFileBytes.formatted(.byteCount(style: .file)))
            }
            DisclosureGroup("Every file") {
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(preview.relativePaths, id: \.self) { path in
                        Text(path).font(.system(size: 12, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, 6)
            }
        }
        .padding(16).standardPanel(cornerRadius: 12)
    }

    @ViewBuilder private func compatibility(_ preview: WorkspacePackageExport) -> some View {
        if preview.compatibility.isEmpty {
            Text("This Mac has not checked what your apps support yet, so nothing can be said about where this package would work.")
                .foregroundStyle(.secondary)
        } else {
            VStack(alignment: .leading, spacing: 12) {
                Text("What your apps could do with it").font(.title3.weight(.semibold))
                ForEach(preview.compatibility, id: \.surface) { report in
                    VStack(alignment: .leading, spacing: 6) {
                        Label(report.surface.displayName,
                              systemImage: report.isFullySupported ? "checkmark.circle" : "exclamationmark.circle")
                            .font(.system(size: 14, weight: .medium))
                        if report.notes.isEmpty {
                            Text("Nothing in this package is a problem for this app.")
                                .foregroundStyle(.secondary)
                        }
                        ForEach(Array(report.notes.enumerated()), id: \.offset) { _, note in
                            HStack(alignment: .firstTextBaseline, spacing: 8) {
                                Text("•").foregroundStyle(.secondary)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(note.detail).foregroundStyle(.secondary)
                                    if let path = note.relativePath {
                                        Text(path).font(.system(size: 12, design: .monospaced))
                                            .foregroundStyle(.tertiary)
                                    }
                                }
                            }
                        }
                    }
                    .padding(.vertical, 4)
                }
            }
            .padding(16).standardPanel(cornerRadius: 12)
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
