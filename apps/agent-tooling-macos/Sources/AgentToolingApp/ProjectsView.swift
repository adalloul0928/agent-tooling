import AgentToolingCore
import AppKit
import SwiftUI

/// Projects are discovered, never registered. The screen keeps the same
/// master–detail shape as Skills and MCP Servers, and the detail pane mirrors
/// the global sections so nothing here has to be learned twice.
struct ProjectsView: View {
    @Environment(AppModel.self) private var model
    @State private var query = ""
    @State private var filter: ProjectFilter = .all
    @State private var selectedPath = ""
    @State private var tab: ProjectDetailTab = .skills
    @State private var ignoreReview: ProjectIgnoreReview?

    var body: some View {
        VStack(spacing: 0) {
            PageToolbar(title: "Projects", context: toolbarContext) {
                Menu {
                    Button("Scan a folder…") { chooseScanRoot() }
                    if !model.projectScanRoots.isEmpty {
                        Divider()
                        ForEach(model.projectScanRoots, id: \.self) { root in
                            Button("Stop scanning \(LocationText.shortName(for: root))") {
                                Task { await model.removeProjectScanRoot(root) }
                            }
                        }
                    }
                } label: {
                    Label("Scan…", systemImage: "folder.badge.questionmark")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .accessibilityLabel("Scan a folder for projects")

                Button {
                    Task { await model.discoverProjects(force: true) }
                } label: {
                    Label("Rescan", systemImage: "arrow.clockwise")
                }
                .buttonStyle(.bordered)
                .disabled(model.isDiscoveringProjects)

                Button {
                    chooseProjectFolder()
                } label: {
                    Label("Add project…", systemImage: "plus")
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut("n", modifiers: .command)
            }

            GeometryReader { proxy in
                HSplitView {
                    collectionPane
                        .frame(
                            minWidth: 340, idealWidth: 410, maxWidth: 520, minHeight: proxy.size.height, maxHeight: proxy.size.height,
                            alignment: .topLeading)
                    detailPane
                        .frame(
                            minWidth: 540, maxWidth: .infinity, minHeight: proxy.size.height, maxHeight: proxy.size.height,
                            alignment: .topLeading)
                }
                .frame(width: proxy.size.width, height: proxy.size.height, alignment: .topLeading)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .task { await model.discoverProjects() }
        .sheet(item: $ignoreReview) { review in
            ProjectIgnoreReviewSheet(plan: review.plan) { model.applyProjectIgnorePlan(review.plan) }
        }
        .onChange(of: model.projects) { _, _ in selectFirstVisibleProjectIfNeeded() }
        .onChange(of: filteredProjects.map(\.id)) { _, _ in selectFirstVisibleProjectIfNeeded() }
    }

    // MARK: Collection

    private var collectionPane: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                TextField("Search projects", text: $query)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityLabel("Search projects")
                Picker("Show", selection: $filter) {
                    ForEach(ProjectFilter.allCases) { item in Text(item.rawValue).tag(item) }
                }
                .labelsHidden()
                .accessibilityLabel("Project filter")
                .pickerStyle(.segmented)
                .frame(width: 196)
            }
            .padding(12)

            if filteredProjects.isEmpty {
                EmptyStateView(
                    symbol: "folder.badge.gearshape",
                    title: emptyStateTitle,
                    message: emptyStateMessage,
                    actionTitle: emptyStateActionTitle,
                    isActionEnabled: !model.isDiscoveringProjects,
                    action: performEmptyStateAction
                )
            } else {
                List(filteredProjects, selection: $selectedPath) { project in
                    ProjectCollectionRow(project: project, selected: selectedPath == project.path)
                        .tag(project.path)
                        .listRowBackground(SelectionRowBackground(selected: selectedPath == project.path))
                        .accessibilityLabel(project.name)
                        .accessibilityValue(project.isPlain ? "No project configuration" : project.badges.joined(separator: ", "))
                }
                .listStyle(.inset)
                .scrollContentBackground(.hidden)
            }
        }
        .paneMaterial()
    }

    @ViewBuilder
    private var detailPane: some View {
        if let project = selectedProject {
            ProjectDetailView(project: project, tab: $tab, onReviewIgnore: presentIgnoreReview)
                .environment(model)
        } else {
            EmptyStateView(
                symbol: "folder.badge.gearshape",
                title: "Select a project",
                message:
                    "See which skills, MCP servers, and plugins a project inherits from this Mac, which ones it replaces, and which of its settings files are shared with the repository."
            )
        }
    }

    // MARK: Data

    private var filteredProjects: [DiscoveredProject] {
        model.projects.filter { project in
            let matchesFilter =
                switch filter {
                case .all: true
                case .configured: !project.isPlain
                case .pinned: project.isPinned
                }
            let searchable = ([project.name, project.path, project.gitBranch ?? ""] + project.badges).joined(separator: " ")
            return matchesFilter && (query.isEmpty || searchable.localizedCaseInsensitiveContains(query))
        }
    }

    private var selectedProject: DiscoveredProject? { model.projects.first { $0.path == selectedPath } }

    private var toolbarContext: String {
        if model.isDiscoveringProjects { return "Looking for projects on this Mac…" }
        let configured = model.projects.filter { !$0.isPlain }.count
        let pinned = model.projects.filter(\.isPinned).count
        var parts = ["\(model.projects.count) found", "\(configured) configured"]
        if pinned > 0 { parts.append("\(pinned) pinned") }
        return parts.joined(separator: " · ")
    }

    private func selectFirstVisibleProjectIfNeeded() {
        guard !filteredProjects.contains(where: { $0.path == selectedPath }) else { return }
        selectedPath = filteredProjects.first?.path ?? ""
    }

    private var emptyStateTitle: String {
        if !query.isEmpty { return "No matching projects" }
        if filter != .all { return filter == .pinned ? "Nothing pinned yet" : "No configured projects" }
        return "No projects yet"
    }

    private var emptyStateMessage: String {
        if !query.isEmpty { return "Try a different search term." }
        if filter == .pinned {
            return "Pin a project to keep it here even when Claude Code has not run in it recently."
        }
        if filter == .configured {
            return "None of the projects found on this Mac has its own skills, MCP servers, plugins, or instruction file yet."
        }
        return
            "Agent Tooling lists the folders Claude Code has already run in, plus any folder you add or scan. Project roots do not travel: they are stripped on export by design, so a project-scoped skill restored on a second Mac arrives unattached and has to be pointed at a folder there."
    }

    private var emptyStateActionTitle: String {
        if !query.isEmpty { return "Clear Search" }
        if filter != .all { return "Show All" }
        return "Add Project…"
    }

    private func performEmptyStateAction() {
        if !query.isEmpty {
            query = ""
        } else if filter != .all {
            filter = .all
        } else {
            chooseProjectFolder()
        }
    }

    // MARK: Actions

    private func presentIgnoreReview(_ project: DiscoveredProject) {
        guard let plan = model.projectIgnorePlan(for: project), !plan.isSatisfied else { return }
        ignoreReview = ProjectIgnoreReview(plan: plan)
    }

    private func chooseProjectFolder() {
        guard let url = chooseFolder(title: "Choose a project folder", prompt: "Add") else { return }
        Task {
            await model.addProject(at: url)
            selectedPath = ProjectPath.canonical(url)
        }
    }

    private func chooseScanRoot() {
        guard let url = chooseFolder(title: "Choose a folder that holds projects", prompt: "Scan") else { return }
        Task { await model.addProjectScanRoot(at: url) }
    }

    private func chooseFolder(title: String, prompt: String) -> URL? {
        let panel = NSOpenPanel()
        panel.title = title
        panel.prompt = prompt
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = false
        guard panel.runModal() == .OK else { return nil }
        return panel.url?.standardizedFileURL
    }
}

// MARK: - Supporting types

private enum ProjectFilter: String, CaseIterable, Identifiable {
    case all = "All"
    case configured = "Configured"
    case pinned = "Pinned"
    var id: String { rawValue }
}

private enum ProjectDetailTab: String, CaseIterable, Identifiable {
    case skills = "Skills"
    case mcpServers = "MCP Servers"
    case plugins = "Plugins"
    case configuration = "Configuration"
    var id: String { rawValue }
}

private struct ProjectIgnoreReview: Identifiable {
    let plan: ProjectIgnorePlan
    var id: String { plan.gitignorePath }
}

// MARK: - Collection row

private struct ProjectCollectionRow: View {
    let project: DiscoveredProject
    let selected: Bool

