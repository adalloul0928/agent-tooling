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
    @State private var isCreatingProject = false

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
                    .disabled(workspace.library.isBusy || workspace.projectDiscovery.isScanning)
                    .help("Read the library again and look for project folders on this Mac.")
                Menu {
                    Button("Look in a folder…", systemImage: "folder.badge.gearshape") { addScanRoot() }
                    if !workspace.projectDiscovery.scanRoots.isEmpty {
                        Section("Looking in") {
                            ForEach(workspace.projectDiscovery.scanRoots, id: \.self) { root in
                                Button("Stop looking in \(abbreviated(root))") {
                                    Task { await workspace.projectDiscovery.removeScanRoot(root) }
                                }
                            }
                        }
                    }
                } label: {
                    Label("Where to look", systemImage: "binoculars")
                }
                .menuStyle(.button)
                .buttonStyle(.glass)
                .help("Besides the folders Claude Code has run in, look through these folders' children for projects.")
                Button("New project…", systemImage: "plus") { isCreatingProject = true }
                    .buttonStyle(.glass)
                    .disabled(workspace.library.access != .writable)
                    .help("Name a project, or start one from a folder on this Mac.")
            }

            if selectedProjectID == nil {
                collectionPane(projects: listed)
            } else {
                HSplitView {
                    collectionPane(projects: listed).frame(minWidth: Size.listPaneMin, idealWidth: Size.paneIdealWide)
                    VStack(spacing: 0) {
                        InspectorHeader(title: "Project details") { selectedProjectID = nil }
                        detailPane(allProjects: allProjects)
                    }.frame(minWidth: Size.detailPaneMin, idealWidth: Size.paneIdealWide)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .task(id: refreshID) {
            await workspace.library.refresh()
            await workspace.projectDiscovery.refresh()
        }
        .onChange(of: listed.map(\.id)) { _, ids in
            if let selectedProjectID, !ids.contains(selectedProjectID) {
                self.selectedProjectID = nil
            }
        }
        .onExitCommand { selectedProjectID = nil }
        .sheet(isPresented: $isCreatingProject) {
            NewProjectSheet(workspace: workspace) { refreshID = UUID() }
        }
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
            HStack(spacing: Space.xl) {
                projectFilter
                Spacer(minLength: Space.xl)
                InventorySearchField(placeholder: "Search projects", text: $query)
                    .frame(width: Size.fieldStandard)
            }
            VStack(alignment: .leading, spacing: Space.md) {
                InventorySearchField(placeholder: "Search projects", text: $query)
                HStack {
                    projectFilter
                    Spacer(minLength: 0)
                }
            }
        }
        .padding(.horizontal, WorkspaceLayout.pageInset)
        .padding(.vertical, Space.lg)
    }

    @ViewBuilder
    private func collectionBody(projects: [WorkspaceLibraryProjectReadModel]) -> some View {
        let found = query.isEmpty && filter == .all ? workspace.projectDiscovery.untrackedFolders : []
        if workspace.library.state == nil, workspace.library.isBusy {
            ProgressView("Loading projects…").frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if projects.isEmpty, found.isEmpty {
            EmptyStateView(
                symbol: "folder.badge.gearshape",
                title: emptyStateTitle,
                message: emptyStateMessage,
                actionTitle: emptyStateActionTitle,
                action: emptyStateAction
            )
        } else {
            projectList(projects, found: found)
        }
    }

    /// The workspace's projects, then the folders on this Mac it does not
    /// track yet. A found folder is a row with two possible answers: make it a
    /// project, or hand it to the project whose repository it is a checkout of.
    private func projectList(_ projects: [WorkspaceLibraryProjectReadModel], found: [WorkspaceProjectDiscoverySession.Match]) -> some View {
        List(selection: $selectedProjectID) {
            if !projects.isEmpty {
                Section {
                    ForEach(projects) { project in projectRow(project) }
                } header: {
                    if !found.isEmpty { listHeader("In your workspace", count: projects.count) }
                }
            }
            if !found.isEmpty {
                Section {
                    ForEach(found) { match in
                        DiscoveredFolderRow(
                            match: match,
                            projectName: match.projectID.flatMap { id in projects.first { $0.id == id }?.name },
                            isBusy: workspace.projectDiscovery.isBusy || workspace.library.access != .writable,
                            track: { Task { await track(match) } },
                            attach: { id in Task { await attach(match, to: id) } })
                        .collectionRowChrome(selected: false)
                    }
                } header: {
                    listHeader("Found on this Mac", count: found.count,
                               detail: workspace.projectDiscovery.lastScan == nil ? "Looking…" : nil)
                }
            }
            if let message = workspace.projectDiscovery.errorMessage {
                AttentionBanner(title: "That could not be recorded", message: message)
                    .listRowSeparator(.hidden)
            }
        }
        .collectionListChrome()
        .collectionSurface()
    }

    private func listHeader(_ title: String, count: Int, detail: String? = nil) -> some View {
        HStack(spacing: Space.md) {
            Text(title).font(AgentFont.captionMedium)
            Text("\(count)").font(AgentFont.caption).foregroundStyle(.tertiary).monospacedDigit()
            if let detail { Text("· \(detail)").font(AgentFont.caption).foregroundStyle(.tertiary) }
        }
        .foregroundStyle(.secondary)
        .textCase(nil)
    }

    private func track(_ match: WorkspaceProjectDiscoverySession.Match) async {
        if let id = await workspace.projectDiscovery.track(match.project) {
            selectedProjectID = id
        }
    }

    private func attach(_ match: WorkspaceProjectDiscoverySession.Match, to projectID: ArtifactID) async {
        if await workspace.projectDiscovery.attach(match.project, to: projectID) {
            selectedProjectID = projectID
        }
    }

    private func addScanRoot() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Look here"
        panel.message = "Agent Tooling will look through this folder's children for projects."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task { await workspace.projectDiscovery.addScanRoot(url) }
    }

    private func abbreviated(_ path: String) -> String {
        PathDisplay.abbreviatingHome(path, home: FileManager.default.homeDirectoryForCurrentUser)
    }

    private func projectRow(_ project: WorkspaceLibraryProjectReadModel) -> some View {
        ProjectCollectionRow(
            project: project,
            assignedCount: assignedCount(project.id),
            hasFolder: projectRoot(for: project.id) != nil,
            selected: selectedProjectID == project.id
        )
        .tag(project.id)
        .collectionRowChrome(selected: selectedProjectID == project.id)
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
                workspace: workspace, project: project, library: workspace.library,
                declarations: workspace.declarations, projectRoot: projectRoot(for: project.id),
                discovery: workspace.projectDiscovery)
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
        let found = workspace.projectDiscovery.untrackedFolders.count
        var parts = ["\(projects.count) in your workspace", "\(assigned) with tools assigned"]
        if found > 0 { parts.append("\(found) found on this Mac") }
        return parts.joined(separator: " · ")
    }

    private var emptyStateTitle: String {
        if !query.isEmpty { return "No matching projects" }
        if filter == .assigned { return "Nothing assigned yet" }
        return "No projects yet"
    }

    private var emptyStateMessage: String {
        if !query.isEmpty { return "Try a different search term." }
        if filter == .assigned { return "Assign a tool to a project to see it here." }
        if workspace.projectDiscovery.lastScan == nil { return "Looking for project folders on this Mac…" }
        return "No project folders were found where Claude Code has run. Create a project, or choose a folder to look in."
    }

    private var emptyStateActionTitle: String? {
        if !query.isEmpty { return "Clear search" }
        if filter == .assigned { return "Show all" }
        return workspace.library.access == .writable ? "New project…" : nil
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
        } else {
            isCreatingProject = true
        }
    }
}

