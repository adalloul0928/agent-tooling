import AgentToolingCore
import SwiftUI

/// Projects: the list, and one project opened beside it — the same
/// master-detail shape Plugins and the Library use.
///
/// Projects are discovered by assignment, never registered by hand: there is
/// no versioned command yet to add or forget one, so a project simply appears
/// once something is assigned to it. Folder roots stay device-local; a
/// project's shared identity is its name and repository hints, never a path.
struct ProjectsView: View {
    let workspace: WorkspaceLaunch.Workspace
    @State private var query = ""
    @State private var filter: ProjectFilter = .all
    @State private var selectedProjectID: ArtifactID?
    @State private var refreshID = UUID()

    /// `initialSelection` opens straight to one project's detail pane. Nothing
    /// in the shell deep-links here today — this section has no external
    /// route of its own — so the only caller today is a render test proving
    /// the detail pane draws; a future route can reuse the same seam.
    init(workspace: WorkspaceLaunch.Workspace, initialSelection: ArtifactID? = nil) {
        self.workspace = workspace
        _selectedProjectID = State(initialValue: initialSelection)
    }

    var body: some View {
        let allProjects = workspace.library.state?.library.projects ?? []
        let listed = filtered(allProjects)

        VStack(spacing: 0) {
            PageToolbar(title: "Projects", context: toolbarContext(allProjects)) {
                Button("Refresh", systemImage: "arrow.clockwise") { refreshID = UUID() }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.glass)
                    .disabled(workspace.library.isBusy)
            }

            if selectedProjectID == nil {
                collectionPane(projects: listed)
            } else {
                HSplitView {
                    collectionPane(projects: listed).frame(minWidth: 320, idealWidth: 600)
                    VStack(spacing: 0) {
                        InspectorHeader(title: "Project details") { selectedProjectID = nil }
                        detailPane(allProjects: allProjects)
                    }.frame(minWidth: 400, idealWidth: 600)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .task(id: refreshID) { await workspace.library.refresh() }
        .onChange(of: listed.map(\.id)) { _, ids in
            if let selectedProjectID, !ids.contains(selectedProjectID) {
                self.selectedProjectID = nil
            }
        }
        .onExitCommand { selectedProjectID = nil }
    }

    // MARK: Collection

    private func collectionPane(projects: [WorkspaceLibraryProjectReadModel]) -> some View {
        VStack(spacing: 0) {
            collectionFilterBar
            collectionBody(projects: projects)
        }
        .paneMaterial()
    }

    private var collectionFilterBar: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 16) {
                projectFilter
                Spacer(minLength: 16)
                InventorySearchField(placeholder: "Search projects", text: $query)
                    .frame(width: 320)
            }
            VStack(alignment: .leading, spacing: 9) {
                InventorySearchField(placeholder: "Search projects", text: $query)
                HStack {
                    projectFilter
                    Spacer(minLength: 0)
                }
            }
        }
        .padding(.horizontal, WorkspaceLayout.pageInset)
        .padding(.vertical, 10)
    }

    @ViewBuilder
    private func collectionBody(projects: [WorkspaceLibraryProjectReadModel]) -> some View {
        if workspace.library.state == nil, workspace.library.isBusy {
            ProgressView("Loading projects…").frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if projects.isEmpty {
            EmptyStateView(
                symbol: "folder.badge.gearshape",
                title: emptyStateTitle,
                message: emptyStateMessage,
                actionTitle: emptyStateActionTitle,
                action: emptyStateAction
            )
        } else {
            projectList(projects)
        }
    }

    private func projectList(_ projects: [WorkspaceLibraryProjectReadModel]) -> some View {
        List(projects, selection: $selectedProjectID) { project in
            projectRow(project)
        }
        .listStyle(.inset)
        .scrollContentBackground(.hidden)
    }

    private func projectRow(_ project: WorkspaceLibraryProjectReadModel) -> some View {
        ProjectCollectionRow(
            project: project,
            assignedCount: assignedCount(project.id),
            hasFolder: projectRoot(for: project.id) != nil,
            selected: selectedProjectID == project.id
        )
        .tag(project.id)
        .listRowBackground(SelectionRowBackground(selected: selectedProjectID == project.id))
        .accessibilityLabel(project.name)
    }

    private var projectFilter: some View {
        WorkspaceSegmentedPicker("Show", selection: $filter) {
            ForEach(ProjectFilter.allCases) { item in Text(item.rawValue).tag(item) }
        }
        .accessibilityLabel("Project filter")
        .fixedSize()
    }

    @ViewBuilder
    private func detailPane(allProjects: [WorkspaceLibraryProjectReadModel]) -> some View {
        if let id = selectedProjectID, let project = allProjects.first(where: { $0.id == id }) {
            ProjectDetailView(
                project: project, library: workspace.library, declarations: workspace.declarations,
                projectRoot: projectRoot(for: project.id))
        } else {
            EmptyStateView(
                symbol: "folder.badge.gearshape",
                title: "Select a project",
                message:
                    "See which skills, connections, and plugins a project keeps for itself, and which it inherits from this Mac.")
        }
    }

    // MARK: Data

    private func filtered(_ projects: [WorkspaceLibraryProjectReadModel]) -> [WorkspaceLibraryProjectReadModel] {
        projects.filter { project in
            let matchesFilter = filter == .all || assignedCount(project.id) > 0
            let searchable = ([project.name] + project.repositoryHints).joined(separator: " ")
            return matchesFilter && (query.isEmpty || searchable.localizedCaseInsensitiveContains(query))
        }
    }

    private func assignedCount(_ projectID: ArtifactID) -> Int {
        workspace.library.state?.library.assignedItemCount(inProject: projectID) ?? 0
    }

    /// This project's folder on this Mac, when it has one. Without it there is
    /// nowhere to write a declaration, and the offer is not made.
    private func projectRoot(for projectID: ArtifactID) -> URL? {
        workspace.library.state?.snapshot.device.projectRoots?
            .first { $0.projectID == projectID }
            .map { URL(fileURLWithPath: $0.rootPath) }
    }

    private func toolbarContext(_ projects: [WorkspaceLibraryProjectReadModel]) -> String {
        let assigned = projects.filter { assignedCount($0.id) > 0 }.count
        return "\(projects.count) found · \(assigned) with tools assigned"
    }

    private var emptyStateTitle: String {
        if !query.isEmpty { return "No matching projects" }
        if filter == .assigned { return "Nothing assigned yet" }
        return "No projects yet"
    }

    private var emptyStateMessage: String {
        if !query.isEmpty { return "Try a different search term." }
        if filter == .assigned { return "Assign a tool to a project to see it here." }
        return "Projects appear here once a tool is assigned to one."
    }

    private var emptyStateActionTitle: String? {
        if !query.isEmpty { return "Clear Search" }
        if filter == .assigned { return "Show All" }
        return nil
    }

    private var emptyStateAction: (() -> Void)? {
        guard emptyStateActionTitle != nil else { return nil }
        return performEmptyStateAction
    }

    private func performEmptyStateAction() {
        if !query.isEmpty {
            query = ""
        } else if filter == .assigned {
            filter = .all
        }
    }
}

