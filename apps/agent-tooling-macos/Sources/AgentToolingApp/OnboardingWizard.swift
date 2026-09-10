import AgentToolingCore
import SwiftUI

/// Whether getting started stands in front of the library.
///
/// A pure rule, kept separate from the view so it can be tested without
/// rendering anything: a writable workspace that holds items and has recorded
/// no assignment at all, and that a person has not already dismissed.
enum OnboardingPresentationPolicy {
    static func shouldPresent(
        skipped: Bool, access: WorkspaceLibraryAccess, rows: [WorkspaceLibraryReadModelRow]?
    ) -> Bool {
        guard !skipped, access == .writable, let rows else { return false }
        return !rows.isEmpty && rows.allSatisfy(\.requestedAssignments.isEmpty)
    }
}

/// The three stops left once a versioned first run has already scanned this
/// Mac and built the library before this view ever appears: what it found,
/// which apps this Mac keeps in sync, and what to assign.
enum OnboardingStep: Int, CaseIterable, Identifiable {
    case found, apps, assign
    var id: Int { rawValue }

    var label: String {
        switch self {
        case .found: "Found"
        case .apps: "Apps"
        case .assign: "Assign"
        }
    }
    var title: String {
        switch self {
        case .found: "Here’s what this Mac found"
        case .apps: "Choose the apps this Mac manages"
        case .assign: "Choose what to assign"
        }
    }
    var subtitle: String {
        switch self {
        case .found: "Your library already holds what the first run discovered. Nothing is installed or assigned yet."
        case .apps: "This only decides which apps this Mac keeps in sync. What is already installed does not change."
        case .assign: "Assigning records where you want a tool. Installing it into an app stays a separate, reviewed step."
        }
    }
}

/// Get started: the old wizard's steps and visual, reconciled to a workspace a
/// versioned first run has already scanned and built.
///
/// The wizard used to scan, preview an adoption plan, and review copy issues
/// before anything could be tracked. A versioned first run does all of that
/// before this view ever appears, so none of it is this view's job any more —
/// only saying what was found, deciding which apps this Mac manages, and
/// choosing what to assign. It is content inside the Library section, not a
/// sheet over the window, so every other section stays one click away while it
/// is up.
struct OnboardingWizard: View {
    let workspace: WorkspaceLaunch.Workspace
    var onFinish: () -> Void

    @Environment(AppNavigationState.self) private var navigation
    @Environment(\.workspaceNavigate) private var workspaceNavigate
    @State private var step: OnboardingStep
    @State private var isAssigning = false

    init(workspace: WorkspaceLaunch.Workspace, step: OnboardingStep = .found, onFinish: @escaping () -> Void) {
        self.workspace = workspace
        self.onFinish = onFinish
        _step = State(initialValue: step)
    }

