import AgentToolingCore
import SwiftUI

/// Projects: the list, and one project opened.
///
/// Which of the two is showing is this pane's own business, so the shell never
/// learns that a project can be opened and the back button has nowhere else to
/// report to.
struct ProjectsSection: View {
    let workspace: WorkspaceLaunch.Workspace
    @State private var openProjectID: ArtifactID?

    var body: some View {
        if let openProjectID,
            let project = workspace.library.state?.library.projects.first(where: { $0.id == openProjectID })
        {
            WorkspaceProjectDetailView(
                session: workspace.library, project: project,
                declarations: workspace.declarations
            ) {
                self.openProjectID = nil
            }
        } else {
            WorkspaceProjectsView(session: workspace.library) { openProjectID = $0 }
        }
    }
}

/// Lists this workspace's logical projects with what is already assigned to
/// each. Folder paths stay device-local and are shown as bindings, never as the
/// project's shared identity.
struct WorkspaceProjectsView: View {
    let session: WorkspaceLibrarySession
    var onOpen: (ArtifactID) -> Void
    @State private var refreshID = UUID()

    var body: some View {
        VStack(spacing: 0) {
            PageToolbar(title: "Projects", context: context) {
                Button("Refresh", systemImage: "arrow.clockwise") { refreshID = UUID() }
                    .labelStyle(.iconOnly).buttonStyle(.glass).disabled(session.isBusy)
            }
            Divider()
            if let state = session.state {
                let projects = state.library.projects
                if projects.isEmpty {
                    ContentUnavailableView(
                        "No projects yet", systemImage: "folder",
                        description: Text("Projects appear here once a tool is assigned to one."))
                } else {
                    List(projects) { project in
                        let count = state.library.assignedItemCount(inProject: project.id)
                        let root = state.snapshot.device.projectRoots?.first { $0.projectID == project.id }
                        HStack(spacing: 14) {
                            Image(systemName: "folder")
                                .font(.system(size: 21)).foregroundStyle(.secondary).frame(width: 28)
                            VStack(alignment: .leading, spacing: 4) {
                                Text(project.name).font(.system(size: 15, weight: .medium)).lineLimit(1)
                                HStack(spacing: 8) {
                                    Text(count == 1 ? "1 tool assigned" : "\(count) tools assigned")
                                    Text(root == nil ? "Not on this Mac" : "On this Mac")
                                }
                                .font(.system(size: 13)).foregroundStyle(.secondary)
                            }
                            Spacer(minLength: 12)
                            Button("Add tools…", systemImage: "plus") { onOpen(project.id) }
                                .buttonStyle(.borderless)
                                .accessibilityLabel("Add tools to \(project.name)")
                        }
                        .padding(.vertical, 9)
                        .contentShape(Rectangle())
                        .onTapGesture { onOpen(project.id) }
                        .help(root?.rootPath ?? "This project has no folder on this Mac yet.")
                        .accessibilityElement(children: .contain)
                        .contextMenu {
                            Button("Add tools", systemImage: "plus") { onOpen(project.id) }
                        }
                    }
                    .listStyle(.plain)
                }
            } else if session.isBusy {
                ProgressView("Loading projects…").frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ContentUnavailableView(
                    "Projects unavailable", systemImage: "folder",
                    description: Text("Refresh to read this workspace again."))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(AgentTheme.contentBackground)
        .frame(minWidth: 720, minHeight: 480)
        .task(id: refreshID) { await session.refresh() }
    }

    private var context: String {
        session.access == .readOnly ? "Workspace preview" : "Assign tools per project"
    }
}

/// One project: what it already has, what every project inherits, and one way
/// to add more. Adding uses the shared browser and sheet with this project
/// prefilled, so the flow is identical to assigning from the Library.
struct WorkspaceProjectDetailView: View {
    let session: WorkspaceLibrarySession
    let project: WorkspaceLibraryProjectReadModel
    var declarations: WorkspaceProjectDeclarationSession?
    var onBack: () -> Void
    @State private var isAdding = false
    @State private var isDeclaring = false

    var body: some View {
        VStack(spacing: 0) {
            PageToolbar(title: project.name, context: context) {
                Button("All projects", systemImage: "chevron.backward", action: onBack)
                    .buttonStyle(.glass)
                if declarations != nil, projectRoot != nil {
                    Button("Project files…", systemImage: "doc.badge.plus") {
                        declarations?.prepare(projectID: project.id)
                        if let root = projectRoot { declarations?.readCommitted(projectRoot: root) }
                        isDeclaring = true
                    }
                    .buttonStyle(.glass)
                    .disabled(session.isBusy || session.access != .writable)
                    .help("Write what this project asks for, and what it resolved to, into its folder.")
                }
                Button("Add tools…", systemImage: "plus") { isAdding = true }
                    .buttonStyle(.glassProminent).tint(AgentTheme.selection)
                    .disabled(session.isBusy)
            }
            Divider()
            if let library = session.state?.library {
                let assigned = library.rows(inProject: project.id)
                let inherited = library.globallyAssignedRows
                if assigned.isEmpty, inherited.isEmpty {
                    ContentUnavailableView(
                        "Nothing assigned yet", systemImage: "folder",
                        description: Text("Add tools to make them available in this project."))
                } else {
                    List {
                        Section("Assigned to this project") {
                            if assigned.isEmpty {
                                Text("Nothing is assigned specifically to this project yet.")
                                    .foregroundStyle(.secondary)
                            }
                            ForEach(assigned) { row in WorkspaceProjectRow(row: row, inherited: false) }
                        }
                        Section("Available in every project") {
                            if inherited.isEmpty {
                                Text("No tools are assigned outside a project.")
                                    .foregroundStyle(.secondary)
                            }
                            ForEach(inherited) { row in WorkspaceProjectRow(row: row, inherited: true) }
                        }
                    }
                    .listStyle(.inset)
                }
            } else if session.isBusy {
                ProgressView("Loading project…").frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ContentUnavailableView(
                    "Project unavailable", systemImage: "folder",
                    description: Text("Refresh to read this workspace again."))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(AgentTheme.contentBackground)
        .frame(minWidth: 720, minHeight: 480)
        .sheet(isPresented: $isAdding) {
            WorkspaceProjectAddSheet(session: session, project: project)
        }
        .sheet(isPresented: $isDeclaring) {
            if let declarations, let root = projectRoot {
                WorkspaceProjectDeclarationSheet(
                    session: declarations, projectRoot: root,
                    projectName: project.name)
            }
        }
    }

    /// This project's folder on this Mac, when it has one. Without it there is
    /// nowhere to write, and the offer is not made.
    private var projectRoot: URL? {
        session.state?.snapshot.device.projectRoots?
            .first { $0.projectID == project.id }
            .map { URL(fileURLWithPath: $0.rootPath) }
    }

    private var context: String {
        guard
            let root = session.state?.snapshot.device.projectRoots?
                .first(where: { $0.projectID == project.id })
        else {
            return "This project has no folder on this Mac"
        }
        return "Folder on this Mac · \(root.rootPath)"
    }
}

private struct WorkspaceProjectRow: View {
    let row: WorkspaceLibraryReadModelRow
    let inherited: Bool

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: row.kind.librarySymbol)
                .font(.system(size: 19)).foregroundStyle(.secondary).frame(width: 26)
            VStack(alignment: .leading, spacing: 3) {
                Text(row.displayName).font(.system(size: 15, weight: .medium)).lineLimit(1)
                HStack(spacing: 8) {
                    Text(row.ownershipLabel)
                    if row.childCount > 0 {
                        Text("Includes \(row.childCount) \(row.childCount == 1 ? "tool" : "tools")")
                    }
                }
                .font(.system(size: 13)).foregroundStyle(.secondary)
            }
            Spacer(minLength: 12)
            if inherited {
                Text("Inherited").font(.system(size: 13)).foregroundStyle(.secondary)
                    .help("Assigned without a project, so every project can use it.")
            }
        }
        .padding(.vertical, 7)
        .accessibilityElement(children: .contain)
    }
}

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

/// Writing a project's declaration and lock into its folder.
///
/// Both files are shown before anything is written, because they are meant to be
/// committed and read by other people.
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