// MARK: - Supporting types

private enum ProjectFilter: String, CaseIterable, Identifiable {
    case all = "All"
    case assigned = "Assigned"
    var id: String { rawValue }
}

private enum ProjectDetailTab: String, CaseIterable, Identifiable {
    case skills = "Skills"
    case mcpServers = "Connections"
    case plugins = "Plugins"
    var id: String { rawValue }

    /// Plugins covers both a native discovery and a centrally tracked
    /// package; every other tab is exactly one artifact kind.
    var kinds: Set<ArtifactKind> {
        switch self {
        case .skills: [.skill]
        case .mcpServers: [.mcpServer]
        case .plugins: [.nativePlugin, .package]
        }
    }

    var noun: String {
        switch self {
        case .skills: "skills"
        case .mcpServers: "connections"
        case .plugins: "plugins"
        }
    }

    var caption: String {
        switch self {
        case .skills:
            "A project skill lives in a selected client's skill folder inside the repository and hides a skill of the same name installed on this Mac. Create and edit skills in the Skills tab."
        case .mcpServers:
            "Project MCP servers come from files inside the repository. Adding or reviewing one still goes through a reviewed assignment, scoped to this project."
        case .plugins:
            "A project enables plugins in its own settings file. Installing a plugin remains a client-level action reviewed on the Install screen."
        }
    }
}

// MARK: - Collection row

private struct ProjectCollectionRow: View {
    let project: WorkspaceLibraryProjectReadModel
    let assignedCount: Int
    let hasFolder: Bool
    let selected: Bool

