import AgentToolingCore
import SwiftUI

/// Presets: the old Collections screen, restyled over the versioned read
/// model. A list on the left; on the right, which destinations follow a
/// preset, what catching up would change, its items, and a way to share one
/// of them.
///
/// A preset can be created here from library items, renamed, and deleted;
/// deleting one leaves its members exactly where they are and only lets go of
/// the assignments the preset itself produced. Its membership is still edited
/// by adding or removing the tools in the Library. Export, Share and Follow
/// stay as they were.
struct PresetsView: View {
    let session: WorkspacePresetsSession
    let library: WorkspaceLibrarySession
    let export: WorkspacePackageExportSession
    @State private var selection: ArtifactID?
    @State private var linking: ArtifactID?
    @State private var shareSelection: ArtifactID?
    @State private var shareAnchor = ShareAnchor()
    @State private var creatingPreset = false
    @State private var renaming: ArtifactID?

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
                Button("New preset…", systemImage: "plus") { creatingPreset = true }
                    .buttonStyle(.glass)
                    .disabled(session.isBusy || !session.canWrite)
                    .help(
                        session.canWrite
                            ? "Create a preset from items already in your library"
                            : "This workspace is open for reading only.")
                Button("Refresh", systemImage: "arrow.clockwise") { Task { await session.refresh() } }
                    .labelStyle(.iconOnly).buttonStyle(.glass).disabled(session.isBusy)
            }
            Hairline()
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
        .sheet(isPresented: $creatingPreset) {
            PresetEditorSheet(session: session, library: library, mode: .create) { created in
                selection = created
            }
        }
        .sheet(isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            if let presetID = renaming, let preset = presets.first(where: { $0.id == presetID }) {
                PresetEditorSheet(
                    session: session, library: library,
                    mode: .rename(presetID: presetID, currentName: preset.name)) { _ in }
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
                message: "A preset is a named set of tools you can put in place together. Create one with “New preset…” from items already in your library, or receive one with a workspace — restored from a backup, synced from another Mac, or shared with you.",
                actionTitle: session.canWrite ? "New preset…" : nil,
                isActionEnabled: session.canWrite && !session.isBusy
            ) {
                creatingPreset = true
            }
        } else if let selection, let preset = presets.first(where: { $0.id == selection }) {
            HSplitView {
                list.frame(minWidth: Size.listPaneMin, idealWidth: Size.paneIdealWide)
                VStack(spacing: 0) {
                    InspectorHeader(title: "Preset details") { self.selection = nil }
                    detail(preset)
                }
                .frame(minWidth: Size.detailPaneMin, idealWidth: Size.paneIdealWide)
            }
            .onExitCommand { self.selection = nil }
        } else {
            list
        }
    }

    /// The same standing card, row insets and hairlines as the Skills,
    /// Plugins and Connections tabs beside it.
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
                    .hairlineBottom(preset.id != selection && preset.id != presets.last?.id)
                }
            }
        }
        .collectionSurface()
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
        HStack(alignment: .top, spacing: Space.xl) {
            KindTile(kind: .collection, size: Size.tileLarge)
            VStack(alignment: .leading, spacing: Space.xs) {
                Text(preset.name).font(AgentFont.title)
                Text(itemSummary(preset)).font(AgentFont.body).foregroundStyle(.secondary)
            }
            Spacer()
            Menu {
                Button("Rename…", systemImage: "pencil") { renaming = preset.id }
                    .disabled(!session.canWrite || session.isBusy)
                Button("Delete preset", systemImage: "trash", role: .destructive) {
                    Task {
                        if await session.deletePreset(preset.id), selection == preset.id { selection = nil }
                    }
                }
                .disabled(!session.canWrite || session.isBusy)
            } label: {
                Label("Preset actions", systemImage: "ellipsis.circle")
                    .labelStyle(.iconOnly)
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .disabled(!session.canWrite || session.isBusy)
            .help(
                session.canWrite
                    ? "Rename or delete this preset. Deleting it leaves its items in your library."
                    : "This workspace is open for reading only.")
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
                .font(AgentFont.body).foregroundStyle(.secondary)
                .padding(Space.xl)
                if let row, row.isLinked {
                    Hairline()
                    InfoRow("Following on this Mac", detail: destinationText(row.subscription?.destinations ?? [])) {
                        Image(systemName: "link").foregroundStyle(.secondary).frame(width: Size.glyphSlot)
                    }
                    Hairline()
                    changesSection(row)
                    Hairline()
                    HStack(spacing: Space.lg) {
                        Button("Catch up") { Task { await session.catchUp(preset.id) } }
                            .primaryActionStyle()
                            .disabled(session.isBusy || !session.canWrite || !row.needsCatchUp)
                        Button("Stop following") { Task { await session.unlink(preset.id) } }
                            .disabled(session.isBusy || !session.canWrite)
                        Spacer()
                        if !session.canWrite {
                            Text("This workspace is open for reading only.").font(AgentFont.body).foregroundStyle(.secondary)
                        }
                    }
                    .padding(Space.xl)
                } else {
                    Hairline()
                    HStack(spacing: Space.lg) {
                        Button("Follow this preset…") { linking = preset.id }
                            .primaryActionStyle()
                            .disabled(session.isBusy || !session.canWrite)
                        Spacer()
                        if !session.canWrite {
                            Text("This workspace is open for reading only.").font(AgentFont.body).foregroundStyle(.secondary)
                        }
                    }
                    .padding(Space.xl)
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
            VStack(alignment: .leading, spacing: Space.sm) {
                if update.changes.isEmpty {
                    Text("Up to date with this preset.").font(AgentFont.body).foregroundStyle(.secondary)
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
            .font(AgentFont.body)
            .padding(Space.xl)
            .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            Text("This preset is no longer in your library, so there is nothing to follow.")
                .font(AgentFont.body).foregroundStyle(.secondary)
                .padding(Space.xl)
        }
    }

    private func itemsCard(_ preset: WorkspaceLibraryPresetReadModel) -> some View {
        TitledCard("Items", count: "\(preset.memberArtifactIDs.count)") {
            VStack(alignment: .leading, spacing: 0) {
                Text("A preset's items are set when you create it. To change which tools are in it, add or remove the tools themselves in the Library.")
                    .font(AgentFont.caption).foregroundStyle(.secondary)
                    .padding(Space.xl)
                if preset.memberArtifactIDs.isEmpty {
                    Hairline()
                    Text("This preset has no items.").font(AgentFont.body).foregroundStyle(.secondary).padding(Space.xl)
                } else {
                    ForEach(preset.memberArtifactIDs, id: \.self) { id in
                        Hairline()
                        memberRow(id)
                    }
                }
            }
        }
    }

    private func memberRow(_ id: ArtifactID) -> some View {
        let member = resolve(id)
        return InfoRow(member.name, detail: member.detail) {
            KindTile(kind: member.kind, size: Size.tile, ghost: !member.present)
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
            VStack(alignment: .leading, spacing: Space.lg) {
                Label(
                    "Export writes a one-time copy. The file is a snapshot, not a live link — later edits here never reach anyone you shared it with.",
                    systemImage: "doc.badge.arrow.up"
                )
                .font(AgentFont.body).foregroundStyle(.secondary)
                Label("Credentials are never included in an exported package.", systemImage: "lock")
                    .font(AgentFont.body).foregroundStyle(.secondary)

                if candidates.isEmpty {
                    Text("Nothing in this preset can be shared from this Mac yet.")
                        .font(AgentFont.body).foregroundStyle(.secondary)
                } else {
                    Picker("Item to share", selection: $shareSelection) {
                        ForEach(candidates, id: \.id) { candidate in
                            Text(candidate.name).tag(ArtifactID?.some(candidate.id))
                        }
                    }
                    .labelsHidden()
                    .frame(maxWidth: Size.fieldStandard)
                    .onAppear { if shareSelection == nil { shareSelection = candidates.first?.id } }
                    .onChange(of: preset.id) { _, _ in shareSelection = candidates.first?.id }

                    shareActions
                }
            }
            .padding(Space.xl)
        }
        .onChange(of: shareSelection) { _, _ in export.discard() }
    }

    @ViewBuilder
    private var shareActions: some View {
        if let preview = export.preview, preview.artifactID == shareSelection {
            previewSummary(preview)
            HStack(spacing: Space.md) {
                Button {
                    guard let destination = PackageFileExport.chooseDestinationFolder() else { return }
                    Task { await export.write(to: destination) }
                } label: {
                    Label("Export…", systemImage: "square.and.arrow.down")
                }
                .secondaryActionStyle()
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
                .secondaryActionStyle()
                .disabled(export.isBusy)
                .overlay(alignment: .bottom) {
                    ShareAnchorView(anchor: shareAnchor).frame(width: Size.anchorPoint, height: Size.anchorPoint)
                }

                Spacer()
            }
        } else {
            Button {
                guard let id = shareSelection else { return }
                Task { await export.prepare(id) }
            } label: {
                Label("Prepare export…", systemImage: "doc.text.magnifyingglass")
            }
            .secondaryActionStyle()
            .disabled(export.isBusy || shareSelection == nil)
        }
        if let message = export.errorMessage {
            Text(message).font(AgentFont.body).foregroundStyle(.secondary)
        }
        if let path = export.writtenPath {
            HStack(spacing: Space.sm) {
                Image(systemName: "checkmark.circle").foregroundStyle(AgentTheme.ok)
                Text("Written to")
                LocationText(path: path)
            }
            .font(AgentFont.body)
        }
    }

    private func previewSummary(_ preview: WorkspacePackageExport) -> some View {
        let unsupported = preview.compatibility.filter { !$0.isFullySupported }
        return VStack(alignment: .leading, spacing: Space.xs) {
            Text(
                "\(preview.fileCount) file\(preview.fileCount == 1 ? "" : "s") · "
                    + ByteCountFormatter.string(fromByteCount: Int64(preview.totalFileBytes), countStyle: .file)
            )
            .font(AgentFont.body).foregroundStyle(.secondary)
            if !unsupported.isEmpty {
                Text("Not fully supported by \(unsupported.map { $0.surface.displayName }.formatted(.list(type: .and))).")
                    .font(AgentFont.caption).foregroundStyle(.secondary)
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
                kind: ToolingKind(row.kind), present: true)
        }
        for row in libraryModel.rows {
            if let child = row.includedChildren.first(where: { $0.artifactID == id }) {
                return .init(
                    name: child.displayName, detail: "In \(row.displayName)", kind: ToolingKind(child.kind), present: true)
            }
        }
        return .init(name: "Item no longer in this library", detail: "", kind: .skill, present: false)
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
        HStack(spacing: Space.lg) {
            KindTile(kind: .collection, size: Size.tile)
            VStack(alignment: .leading, spacing: Space.xxs) {
                Text(preset.name)
                    .font(AgentFont.bodyMedium)
                    .foregroundStyle(selected ? AgentTheme.onSelection : Color.primary)
                    .lineLimit(1)
                Text(subtitle)
                    .font(AgentFont.caption)
                    .foregroundStyle(selected ? AgentTheme.onSelection.opacity(Opacity.secondaryOnSelection) : Color.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: Space.lg)
            Text(itemSummary)
                .font(AgentFont.caption)
                .foregroundStyle(selected ? AgentTheme.onSelection.opacity(Opacity.secondaryOnSelection) : Color.secondary)
        }
        .padding(.horizontal, Space.xl)
        .frame(minHeight: Size.rowHeight)
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
struct PresetFollowSheet: View {
    let session: WorkspacePresetsSession
    let library: WorkspaceLibrarySession
    let presetID: ArtifactID
    let name: String
    @Environment(\.dismiss) private var dismiss
    @Environment(\.availableClients) private var availableClients
    @State private var clients: Set<ClientKind> = []
    @State private var scope: ToolingScope = .user
    @State private var projectID: ArtifactID?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Follow \(name)").font(AgentFont.title)
                Spacer()
            }.padding(Space.xxl)
            Hairline()
            VStack(alignment: .leading, spacing: Space.xxl) {
                Text(
                    "Choose where this preset's tools belong. Agent Tooling keeps them there as the preset changes, and shows you each change before applying it."
                )
                .foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: Space.md) {
                    Text("Apps").font(AgentFont.heading)
                    ForEach(availableClients) { client in
                        Toggle(
                            client.rawValue,
                            isOn: Binding(
                                get: { clients.contains(client) },
                                set: { if $0 { clients.insert(client) } else { clients.remove(client) } })
                        )
                        .toggleStyle(.checkbox)
                    }
                }
                VStack(alignment: .leading, spacing: Space.md) {
                    Text("Where").font(AgentFont.heading)
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
                        }.frame(maxWidth: Size.fieldStandard)
                    }
                }
                Spacer(minLength: 0)
            }.padding(Space.xxl)
            Hairline()
            HStack {
                Text("Following records the choice. Nothing moves until you catch up.")
                    .font(AgentFont.body).foregroundStyle(.secondary)
                Spacer()
                Button("Cancel") { dismiss() }.buttonStyle(.glass).keyboardShortcut(.cancelAction)
                Button("Follow") {
                    Task {
                        await session.link(presetID, destinations: destinations)
                        dismiss()
                    }
                }
                .primaryActionStyle()
                .disabled(!canFollow || session.isBusy)
            }.padding(Space.xxl)
        }
        .sheetSize(SheetSize.medium)
        .background(AgentTheme.contentBackground)
    }

    private var canFollow: Bool {
        guard !clients.isEmpty else { return false }
        return scope != .project || projectID != nil
    }

    private var destinations: [PortableDestination] {
        clients.sorted { $0.rawValue < $1.rawValue }.map { client in
            .init(
                surface: client.defaultSurface, scope: scope,
                logicalProjectID: scope == .project ? projectID : nil,
                deviceIDs: [library.deviceID])
        }
    }
}

