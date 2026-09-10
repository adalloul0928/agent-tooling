import AgentToolingCore
import SwiftUI

/// Presets: the old Collections screen, restyled over the versioned read
/// model. A list on the left; on the right, which destinations follow a
/// preset, what catching up would change, its items, and a way to share one
/// of them.
///
/// Presets are read-only here — there is no command yet for creating one or
/// changing its membership from this app, so this screen only follows,
/// catches up, and shares. That is stated once, plainly, rather than left
/// implicit by missing buttons.
struct PresetsView: View {
    let session: WorkspacePresetsSession
    let library: WorkspaceLibrarySession
    let export: WorkspacePackageExportSession
    @State private var selection: ArtifactID?
    @State private var linking: ArtifactID?
    @State private var shareSelection: ArtifactID?
    @State private var shareAnchor = ShareAnchor()

    init(
        session: WorkspacePresetsSession, library: WorkspaceLibrarySession,
        export: WorkspacePackageExportSession, initialSelection: ArtifactID? = nil
    ) {
        self.session = session
        self.library = library
        self.export = export
        _selection = State(initialValue: initialSelection)
    }

    var body: some View {
        VStack(spacing: 0) {
            PageToolbar(title: AppSection.presets.navigationTitle, context: context) {
                Button("Refresh", systemImage: "arrow.clockwise") { Task { await session.refresh() } }
                    .labelStyle(.iconOnly).buttonStyle(.glass).disabled(session.isBusy)
            }
            Divider()
            if let message = session.errorMessage {
                AttentionBanner(title: "Presets need attention", message: message)
                    .padding(WorkspaceLayout.pageInset)
            }
            content
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task { await session.refresh() }
        .sheet(isPresented: Binding(get: { linking != nil }, set: { if !$0 { linking = nil } })) {
            if let presetID = linking, let preset = presets.first(where: { $0.id == presetID }) {
                PresetFollowSheet(session: session, library: library, presetID: presetID, name: preset.name)
            }
        }
    }

    private var presets: [WorkspaceLibraryPresetReadModel] { library.state?.library.presets ?? [] }

    @ViewBuilder
    private var content: some View {
        if presets.isEmpty {
            EmptyStateView(
                symbol: "square.stack",
                title: "No presets yet",
                message: "A preset is a named set of tools you can put in place together. There is no way to create one from this Mac yet."
            )
        } else if let selection, let preset = presets.first(where: { $0.id == selection }) {
            HSplitView {
                list.frame(minWidth: 280, idealWidth: 320)
                VStack(spacing: 0) {
                    InspectorHeader(title: "Preset details") { self.selection = nil }
                    detail(preset)
                }
                .frame(minWidth: 420, idealWidth: 600)
            }
            .onExitCommand { self.selection = nil }
        } else {
            list
        }
    }

    private var list: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(presets) { preset in
                    Button {
                        selection = preset.id
                    } label: {
                        PresetListRow(
                            preset: preset, row: session.rows.first { $0.id == preset.id },
                            selected: preset.id == selection)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(preset.name)
                    .accessibilityValue(preset.id == selection ? "Selected" : "")
                }
            }
        }
        .paneMaterial()
    }

    // MARK: - Detail

    @ViewBuilder
    private func detail(_ preset: WorkspaceLibraryPresetReadModel) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: WorkspaceLayout.sectionSpacing) {
                header(preset)
                followingCard(preset)
                itemsCard(preset)
                shareCard(preset)
            }
            .padding(WorkspaceLayout.pageInset)
        }
        .id(preset.id)
    }

    private func header(_ preset: WorkspaceLibraryPresetReadModel) -> some View {
        HStack(alignment: .top, spacing: 14) {
            KindTile(kind: .collection, size: 40)
            VStack(alignment: .leading, spacing: 4) {
                Text(preset.name).font(.title3.weight(.semibold))
                Text(itemSummary(preset)).font(.callout).foregroundStyle(.secondary)
            }
            Spacer()
        }
    }

    @ViewBuilder
    private func followingCard(_ preset: WorkspaceLibraryPresetReadModel) -> some View {
        let row = session.rows.first { $0.id == preset.id }
        TitledCard("Following") {
            VStack(alignment: .leading, spacing: 0) {
                Text(
                    "Following a preset keeps its tools where you put them, even when whoever maintains it adds or removes one. It never changes anything without showing you first."
                )
                .font(.callout).foregroundStyle(.secondary)
                .padding(14)
                if let row, row.isLinked {
                    Divider()
                    InfoRow("Following on this Mac", detail: destinationText(row.subscription?.destinations ?? [])) {
                        Image(systemName: "link").foregroundStyle(.secondary).frame(width: 20)
                    }
                    Divider()
                    changesSection(row)
                    Divider()
                    HStack(spacing: 12) {
                        Button("Catch up") { Task { await session.catchUp(preset.id) } }
                            .buttonStyle(.borderedProminent)
                            .disabled(session.isBusy || !session.canWrite || !row.needsCatchUp)
                        Button("Stop following") { Task { await session.unlink(preset.id) } }
                            .disabled(session.isBusy || !session.canWrite)
                        Spacer()
                        if !session.canWrite {
                            Text("This workspace is open for reading only.").font(.callout).foregroundStyle(.secondary)
                        }
                    }
                    .padding(14)
                } else {
                    Divider()
                    HStack(spacing: 12) {
                        Button("Follow this preset…") { linking = preset.id }
                            .buttonStyle(.borderedProminent)
                            .disabled(session.isBusy || !session.canWrite)
                        Spacer()
                        if !session.canWrite {
                            Text("This workspace is open for reading only.").font(.callout).foregroundStyle(.secondary)
                        }
                    }
                    .padding(14)
                }
            }
        }
    }

    @ViewBuilder
    private func changesSection(_ row: WorkspacePresetsSession.Row) -> some View {
        if let update = row.update {
            let added = update.changes.filter { $0.kind == .add }
            let removed = update.changes.filter { $0.kind == .removeContribution }
            let kept = update.changes.filter { $0.kind == .retainedByOtherReason }
            VStack(alignment: .leading, spacing: 6) {
                if update.changes.isEmpty {
                    Text("Up to date with this preset.").font(.callout).foregroundStyle(.secondary)
                } else {
                    if !added.isEmpty {
                        Label(
                            added.count == 1 ? "1 tool would be added" : "\(added.count) tools would be added",
                            systemImage: "plus.circle")
                    }
                    if !removed.isEmpty {
                        Label(
                            removed.count == 1
                                ? "1 tool would be taken back out" : "\(removed.count) tools would be taken back out",
                            systemImage: "minus.circle")
                    }
                    if !kept.isEmpty {
                        Label(
                            kept.count == 1
                                ? "1 tool left the preset but stays, because you asked for it another way"
                                : "\(kept.count) tools left the preset but stay, because you asked for them another way",
                            systemImage: "hand.raised"
                        )
                        .foregroundStyle(.secondary)
                    }
                }
            }
            .font(.callout)
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            Text("This preset is no longer in your library, so there is nothing to follow.")
                .font(.callout).foregroundStyle(.secondary)
                .padding(14)
        }
    }

    private func itemsCard(_ preset: WorkspaceLibraryPresetReadModel) -> some View {
        TitledCard("Items", count: "\(preset.memberArtifactIDs.count)") {
            VStack(alignment: .leading, spacing: 0) {
                Text("Presets are read-only here. Add or remove tools from their own screen.")
                    .font(.caption).foregroundStyle(.secondary)
                    .padding(14)
                if preset.memberArtifactIDs.isEmpty {
                    Divider()
                    Text("This preset has no items.").font(.callout).foregroundStyle(.secondary).padding(14)
                } else {
                    ForEach(preset.memberArtifactIDs, id: \.self) { id in
                        Divider()
                        memberRow(id)
                    }
                }
            }
        }
    }

    private func memberRow(_ id: ArtifactID) -> some View {
        let member = resolve(id)
        return InfoRow(member.name, detail: member.detail) {
            KindTile(kind: member.kind, size: 24, ghost: !member.present)
        }
        .help(member.present ? member.name : id.rawValue.uuidString)
    }

    @ViewBuilder
    private func shareCard(_ preset: WorkspaceLibraryPresetReadModel) -> some View {
        let candidates = preset.memberArtifactIDs.compactMap { id -> (id: ArtifactID, name: String)? in
            let member = resolve(id)
            return member.present ? (id, member.name) : nil
        }
        TitledCard("Share") {
            VStack(alignment: .leading, spacing: 12) {
                Label(
                    "Export writes a one-time copy. The file is a snapshot, not a live link — later edits here never reach anyone you shared it with.",
                    systemImage: "doc.badge.arrow.up"
                )
                .font(.callout).foregroundStyle(.secondary)
                Label("Credentials are never included in an exported package.", systemImage: "lock")
                    .font(.callout).foregroundStyle(.secondary)

                if candidates.isEmpty {
                    Text("Nothing in this preset can be shared from this Mac yet.")
                        .font(.callout).foregroundStyle(.secondary)
                } else {
                    Picker("Item to share", selection: $shareSelection) {
                        ForEach(candidates, id: \.id) { candidate in
                            Text(candidate.name).tag(ArtifactID?.some(candidate.id))
                        }
                    }
                    .labelsHidden()
                    .frame(maxWidth: 320)
                    .onAppear { if shareSelection == nil { shareSelection = candidates.first?.id } }
                    .onChange(of: preset.id) { _, _ in shareSelection = candidates.first?.id }

                    shareActions
                }
            }
            .padding(14)
        }
        .onChange(of: shareSelection) { _, _ in export.discard() }
    }

    @ViewBuilder
    private var shareActions: some View {
        if let preview = export.preview, preview.artifactID == shareSelection {
            previewSummary(preview)
            HStack(spacing: 8) {
                Button {
                    guard let destination = PackageFileExport.chooseDestinationFolder() else { return }
                    Task { await export.write(to: destination) }
                } label: {
                    Label("Export…", systemImage: "square.and.arrow.down")
                }
                .buttonStyle(.bordered)
                .disabled(export.isBusy)

                Button {
                    Task {
                        guard let folder = try? PackageFileExport.stagingFolder() else { return }
                        await export.write(to: folder)
                        if let path = export.writtenPath {
                            shareAnchor.present([URL(fileURLWithPath: path)])
                        }
                    }
                } label: {
                    Label("Share…", systemImage: "square.and.arrow.up")
                }
                .buttonStyle(.bordered)
                .disabled(export.isBusy)
                .overlay(alignment: .bottom) { ShareAnchorView(anchor: shareAnchor).frame(width: 1, height: 1) }

                Spacer()
            }
        } else {
            Button {
                guard let id = shareSelection else { return }
                Task { await export.prepare(id) }
            } label: {
                Label("Prepare export…", systemImage: "doc.text.magnifyingglass")
            }
            .buttonStyle(.bordered)
            .disabled(export.isBusy || shareSelection == nil)
        }
        if let message = export.errorMessage {
            Text(message).font(.callout).foregroundStyle(.secondary)
        }
        if let path = export.writtenPath {
            HStack(spacing: 6) {
                Image(systemName: "checkmark.circle").foregroundStyle(AgentTheme.ok)
                Text("Written to")
                LocationText(path: path)
            }
            .font(.callout)
        }
    }

    private func previewSummary(_ preview: WorkspacePackageExport) -> some View {
        let unsupported = preview.compatibility.filter { !$0.isFullySupported }
        return VStack(alignment: .leading, spacing: 4) {
            Text(
                "\(preview.fileCount) file\(preview.fileCount == 1 ? "" : "s") · "
                    + ByteCountFormatter.string(fromByteCount: Int64(preview.totalFileBytes), countStyle: .file)
            )
            .font(.callout).foregroundStyle(.secondary)
            if !unsupported.isEmpty {
                Text("Not fully supported by \(unsupported.map { $0.surface.displayName }.formatted(.list(type: .and))).")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Reading

    private struct MemberDescriptor {
        let name: String
        let detail: String
        let kind: ToolingKind
        let present: Bool
    }

    private func resolve(_ id: ArtifactID) -> MemberDescriptor {
        guard let libraryModel = library.state?.library else {
            return .init(name: "Item no longer in this library", detail: "", kind: .skill, present: false)
        }
        if let row = libraryModel.rows.first(where: { $0.artifactID == id }) {
            return .init(
                name: row.displayName, detail: row.sourceLabel ?? row.observedDescription ?? "",
                kind: toolingKind(row.kind), present: true)
        }
        for row in libraryModel.rows {
            if let child = row.includedChildren.first(where: { $0.artifactID == id }) {
                return .init(
                    name: child.displayName, detail: "In \(row.displayName)", kind: toolingKind(child.kind), present: true)
            }
        }
        return .init(name: "Item no longer in this library", detail: "", kind: .skill, present: false)
    }

    private func toolingKind(_ kind: ArtifactKind) -> ToolingKind {
        switch kind {
        case .skill: .skill
        case .mcpServer: .mcpServer
        case .nativePlugin, .package: .plugin
        case .preset: .collection
        case .logicalProject: .library
        }
    }

    private func destinationText(_ destinations: [PortableDestination]) -> String {
        let names = destinations.map { "\($0.surface.displayName) · \($0.scope.displayName)" }.sorted()
        return names.isEmpty ? "no destinations" : names.formatted(.list(type: .and))
    }

    private func itemSummary(_ preset: WorkspaceLibraryPresetReadModel) -> String {
        preset.memberArtifactIDs.count == 1 ? "1 item" : "\(preset.memberArtifactIDs.count) items"
    }

    private var context: String {
        let following = session.rows.filter(\.isLinked).count
        let pending = session.rows.filter(\.hasPendingChanges).count
        if pending > 0 { return pending == 1 ? "1 preset has changes to review" : "\(pending) presets have changes to review" }
        return following == 0
            ? "Not following any preset on this Mac" : "Following \(following == 1 ? "1 preset" : "\(following) presets") on this Mac"
    }
}

private struct PresetListRow: View {
    let preset: WorkspaceLibraryPresetReadModel
    let row: WorkspacePresetsSession.Row?
    let selected: Bool

    var body: some View {
        HStack(spacing: 11) {
            KindTile(kind: .collection, size: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(preset.name)
                    .font(.callout.weight(.medium))
                    .foregroundStyle(selected ? Color.white : Color.primary)
                    .lineLimit(1)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(selected ? Color.white.opacity(0.78) : Color.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 12)
            Text(itemSummary)
                .font(.caption)
                .foregroundStyle(selected ? Color.white.opacity(0.78) : Color.secondary)
        }
        .padding(.horizontal, 13)
        .frame(minHeight: 52)
        .rowSelection(selected)
        .contentShape(Rectangle())
    }

    private var subtitle: String {
        guard let row, row.isLinked else { return "Not followed on this Mac" }
        return row.needsCatchUp ? "Following · changes to review" : "Following · up to date"
    }

    private var itemSummary: String {
        preset.memberArtifactIDs.count == 1 ? "1 item" : "\(preset.memberArtifactIDs.count) items"
    }
}

/// Choosing where a preset's tools should go before following it. The same
/// interaction `WorkspacePresetsView` offers, ported into this screen's own
/// file so its detail pane can present it directly.
private struct PresetFollowSheet: View {
    let session: WorkspacePresetsSession
    let library: WorkspaceLibrarySession
    let presetID: ArtifactID
    let name: String
    @Environment(\.dismiss) private var dismiss
    @State private var clients: Set<ClientKind> = []
    @State private var scope: ToolingScope = .user
    @State private var projectID: ArtifactID?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Follow \(name)").font(.title3.weight(.semibold))
                Spacer()
                Button("Cancel") { dismiss() }.buttonStyle(.glass).keyboardShortcut(.cancelAction)
            }.padding(20)
            Divider()
            VStack(alignment: .leading, spacing: 18) {
                Text(
                    "Choose where this preset's tools belong. Agent Tooling keeps them there as the preset changes, and shows you each change before applying it."
                )
                .foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 8) {
                    Text("Apps").font(.headline)
                    ForEach(ClientKind.allCases) { client in
                        Toggle(
                            client.rawValue,
                            isOn: Binding(
                                get: { clients.contains(client) },
                                set: { if $0 { clients.insert(client) } else { clients.remove(client) } })
                        )
                        .toggleStyle(.checkbox)
                    }
                }
                VStack(alignment: .leading, spacing: 8) {
                    Text("Where").font(.headline)
                    Picker("Where", selection: $scope) {
                        Text("Everywhere on this Mac").tag(ToolingScope.user)
                        Text("One project").tag(ToolingScope.project)
                    }
                    .labelsHidden().pickerStyle(.radioGroup)
                    if scope == .project {
                        Picker("Project", selection: $projectID) {
                            Text("Choose a project").tag(ArtifactID?.none)
                            ForEach(library.state?.library.projects ?? []) { project in
                                Text(project.name).tag(ArtifactID?.some(project.id))
                            }
                        }.frame(maxWidth: 320)
                    }
                }
                Spacer(minLength: 0)
            }.padding(20)
            Divider()
            HStack {
                Text("Following records the choice. Nothing moves until you catch up.")
                    .font(.callout).foregroundStyle(.secondary)
                Spacer()
                Button("Follow") {
                    Task {
                        await session.link(presetID, destinations: destinations)
                        dismiss()
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(!canFollow || session.isBusy)
            }.padding(20)
        }
        .frame(width: 560, height: 500)
        .background(AgentTheme.contentBackground)
    }

    private var canFollow: Bool {
        guard !clients.isEmpty else { return false }
        return scope != .project || projectID != nil
    }

    private var destinations: [PortableDestination] {
        clients.sorted { $0.rawValue < $1.rawValue }.map { client in
            .init(
                surface: client.primarySurface, scope: scope,
                logicalProjectID: scope == .project ? projectID : nil,
                deviceIDs: [library.deviceID])
        }
    }
}

private extension ClientKind {
    var primarySurface: TargetSurface {
        switch self {
        case .claude: .claudeCode
        case .codex: .codexCLI
        case .gemini: .geminiCLI
        }
    }
}