    var body: some View {
        HStack(spacing: 11) {
            SymbolTile(symbol: assignedCount > 0 ? "folder.badge.gearshape" : "folder", size: 28)
                .opacity(assignedCount > 0 ? 1 : 0.5)
            VStack(alignment: .leading, spacing: 3) {
                Text(project.name)
                    .font(.callout.weight(.medium))
                    .foregroundStyle(selected ? Color.white : Color.primary)
                    .lineLimit(1)
                HStack(spacing: 6) {
                    Text(assignedCount == 1 ? "1 tool assigned" : "\(assignedCount) tools assigned")
                    if let hint = project.repositoryHints.first {
                        Text(hint).lineLimit(1).truncationMode(.middle)
                    }
                }
                .font(.caption)
                .foregroundStyle(selected ? Color.white.opacity(0.78) : Color.secondary)
            }
            Spacer(minLength: 12)
            StatusGlyph(state: hasFolder ? .healthy : .pending, size: 13, tint: selected ? Color.white : nil)
        }
        .padding(.vertical, 6)
        .help(hasFolder ? "This project has a folder on this Mac." : "This project has no folder on this Mac yet.")
        .accessibilityValue(
            "\(assignedCount == 1 ? "1 tool assigned" : "\(assignedCount) tools assigned"), \(hasFolder ? "on this Mac" : "not on this Mac")"
        )
    }
}

// MARK: - Detail

private struct ProjectDetailView: View {
    let project: WorkspaceLibraryProjectReadModel
    let library: WorkspaceLibrarySession
    var declarations: WorkspaceProjectDeclarationSession?
    let projectRoot: URL?
    @State private var tab: ProjectDetailTab = .skills
    @State private var isAdding = false
    @State private var isDeclaring = false

    var body: some View {
        VStack(spacing: 0) {
            header
            WorkspaceSegmentedPicker("Section", selection: $tab) {
                ForEach(ProjectDetailTab.allCases) { item in Text(item.rawValue).tag(item) }
            }
            .labelsHidden()
            .accessibilityLabel("Project section")
            .padding(.horizontal, 22)
            .padding(.bottom, 12)
            Divider().opacity(0.4)

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    componentSection(tab: tab)
                }
                .padding(22)
            }
        }
        .sheet(isPresented: $isAdding) {
            WorkspaceProjectAddSheet(session: library, project: project)
        }
        .sheet(isPresented: $isDeclaring) {
            if let declarations, let projectRoot {
                WorkspaceProjectDeclarationSheet(session: declarations, projectRoot: projectRoot, projectName: project.name)
            }
        }
    }

    // MARK: Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 14) {
                SymbolTile(symbol: projectRoot == nil ? "folder" : "folder.badge.gearshape", size: 40)
                VStack(alignment: .leading, spacing: 4) {
                    Text(project.name).font(.title3.weight(.semibold))
                    if let projectRoot {
                        LocationText(path: projectRoot.path).foregroundStyle(.secondary)
                    } else {
                        Text("No folder on this Mac yet").font(.callout).foregroundStyle(.secondary)
                    }
                }
                Spacer()
                if declarations != nil, projectRoot != nil {
                    Button("Project files…", systemImage: "doc.badge.plus") {
                        declarations?.prepare(projectID: project.id)
                        if let projectRoot { declarations?.readCommitted(projectRoot: projectRoot) }
                        isDeclaring = true
                    }
                    .buttonStyle(.bordered)
                    .disabled(library.isBusy || library.access != .writable)
                    .help("Write what this project asks for, and what it resolved to, into its folder.")
                }
                Button("Add tools…", systemImage: "plus") { isAdding = true }
                    .buttonStyle(.borderedProminent)
                    .tint(AgentTheme.selection)
                    .disabled(library.isBusy)
            }

            Text(originSummary)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 22)
        .padding(.top, 18)
        .padding(.bottom, 14)
    }

    private var originSummary: String {
        "Appears because a tool was assigned to it. Project folders do not travel: they are stripped on export, so a project-scoped item restored on a second Mac arrives unattached and has to be pointed at a folder there."
    }

    // MARK: Component tabs

    @ViewBuilder
    private func componentSection(tab: ProjectDetailTab) -> some View {
        let local = (library.state?.library.rows(inProject: project.id) ?? []).filter { tab.kinds.contains($0.kind) }
        let inherited = (library.state?.library.globallyAssignedRows ?? []).filter { tab.kinds.contains($0.kind) }

        TitledCard("In this project", count: "\(local.count)") {
            if local.isEmpty {
                EmptyCardRow(
                    text: inherited.isEmpty
                        ? "This project has no \(tab.noun) of its own."
                        : "This project has no \(tab.noun) of its own. Everything below comes from this Mac.")
            } else {
                ComponentRows(rows: local, library: library, project: project, reviewable: tab == .mcpServers)
            }
        }

        TitledCard("Inherited from this Mac", count: "\(inherited.count)") {
            if inherited.isEmpty {
                EmptyCardRow(text: "No \(tab.noun) are assigned outside a project.")
            } else {
                ComponentRows(rows: inherited, library: library, project: project, reviewable: false)
            }
        }

        SectionCaption(text: tab.caption)
    }
}

