import AgentToolingCore
import SwiftUI

/// The Library, and the same browser a project uses. One session, one read
/// model; a project only prefills its own context.
struct WorkspaceLibraryView: View {
    let session: WorkspaceLibrarySession
    var initialProjectID: ArtifactID? = nil
    var authoring: WorkspaceAuthoringSession?
    var export: WorkspacePackageExportSession?
    /// The kind a Library tab opens on. Anything but `.all` hides the in-pane
    /// kind picker, because the tab already made that choice.
    var initialKind: LibraryKind = .all
    @State private var isAttaching = false
    @State private var exporting: ExportPresentation?
    @State private var query = ""
    @State private var kind: LibraryKind
    @State private var selection: Set<ArtifactID> = []
    @State private var detailID: ArtifactID?
    @State private var assignment: AssignmentPresentation?
    @State private var refreshID = UUID()

    init(
        session: WorkspaceLibrarySession, initialProjectID: ArtifactID? = nil,
        authoring: WorkspaceAuthoringSession? = nil, export: WorkspacePackageExportSession? = nil,
        initialKind: LibraryKind = .all
    ) {
        self.session = session
        self.initialProjectID = initialProjectID
        self.authoring = authoring
        self.export = export
        self.initialKind = initialKind
        _kind = State(initialValue: initialKind)
    }