    var body: some View {
        HStack(spacing: 11) {
            SymbolTile(symbol: project.isPlain ? "folder" : "folder.badge.gearshape", size: 28)
                .opacity(project.isPlain ? 0.5 : 1)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 5) {
                    Text(project.name)
                        .font(.callout.weight(.medium))
                        .foregroundStyle(selected ? Color.white : Color.primary)
                        .lineLimit(1)
                    if project.isPinned {
                        Image(systemName: "pin.fill")
                            .font(.system(size: 9))
                            .foregroundStyle(selected ? Color.white.opacity(0.8) : Color.secondary)
                            .accessibilityHidden(true)
                    }
                }
                HStack(spacing: 6) {
                    if let branch = project.gitBranch {
                        BranchChip(name: branch, isDetached: project.isDetachedHead, selected: selected)
                    }
                    Text(summary)
                        .font(.caption)
                        .foregroundStyle(selected ? Color.white.opacity(0.78) : Color.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }
            Spacer(minLength: 12)
            if let health = project.configurationHealth {
                StatusGlyph(state: health, size: 13, tint: selected ? Color.white : nil)
            }
        }
        .padding(.vertical, 6)
    }

    private var summary: String {
        project.isPlain ? "No project configuration" : project.badges.joined(separator: " · ")
    }
}

/// The branch is a configuration fact about the checkout, not a live status.
private struct BranchChip: View {
    let name: String
    var isDetached = false
    var selected = false

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: isDetached ? "arrow.triangle.pull" : "arrow.triangle.branch")
                .font(.system(size: 8, weight: .semibold))
            Text(name)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .font(.system(size: 10, weight: .medium))
        .foregroundStyle(selected ? Color.white.opacity(0.9) : Color.secondary)
        .padding(.horizontal, 6)
        .frame(height: 16)
        .background(
            (selected ? Color.white.opacity(0.18) : Color.primary.opacity(0.06)),
            in: Capsule()
        )
        .accessibilityLabel(isDetached ? "Detached at commit \(name)" : "Branch \(name)")
    }
}

