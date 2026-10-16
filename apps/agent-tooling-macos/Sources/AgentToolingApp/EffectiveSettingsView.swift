import AgentToolingCore
import AppKit
import SwiftUI

/// Apps · Settings: what each installed app will actually use, with where each
/// value comes from and whether changing it here could take effect.
///
/// This screen has no pre-removal original — `WorkspaceSettingsSession` is new
/// to the versioned workspace — so the logic is `WorkspaceSettingsView`'s, and
/// the visual is the old Settings screen's cards and rows: a titled card per
/// app, `InfoRow` for each setting, the same restraint about what can be
/// changed from here.
struct EffectiveSettingsView: View {
    let session: WorkspaceSettingsSession
    @Environment(\.availableClients) private var managedClients
    @State private var refreshID = UUID()

    var body: some View {
        VStack(spacing: 0) {
            PageToolbar(title: "App settings", context: "What each app will use on this Mac") {
                if !session.projects.isEmpty {
                    Picker(
                        "Project",
                        selection: Binding(get: { session.selectedProjectID }, set: { session.select(project: $0) })
                    ) {
                        Text("No project").tag(ArtifactID?.none)
                        ForEach(session.projects) { project in
                            Text(project.name).tag(ArtifactID?.some(project.id))
                        }
                    }
                    .labelsHidden().fixedSize()
                }
                Button("Refresh", systemImage: "arrow.clockwise") { refreshID = UUID() }
                    .labelStyle(.iconOnly).buttonStyle(.glass).disabled(session.isBusy)
                    .help("Refresh")
            }
            Hairline()
            ScrollView {
                VStack(alignment: .leading, spacing: WorkspaceLayout.sectionSpacing) {
                    Text("These values are read from your apps' own files. Only the few marked with a pencil can be changed here.")
                        .foregroundStyle(.secondary)
                    if session.managedPolicyUnknown {
                        Text(
                            "Agent Tooling was not told where an organization policy file would be on this Mac, so it cannot rule one out. If your organization sets one, it may decide a setting shown here as changeable."
                        )
                        .font(AgentFont.body).foregroundStyle(.secondary)
                    }
                    if let receipt = session.lastReceipt {
                        receiptCard(receipt)
                    }
                    if let message = session.editMessage {
                        AttentionBanner(title: "That change was not made", message: message)
                    }
                    if session.hasNoReadableSurfaces {
                        EmptyStateView(
                            symbol: "gearshape",
                            title: "No app settings to show",
                            message: "No settings can be read yet for the apps this Mac manages."
                        )
                        .frame(maxWidth: .infinity, minHeight: 160)
                    }
                    ForEach(session.surfaces) { surface in
                        surfaceCard(surface)
                    }
                    instructionsCard
                }
                .padding(WorkspaceLayout.pageInset)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task(id: refreshID) { await session.refresh(managedClients: managedClients) }
        .task(id: managedClients) { await session.refresh(managedClients: managedClients) }
        .sheet(
            item: Binding(get: { session.pendingEdit }, set: { if $0 == nil { session.discardEdit() } })
        ) { edit in
            EffectiveSettingEditSheet(session: session, edit: edit)
        }
    }

    private func receiptCard(_ receipt: ConfigurationEditReceipt) -> some View {
        TitledCard("Changed \(receipt.key)") {
            VStack(alignment: .leading, spacing: Space.sm) {
                Label("Now \(receipt.effectiveValue.displayText)", systemImage: "checkmark.circle")
                    .font(AgentFont.bodyMedium)
                Text("Your original file is kept beside it as a backup.").foregroundStyle(.secondary)
                CompactPathText(path: receipt.backupPath, lineLimit: 2)
            }
            .padding(Space.xl)
        }
    }

    @ViewBuilder
    private func surfaceCard(_ surface: WorkspaceSettingsSession.Surface) -> some View {
        TitledCard(surface.title) {
            if let message = surface.errorMessage {
                AttentionBanner(title: "Settings need attention", message: message)
                    .padding(Space.xl)
            } else if let configuration = surface.configuration {
                VStack(alignment: .leading, spacing: 0) {
                    HStack {
                        Text(configuration.summary).font(AgentFont.body).foregroundStyle(.secondary)
                        Spacer()
                        Text(configuration.installedClientVersion.map { "Version \($0)" } ?? "Version unknown")
                            .font(AgentFont.body).foregroundStyle(.secondary)
                    }
                    .padding(Space.xl)
                    if configuration.rows.isEmpty {
                        Hairline()
                        Text("No settings were found for this app on this Mac.")
                            .foregroundStyle(.secondary)
                            .padding(Space.xl)
                    }
                    ForEach(configuration.rows, id: \.key) { row in
                        Hairline()
                        settingRow(row, in: surface)
                    }
                    if !configuration.combinedBreakdowns.filter({ $0.contributingFileCount > 0 }).isEmpty {
                        Hairline()
                        combinedSection(configuration)
                    }
                    if !configuration.inactiveLayers.isEmpty {
                        Hairline()
                        Text("Files this version does not read: \(configuration.inactiveLayers.map(label).joined(separator: ", "))")
                            .font(AgentFont.body).foregroundStyle(.secondary)
                            .padding(Space.xl)
                    }
                    if !configuration.unrecognized.isEmpty {
                        Hairline()
                        DisclosureGroup("\(configuration.unrecognized.count) settings this app version manages itself") {
                            VStack(alignment: .leading, spacing: Space.xs) {
                                ForEach(configuration.unrecognized, id: \.key) { entry in
                                    Text("\(entry.key) · \(label(entry.layer))")
                                        .font(AgentFont.body).foregroundStyle(.secondary)
                                }
                            }.padding(.top, Space.md)
                        }
                        .padding(Space.xl)
                    }
                }
            }
        }
    }

    private func settingRow(_ row: EffectiveConfigurationRow, in surface: WorkspaceSettingsSession.Surface) -> some View {
        InfoRow(row.displayName, detail: rowDetail(row)) {
            EmptyView()
        } trailing: {
            HStack(spacing: Space.md) {
                Text(row.value.displayText)
                    .multilineTextAlignment(.trailing).lineLimit(3).textSelection(.enabled)
                if session.isEditable(row, surface: surface.id) {
                    Button("Edit", systemImage: "pencil") { session.beginEdit(row, surface: surface) }
                        .labelStyle(.iconOnly).inlineActionStyle()
                        .disabled(session.isBusy)
                        .accessibilityLabel("Edit \(row.displayName)")
                }
            }
        }
        .help(row.definingSourcePath ?? row.key)
    }

    private func rowDetail(_ row: EffectiveConfigurationRow) -> String {
        var parts = ["From \(label(row.definedBy))"]
        if row.rule == .combineList { parts.append("Combined from every file") }
        if row.isConstrained { parts.append("Fixed here; a change lower down would not take effect") }
        if row.requiresNewSession { parts.append("Applies to new sessions") }
        if !row.contributions.filter(\.isOverridden).isEmpty {
            parts.append("Also set in " + row.contributions.filter(\.isOverridden).map { label($0.layer) }.joined(separator: ", "))
        }
        return parts.joined(separator: " · ")
    }

    @ViewBuilder
    private func combinedSection(_ configuration: EffectiveConfiguration) -> some View {
        let breakdowns = configuration.combinedBreakdowns.filter { $0.contributingFileCount > 0 }
        VStack(alignment: .leading, spacing: Space.lg) {
            Text("Settings that add up").font(AgentFont.title)
            Text("These are not overridden by the file with the most say — every file's entries are used together.")
                .font(AgentFont.body).foregroundStyle(.secondary)
            ForEach(breakdowns, id: \.key) { breakdown in
                VStack(alignment: .leading, spacing: Space.sm) {
                    HStack(alignment: .firstTextBaseline) {
                        Text(breakdown.displayName).fontWeight(.medium)
                        Spacer(minLength: Space.lg)
                        Text(
                            breakdown.totalEntryCount == 1
                                ? "1 in total, from 1 file"
                                : "\(breakdown.totalEntryCount) in total, from \(breakdown.contributingFileCount) \(breakdown.contributingFileCount == 1 ? "file" : "files")"
                        )
                        .foregroundStyle(.secondary)
                    }
                    if breakdown.key == "hooks" {
                        Label(
                            "Hooks run commands on this Mac. Agent Tooling does not read what each one does — open a file to see for yourself.",
                            systemImage: "exclamationmark.triangle"
                        )
                        .font(AgentFont.body).foregroundStyle(.secondary)
                    }
                    ForEach(Array(breakdown.contributions.enumerated()), id: \.offset) { _, entry in
                        if entry.entryCount > 0 {
                            HStack(spacing: Space.lg) {
                                Text(entry.entryCount == 1 ? "1 from" : "\(entry.entryCount) from").foregroundStyle(.secondary)
                                Text(label(entry.layer))
                                Spacer(minLength: Space.lg)
                                if let path = entry.sourcePath {
                                    Button("Show file") { reveal(path) }
                                        .inlineActionStyle()
                                        .accessibilityLabel("Show the file for \(label(entry.layer))")
                                }
                            }
                            .font(AgentFont.body)
                        }
                    }
                }
                .padding(.vertical, Space.xs)
            }
        }
        .padding(Space.xl)
    }

    @ViewBuilder
    private var instructionsCard: some View {
        if let inventory = session.instructions, !inventory.entries.isEmpty || !inventory.notes.isEmpty {
            TitledCard("Standing instructions") {
                VStack(alignment: .leading, spacing: Space.xl) {
                    Text(
                        "Each app reads these at the start of every session, all of them together. A file closer to your project does not replace one further out."
                    )
                    .foregroundStyle(.secondary)
                    ForEach(inventory.notes, id: \.detail) { note in
                        AttentionBanner(title: "\(note.surface.displayName) reads a different file", message: note.detail)
                    }
                    ForEach(Self.instructionSurfaces, id: \.self) { surface in
                        let entries = inventory.entries.filter { $0.surface == surface }
                        if !entries.isEmpty {
                            VStack(alignment: .leading, spacing: Space.md) {
                                Text(surface.displayName).font(AgentFont.title)
                                ForEach(entries, id: \.path) { entry in
                                    instructionRow(entry)
                                }
                            }
                            .padding(.vertical, Space.xs)
                        }
                    }
                }
                .padding(Space.xl)
            }
        }
    }

    private func instructionRow(_ entry: AgentInstructionInventory.Entry) -> some View {
        InfoRow(
            URL(fileURLWithPath: entry.path).lastPathComponent,
            detail: "\(describe(entry.kind)) · \(describe(entry.scope))" + (entry.isEmpty ? " · empty" : "")
        ) {
            Image(systemName: symbol(entry.kind)).foregroundStyle(.secondary).frame(width: Size.glyphSlot)
        } trailing: {
            Button("Show file") { reveal(entry.path) }
                .inlineActionStyle()
                .accessibilityLabel("Show \(entry.path)")
        }
        .help(entry.path)
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
        case .user: "every project on this Mac"
        case .project: "this project"
        case .localProject: "this project, just for you"
        }
    }

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
        case .user: "every project on this Mac"
        case .builtInDefault: "the app's default"
        }
    }
}