// MARK: - Supporting types

private enum ProjectFilter: String, CaseIterable, Identifiable {
    case all = "All"
    case assigned = "Assigned"
    var id: String { rawValue }
}

// MARK: - Collection row

private struct ProjectCollectionRow: View {
    let project: WorkspaceLibraryProjectReadModel
    let assignedCount: Int
    let hasFolder: Bool
    let selected: Bool

    var body: some View {
        HStack(spacing: Space.lg) {
            SymbolTile(symbol: assignedCount > 0 ? "folder.badge.gearshape" : "folder", size: Size.discLarge)
                .opacity(assignedCount > 0 ? 1 : Opacity.inactive)
            VStack(alignment: .leading, spacing: Space.xxs) {
                Text(project.name)
                    .font(AgentFont.bodyMedium)
                    .foregroundStyle(selected ? AgentTheme.onSelection : Color.primary)
                    .lineLimit(1)
                HStack(spacing: Space.sm) {
                    Text(assignedCount == 1 ? "1 tool assigned" : "\(assignedCount) tools assigned")
                    if let hint = project.repositoryHints.first {
                        Text(hint).lineLimit(1).truncationMode(.middle)
                    }
                }
                .font(AgentFont.caption)
                .foregroundStyle(selected ? AgentTheme.onSelection.opacity(Opacity.secondaryOnSelection) : Color.secondary)
            }
            Spacer(minLength: Space.lg)
            StatusGlyph(state: hasFolder ? .healthy : .pending, size: Size.glyph, tint: selected ? AgentTheme.onSelection : nil)
        }
        .padding(.vertical, Space.sm)
        .help(hasFolder ? "This project has a folder on this Mac." : "This project has no folder on this Mac yet.")
        .accessibilityValue(
            "\(assignedCount == 1 ? "1 tool assigned" : "\(assignedCount) tools assigned"), \(hasFolder ? "on this Mac" : "not on this Mac")"
        )
    }
}