    var body: some View {
        VStack(spacing: 0) {
            PageToolbar(title: "Get started", context: "Choose what each app should have") {}
            Divider()
            progressHeader
            Divider()
            VStack(alignment: .leading, spacing: 6) {
                Text(step.title).font(.system(size: 21, weight: .semibold))
                Text(step.subtitle).font(.system(size: 14)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 28).padding(.top, 20).padding(.bottom, 16)
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    switch step {
                    case .found: foundStep
                    case .apps: appsStep
                    case .assign: assignStep
                    }
                }
                .padding(.horizontal, 28).padding(.bottom, 24)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            Divider()
            footer
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(AgentTheme.contentBackground)
        .frame(minWidth: 720, minHeight: 480)
        .sheet(isPresented: $isAssigning) {
            OnboardingAssignmentPickerSheet(session: workspace.library)
        }
    }

    private var progressHeader: some View {
        HStack(spacing: 12) {
            Image(systemName: "slider.horizontal.3")
                .font(.system(size: 17, weight: .medium)).foregroundStyle(.secondary)
            Text("Set up Agent Tooling").font(.system(size: 14, weight: .semibold))
            Spacer()
            Text("Step \(step.rawValue + 1) of \(OnboardingStep.allCases.count) · \(step.label)")
                .font(.system(size: 12, weight: .medium)).foregroundStyle(.secondary)
            HStack(spacing: 4) {
                ForEach(OnboardingStep.allCases) { candidate in
                    Capsule().fill(candidate.rawValue <= step.rawValue ? AgentTheme.blue : Color.secondary.opacity(0.18))
                        .frame(width: 22, height: 4)
                }
            }.accessibilityHidden(true)
        }
        .padding(.horizontal, 28)
        .padding(.vertical, 14)
    }

    // MARK: - Found

    @ViewBuilder
    private var foundStep: some View {
        if let library = workspace.library.state?.library {
            VStack(alignment: .leading, spacing: 22) {
                Text(librarySummary(library)).font(.system(size: 14)).foregroundStyle(.secondary)
                TitledCard("Apps on this Mac", count: "\(workspace.device.availableClients.count)") {
                    ForEach(Array(workspace.device.availableClients.enumerated()), id: \.element) { index, client in
                        foundClientRow(client)
                        if index < workspace.device.availableClients.count - 1 { Divider().padding(.leading, 54) }
                    }
                }
                TitledCard("In your library", count: "\(library.rows.count)") {
                    ForEach(Array(library.rows.prefix(6).enumerated()), id: \.element.id) { index, row in
                        foundLibraryRow(row)
                        if index < min(6, library.rows.count) - 1 { Divider().padding(.leading, 54) }
                    }
                    if library.rows.count > 6 {
                        Divider().padding(.leading, 54)
                        Text("and \(library.rows.count - 6) more entries")
                            .font(.system(size: 12)).foregroundStyle(.secondary)
                            .padding(.horizontal, 13).padding(.vertical, 9)
                    }
                }
                Text("This covers local agent setup. Cloud account connections and desktop-only settings remain in their own apps.")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
            }
        } else {
            ProgressView("Reading your library…")
                .frame(maxWidth: .infinity, minHeight: 200)
        }
    }

    private func foundClientRow(_ client: ClientKind) -> some View {
        let verdict = workspace.device.verdict(for: client)
        return InfoRow(client.rawValue, detail: clientScope(client)) {
            ClientBrandIcon(client: client, size: 22).frame(width: 28, height: 28)
        } trailing: {
            StatusBadge(state: verdict.state, text: verdict.text)
        }
    }

    private func foundLibraryRow(_ row: WorkspaceLibraryReadModelRow) -> some View {
        InfoRow(row.displayName, detail: row.ownershipLabel) {
            KindTile(kind: toolingKind(row.kind), size: 26)
        }
    }

    private func librarySummary(_ library: WorkspaceLibraryReadModel) -> String {
        let nested = library.nestedToolCount
        let total = library.toolCount
        let holds = total == 1 ? "It holds 1 tool." : "It holds \(total) tools."
        guard nested > 0 else { return holds }
        return nested == 1
            ? "\(holds) One of them comes inside a plugin."
            : "\(holds) \(nested) of them come inside plugins."
    }

    // MARK: - Apps

    private var appsStep: some View {
        VStack(alignment: .leading, spacing: 22) {
            VStack(spacing: 0) {
                ForEach(Array(workspace.device.availableClients.enumerated()), id: \.element) { index, client in
                    if index > 0 { Divider().padding(.leading, 64) }
                    Toggle(isOn: clientBinding(client)) {
                        HStack(spacing: 14) {
                            ClientBrandIcon(client: client, size: 28)
                                .frame(width: 36, height: 40)
                            VStack(alignment: .leading, spacing: 4) {
                                Text(client.rawValue).font(.system(size: 16, weight: .semibold))
                                Text(clientScope(client)).font(.system(size: 14)).foregroundStyle(.secondary)
                            }
                            Spacer()
                        }
                    }
                    .toggleStyle(.checkbox)
                    .padding(18)
                    .accessibilityLabel("Have this Mac manage \(client.rawValue)")
                }
            }
            .standardPanel(cornerRadius: 14)
            Text(
                "Tracking follows your library either way. Turning an app off here only stops this Mac from keeping it in sync — nothing already installed changes."
            )
            .font(.system(size: 13)).foregroundStyle(.secondary)
            if let error = workspace.device.errorMessage {
                AttentionBanner(title: "Couldn’t save that choice", message: error)
            }
        }
    }

    private func clientBinding(_ client: ClientKind) -> Binding<Bool> {
        Binding(
            get: { workspace.device.isEnabled(client) },
            set: { newValue in Task { await workspace.device.setEnabled(client, newValue) } })
    }

    // MARK: - Assign

    @ViewBuilder
    private var assignStep: some View {
        if workspace.library.state == nil {
            ProgressView("Reading your library…")
                .frame(maxWidth: .infinity, minHeight: 200)
        } else if isDone {
            doneCard
        } else {
            VStack(alignment: .leading, spacing: 14) {
                Text(
                    "Nothing is assigned yet. Choosing tools here records where you want them; installing them into your apps stays a separate step you review."
                )
                .font(.system(size: 14)).foregroundStyle(.secondary)
                if !canAssign {
                    AttentionBanner(
                        title: "Nothing is ready to assign yet",
                        message:
                            "A first run only tracks what it finds. Manage an item from the library before assigning it here, or skip this for now."
                    )
                }
                if let error = workspace.library.errorMessage {
                    AttentionBanner(title: "Couldn’t prepare assignments", message: error)
                }
            }
        }
    }

    private var doneCard: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 14) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 28)).foregroundStyle(AgentTheme.ok)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Your assignments are saved").font(.system(size: 16, weight: .semibold))
                    Text("Review installation changes to make them available in your apps.")
                        .font(.system(size: 13)).foregroundStyle(.secondary)
                }
                Spacer()
            }
            Text("Make it yours").font(.system(size: 15, weight: .semibold))
            VStack(spacing: 0) {
                nextStepRow(
                    "Review app changes", detail: "Compare your saved assignments with this Mac.",
                    symbol: "arrow.triangle.2.circlepath", destination: .syncCenter)
                Divider().padding(.leading, 54)
                nextStepRow(
                    "Set up a backup", detail: "Keep a local backup or choose an encrypted sync folder.",
                    symbol: "externaldrive", destination: .settings)
                Divider().padding(.leading, 54)
                nextStepRow(
                    "Find useful skills", detail: "Choose whether to review recent work in Insights.",
                    symbol: "lightbulb", destination: .insights)
            }
            .standardPanel(cornerRadius: 14)
        }
    }

    private func nextStepRow(_ title: String, detail: String, symbol: String, destination: AppSection) -> some View {
        Button {
            onFinish()
            workspaceNavigate(destination)
        } label: {
            HStack(spacing: 12) {
                Image(systemName: symbol).font(.system(size: 18)).foregroundStyle(.secondary).frame(width: 26)
                VStack(alignment: .leading, spacing: 3) {
                    Text(title).font(.system(size: 14, weight: .semibold))
                    Text(detail).font(.system(size: 13)).foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: "chevron.right").font(.system(size: 11)).foregroundStyle(.tertiary)
            }.padding(15).contentShape(Rectangle())
        }.buttonStyle(.plain)
    }

    private var isDone: Bool { workspace.library.lastReceipt != nil }

    private var canAssign: Bool {
        workspace.library.state?.library.rows.contains(where: \.isAssignable) ?? false
    }

    // MARK: - Footer

    private var footer: some View {
        HStack(spacing: 12) {
            if step != .assign || !isDone {
                Button("Set up later", action: onFinish)
                    .buttonStyle(.plain).foregroundStyle(.secondary)
            }
            Spacer()
            if step != .found, !(step == .assign && isDone) {
                Button("Back") { step = OnboardingStep(rawValue: step.rawValue - 1) ?? .found }
                    .buttonStyle(.glass)
            }
            Button(primaryTitle, action: advance)
                .buttonStyle(.glassProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(step == .assign && !isDone && !canAssign)
        }
        .controlSize(.large)
        .padding(.horizontal, 28)
        .padding(.vertical, 16)
    }

    private var primaryTitle: String {
        switch step {
        case .found, .apps: "Continue"
        case .assign: isDone ? "Go to Home" : "Choose tools to assign…"
        }
    }

    private func advance() {
        switch step {
        case .found: step = .apps
        case .apps: step = .assign
        case .assign:
            if isDone {
                onFinish()
                navigation.open(.section(.overview))
            } else {
                workspace.library.discardReview()
                isAssigning = true
            }
        }
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

    private func clientScope(_ client: ClientKind) -> String {
        switch client {
        case .codex: "Agent configuration shared by Codex app and CLI"
        case .claude: "Claude Code skills, plugins, and MCP configuration"
        case .gemini: "Gemini CLI extensions and local configuration"
        }
    }
}

/// Choosing which library rows to send into a review. Every row starts
/// unselected, and nothing here is enabled, removed, or installed for an item
/// nobody chose — the same browser, the same review and the same save as
/// everywhere else in the app.
private struct OnboardingAssignmentPickerSheet: View {
    let session: WorkspaceLibrarySession
    @Environment(\.dismiss) private var dismiss
    @State private var selection: Set<ArtifactID> = []
    @State private var search = ""
    @State private var isReviewing = false

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Choose tools to assign").font(.title3.weight(.semibold))
                Spacer()
            }.padding(20)
            Divider()
            if let library = session.state?.library {
                let visible = library.filteredRows(matching: search)
                HStack(spacing: 16) {
                    InventorySearchField(placeholder: "Search your library", text: $search)
                    Button(search.isEmpty ? "Select all" : "Select results") { setSelected(visible, to: true) }
                        .disabled(!visible.contains(where: \.isAssignable))
                    Button("Clear") { setSelected(visible, to: false) }
                        .disabled(!visible.contains { selection.contains($0.artifactID) })
                }
                .font(.system(size: 13)).buttonStyle(.plain)
                .padding(.horizontal, 20).padding(.bottom, 12)
                if visible.isEmpty {
                    ContentUnavailableView(
                        search.isEmpty ? "Nothing to assign" : "No matches",
                        systemImage: "books.vertical",
                        description: Text(
                            search.isEmpty
                                ? "Everything here is tracked only. Manage an item from the library first."
                                : "Try another name.")
                    ).frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    List(visible) { row in
                        OnboardingChoiceRow(row: row, isSelected: rowBinding(row))
                            .listRowInsets(EdgeInsets(top: 0, leading: 14, bottom: 0, trailing: 14))
                            .listRowBackground(AgentTheme.controlBackground)
                    }
                    .listStyle(.plain).scrollContentBackground(.hidden)
                }
            } else {
                ProgressView("Loading library…").frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            Divider()
            HStack {
                Button("Cancel") { dismiss() }
                Spacer()
                Text(selection.isEmpty ? "Nothing selected yet." : "\(selection.count) selected")
                    .foregroundStyle(.secondary)
                Button("Continue") { isReviewing = true }
                    .buttonStyle(.borderedProminent)
                    .disabled(selection.isEmpty || session.isBusy)
            }.padding(20)
        }
        .frame(width: 720, height: 560)
        .background(AgentTheme.contentBackground)
        .sheet(
            isPresented: $isReviewing, onDismiss: { dismiss() },
            content: { WorkspaceAssignmentSheet(session: session, artifactIDs: selection.sorted()) })
    }

    private func rowBinding(_ row: WorkspaceLibraryReadModelRow) -> Binding<Bool> {
        Binding(
            get: { selection.contains(row.artifactID) },
            set: { selected in
                guard row.isAssignable else { return }
                if selected { selection.insert(row.artifactID) } else { selection.remove(row.artifactID) }
            })
    }

    private func setSelected(_ rows: [WorkspaceLibraryReadModelRow], to value: Bool) {
        for row in rows where row.isAssignable {
            if value { selection.insert(row.artifactID) } else { selection.remove(row.artifactID) }
        }
    }
}