    var body: some View {
        VStack(spacing: 0) {
            PageToolbar(title: "Library", context: context) {
                Button("Refresh", systemImage: "arrow.clockwise") { refreshID = UUID() }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.glass)
                    .disabled(session.isBusy)
                Menu("Use preset", systemImage: "square.stack") {
                    ForEach(session.state?.library.presets ?? []) { preset in
                        Button(preset.name) {
                            session.discardReview()
                            assignment = .init(artifactIDs: preset.memberArtifactIDs, presetID: preset.id)
                        }
                        .disabled(preset.memberArtifactIDs.isEmpty)
                    }
                }
                .buttonStyle(.glass)
                .disabled(session.isBusy || session.state?.library.presets.isEmpty != false)
                if authoring != nil {
                    Button("Attach folder…", systemImage: "folder.badge.plus") { isAttaching = true }
                        .buttonStyle(.glass)
                        .disabled(session.isBusy || session.access != .writable)
                        .help("Register a folder you already author in as the editable copy for a skill.")
                }
            }
            HStack(spacing: 16) {
                if initialKind == .all {
                    WorkspaceSegmentedPicker("Item type", selection: $kind) {
                        ForEach(LibraryKind.allCases) { value in Text(value.rawValue).tag(value) }
                    }.fixedSize()
                }
                Spacer(minLength: 12)
                InventorySearchField(placeholder: "Search library", text: $query)
                    .frame(minWidth: 180, idealWidth: 260, maxWidth: 340)
            }
            .padding(.horizontal, WorkspaceLayout.pageInset)
            .padding(.vertical, 12)
            Divider()
            if let message = session.errorMessage, assignment == nil {
                Label(message, systemImage: "exclamationmark.circle")
                    .font(.body).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(WorkspaceLayout.pageInset)
            }
            if let library = session.state?.library {
                let rows = library.filteredRows(matching: query).filter { kind.includes($0.kind) }
                if rows.isEmpty {
                    ContentUnavailableView(
                        query.isEmpty ? "No items yet" : "No matching items",
                        systemImage: "books.vertical",
                        description: Text(
                            query.isEmpty
                                ? "Items in this workspace will appear here."
                                : "Try a name, plugin, or repository."))
                } else {
                    List(rows) { row in
                        HStack(spacing: 14) {
                            Toggle(
                                "Select \(row.displayName)",
                                isOn: Binding(
                                    get: { selection.contains(row.id) },
                                    set: { if $0 { selection.insert(row.id) } else { selection.remove(row.id) } }
                                )
                            )
                            .labelsHidden().toggleStyle(.checkbox)
                            .disabled(!row.isAssignable || session.isBusy)
                            Image(systemName: row.kind.librarySymbol)
                                .font(.system(size: 21)).foregroundStyle(.secondary)
                                .frame(width: 28)
                            VStack(alignment: .leading, spacing: 4) {
                                Text(row.displayName).font(.system(size: 15, weight: .medium))
                                    .lineLimit(1)
                                HStack(spacing: 8) {
                                    Text(row.ownershipLabel)
                                    if row.childCount > 0 { Text("Includes \(row.childCount) \(row.childCount == 1 ? "tool" : "tools")") }
                                    if let source = row.sourceLabel { Text(source).lineLimit(1) }
                                }
                                .font(.system(size: 13)).foregroundStyle(.secondary)
                            }
                            Spacer(minLength: 12)
                            if !row.requestedAssignments.isEmpty {
                                Text("\(row.requestedAssignments.count) requested")
                                    .font(.system(size: 13)).foregroundStyle(.secondary)
                                    .help("Saved assignment reasons, including other devices. Installation is checked separately.")
                            }
                            Button("Details", systemImage: "info.circle") { detailID = row.id }
                                .labelStyle(.iconOnly).buttonStyle(.borderless)
                                .accessibilityLabel("Show details for \(row.displayName)")
                        }
                        .padding(.vertical, 9)
                        .help(row.assignmentExplanation ?? row.displayName)
                        .accessibilityElement(children: .contain)
                        .contextMenu {
                            Button("Show details", systemImage: "info.circle") { detailID = row.id }
                            if export != nil {
                                Button("Export…", systemImage: "square.and.arrow.up") {
                                    exporting = .init(artifactID: row.id, name: row.displayName)
                                }
                            }
                            if let authoring, row.ownership == .attachedAuthoring,
                                session.access == .writable
                            {
                                Button("Stop managing this folder", systemImage: "folder.badge.minus") {
                                    Task { await authoring.detach(row.id, named: row.displayName) }
                                }
                            }
                        }
                    }
                    .listStyle(.plain)
                }
            } else if session.isBusy {
                ProgressView("Loading library…").frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ContentUnavailableView(
                    "Library unavailable", systemImage: "books.vertical",
                    description: Text("Refresh to read this workspace again."))
            }
            Divider()
            HStack(spacing: 16) {
                Text(selection.isEmpty ? "Select items, then choose where to use them." : "\(selection.count) selected")
                    .font(.body).foregroundStyle(.secondary)
                if !selection.isEmpty {
                    Button("Clear") { selection = [] }.buttonStyle(.plain)
                }
                Spacer()
                Button("Assign…", systemImage: "arrow.turn.up.right") {
                    session.discardReview()
                    assignment = .init(artifactIDs: selection.sorted())
                }
                .buttonStyle(.glassProminent).tint(AgentTheme.selection)
                .disabled(selection.isEmpty || session.isBusy)
            }
            .padding(.horizontal, WorkspaceLayout.pageInset).padding(.vertical, 14)
        }
        .background(AgentTheme.contentBackground)
        .frame(minWidth: 720, minHeight: 480)
        .task(id: refreshID) { await session.refresh() }
        .onChange(of: session.state?.snapshot.document.revision.id) { _, _ in
            selection.formIntersection(session.state?.library.rows.filter(\.isAssignable).map(\.id) ?? [])
        }
        .sheet(item: $assignment) { presentation in
            WorkspaceAssignmentSheet(
                session: session, artifactIDs: presentation.artifactIDs,
                presetID: presentation.presetID, initialProjectID: initialProjectID)
        }
        .sheet(isPresented: Binding(get: { detailID != nil }, set: { if !$0 { detailID = nil } })) {
            if let row = session.state?.library.rows.first(where: { $0.id == detailID }) {
                WorkspaceLibraryItemDetails(row: row)
            }
        }
        .sheet(isPresented: $isAttaching) {
            if let authoring { WorkspaceAttachFolderSheet(session: authoring) }
        }
        .sheet(item: $exporting) { presentation in
            if let export {
                WorkspacePackageExportSheet(session: export, itemName: presentation.name)
                    .task { await export.prepare(presentation.artifactID) }
            }
        }
    }

    private var context: String {
        let prefix = session.access == .readOnly ? "Workspace preview" : "Workspace library"
        if let project = session.state?.library.projects.first(where: { $0.id == initialProjectID }) {
            return "\(prefix) · Choose items for \(project.name)"
        }
        return prefix
    }

    private struct ExportPresentation: Identifiable {
        let id = UUID()
        let artifactID: ArtifactID
        let name: String
    }

    private struct AssignmentPresentation: Identifiable {
        let id = UUID()
        let artifactIDs: [ArtifactID]
        var presetID: ArtifactID? = nil
    }

    enum LibraryKind: String, CaseIterable, Identifiable {
        case all = "All"
        case skills = "Skills"
        case plugins = "Plugins"
        case mcp = "MCP"
        var id: String { rawValue }
        func includes(_ kind: ArtifactKind) -> Bool {
            switch self {
            case .all: true
            case .skills: kind == .skill
            case .plugins: kind == .package || kind == .nativePlugin
            case .mcp: kind == .mcpServer
            }
        }
    }
}