// MARK: - Detail

private struct ProjectDetailView: View {
    @Environment(AppModel.self) private var model
    let project: DiscoveredProject
    @Binding var tab: ProjectDetailTab
    let onReviewIgnore: (DiscoveredProject) -> Void

    var body: some View {
        VStack(spacing: 0) {
            header
            Picker("Section", selection: $tab) {
                ForEach(ProjectDetailTab.allCases) { item in Text(item.rawValue).tag(item) }
            }
            .labelsHidden()
            .pickerStyle(.segmented)
            .accessibilityLabel("Project section")
            .padding(.horizontal, 22)
            .padding(.bottom, 12)
            Divider().opacity(0.4)

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    switch tab {
                    case .skills:
                        componentSection(
                            plural: "skills",
                            rows: skillRows,
                            caption:
                                "A project skill lives in .claude/skills, .agents/skills, or .gemini/skills inside the repository and hides a skill of the same name installed on this Mac. Create and edit skills in the Skills section."
                        )
                    case .mcpServers:
                        componentSection(
                            plural: "MCP servers",
                            rows: mcpRows,
                            caption:
                                "Project MCP servers come from files inside the repository. Adding or removing one still goes through a reviewed plan in the MCP Servers section."
                        )
                    case .plugins:
                        componentSection(
                            plural: "plugins",
                            rows: pluginRows,
                            caption:
                                "A project enables plugins in its own settings file. Installing a plugin remains a client-level action reviewed in the Plugins section."
                        )
                    case .configuration:
                        configurationSection
                    }
                }
                .padding(22)
            }
        }
    }

    // MARK: Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 14) {
                SymbolTile(symbol: project.isPlain ? "folder" : "folder.badge.gearshape", size: 40)
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 8) {
                        Text(project.name).font(.title3.weight(.semibold))
                        if let branch = project.gitBranch {
                            BranchChip(name: branch, isDetached: project.isDetachedHead)
                        }
                    }
                    LocationText(path: project.path)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if project.isPinned {
                    Button(isPinnedOnly ? "Forget" : "Unpin", systemImage: "pin.slash") {
                        model.forgetProject(project.path)
                    }
                    .buttonStyle(.bordered)
                    .help(
                        isPinnedOnly
                            ? "Removes this folder from the list. It comes back if Claude Code runs in it."
                            : "Keeps the project listed, without the pin.")
                } else {
                    Button("Pin", systemImage: "pin") { model.setProjectPinned(project.path, pinned: true) }
                        .buttonStyle(.bordered)
                        .help("Keeps this project listed even when it stops appearing in Claude Code's session index.")
                }
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

    private var isPinnedOnly: Bool { project.origins == [.pinned] }

    private var originSummary: String {
        let origins = ProjectDiscoveryOrigin.allCases.filter(project.origins.contains).map(\.displayName)
        let source = origins.isEmpty ? "Discovered on this Mac" : origins.joined(separator: " · ")
        return project.isPlain
            ? "\(source). This project has no agent configuration of its own; everything here is inherited from this Mac."
            : source
    }

    // MARK: Component tabs

    @ViewBuilder
    private func componentSection(
        plural: String,
        rows: [ProjectComponentRow],
        caption: String
    ) -> some View {
        let local = rows.filter { $0.origin != .inherited }
        let inherited = rows.filter { $0.origin == .inherited }

        TitledCard("In this project", count: "\(local.count)") {
            if local.isEmpty {
                EmptyCardRow(
                    text: inherited.isEmpty
                        ? "This project declares no \(plural)."
                        : "This project declares no \(plural) of its own. Everything below comes from this Mac.")
            } else {
                ComponentRows(rows: local, project: project)
            }
        }

        TitledCard("Inherited from this Mac", count: "\(inherited.count)") {
            if inherited.isEmpty {
                EmptyCardRow(text: "No \(plural) are installed for your user account.")
            } else {
                ComponentRows(rows: inherited, project: project)
            }
        }

        SectionCaption(text: caption)
    }

    /// A component Agent Tooling has already scoped to this project but has
    /// not yet written into it. Without this it would be invisible everywhere.
    private func declaredButUnwritten(
        kind: ComponentKind,
        existing: [ProjectComponentRecord],
        candidates: [(id: String, name: String)]
    ) -> [ProjectComponentRecord] {
        let known = Set(existing.map(\.id))
        return candidates.filter { !known.contains($0.id) }
            .map { candidate in
                ProjectComponentRecord(
                    id: candidate.id,
                    name: candidate.name,
                    kind: kind,
                    client: nil,
                    sharing: nil,
                    sourceRelativePath: "Scoped to this project in Agent Tooling · not written into the folder yet",
                    sourcePath: nil
                )
            }
    }

    private var skillRows: [ProjectComponentRow] {
        ProjectOverlay.rows(
            kind: .skill,
            inherited: model.skills
                .filter { ($0.projectRoot?.isEmpty ?? true) }
                .map {
                    ProjectInheritedComponent(
                        id: $0.id,
                        name: $0.displayName,
                        detail: $0.summary,
                        clients: $0.clients.filter(\.reportsLocalPresence).map(\.client)
                    )
                },
            local: project.skills
                + declaredButUnwritten(
                    kind: .skill,
                    existing: project.skills,
                    candidates: model.skills
                        .filter { ProjectPath.matches($0.projectRoot, project: project.path) }
                        .map { (id: $0.id, name: $0.displayName) }
                )
        )
    }

    private var mcpRows: [ProjectComponentRow] {
        ProjectOverlay.rows(
            kind: .mcpServer,
            inherited: model.mcpServers
                .filter { ($0.projectRoot?.isEmpty ?? true) }
                .map {
                    ProjectInheritedComponent(
                        id: $0.id,
                        name: $0.name,
                        detail: "\($0.transport.rawValue) · \($0.scope)",
                        clients: $0.clients.filter(\.reportsLocalPresence).map(\.client)
                    )
                },
            local: project.mcpServers
                + declaredButUnwritten(
                    kind: .mcpServer,
                    existing: project.mcpServers,
                    candidates: model.mcpServers
                        .filter { ProjectPath.matches($0.projectRoot, project: project.path) }
                        .map { (id: $0.id, name: $0.name) }
                )
        )
    }

    private var pluginRows: [ProjectComponentRow] {
        ProjectOverlay.rows(
            kind: .plugin,
            inherited: model.plugins.map {
                ProjectInheritedComponent(
                    id: $0.id,
                    name: $0.name,
                    detail: $0.scope,
                    clients: $0.clients.filter(\.reportsLocalPresence).map(\.client)
                )
            },
            local: project.plugins
        )
    }

    // MARK: Configuration tab

    @ViewBuilder
    private var configurationSection: some View {
        let committed = project.committedFiles
        let machineLocal = project.machineLocalFiles

        if !project.unlistedMachineLocalPatterns.isEmpty {
            AttentionBanner(
                title: "Machine-local settings are not in .gitignore",
                message:
                    "\(project.unlistedMachineLocalPatterns.joined(separator: ", ")) would be committed with the repository. These files belong to this Mac only."
            ) {
                Button("Add to .gitignore…") { onReviewIgnore(project) }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
            }
        }

        TitledCard("Shared with the repository", count: "\(committed.count)") {
            if committed.isEmpty {
                EmptyCardRow(text: "No committed agent configuration was found in this folder.")
            } else {
                ConfigurationFileRows(files: committed)
            }
        }

        TitledCard("This Mac only", count: "\(machineLocal.count)") {
            if machineLocal.isEmpty {
                EmptyCardRow(text: "No machine-local agent settings were found in this folder.")
            } else {
                ConfigurationFileRows(files: machineLocal, unlisted: Set(project.unlistedMachineLocalPatterns))
            }
        }

        SectionCaption(
            text:
                "A file under .claude/, .codex/, .gemini/, or .agents/ whose name contains .local. belongs to this Mac and should never be committed. Everything else in those folders travels with the repository."
        )
        SectionCaption(
            text:
                "Project roots do not travel. They are stripped when a workspace is exported, so a project-scoped skill or MCP server restored on another Mac arrives unattached and has to be pointed at a folder there."
        )
    }
}

