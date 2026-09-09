import AgentToolingCore
import AppKit
import SwiftUI

/// What each installed app will actually use, with where each value comes from
/// and whether changing it here could take effect.
///
/// Most of this screen only explains. An Edit button appears on the narrow set
/// of settings this build records as writable and can actually make effective —
/// everything else says why it cannot be changed here rather than offering a
/// control that would not work.
struct WorkspaceSettingsView: View {
    let session: WorkspaceSettingsSession
    @State private var refreshID = UUID()

    var body: some View {
        VStack(spacing: 0) {
            PageToolbar(title: "App settings", context: "What each app will use on this Mac") {
                if !session.projects.isEmpty {
                    Picker("Project", selection: Binding(
                        get: { session.selectedProjectID },
                        set: { session.select(project: $0) }
                    )) {
                        Text("No project").tag(ArtifactID?.none)
                        ForEach(session.projects) { project in
                            Text(project.name).tag(ArtifactID?.some(project.id))
                        }
                    }
                    .labelsHidden().fixedSize()
                }
                Button("Refresh", systemImage: "arrow.clockwise") { refreshID = UUID() }
                    .labelStyle(.iconOnly).buttonStyle(.glass).disabled(session.isBusy)
            }
            Divider()
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 24) {
                    Text("These values are read from your apps' own files. Only the few marked with a pencil can be changed here.")
                        .foregroundStyle(.secondary)
                    if session.managedPolicyUnknown {
                        Text("Agent Tooling was not told where an organization policy file would be on this Mac, so it cannot rule one out. If your organization sets one, it may decide a setting shown here as changeable.")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                    if let receipt = session.lastReceipt {
                        VStack(alignment: .leading, spacing: 6) {
                            Label("Changed \(receipt.key)", systemImage: "checkmark.circle")
                                .font(.system(size: 14, weight: .medium))
                            Text("Now \(receipt.effectiveValue.displayText). Your original file is kept beside it as a backup.")
                                .foregroundStyle(.secondary)
                            Text(receipt.backupPath).font(.system(size: 12, design: .monospaced))
                                .foregroundStyle(.tertiary).textSelection(.enabled).lineLimit(2)
                        }
                        .padding(16).standardPanel(cornerRadius: 12)
                    }
                    if let message = session.editMessage {
                        AttentionBanner(title: "That change was not made", message: message)
                    }
                    ForEach(session.surfaces) { surface in
                        surfaceSection(surface)
                    }
                    instructionSection
                }
                .padding(28)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(AgentTheme.contentBackground)
        .frame(minWidth: 720, minHeight: 480)
        .task(id: refreshID) { await session.refresh() }
        .sheet(item: Binding(
            get: { session.pendingEdit },
            set: { if $0 == nil { session.discardEdit() } }
        )) { edit in
            WorkspaceSettingEditSheet(session: session, edit: edit)
        }
    }

    @ViewBuilder
    private func surfaceSection(_ surface: WorkspaceSettingsSession.Surface) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                Text(surface.title).font(.title3.weight(.semibold))
                Spacer()
                if let version = surface.configuration?.installedClientVersion {
                    Text("Version \(version)").font(.callout).foregroundStyle(.secondary)
                } else {
                    Text("Version unknown").font(.callout).foregroundStyle(.secondary)
                }
            }
            if let message = surface.errorMessage {
                AttentionBanner(title: "Settings need attention", message: message)
            } else if let configuration = surface.configuration {
                Text(configuration.summary).font(.callout).foregroundStyle(.secondary)
                if configuration.rows.isEmpty {
                    Text("No settings were found for this app on this Mac.").foregroundStyle(.secondary)
                }
                ForEach(configuration.rows, id: \.key) { row in
                    settingRow(row, in: surface)
                    Divider()
                }
                combined(configuration)
                if !configuration.inactiveLayers.isEmpty {
                    Text("Files this version does not read: \(configuration.inactiveLayers.map(label).joined(separator: ", "))")
                        .font(.callout).foregroundStyle(.secondary)
                }
                if !configuration.unrecognized.isEmpty {
                    DisclosureGroup("\(configuration.unrecognized.count) settings this app version manages itself") {
                        VStack(alignment: .leading, spacing: 4) {
                            ForEach(configuration.unrecognized, id: \.key) { entry in
                                Text("\(entry.key) · \(label(entry.layer))")
                                    .font(.callout).foregroundStyle(.secondary)
                            }
                        }.padding(.top, 8)
                    }
                }
            }
        }
        .padding(18)
        .standardPanel(cornerRadius: 14)
    }

    private func settingRow(
        _ row: EffectiveConfigurationRow, in surface: WorkspaceSettingsSession.Surface
    ) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Text(row.displayName).fontWeight(.medium)
                Spacer(minLength: 16)
                Text(row.value.displayText)
                    .multilineTextAlignment(.trailing).lineLimit(3).textSelection(.enabled)
                if session.isEditable(row, surface: surface.id) {
                    Button("Edit", systemImage: "pencil") { session.beginEdit(row, surface: surface) }
                        .labelStyle(.iconOnly).buttonStyle(.borderless)
                        .disabled(session.isBusy)
                        .accessibilityLabel("Edit \(row.displayName)")
                }
            }
            HStack(spacing: 8) {
                Text("From \(label(row.definedBy))")
                if row.rule == .combineList { Text("Combined from every file") }
                if row.isConstrained { Text("Fixed here; a change lower down would not take effect") }
                if row.requiresNewSession { Text("Applies to new sessions") }
            }
            .font(.callout).foregroundStyle(.secondary)
            if row.contributions.filter(\.isOverridden).isEmpty == false {
                Text("Also set in " + row.contributions.filter(\.isOverridden)
                    .map { label($0.layer) }.joined(separator: ", "))
                    .font(.callout).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 7)
        .help(row.definingSourcePath ?? row.key)
    }

    /// Standing instructions and agent definitions, from the places each
    /// vendor documents.
    ///
    /// Like hooks, these files are used together rather than overriding each
    /// other, and that is stated. What any of them says is not shown: an
    /// instruction file is prose written for an agent, and summarising one here
    /// would be inventing a claim about how it behaves. The file is one click
    /// away instead.
    @ViewBuilder private var instructionSection: some View {
        if let inventory = session.instructions, !inventory.entries.isEmpty || !inventory.notes.isEmpty {
            VStack(alignment: .leading, spacing: 14) {
                Text("Standing instructions").font(.title3.weight(.semibold))
                Text("Each app reads these at the start of every session, all of them together. A file closer to your project does not replace one further out.")
                    .foregroundStyle(.secondary)
                ForEach(inventory.notes, id: \.detail) { note in
                    AttentionBanner(title: "\(note.surface.displayName) reads a different file",
                                    message: note.detail)
                }
                ForEach(Self.instructionSurfaces, id: \.self) { surface in
                    let entries = inventory.entries.filter { $0.surface == surface }
                    if !entries.isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            Text(surface.displayName).font(.system(size: 15, weight: .medium))
                            ForEach(entries, id: \.path) { entry in
                                HStack(spacing: 10) {
                                    Image(systemName: symbol(entry.kind)).foregroundStyle(.secondary)
                                        .frame(width: 18)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(URL(fileURLWithPath: entry.path).lastPathComponent)
                                        Text("\(describe(entry.kind)) · \(describe(entry.scope))"
                                             + (entry.isEmpty ? " · empty" : ""))
                                            .font(.callout).foregroundStyle(.secondary)
                                    }
                                    Spacer(minLength: 12)
                                    Button("Show file") { reveal(entry.path) }
                                        .buttonStyle(.borderless)
                                        .accessibilityLabel("Show \(entry.path)")
                                }
                                .help(entry.path)
                            }
                        }
                        .padding(.vertical, 4)
                    }
                }
            }
            .padding(18)
            .standardPanel(cornerRadius: 14)
        }
    }

    private static let instructionSurfaces: [TargetSurface] = [.claudeCode, .codexCLI]

    private func symbol(_ kind: AgentInstructionInventory.Kind) -> String {
        switch kind {
        case .instructions: "text.document"
        case .rule: "list.bullet.rectangle"
        case .agent: "person.crop.square"
        }
    }

    private func describe(_ kind: AgentInstructionInventory.Kind) -> String {
        switch kind {
        case .instructions: "Instructions"
        case .rule: "Rule for part of the project"
        case .agent: "Agent"
        }
    }

    private func describe(_ scope: AgentInstructionInventory.Scope) -> String {
        switch scope {
        case .managedPolicy: "your organization"
        case .user: "your account on this Mac"
        case .project: "this project"
        case .localProject: "this project, just for you"
        }
    }

    /// Settings whose files add up instead of overriding each other.
    ///
    /// This is the misreading worth preventing: for a value that replaces, the
    /// top file won and the rest are inert. For one that combines, every file's
    /// entries are live at once. Somebody who thinks their own file overrode a
    /// project's hooks thinks commands are not running that are.
    @ViewBuilder private func combined(_ configuration: EffectiveConfiguration) -> some View {
        let breakdowns = configuration.combinedBreakdowns.filter { $0.contributingFileCount > 0 }
        if !breakdowns.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                Text("Settings that add up").font(.system(size: 15, weight: .medium))
                Text("These are not overridden by the file with the most say — every file's entries are used together.")
                    .font(.callout).foregroundStyle(.secondary)
                ForEach(breakdowns, id: \.key) { breakdown in
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(alignment: .firstTextBaseline) {
                            Text(breakdown.displayName).fontWeight(.medium)
                            Spacer(minLength: 12)
                            Text(breakdown.totalEntryCount == 1
                                 ? "1 in total, from 1 file"
                                 : "\(breakdown.totalEntryCount) in total, from \(breakdown.contributingFileCount) \(breakdown.contributingFileCount == 1 ? "file" : "files")")
                                .foregroundStyle(.secondary)
                        }
                        if breakdown.key == "hooks" {
                            Label("Hooks run commands on this Mac. Agent Tooling does not read what each one does — open a file to see for yourself.",
                                  systemImage: "exclamationmark.triangle")
                                .font(.callout).foregroundStyle(.secondary)
                        }
                        ForEach(Array(breakdown.contributions.enumerated()), id: \.offset) { _, entry in
                            if entry.entryCount > 0 {
                                HStack(spacing: 10) {
                                    Text(entry.entryCount == 1 ? "1 from" : "\(entry.entryCount) from")
                                        .foregroundStyle(.secondary)
                                    Text(label(entry.layer))
                                    Spacer(minLength: 12)
                                    if let path = entry.sourcePath {
                                        Button("Show file") { reveal(path) }
                                            .buttonStyle(.borderless)
                                            .accessibilityLabel("Show the file for \(label(entry.layer))")
                                    }
                                }
                                .font(.callout)
                            }
                        }
                    }
                    .padding(.vertical, 5)
                }
            }
            .padding(.top, 4)
        }
    }

    /// Opens the file in Finder. Agent Tooling does not claim to interpret what
    /// is in it, so the honest answer to "what does this hook do" is to take the
    /// person to it rather than to summarise it wrongly.
    private func reveal(_ path: String) {
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
    }

    private func label(_ kind: ConfigurationLayerKind) -> String {
        switch kind {
        case .managedPolicy: "your organization's policy"
        case .commandLine: "how the app was started"
        case .session: "the running session"
        case .localProject: "this project, just for you"
        case .project: "this project"
        case .user: "your account on this Mac"
        case .builtInDefault: "the app's default"
        }
    }
}