private struct WorkspaceLibraryItemDetails: View {
    @Environment(\.dismiss) private var dismiss
    let row: WorkspaceLibraryReadModelRow

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Image(systemName: row.kind.librarySymbol).font(.title2).foregroundStyle(.secondary)
                Text(row.displayName).font(.title2.weight(.semibold)).lineLimit(2)
                Spacer()
                Button("Done") { dismiss() }.buttonStyle(.glass).keyboardShortcut(.cancelAction)
            }.padding(24)
            Divider()
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 20) {
                    Text(row.ownershipLabel).font(.headline)
                    if let description = row.observedDescription, !description.isEmpty {
                        Text(description).font(.body).foregroundStyle(.secondary).textSelection(.enabled)
                    }
                    if let source = row.sourceLabel { LabeledContent("Repository", value: source) }
                    if let explanation = row.assignmentExplanation { Text(explanation).foregroundStyle(.secondary) }
                    if !row.nativeRoutes.isEmpty {
                        Text("Native packages").font(.headline)
                        ForEach(row.nativeRoutes, id: \.client) { route in
                            LabeledContent(route.client.rawValue, value: route.externalPluginID)
                                .font(.body).textSelection(.enabled)
                        }
                    }
                    if !row.includedChildren.isEmpty {
                        Text("Included tools").font(.headline)
                        ForEach(row.includedChildren) { child in
                            Label(child.displayName, systemImage: child.kind.librarySymbol)
                                .font(.body).padding(.vertical, 3)
                        }
                    }
                    if !row.requestedAssignments.isEmpty {
                        Text("Requested assignments").font(.headline)
                        Text("These are saved choices. Availability is checked in each app.")
                            .font(.body).foregroundStyle(.secondary)
                        ForEach(row.requestedAssignments) { assignment in
                            VStack(alignment: .leading, spacing: 4) {
                                Text("\(assignment.destination.surface.displayName) · \(assignment.destination.scope.displayName)")
                                Text(assignment.deviceScope.libraryLabel)
                                    .font(.body).foregroundStyle(.secondary)
                            }
                        }
                    }
                }.padding(24).frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(width: 600, height: 520).background(AgentTheme.contentBackground)
    }
}

extension ArtifactKind {
    var librarySymbol: String {
        switch self {
        case .skill: "doc.text"
        case .package, .nativePlugin: "puzzlepiece.extension"
        case .mcpServer: "server.rack"
        case .preset: "square.stack"
        case .logicalProject: "folder"
        }
    }
}

extension WorkspaceLibraryReadModelRow {
    var ownershipLabel: String {
        kind == .mcpServer && ownership == .centralPersonal
            ? "Managed connection" : ownership.libraryLabel
    }
}

extension WorkspaceLibraryOwnership {
    var libraryLabel: String {
        switch self {
        case .centralPersonal: "Personal library"
        case .centralUpstream: "From a repository"
        case .nativeOwned: "Managed by its app"
        case .attachedAuthoring: "Linked authoring folder"
        case .trackedOnly: "Tracked only"
        }
    }
}

private extension WorkspaceLibraryDeviceScope {
    var libraryLabel: String {
        switch self {
        case .allEnrolledDevices: "All enrolled Macs"
        case .noDevices: "No Macs selected"
        case .thisDevice: "This Mac"
        case .thisAndOtherDevices: "This Mac and other Macs"
        case .otherDevices: "Other Macs"
        }
    }
}