// MARK: - Rows

private struct ComponentRows: View {
    @Environment(AppModel.self) private var model
    let rows: [ProjectComponentRow]
    let project: DiscoveredProject

    var body: some View {
        VStack(spacing: 0) {
            ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                InfoRow(row.name, detail: row.detail) {
                    KindTile(kind: tile(for: row.kind), size: 26, ghost: row.origin == .inherited)
                } trailing: {
                    HStack(spacing: 10) {
                        if let server = reviewableServer(for: row) {
                            Button("Review…") { model.planMCPConfiguration(server: server) }
                                .buttonStyle(.bordered)
                                .controlSize(.small)
                                .disabled(model.isInteractionLocked)
                        }
                        if !row.clients.isEmpty {
                            ClientMarks(present: Set(row.clients), size: 12)
                        }
                        OriginTag(origin: row.origin)
                        if let path = row.sourcePath {
                            PathInfoButton(path: path)
                        }
                    }
                }
                if index < rows.count - 1 { Divider().opacity(0.45) }
            }
        }
    }

    private func tile(for kind: ComponentKind) -> ToolingKind {
        switch kind {
        case .skill: .skill
        case .plugin: .plugin
        case .mcpServer: .mcpServer
        default: .source
        }
    }

    /// Only a managed definition already scoped to this project can be
    /// re-reviewed here; everything else stays read-only.
    private func reviewableServer(for row: ProjectComponentRow) -> MCPServer? {
        guard row.kind == .mcpServer, row.origin != .inherited else { return nil }
        return model.mcpServers.first {
            $0.id == row.id && $0.isManagedDefinition && ProjectPath.matches($0.projectRoot, project: project.path)
        }
    }
}