/// Creating a preset, or renaming one.
///
/// A preset is a name and a set of library items. Create mode asks for both: a
/// name, and a checklist of the skills, servers and plugins the library already
/// holds, searchable because a full library is long. Rename mode asks for the
/// name only — a preset's membership is changed by editing the tools in the
/// Library, not here. Nothing is put in place by either: creating records the
/// shelf, and following it later is what moves anything.
struct PresetEditorSheet: View {
    enum Mode {
        case create
        case rename(presetID: ArtifactID, currentName: String)
    }

    let session: WorkspacePresetsSession
    let library: WorkspaceLibrarySession
    let mode: Mode
    /// Called with the new preset's id after a successful create, so the list
    /// can select it. Rename passes nil back through the same closure unused.
    let onCreated: (ArtifactID?) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var members: Set<ArtifactID> = []
    @State private var search = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(isRenaming ? "Rename preset" : "New preset").font(AgentFont.title)
                Spacer()
            }
            .padding(Space.xxl)
            Hairline()
            VStack(alignment: .leading, spacing: Space.xl) {
                if let message = session.errorMessage {
                    AttentionBanner(title: isRenaming ? "That preset was not renamed" : "That preset was not created", message: message)
                }
                LabeledContent("Name") {
                    TextField("Starter set", text: $name)
                        .textFieldStyle(.roundedBorder).frame(maxWidth: Size.fieldStandard)
                        .accessibilityLabel("Preset name")
                }
                if !isRenaming { memberPicker }
                Spacer(minLength: 0)
            }
            .padding(Space.xxl)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            Hairline()
            HStack {
                Text(
                    isRenaming
                        ? "Renaming keeps the preset's items and its following."
                        : "Creating records the preset. Nothing is put in place until you follow it."
                )
                .font(AgentFont.body).foregroundStyle(.secondary)
                Spacer()
                Button("Cancel") { dismiss() }.buttonStyle(.glass).keyboardShortcut(.cancelAction)
                Button(isRenaming ? "Rename" : "Create preset") { commit() }
                    .primaryActionStyle()
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canCommit)
            }
            .padding(Space.xxl)
        }
        .sheetSize(SheetSize.medium)
        .background(AgentTheme.contentBackground)
        .onAppear {
            session.clearError()
            if case .rename(_, let currentName) = mode { name = currentName }
        }
    }

    private var memberPicker: some View {
        VStack(alignment: .leading, spacing: Space.md) {
            HStack {
                Text("Items").font(AgentFont.heading)
                Spacer()
                Text(members.count == 1 ? "1 chosen" : "\(members.count) chosen")
                    .font(AgentFont.caption).foregroundStyle(.secondary)
            }
            InventorySearchField(placeholder: "Search your library", text: $search)
            if candidates.isEmpty {
                Text("Your library has no skills, servers, or plugins to put in a preset yet.")
                    .font(AgentFont.body).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(filteredCandidates) { row in
                            PresetMemberToggle(
                                row: row,
                                isMember: members.contains(row.artifactID),
                                kind: ToolingKind(row.kind)
                            ) { on in
                                if on { members.insert(row.artifactID) } else { members.remove(row.artifactID) }
                            }
                            if row.artifactID != filteredCandidates.last?.artifactID { Hairline() }
                        }
                    }
                    .padding(.horizontal, Space.xs)
                }
                .frame(maxHeight: .infinity)
                .standardPanel()
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var isRenaming: Bool {
        if case .rename = mode { return true }
        return false
    }

    /// The library items that can go in a preset: skills, servers and plugins.
    /// Presets and logical projects are not members of a preset, so they are
    /// left out rather than offered as choices that would be refused.
    private var candidates: [WorkspaceLibraryReadModelRow] {
        (library.state?.library.rows ?? []).filter {
            switch $0.kind {
            case .skill, .mcpServer, .nativePlugin, .package: true
            case .preset, .logicalProject: false
            }
        }
    }

    private var filteredCandidates: [WorkspaceLibraryReadModelRow] {
        let term = search.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !term.isEmpty else { return candidates }
        return candidates.filter { $0.displayName.localizedCaseInsensitiveContains(term) }
    }

    private var canCommit: Bool {
        guard !session.isBusy, session.canWrite,
            !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return false }
        return isRenaming || !members.isEmpty
    }

    private func commit() {
        Task {
            switch mode {
            case .create:
                if await session.createPreset(name: name, memberArtifactIDs: Array(members)) {
                    onCreated(session.lastCreatedPresetID)
                    dismiss()
                }
            case .rename(let presetID, _):
                if await session.renamePreset(presetID, name: name) { dismiss() }
            }
        }
    }

}