// MARK: - Rows

/// One kind's rows for a project, local or inherited. Only a local MCP server
/// row offers a project-scoped review: that is the one place this screen
/// still lets someone open the shared assignment sheet, prefilled with this
/// project, rather than only reading what is already saved.
private struct ComponentRows: View {
    let rows: [WorkspaceLibraryReadModelRow]
    let library: WorkspaceLibrarySession
    let project: WorkspaceLibraryProjectReadModel
    let reviewable: Bool
    @State private var reviewingID: ArtifactID?
    @State private var isReviewing = false

    var body: some View {
        LazyVStack(spacing: 0) {
            ForEach(rows) { row in
                InfoRow(row.displayName, detail: detail(for: row)) {
                    KindTile(kind: toolingKind(row.kind), size: 26)
                } trailing: {
                    HStack(spacing: 10) {
                        if reviewable, row.kind == .mcpServer, row.isAssignable {
                            Button("Review…") {
                                library.discardReview()
                                reviewingID = row.artifactID
                                isReviewing = true
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                            .disabled(library.isBusy)
                        }
                        if !row.nativeRoutes.isEmpty {
                            ClientMarks(present: Set(row.nativeRoutes.map(\.client)), size: 12)
                        }
                    }
                }
                if row.id != rows.last?.id { Divider().opacity(0.45) }
            }
        }
        .sheet(isPresented: $isReviewing) {
            if let reviewingID {
                WorkspaceAssignmentSheet(session: library, artifactIDs: [reviewingID], initialProjectID: project.id)
            }
        }
    }

    private func detail(for row: WorkspaceLibraryReadModelRow) -> String {
        row.childCount > 0
            ? "\(row.ownershipLabel) · Includes \(row.childCount) \(row.childCount == 1 ? "tool" : "tools")"
            : row.ownershipLabel
    }

    private func toolingKind(_ kind: ArtifactKind) -> ToolingKind {
        switch kind {
        case .skill: .skill
        case .mcpServer: .mcpServer
        case .package, .nativePlugin: .plugin
        case .preset: .profile
        case .logicalProject: .library
        }
    }
}

private struct EmptyCardRow: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.callout)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Add tools

/// Selecting items for one project. The browser and the review are the shared
/// ones; only the destination context is prefilled.
private struct WorkspaceProjectAddSheet: View {
    let session: WorkspaceLibrarySession
    let project: WorkspaceLibraryProjectReadModel
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var selection: Set<ArtifactID> = []
    @State private var isReviewing = false

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Text("Add tools to \(project.name)").font(.title3.weight(.semibold))
                Spacer()
                InventorySearchField(placeholder: "Search library", text: $query)
                    .frame(minWidth: 180, idealWidth: 240)
            }.padding(20)
            Divider()
            if let library = session.state?.library {
                let rows = library.filteredRows(matching: query)
                List(rows) { row in
                    Toggle(
                        isOn: Binding(
                            get: { selection.contains(row.artifactID) },
                            set: { if $0 { selection.insert(row.artifactID) } else { selection.remove(row.artifactID) } }
                        )
                    ) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(row.displayName).lineLimit(1)
                            Text(row.ownershipLabel).font(.system(size: 13)).foregroundStyle(.secondary)
                        }
                    }
                    .toggleStyle(.checkbox)
                    .disabled(!row.isAssignable || session.isBusy)
                    .help(row.assignmentExplanation ?? row.displayName)
                }
                .listStyle(.plain)
            } else {
                ProgressView("Loading library…").frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            Divider()
            HStack {
                Button("Cancel") { dismiss() }
                Spacer()
                Text(selection.isEmpty ? "Select the tools this project needs." : "\(selection.count) selected")
                    .foregroundStyle(.secondary)
                Button("Continue") {
                    session.discardReview()
                    isReviewing = true
                }
                .buttonStyle(.borderedProminent)
                .disabled(selection.isEmpty || session.isBusy)
            }.padding(20)
        }
        .frame(width: 720, height: 560)
        .sheet(
            isPresented: $isReviewing, onDismiss: { dismiss() },
            content: {
                WorkspaceAssignmentSheet(
                    session: session, artifactIDs: selection.sorted(),
                    initialProjectID: project.id)
            })
    }
}

// MARK: - Declarations and locks