/// The mark the rest of the app cannot show: where this component comes from.
private struct OriginTag: View {
    let origin: ProjectComponentOrigin

    var body: some View {
        Text(origin.displayName)
            .font(.caption.weight(.medium))
            .foregroundStyle(color)
            .padding(.horizontal, 8)
            .frame(height: 20)
            .background(color.opacity(0.13), in: Capsule())
            .overlay { Capsule().strokeBorder(color.opacity(0.28), lineWidth: 0.5) }
            .help(origin.explanation)
            .accessibilityLabel(origin.displayName)
            .accessibilityHint(origin.explanation)
    }

    private var color: Color {
        switch origin {
        case .inherited: AgentTheme.graphite
        case .overridden: AgentTheme.warning
        case .projectOnly: AgentTheme.blue
        }
    }
}

private struct ConfigurationFileRows: View {
    let files: [ProjectFilePresence]
    var unlisted: Set<String> = []

    var body: some View {
        VStack(spacing: 0) {
            ForEach(Array(files.enumerated()), id: \.element.id) { index, file in
                InfoRow(file.descriptor.title, detail: detail(for: file)) {
                    SymbolTile(symbol: symbol(for: file.descriptor), size: 26)
                } trailing: {
                    HStack(spacing: 10) {
                        if let client = file.descriptor.client {
                            ClientMarks(present: [client], size: 12)
                        }
                        if unlisted.contains("/" + file.descriptor.relativePath) {
                            StatusBadge(state: .attention, text: "Not in .gitignore")
                        } else if file.descriptor.sharing == .machineLocal {
                            StatusBadge(state: .healthy, text: "In .gitignore")
                        }
                        PathInfoButton(path: file.path)
                    }
                }
                if index < files.count - 1 { Divider().opacity(0.45) }
            }
        }
    }