/// One checkable library item in the preset editor's member list. Extracted so
/// the enclosing `ForEach` infers a plain collection rather than the binding
/// overload the inline `Toggle` binding pushed it toward.
private struct PresetMemberToggle: View {
    let row: WorkspaceLibraryReadModelRow
    let isMember: Bool
    let kind: ToolingKind
    let setMember: @MainActor @Sendable (Bool) -> Void

    var body: some View {
        Toggle(isOn: Binding(get: { isMember }, set: { setMember($0) })) {
            HStack(spacing: Space.md) {
                KindTile(kind: kind, size: Size.tileSmall)
                VStack(alignment: .leading, spacing: Space.xxs) {
                    Text(row.displayName).font(AgentFont.body)
                    Text(kindLabel(row.kind)).font(AgentFont.micro).foregroundStyle(.secondary)
                }
            }
        }
        .toggleStyle(.checkbox)
        .padding(.vertical, Space.xs)
    }

    /// A plain word for the item's kind, so the row reads without leaning on a
    /// domain enum's raw case name.
    private func kindLabel(_ kind: ArtifactKind) -> String {
        switch kind {
        case .skill: "Skill"
        case .mcpServer: "MCP server"
        case .nativePlugin, .package: "Plugin"
        case .preset: "Preset"
        case .logicalProject: "Project"
        }
    }
}