/// A folder the scan found that the workspace does not track here. Says what
/// is in it, and offers the one or two things that can be done with it.
private struct DiscoveredFolderRow: View {
    let match: WorkspaceProjectDiscoverySession.Match
    /// The project this folder is a checkout of, when it matches one.
    let projectName: String?
    let isBusy: Bool
    let track: () -> Void
    let attach: (ArtifactID) -> Void

    var body: some View {
        HStack(spacing: Space.lg) {
            SymbolTile(symbol: "folder.badge.questionmark", size: Size.discLarge)
                .opacity(Opacity.quiet)
            VStack(alignment: .leading, spacing: Space.xxs) {
                Text(match.project.name).font(AgentFont.bodyMedium).lineLimit(1)
                HStack(spacing: Space.sm) {
                    Text(summary).lineLimit(1)
                    if let hint = match.project.repositoryHint {
                        Text("·").foregroundStyle(.tertiary)
                        Text(hint.replacingOccurrences(of: "https://", with: "")).lineLimit(1).truncationMode(.middle)
                    }
                }
                .font(AgentFont.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: Space.lg)
            if case .matches(let projectID) = match.standing, let projectName {
                Button("Use for \(projectName)") { attach(projectID) }
                    .primaryActionStyle().controlSize(.small).disabled(isBusy)
                    .help("This folder is a checkout of \(projectName)'s repository. Make it that project's folder on this Mac.")
            }
            Button("Track") { track() }
                .secondaryActionStyle().controlSize(.small).disabled(isBusy)
                .help("Make this folder a project of its own, named after the folder.")
        }
        .padding(.vertical, Space.sm)
        .help(match.project.path)
        .accessibilityLabel("\(match.project.name), found on this Mac")
    }

    private var summary: String {
        let project = match.project
        var parts: [String] = []
        if !project.skills.isEmpty { parts.append(project.skills.count == 1 ? "1 skill" : "\(project.skills.count) skills") }
        if !project.mcpServers.isEmpty { parts.append(project.mcpServers.count == 1 ? "1 server" : "\(project.mcpServers.count) servers") }
        if !project.plugins.isEmpty { parts.append(project.plugins.count == 1 ? "1 plugin" : "\(project.plugins.count) plugins") }
        if parts.isEmpty { parts.append(project.instructionFileTitles.isEmpty ? "No agent files" : project.instructionFileTitles.joined(separator: ", ")) }
        if let branch = project.gitBranch { parts.append(project.isDetachedHead ? "at \(branch)" : "on \(branch)") }
        return parts.joined(separator: " · ")
    }
}