    private func detail(for file: ProjectFilePresence) -> String {
        var parts = [file.descriptor.relativePath, file.descriptor.role.displayName]
        if let count = file.entryCount, count > 0 { parts.append("\(count) entr\(count == 1 ? "y" : "ies")") }
        return parts.joined(separator: " · ")
    }

    private func symbol(for descriptor: ProjectFileDescriptor) -> String {
        switch descriptor.role {
        case .instructions: "text.document"
        case .settings: "slider.horizontal.3"
        case .mcpDefinitions: "server.rack"
        case .skills: "doc.text"
        case .plugins: "puzzlepiece.extension"
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

// MARK: - Reviewed .gitignore edit

/// Nothing is written until the exact text has been shown. The edit only ever
/// appends, and running it again after the lines are present changes nothing.
private struct ProjectIgnoreReviewSheet: View {
    @Environment(\.dismiss) private var dismiss
    let plan: ProjectIgnorePlan
    let onApply: () -> Bool

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                SymbolTile(symbol: "eye.slash", size: 40)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Add machine-local settings to .gitignore").font(.title3.weight(.semibold))
                    Text("One append. Nothing already in the file is changed or reordered.")
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(22)
            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    GroupBox("Destination") {
                        LabeledValueRow("File") {
                            CompactPathText(path: plan.gitignorePath)
                        }
                    }
                    GroupBox("Appended exactly") {
                        Text(plan.appendedText.trimmingCharacters(in: .newlines))
                            .font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(14)
                    }
                    SectionCaption(
                        text:
                            "Agent Tooling does not run git. It matches lines literally, so a pattern written another way may already cover these files."
                    )
                }
                .padding(22)
            }

            Divider()
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .buttonStyle(.bordered)
                    .keyboardShortcut(.cancelAction)
                Button("Add to .gitignore") {
                    _ = onApply()
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
            }
            .padding(16)
        }
        .frame(width: 640, height: 460)
        .background(AgentTheme.contentBackground)
    }
}