/// One reviewed change to one setting in one file.
///
/// The file is shown by name and the value it holds now is shown beside the new
/// one, because this writes into a file the person's app owns. A backup is
/// written first, and the change is only reported as made once the app would
/// actually use the new value.
private struct WorkspaceSettingEditSheet: View {
    let session: WorkspaceSettingsSession
    let edit: WorkspaceSettingsSession.PendingEdit
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @State private var flag = false
    @State private var loaded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Change \(edit.row.displayName)").font(.title3.weight(.semibold))
                Spacer()
                Button("Cancel") { dismiss() }.buttonStyle(.glass).keyboardShortcut(.cancelAction)
            }.padding(20)
            Divider()
            VStack(alignment: .leading, spacing: 18) {
                Text("This writes into \(edit.surfaceTitle)'s own file. Your current file is copied beside it first, and the change is only reported as made once \(edit.surfaceTitle) would actually use it.")
                    .foregroundStyle(.secondary)
                LabeledContent("File") {
                    Text(edit.sourcePath).textSelection(.enabled).lineLimit(2)
                }
                LabeledContent("Now") { Text(edit.row.value.displayText) }
                VStack(alignment: .leading, spacing: 8) {
                    Text("New value").font(.headline)
                    switch edit.row.value {
                    case .boolean:
                        Toggle(edit.row.displayName, isOn: $flag).toggleStyle(.switch)
                    default:
                        TextField(edit.row.displayName, text: $text)
                            .textFieldStyle(.roundedBorder).frame(maxWidth: 360)
                    }
                }
                if edit.row.requiresNewSession {
                    Label("Applies to new sessions, not one already running.",
                          systemImage: "clock.arrow.circlepath")
                        .font(.callout).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }.padding(20)
            Divider()
            HStack {
                if let message = session.editMessage {
                    Text(message).font(.callout).foregroundStyle(.secondary).lineLimit(3)
                }
                Spacer()
                Button("Change it") {
                    Task {
                        await session.applyEdit(value)
                        if session.editMessage == nil { dismiss() }
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(session.isBusy || !hasChange)
            }.padding(20)
        }
        .frame(width: 620, height: 460)
        .background(AgentTheme.contentBackground)
        .task {
            guard !loaded else { return }
            loaded = true
            switch edit.row.value {
            case .boolean(let value): flag = value
            default: text = edit.row.value.displayText
            }
        }
    }

    /// Typed text becomes the kind of value the setting already holds, so a
    /// number stays a number rather than quietly becoming a string in the file.
    private var value: ConfigurationValue {
        switch edit.row.value {
        case .boolean: .boolean(flag)
        case .number: Double(text).map { ConfigurationValue.number($0) } ?? .string(text)
        default: .string(text)
        }
    }

    private var hasChange: Bool {
        switch edit.row.value {
        case .boolean(let current): flag != current
        default: !text.isEmpty && value != edit.row.value
        }
    }
}