/// Writing a project's declaration and lock into its folder.
///
/// Both files are shown before anything is written, because they are meant to
/// be committed and read by other people.
private struct WorkspaceProjectDeclarationSheet: View {
    let session: WorkspaceProjectDeclarationSession
    let projectRoot: URL
    let projectName: String
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Project files for \(projectName)").font(.title3.weight(.semibold))
                Spacer()
                Button("Done") { dismiss() }.buttonStyle(.glass).keyboardShortcut(.cancelAction)
            }.padding(20)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text(
                        "Two files, written into this project's folder for you to commit. `project.json` says what this project asks for. `project-lock.json` pins what those resolved to, so a checkout later gets the same versions."
                    )
                    .foregroundStyle(.secondary)
                    if let message = session.errorMessage {
                        AttentionBanner(title: "Nothing was written", message: message)
                    }
                    if !session.writtenPaths.isEmpty {
                        VStack(alignment: .leading, spacing: 6) {
                            Label("Written", systemImage: "checkmark.circle")
                                .font(.system(size: 14, weight: .medium))
                            ForEach(session.writtenPaths, id: \.self) { path in
                                Text(path).font(.system(size: 12, design: .monospaced))
                                    .foregroundStyle(.secondary).textSelection(.enabled).lineLimit(2)
                            }
                        }
                    }
                    if let result = session.committed {
                        committedSummary(result)
                    } else if let message = session.committedMessage {
                        Text(message).font(.callout).foregroundStyle(.secondary)
                    }
                    if let preview = session.preview {
                        summary(preview)
                    }
                }
                .padding(20)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            Divider()
            HStack {
                Text("Neither file carries a path from this Mac, a time, or anything private.")
                    .font(.callout).foregroundStyle(.secondary)
                Spacer()
                Button("Write them") {
                    Task { await session.write(to: projectRoot) }
                }
                .buttonStyle(.borderedProminent)
                .disabled(session.isBusy || !session.canWrite || session.preview == nil)
            }.padding(20)
        }
        .frame(width: 640, height: 520)
        .background(AgentTheme.contentBackground)
        .onDisappear { session.discard() }
    }

    /// What a declaration already in the folder asks for, against what this
    /// workspace holds. Nothing here installs anything.
    private func committedSummary(
        _ result: WorkspaceProjectDeclarationReconciliation.Result
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("What this project already asks for").font(.system(size: 15, weight: .medium))
            if result.isFullySatisfied {
                Label(
                    "You have all of it, at the versions this project pins.",
                    systemImage: "checkmark.circle"
                ).foregroundStyle(.secondary)
            }
            ForEach(result.items, id: \.name) { item in
                HStack(spacing: 10) {
                    Image(systemName: symbol(item.state)).foregroundStyle(.secondary)
                        .frame(width: 18)
                    Text(item.name)
                    Spacer(minLength: 12)
                    Text(describe(item.state)).foregroundStyle(.secondary)
                }
                .font(.callout)
            }
            Text("This only says what you have. Getting anything you are missing stays a separate, reviewed step.")
                .font(.callout).foregroundStyle(.secondary)
        }
        .padding(16)
        .standardPanel(cornerRadius: 12)
    }

    private func symbol(_ state: WorkspaceProjectDeclarationReconciliation.State) -> String {
        switch state {
        case .matchesLock: "checkmark.circle"
        case .differsFromLock: "arrow.triangle.2.circlepath"
        case .heldUnpinned: "questionmark.circle"
        case .missing: "minus.circle"
        }
    }

    private func describe(_ state: WorkspaceProjectDeclarationReconciliation.State) -> String {
        switch state {
        case .matchesLock: "You have this version"
        case .differsFromLock: "You have a different version"
        case .heldUnpinned: "You have it; no version pinned"
        case .missing: "You do not have this"
        }
    }

    private func summary(_ preview: WorkspaceProjectDeclarationSession.Preview) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            LabeledContent("Asked for") {
                Text(
                    preview.declaration.entries.isEmpty
                        ? "Nothing yet"
                        : preview.declaration.entries.map(\.name).formatted(.list(type: .and))
                )
                .multilineTextAlignment(.trailing)
            }
            LabeledContent("Pinned") {
                Text(
                    preview.lock.map { $0.entries.count == 1 ? "1 version" : "\($0.entries.count) versions" }
                        ?? "None")
            }
            if !preview.unlocked.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Label("Asked for, but not pinned", systemImage: "questionmark.circle")
                        .font(.system(size: 14, weight: .medium))
                    Text(preview.unlocked.formatted(.list(type: .and))).foregroundStyle(.secondary)
                    Text(
                        "These have no exact version behind them, so a lock line for one could not bring back the same files. They are in the declaration and left out of the lock."
                    )
                    .font(.callout).foregroundStyle(.secondary)
                }
            }
        }
        .padding(16)
        .standardPanel(cornerRadius: 12)
    }
}
