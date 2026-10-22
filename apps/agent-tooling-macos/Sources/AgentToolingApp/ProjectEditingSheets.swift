import AgentToolingCore
import SwiftUI

// MARK: - Add tools

/// Selecting items for one project. The browser and the review are the shared
/// ones; only the destination context is prefilled.
struct WorkspaceProjectAddSheet: View {
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
                    .frame(minWidth: Size.searchFieldMin, idealWidth: Size.searchFieldSheetIdeal)
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
                // Opens the assignment sheet over this one.
                Button("Continue…") {
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
struct WorkspaceProjectDeclarationSheet: View {
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
                    preview.lock.map { CountNoun("version").phrase($0.entries.count) } ?? "None")
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
struct NewProjectSheet: View {
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
                            .textFieldStyle(.roundedBorder).frame(maxWidth: Size.fieldCapped)
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
                Button("Create project") { create() }
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
        panel.prompt = "Use folder"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        guard ProjectDiscovery.isEligibleProjectRoot(url, homeURL: workspace.homeRoot) else {
            errorMessage = "Your home folder is where this Mac's own skills and connections live. Choose a project folder inside it."
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
