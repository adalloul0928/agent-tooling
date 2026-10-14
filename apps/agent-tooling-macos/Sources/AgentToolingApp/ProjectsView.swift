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
                Button("New Project…", systemImage: "plus") { isCreatingProject = true }
                    .buttonStyle(.glass)
                    .disabled(workspace.library.access != .writable)
                    .help("Name a project, or start one from a folder on this Mac.")
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
                    .frame(width: 320)
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
        panel.prompt = "Look Here"
        panel.message = "Agent Tooling will look through this folder's children for projects."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task { await workspace.projectDiscovery.addScanRoot(url) }
    }

    private func abbreviated(_ path: String) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path(percentEncoded: false)
        return path.hasPrefix(home) ? "~" + path.dropFirst(home.count) : path
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
        if !query.isEmpty { return "Clear Search" }
        if filter == .assigned { return "Show All" }
        return workspace.library.access == .writable ? "New Project…" : nil
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
        HStack(spacing: Space.lg) {
            SymbolTile(symbol: assignedCount > 0 ? "folder.badge.gearshape" : "folder", size: Size.discLarge)
                .opacity(assignedCount > 0 ? 1 : 0.5)
            VStack(alignment: .leading, spacing: Space.xxs) {
                Text(project.name)
                    .font(AgentFont.bodyMedium)
                    .foregroundStyle(selected ? Color.white : Color.primary)
                    .lineLimit(1)
                HStack(spacing: Space.sm) {
                    Text(assignedCount == 1 ? "1 tool assigned" : "\(assignedCount) tools assigned")
                    if let hint = project.repositoryHints.first {
                        Text(hint).lineLimit(1).truncationMode(.middle)
                    }
                }
                .font(AgentFont.caption)
                .foregroundStyle(selected ? Color.white.opacity(0.78) : Color.secondary)
            }
            Spacer(minLength: Space.lg)
            StatusGlyph(state: hasFolder ? .healthy : .pending, size: Size.glyph, tint: selected ? Color.white : nil)
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
                .opacity(0.7)
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

// MARK: - Detail

private struct ProjectDetailView: View {
    let workspace: WorkspaceLaunch.Workspace
    let project: WorkspaceLibraryProjectReadModel
    let library: WorkspaceLibrarySession
    var declarations: WorkspaceProjectDeclarationSession?
    let projectRoot: URL?
    var discovery: WorkspaceProjectDiscoverySession?
    @State private var tab: ProjectDetailTab = .skills
    @State private var isAdding = false
    @State private var isDeclaring = false
    /// Filled when binding or forgetting a folder could not be recorded, so the
    /// header can say what happened instead of silently doing nothing.
    @State private var folderError: String?
    @State private var isBindingFolder = false

    var body: some View {
        VStack(spacing: 0) {
            header
            WorkspaceSegmentedPicker("Section", selection: $tab) {
                ForEach(ProjectDetailTab.allCases) { item in Text(item.rawValue).tag(item) }
            }
            .labelsHidden()
            .accessibilityLabel("Project section")
            .padding(.horizontal, Space.xxxl)
            .padding(.bottom, Space.lg)
            Hairline()

            ScrollView {
                VStack(alignment: .leading, spacing: Space.xl) {
                    componentSection(tab: tab)
                }
                .padding(Space.xxxl)
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
        VStack(alignment: .leading, spacing: Space.lg) {
            HStack(spacing: Space.xl) {
                SymbolTile(symbol: projectRoot == nil ? "folder" : "folder.badge.gearshape", size: Size.tileLarge)
                VStack(alignment: .leading, spacing: Space.xs) {
                    Text(project.name).font(AgentFont.title)
                    if let projectRoot {
                        LocationText(path: projectRoot.path).foregroundStyle(.secondary)
                    } else {
                        Text("No folder on this Mac yet").font(AgentFont.body).foregroundStyle(.secondary)
                    }
                }
                Spacer()
                folderControls
                if declarations != nil, projectRoot != nil {
                    Button("Project files…", systemImage: "doc.badge.plus") {
                        declarations?.prepare(projectID: project.id)
                        if let projectRoot { declarations?.readCommitted(projectRoot: projectRoot) }
                        isDeclaring = true
                    }
                    .secondaryActionStyle()
                    .disabled(library.isBusy || library.access != .writable)
                    .help("Write what this project asks for, and what it resolved to, into its folder.")
                }
                Button("Add tools…", systemImage: "plus") { isAdding = true }
                    .primaryActionStyle()
                    .disabled(library.isBusy)
            }

            if let folderError {
                AttentionBanner(title: "That folder was not set", message: folderError)
            }

            if projectRoot == nil {
                if let discovery, !discovery.candidates(for: project.id).isEmpty {
                    candidatesBanner(discovery.candidates(for: project.id), discovery: discovery)
                } else {
                    Text(noFolderExplanation)
                        .font(AgentFont.caption)
                        .foregroundStyle(.secondary)
                        .wrapsLines()
                }
            }

            if let message = discovery?.errorMessage {
                AttentionBanner(title: "That folder was not set", message: message)
            }

            Text(originSummary)
                .font(AgentFont.caption)
                .foregroundStyle(.secondary)
                .wrapsLines()
        }
        .padding(.horizontal, Space.xxxl)
        .padding(.top, Space.xxl)
        .padding(.bottom, Space.xl)
    }

    /// The one place a project's folder on this Mac is chosen, changed or
    /// forgotten. Offered only where the workspace can be written to, because
    /// each is a recorded change and a read-only session cannot make one.
    @ViewBuilder
    private var folderControls: some View {
        if library.access == .writable {
            if projectRoot == nil {
                Button("Choose folder…", systemImage: "folder.badge.plus") { chooseFolder() }
                    .secondaryActionStyle()
                    .disabled(isBindingFolder || library.isBusy)
                    .help("Point this project at a folder on this Mac so project-scoped tools have somewhere to install.")
            } else {
                Menu("Folder") {
                    Button("Change folder…") { chooseFolder() }
                    Button("Forget folder") { forgetFolder() }
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .disabled(isBindingFolder || library.isBusy)
                .help("Change which folder on this Mac backs this project, or forget it. Nothing on disk is deleted.")
            }
        }
    }

    /// Opens a directory picker, then records the choice on this Mac. A folder
    /// the command refuses — a symlink, a file, one another project already
    /// uses — surfaces its plain reason rather than binding anything.
    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.prompt = "Use Folder"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let path = url.standardizedFileURL.path
        isBindingFolder = true
        folderError = nil
        Task { @MainActor in
            defer { isBindingFolder = false }
            // Through discovery when it is here: the folder is read first, so a
            // checkout's repository is recorded on the project along with the
            // binding and the next Mac can recognise its own clone.
            if let discovery, let folder = ProjectDiscovery.inspect(root: url, origins: [.pinned]) {
                if !(await discovery.attach(folder, to: project.id)) {
                    folderError = discovery.errorMessage
                }
                return
            }
            do {
                guard let head = try await workspace.service.snapshot()?.document.revision.id else {
                    throw WorkspaceRevisionStoreError.notInitialized
                }
                try await workspace.service.bindProjectRoot(
                    projectID: project.id, rootPath: path, expectedRevisionID: head)
                // The header, the assignment sheet and the install plan all read
                // the binding from the library, so it has to see it now.
                await workspace.library.refresh()
            } catch let error as WorkspaceProjectRootError {
                folderError = error.localizedDescription
            } catch {
                folderError = "This Mac could not record that folder. Nothing was changed."
            }
        }
    }

    /// Removes the binding on this Mac. Nothing in the folder is touched — the
    /// project simply has no folder here again.
    private func forgetFolder() {
        isBindingFolder = true
        folderError = nil
        Task { @MainActor in
            defer { isBindingFolder = false }
            do {
                guard let head = try await workspace.service.snapshot()?.document.revision.id else {
                    throw WorkspaceRevisionStoreError.notInitialized
                }
                try await workspace.service.unbindProjectRoot(
                    projectID: project.id, expectedRevisionID: head)
                await workspace.library.refresh()
            } catch {
                folderError = "This Mac could not forget that folder. Nothing was changed."
            }
        }
    }

    /// The folders on this Mac that are checkouts of this project's repository.
    /// One is a recognition; several is a choice.
    private func candidatesBanner(_ candidates: [DiscoveredProject], discovery: WorkspaceProjectDiscoverySession) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: Space.lg) {
            StatusGlyph(state: .pending, size: Size.glyph)
            VStack(alignment: .leading, spacing: Space.xs) {
                Text(candidates.count == 1
                     ? "A checkout of this project's repository is on this Mac."
                     : "\(candidates.count) checkouts of this project's repository are on this Mac.")
                    .font(AgentFont.bodyMedium)
                ForEach(candidates) { candidate in
                    HStack(spacing: Space.md) {
                        Text(abbreviated(candidate.path)).font(AgentFont.mono).foregroundStyle(.secondary)
                            .lineLimit(1).truncationMode(.middle)
                        Spacer(minLength: Space.md)
                        Button("Use this folder") { Task { await discovery.attach(candidate, to: project.id) } }
                            .primaryActionStyle().controlSize(.small)
                            .disabled(discovery.isBusy || library.access != .writable)
                    }
                }
            }
        }
        .padding(Space.xl)
        .frame(maxWidth: .infinity, alignment: .leading)
        .standardPanel()
    }

    private var noFolderExplanation: String {
        project.repositoryHints.isEmpty
            ? "Project tools install into the folder's own app directories (for example .claude/skills). Choose the folder, or track it from the list when it is found on this Mac."
            : "This project is a checkout of \(project.repositoryHints.map { $0.replacingOccurrences(of: "https://", with: "") }.formatted(.list(type: .or))). Clone it here and it is recognised; or choose its folder."
    }

    private var originSummary: String {
        project.repositoryHints.isEmpty
            ? "A project is a name tools are assigned to. Its folder is this Mac's business and does not travel; recording the repository it comes from (track it from a checkout) is what lets another Mac recognise it."
            : "The repository travels with the project; the folder does not. Another Mac that has a checkout of the same repository recognises it as this project."
    }

    private func abbreviated(_ path: String) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path(percentEncoded: false)
        return path.hasPrefix(home) ? "~" + path.dropFirst(home.count) : path
    }

    // MARK: Component tabs

    @ViewBuilder
    private func componentSection(tab: ProjectDetailTab) -> some View {
        let local = (library.state?.library.rows(inProject: project.id) ?? []).filter { tab.kinds.contains($0.kind) }
        let inherited = (library.state?.library.globallyAssignedRows ?? []).filter { tab.kinds.contains($0.kind) }

        TitledCard("Assigned to this project", count: "\(local.count)") {
            if local.isEmpty {
                EmptyCardRow(text: "No \(tab.noun) from the library are assigned to this project. Add tools… assigns some.")
            } else {
                ComponentRows(rows: local, library: library, project: project, reviewable: tab == .mcpServers)
            }
        }

        if let folder = projectRoot.flatMap({ _ in discovery?.folder(for: project.id) }) {
            inFolderCard(folder, tab: tab)
        } else if projectRoot != nil, discovery?.lastScan == nil {
            TitledCard("In the folder") {
                EmptyCardRow(text: "Looking at what the folder holds…")
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

    /// What the folder itself holds for this kind, read from disk: the files
    /// each app reads from a checkout, whoever put them there. This is the
    /// repo's own configuration, distinct from what the library assigned.
    private func inFolderCard(_ folder: DiscoveredProject, tab: ProjectDetailTab) -> some View {
        let records: [ProjectComponentRecord] = switch tab {
        case .skills: folder.skills
        case .mcpServers: folder.mcpServers
        case .plugins: folder.plugins
        }
        let files = folder.files.filter { file in
            switch tab {
            case .skills: file.descriptor.role == .skills || file.descriptor.role == .instructions
            case .mcpServers: file.descriptor.role == .mcpDefinitions
            case .plugins: file.descriptor.role == .plugins || file.descriptor.role == .settings
            }
        }
        return TitledCard("In the folder", count: "\(records.count)") {
            if records.isEmpty, files.isEmpty {
                EmptyCardRow(text: "The folder holds no \(tab.noun) of its own. The apps use what this Mac has.")
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(records.enumerated()), id: \.element.id) { index, record in
                        HStack(spacing: Space.lg) {
                            if let client = record.client {
                                ClientBrandIcon(client: client, size: Size.tileSmall).frame(width: Size.tile, height: Size.tile)
                            } else {
                                KindTile(kind: .skill, size: Size.tileSmall)
                            }
                            VStack(alignment: .leading, spacing: Space.xxs) {
                                Text(record.name).font(AgentFont.bodyMedium)
                                Text(record.sourceRelativePath).font(AgentFont.mono).foregroundStyle(.secondary).lineLimit(1)
                            }
                            Spacer()
                            if let sharing = record.sharing {
                                StatusBadge(state: sharing == .committed ? .healthy : .pending, text: sharing.displayName)
                            }
                        }
                        .padding(.horizontal, Space.xl).frame(minHeight: Size.rowHeight)
                        if index < records.count - 1 || !files.isEmpty { Hairline(indent: Hairline.afterLeading(Size.tile)) }
                    }
                    ForEach(Array(files.filter { $0.descriptor.role != .skills || records.isEmpty }.enumerated()), id: \.element.id) { index, file in
                        HStack(spacing: Space.lg) {
                            Image(systemName: file.descriptor.isDirectory ? "folder" : "doc.text")
                                .foregroundStyle(.secondary).frame(width: Size.tile)
                            VStack(alignment: .leading, spacing: Space.xxs) {
                                Text(file.descriptor.title).font(AgentFont.bodyMedium)
                                Text(file.descriptor.relativePath).font(AgentFont.mono).foregroundStyle(.secondary).lineLimit(1)
                            }
                            Spacer()
                            StatusBadge(state: file.descriptor.sharing == .committed ? .healthy : .pending, text: file.descriptor.sharing.displayName)
                        }
                        .padding(.horizontal, Space.xl).frame(minHeight: Size.rowHeight)
                        if index < files.count - 1 { Hairline(indent: Hairline.afterLeading(Size.tile)) }
                    }
                    Hairline()
                    Text("Read from the folder. These are what the apps use in this project whether or not the library placed them; adopting them into the library is a separate step.")
                        .font(AgentFont.caption).foregroundStyle(.tertiary).wrapsLines()
                        .padding(.horizontal, Space.xl).padding(.vertical, Space.md)
                }
            }
        }
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
                    KindTile(kind: toolingKind(row.kind), size: Size.tile)
                } trailing: {
                    HStack(spacing: Space.lg) {
                        if reviewable, row.kind == .mcpServer, row.isAssignable {
                            Button("Review…") {
                                library.discardReview()
                                reviewingID = row.artifactID
                                isReviewing = true
                            }
                            .secondaryActionStyle()
                            .controlSize(.small)
                            .disabled(library.isBusy)
                        }
                        if !row.nativeRoutes.isEmpty {
                            ClientMarks(present: Set(row.nativeRoutes.map(\.client)), size: Size.brandMark)
                        }
                    }
                }
                if row.id != rows.last?.id { Hairline() }
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
            .font(AgentFont.body)
            .foregroundStyle(.secondary)
            .wrapsLines()
            .padding(.horizontal, Space.xl)
            .padding(.vertical, Space.lg)
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
            HStack(spacing: Space.lg) {
                Text("Add tools to \(project.name)").font(AgentFont.title)
                Spacer()
                InventorySearchField(placeholder: "Search library", text: $query)
                    .frame(minWidth: 180, idealWidth: 240)
            }.padding(Space.xxl)
            Hairline()
            if let library = session.state?.library {
                let rows = library.filteredRows(matching: query)
                List(rows) { row in
                    Toggle(
                        isOn: Binding(
                            get: { selection.contains(row.artifactID) },
                            set: { if $0 { selection.insert(row.artifactID) } else { selection.remove(row.artifactID) } }
                        )
                    ) {
                        VStack(alignment: .leading, spacing: Space.xxs) {
                            Text(row.displayName).font(AgentFont.bodyMedium).lineLimit(1)
                            Text(row.ownershipLabel).font(AgentFont.caption).foregroundStyle(.secondary)
                        }
                    }
                    .toggleStyle(.checkbox)
                    .disabled(!row.isAssignable || session.isBusy)
                    .help(row.assignmentExplanation ?? row.displayName)
                    .collectionRowChrome(selected: false)
                }
                .collectionListChrome()
            } else {
                ProgressView("Loading library…").frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            Hairline()
            HStack {
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Spacer()
                Text(selection.isEmpty ? "Select the tools this project needs." : "\(selection.count) selected")
                    .foregroundStyle(.secondary)
                Button("Continue") {
                    session.discardReview()
                    isReviewing = true
                }
                .primaryActionStyle()
                .disabled(selection.isEmpty || session.isBusy)
            }.padding(Space.xxl)
        }
        .sheetSize(SheetSize.large)
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
                Text("Project files for \(projectName)").font(AgentFont.title)
                Spacer()
                Button("Done") { dismiss() }.buttonStyle(.glass).keyboardShortcut(.cancelAction)
            }.padding(Space.xxl)
            Hairline()
            ScrollView {
                VStack(alignment: .leading, spacing: Space.xl) {
                    Text(
                        "Two files, written into this project's folder for you to commit. `project.json` says what this project asks for. `project-lock.json` pins what those resolved to, so a checkout later gets the same versions."
                    )
                    .foregroundStyle(.secondary)
                    if let message = session.errorMessage {
                        AttentionBanner(title: "Nothing was written", message: message)
                    }
                    if !session.writtenPaths.isEmpty {
                        VStack(alignment: .leading, spacing: Space.sm) {
                            Label("Written", systemImage: "checkmark.circle")
                                .font(AgentFont.bodyMedium)
                            ForEach(session.writtenPaths, id: \.self) { path in
                                Text(path).font(AgentFont.mono)
                                    .foregroundStyle(.secondary).textSelection(.enabled).lineLimit(2)
                            }
                        }
                    }
                    if let result = session.committed {
                        committedSummary(result)
                    } else if let message = session.committedMessage {
                        Text(message).font(AgentFont.body).foregroundStyle(.secondary)
                    }
                    if let preview = session.preview {
                        summary(preview)
                    }
                }
                .padding(Space.xxl)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            Hairline()
            HStack {
                Text("Neither file carries a path from this Mac, a time, or anything private.")
                    .font(AgentFont.body).foregroundStyle(.secondary)
                Spacer()
                Button("Write them") {
                    Task { await session.write(to: projectRoot) }
                }
                .primaryActionStyle()
                .disabled(session.isBusy || !session.canWrite || session.preview == nil)
            }.padding(Space.xxl)
        }
        .sheetSize(SheetSize.medium)
        .background(AgentTheme.contentBackground)
        .onDisappear { session.discard() }
    }

    /// What a declaration already in the folder asks for, against what this
    /// workspace holds. Nothing here installs anything.
    private func committedSummary(
        _ result: WorkspaceProjectDeclarationReconciliation.Result
    ) -> some View {
        VStack(alignment: .leading, spacing: Space.lg) {
            Text("What this project already asks for").font(AgentFont.title)
            if result.isFullySatisfied {
                Label(
                    "You have all of it, at the versions this project pins.",
                    systemImage: "checkmark.circle"
                ).foregroundStyle(.secondary)
            }
            ForEach(result.items, id: \.name) { item in
                HStack(spacing: Space.lg) {
                    Image(systemName: symbol(item.state)).foregroundStyle(.secondary)
                        .frame(width: Size.glyphSlot)
                    Text(item.name)
                    Spacer(minLength: Space.lg)
                    Text(describe(item.state)).foregroundStyle(.secondary)
                }
                .font(AgentFont.body)
            }
            Text("This only says what you have. Getting anything you are missing stays a separate, reviewed step.")
                .font(AgentFont.body).foregroundStyle(.secondary)
        }
        .padding(Space.xl)
        .standardPanel()
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
        VStack(alignment: .leading, spacing: Space.lg) {
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
                VStack(alignment: .leading, spacing: Space.xs) {
                    Label("Asked for, but not pinned", systemImage: "questionmark.circle")
                        .font(AgentFont.bodyMedium)
                    Text(preview.unlocked.formatted(.list(type: .and))).foregroundStyle(.secondary)
                    Text(
                        "These have no exact version behind them, so a lock line for one could not bring back the same files. They are in the declaration and left out of the lock."
                    )
                    .font(AgentFont.body).foregroundStyle(.secondary)
                }
            }
        }
        .padding(Space.xl)
        .standardPanel()
    }
}