/// One reviewed change to one setting in one file, restyled from the old
/// Settings sheet: the file, its current value, and the new one, side by side.
struct EffectiveSettingEditSheet: View {
    let session: WorkspaceSettingsSession
    let edit: WorkspaceSettingsSession.PendingEdit
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @State private var flag = false
    @State private var loaded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Change \(edit.row.displayName)").font(AgentFont.title)
                Spacer()
                Button("Cancel") { dismiss() }.buttonStyle(.glass).keyboardShortcut(.cancelAction)
            }.padding(Space.xxl)
            Hairline()
            VStack(alignment: .leading, spacing: Space.xxl) {
                Text(
                    "This writes into \(edit.surfaceTitle)'s own file. Your current file is copied beside it first, and the change is only reported as made once \(edit.surfaceTitle) would actually use it."
                )
                .foregroundStyle(.secondary)
                LabeledContent("File") { Text(edit.sourcePath).textSelection(.enabled).lineLimit(2) }
                LabeledContent("Now") { Text(edit.row.value.displayText) }
                VStack(alignment: .leading, spacing: Space.md) {
                    Text("New value").font(AgentFont.heading)
                    switch edit.row.value {
                    case .boolean:
                        Toggle(edit.row.displayName, isOn: $flag).toggleStyle(.switch)
                    default:
                        TextField(edit.row.displayName, text: $text)
                            .textFieldStyle(.roundedBorder).frame(maxWidth: Size.fieldMedium)
                    }
                }
                if edit.row.requiresNewSession {
                    Label("Applies to new sessions, not one already running.", systemImage: "clock.arrow.circlepath")
                        .font(AgentFont.body).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }.padding(Space.xxl)
            Hairline()
            HStack {
                if let message = session.editMessage {
                    Text(message).font(AgentFont.body).foregroundStyle(.secondary).lineLimit(3)
                }
                Spacer()
                Button("Change it") {
                    Task {
                        await session.applyEdit(value)
                        if session.editMessage == nil { dismiss() }
                    }
                }
                .primaryActionStyle()
                .disabled(session.isBusy || !hasChange)
            }.padding(Space.xxl)
        }
        .sheetSize(SheetSize.medium)
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
