import AgentToolingCore
import SwiftUI

/// Library and Projects over one versioned session. Both destinations use the
/// same read model and the same assignment sheet; a project only prefills its
/// own context, so nothing about the flow changes with the entry point.
struct WorkspaceShellView: View {
    let session: WorkspaceLibrarySession
    var syncSession: WorkspaceSyncSession?
    var settingsSession: WorkspaceSettingsSession?
    var deploymentSession: WorkspaceDeploymentSession?
    var historySession: WorkspaceHistorySession?
    var authoringSession: WorkspaceAuthoringSession?
    var exportSession: WorkspacePackageExportSession?
    var presetsSession: WorkspacePresetsSession?
    var declarationSession: WorkspaceProjectDeclarationSession?
    @State private var destination: Destination = .library
    @State private var openProjectID: ArtifactID?
    /// Shown once, only while a writable workspace has nothing assigned. It is
    /// dismissed by choosing tools or skipping; it never blocks the library.
    @State private var hasLeftOnboarding = false

    enum Destination: Hashable { case library, projects, presets, install, appSettings, sync, history }

    var body: some View {
        NavigationSplitView {
            List(selection: $destination) {
                Label("Library", systemImage: "books.vertical").tag(Destination.library)
                Label("Projects", systemImage: "folder").tag(Destination.projects)
                if presetsSession != nil {
                    Label("Presets", systemImage: "square.stack").tag(Destination.presets)
                }
                if deploymentSession != nil {
                    Label("Install", systemImage: "arrow.down.circle").tag(Destination.install)
                }
                if settingsSession != nil {
                    Label("App settings", systemImage: "slider.horizontal.3").tag(Destination.appSettings)
                }
                if syncSession != nil {
                    Label("Sync", systemImage: "arrow.triangle.2.circlepath").tag(Destination.sync)
                }
                if historySession != nil {
                    Label("History", systemImage: "clock.arrow.circlepath").tag(Destination.history)
                }
            }
            .navigationSplitViewColumnWidth(min: 180, ideal: 210, max: 260)
            .listStyle(.sidebar)
        } detail: {
            switch destination {
            case .library:
                if showsOnboarding {
                    WorkspaceOnboardingView(session: session) { hasLeftOnboarding = true }
                } else {
                    WorkspaceLibraryView(session: session, authoring: authoringSession,
                                         export: exportSession)
                }
            case .projects:
                if let openProjectID,
                   let project = session.state?.library.projects.first(where: { $0.id == openProjectID }) {
                    WorkspaceProjectDetailView(session: session, project: project,
                                               declarations: declarationSession) {
                        self.openProjectID = nil
                    }
                } else {
                    WorkspaceProjectsView(session: session) { openProjectID = $0 }
                }
            case .presets:
                if let presetsSession {
                    WorkspacePresetsView(session: presetsSession, library: session)
                } else {
                    ContentUnavailableView("Presets unavailable", systemImage: "square.stack",
                        description: Text("This Mac's linked presets could not be opened."))
                }
            case .install:
                if let deploymentSession {
                    WorkspaceDeploymentView(session: deploymentSession)
                } else {
                    ContentUnavailableView("Install unavailable", systemImage: "arrow.down.circle",
                        description: Text("This workspace cannot reach your apps from here."))
                }
            case .appSettings:
                if let settingsSession {
                    WorkspaceSettingsView(session: settingsSession)
                } else {
                    ContentUnavailableView("Settings unavailable", systemImage: "slider.horizontal.3",
                        description: Text("This Mac's app settings could not be located."))
                }
            case .sync:
                if let syncSession {
                    WorkspaceSyncView(session: syncSession)
                } else {
                    ContentUnavailableView("Sync unavailable", systemImage: "arrow.triangle.2.circlepath",
                        description: Text("This workspace has no sync setup on this Mac."))
                }
            case .history:
                if let historySession {
                    WorkspaceHistoryView(session: historySession)
                } else {
                    ContentUnavailableView("History unavailable", systemImage: "clock.arrow.circlepath",
                        description: Text("This workspace's earlier versions are not readable here."))
                }
            }
        }
        .background(AgentTheme.contentBackground)
    }

    /// Only for a writable workspace that holds items and has no assignments at
    /// all. A read-only preview and an already-used workspace go straight in.
    private var showsOnboarding: Bool {
        guard !hasLeftOnboarding, session.access == .writable,
              let library = session.state?.library else { return false }
        return !library.rows.isEmpty
            && library.rows.allSatisfy { $0.requestedAssignments.isEmpty }
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
                    ContentUnavailableView("No projects yet", systemImage: "folder",
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
                ContentUnavailableView("Projects unavailable", systemImage: "folder",
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
                    ContentUnavailableView("Nothing assigned yet", systemImage: "folder",
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
                ContentUnavailableView("Project unavailable", systemImage: "folder",
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
                WorkspaceProjectDeclarationSheet(session: declarations, projectRoot: root,
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
        guard let root = session.state?.snapshot.device.projectRoots?
            .first(where: { $0.projectID == project.id }) else {
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
                    Toggle(isOn: Binding(
                        get: { selection.contains(row.artifactID) },
                        set: { if $0 { selection.insert(row.artifactID) } else { selection.remove(row.artifactID) } }
                    )) {
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
        .sheet(isPresented: $isReviewing, onDismiss: { dismiss() }) {
            WorkspaceAssignmentSheet(session: session, artifactIDs: selection.sorted(),
                initialProjectID: project.id)
        }
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
                    Text("Two files, written into this project's folder for you to commit. `project.json` says what this project asks for. `project-lock.json` pins what those resolved to, so a checkout later gets the same versions.")
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
                    if let result = session.committed { committedSummary(result) }
                    else if let message = session.committedMessage {
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
                Label("You have all of it, at the versions this project pins.",
                      systemImage: "checkmark.circle").foregroundStyle(.secondary)
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
                Text(preview.declaration.entries.isEmpty
                     ? "Nothing yet"
                     : preview.declaration.entries.map(\.name).formatted(.list(type: .and)))
                    .multilineTextAlignment(.trailing)
            }
            LabeledContent("Pinned") {
                Text(preview.lock.map { $0.entries.count == 1 ? "1 version" : "\($0.entries.count) versions" }
                     ?? "None")
            }
            if !preview.unlocked.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Label("Asked for, but not pinned", systemImage: "questionmark.circle")
                        .font(.system(size: 14, weight: .medium))
                    Text(preview.unlocked.formatted(.list(type: .and))).foregroundStyle(.secondary)
                    Text("These have no exact version behind them, so a lock line for one could not bring back the same files. They are in the declaration and left out of the lock.")
                        .font(.callout).foregroundStyle(.secondary)
                }
            }
        }
        .padding(16)
        .standardPanel(cornerRadius: 12)
    }
}
