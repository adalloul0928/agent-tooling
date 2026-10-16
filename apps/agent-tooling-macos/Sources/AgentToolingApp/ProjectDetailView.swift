import AgentToolingCore
import SwiftUI

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
            "Project connections come from files inside the repository. Adding or reviewing one still goes through a reviewed assignment, scoped to this project."
        case .plugins:
            "A project enables plugins in its own settings file. Installing a plugin remains a client-level action reviewed on the Install screen."
        }
    }
}

// MARK: - Detail

struct ProjectDetailView: View {
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
        panel.prompt = "Use folder"
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
        PathDisplay.abbreviatingHome(path, home: FileManager.default.homeDirectoryForCurrentUser)
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
                    KindTile(kind: ToolingKind(row.kind), size: Size.tile)
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
            ? "\(row.ownershipLabel) · Includes \(CountNoun("tool").phrase(row.childCount))"
            : row.ownershipLabel
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