/// Names a project and nothing else. The same footer discipline as every
/// sheet: the primary action is pinned and never moves.
private struct NewProjectSheet: View {
    let workspace: WorkspaceLaunch.Workspace
    let onCreated: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var errorMessage: String?
    @State private var isBusy = false
    /// A folder on this Mac the project starts from: it names the project,
    /// its repository travels with it, and it is bound here at once.
    @State private var folder: DiscoveredProject?
    @FocusState private var nameFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("New project").font(AgentFont.title)
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction).buttonStyle(.glass).keyboardShortcut(.cancelAction)
            }
            .padding(Space.xxl)
            Hairline()
            VStack(alignment: .leading, spacing: Space.xl) {
                Text(
                    "A project is a name your tools are assigned to; Install puts them into the project's folder for each app. Starting from a folder records which repository it is, so another Mac with the same checkout recognises it."
                )
                .foregroundStyle(.secondary)
                .wrapsLines()

                if let errorMessage {
                    AttentionBanner(title: "That project was not created", message: errorMessage)
                }

                VStack(alignment: .leading, spacing: Space.lg) {
                    LabeledContent("Name") {
                        TextField("My service", text: $name)
                            .textFieldStyle(.roundedBorder).frame(maxWidth: 300)
                            .focused($nameFocused)
                            .onSubmit { if canCreate { create() } }
                    }
                    LabeledContent("Folder") {
                        HStack(spacing: Space.md) {
                            if let folder {
                                VStack(alignment: .leading, spacing: Space.xxs) {
                                    Text(folder.path).font(AgentFont.mono).lineLimit(1).truncationMode(.middle)
                                    if let hint = folder.repositoryHint {
                                        Text(hint.replacingOccurrences(of: "https://", with: ""))
                                            .font(AgentFont.caption).foregroundStyle(.secondary).lineLimit(1)
                                    } else {
                                        Text("Not a Git checkout with a remote; the folder is bound on this Mac only.")
                                            .font(AgentFont.caption).foregroundStyle(.secondary).wrapsLines()
                                    }
                                }
                                Button("Change…") { chooseFolder() }.inlineActionStyle()
                            } else {
                                Button("Choose…", systemImage: "folder") { chooseFolder() }.secondaryActionStyle()
                                Text("Optional. Names the project after the folder and binds it on this Mac.")
                                    .font(AgentFont.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                .padding(Space.xl)
                .standardPanel()
            }
            .padding(Space.xxl)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)

            Hairline()
            HStack {
                Spacer()
                Button("Create Project") { create() }
                    .primaryActionStyle()
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canCreate)
            }
            .padding(.horizontal, Space.xxl)
            .padding(.vertical, Space.xl)
        }
        .sheetSize(SheetSize.medium)
        .background(AgentTheme.contentBackground)
        .onAppear { nameFocused = true }
    }

    private var canCreate: Bool {
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !isBusy
            && workspace.library.access == .writable
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Use Folder"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        guard ProjectDiscovery.isEligibleProjectRoot(url, homeURL: workspace.homeRoot) else {
            errorMessage = "Your home folder is where this Mac's own skills and servers live. Choose a project folder inside it."
            return
        }
        folder = ProjectDiscovery.inspect(root: url, origins: [.pinned])
        if let folder, name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { name = folder.name }
    }

    private func create() {
        guard canCreate else { return }
        isBusy = true
        errorMessage = nil
        Task { @MainActor in
            defer { isBusy = false }
            if let folder {
                // The same recorded steps the list's Track button runs.
                if await workspace.projectDiscovery.track(folder, named: name) != nil {
                    onCreated()
                    dismiss()
                } else {
                    errorMessage = workspace.projectDiscovery.errorMessage
                }
                return
            }
            do {
                guard let head = try await workspace.service.snapshot()?.document.revision.id else {
                    throw WorkspaceRevisionStoreError.notInitialized
                }
                _ = try await workspace.service.createProject(
                    .init(expectedRevisionID: head, name: name))
                await workspace.library.refresh()
                onCreated()
                dismiss()
            } catch WorkspaceDomainValidationError.duplicate {
                errorMessage = "A project with this name already exists. Names tell projects apart, so each needs its own."
            } catch {
                errorMessage = "This workspace could not record the project. Nothing was changed."
            }
        }
    }
}
