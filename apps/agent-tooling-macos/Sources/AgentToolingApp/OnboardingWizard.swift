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
            Hairline()
            progressHeader
            Hairline()
            VStack(alignment: .leading, spacing: Space.sm) {
                Text(step.title).font(AgentFont.pageTitle)
                Text(step.subtitle).font(AgentFont.body).foregroundStyle(.secondary)
                    .wrapsLines()
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, WorkspaceLayout.pageInset).padding(.top, Space.xxl).padding(.bottom, Space.xl)
            ScrollView {
                VStack(alignment: .leading, spacing: WorkspaceLayout.sectionSpacing) {
                    switch step {
                    case .found: foundStep
                    case .apps: appsStep
                    case .assign: assignStep
                    }
                }
                .padding(.horizontal, WorkspaceLayout.pageInset).padding(.bottom, Space.xxxl)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            Hairline()
            footer
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .frame(minWidth: 720, minHeight: 480)
        .sheet(isPresented: $isAssigning) {
            OnboardingAssignmentPickerSheet(session: workspace.library)
        }
    }

    private var progressHeader: some View {
        HStack(spacing: Space.lg) {
            Image(systemName: "slider.horizontal.3")
                .font(.system(size: Size.symbol, weight: .medium)).foregroundStyle(.secondary)
            Text("Set up Agent Tooling").font(AgentFont.bodySemibold)
            Spacer()
            Text("Step \(step.rawValue + 1) of \(OnboardingStep.allCases.count) · \(step.label)")
                .font(AgentFont.captionMedium).foregroundStyle(.secondary)
            HStack(spacing: Space.xs) {
                ForEach(OnboardingStep.allCases) { candidate in
                    Capsule().fill(candidate.rawValue <= step.rawValue ? AgentTheme.selection : Color.secondary.opacity(0.18))
                        .frame(width: Size.glyphSlot, height: Space.xs)
                }
            }.accessibilityHidden(true)
        }
        .padding(.horizontal, WorkspaceLayout.pageInset)
        .padding(.vertical, Space.xl)
    }

    // MARK: - Found

    @ViewBuilder
    private var foundStep: some View {
        if let library = workspace.library.state?.library {
            VStack(alignment: .leading, spacing: WorkspaceLayout.sectionSpacing) {
                Text(librarySummary(library)).font(AgentFont.body).foregroundStyle(.secondary)
                TitledCard("Apps on this Mac", count: "\(workspace.device.availableClients.count)") {
                    ForEach(Array(workspace.device.availableClients.enumerated()), id: \.element) { index, client in
                        foundClientRow(client)
                        if index < workspace.device.availableClients.count - 1 { Hairline(indent: Hairline.afterLeading(Size.tile)) }
                    }
                }
                TitledCard("In your library", count: "\(library.rows.count)") {
                    ForEach(Array(library.rows.prefix(6).enumerated()), id: \.element.id) { index, row in
                        foundLibraryRow(row)
                        if index < min(6, library.rows.count) - 1 { Hairline(indent: Hairline.afterLeading(Size.tile)) }
                    }
                    if library.rows.count > 6 {
                        Hairline(indent: Hairline.afterLeading(Size.tile))
                        Text("and \(library.rows.count - 6) more entries")
                            .font(AgentFont.caption).foregroundStyle(.secondary)
                            .padding(.horizontal, Space.lg).padding(.vertical, Space.md)
                    }
                }
                Text("This covers local agent setup. Cloud account connections and desktop-only settings remain in their own apps.")
                    .font(AgentFont.caption).foregroundStyle(.secondary)
            }
        } else {
            ProgressView("Reading your library…")
                .frame(maxWidth: .infinity, minHeight: 200)
        }
    }

    private func foundClientRow(_ client: ClientKind) -> some View {
        let verdict = workspace.device.verdict(for: client)
        return InfoRow(client.rawValue, detail: clientScope(client)) {
            ClientBrandIcon(client: client, size: Size.tileSmall).frame(width: Size.tile, height: Size.tile)
        } trailing: {
            StatusBadge(state: verdict.state, text: verdict.text)
        }
    }

    private func foundLibraryRow(_ row: WorkspaceLibraryReadModelRow) -> some View {
        InfoRow(row.displayName, detail: row.ownershipLabel) {
            KindTile(kind: ToolingKind(row.kind), size: Size.tile)
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
        VStack(alignment: .leading, spacing: WorkspaceLayout.sectionSpacing) {
            VStack(spacing: 0) {
                ForEach(Array(workspace.device.availableClients.enumerated()), id: \.element) { index, client in
                    if index > 0 { Hairline(indent: Hairline.afterLeading(Size.tileLarge, gap: Space.xl)) }
                    Toggle(isOn: clientBinding(client)) {
                        HStack(spacing: Space.xl) {
                            ClientBrandIcon(client: client, size: Size.tile)
                                .frame(width: Size.tileLarge, height: Size.tileLarge)
                            VStack(alignment: .leading, spacing: Space.xs) {
                                Text(client.rawValue).font(AgentFont.title)
                                Text(clientScope(client)).font(AgentFont.body).foregroundStyle(.secondary)
                            }
                            Spacer()
                        }
                    }
                    .toggleStyle(.checkbox)
                    .padding(Space.xxl)
                    .accessibilityLabel("Have this Mac manage \(client.rawValue)")
                }
            }
            .standardPanel()
            Text(
                "Tracking follows your library either way. Turning an app off here only stops this Mac from keeping it in sync — nothing already installed changes."
            )
            .font(AgentFont.body).foregroundStyle(.secondary)
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
            VStack(alignment: .leading, spacing: Space.xl) {
                Text(
                    "Nothing is assigned yet. Choosing tools here records where you want them; installing them into your apps stays a separate step you review."
                )
                .font(AgentFont.body).foregroundStyle(.secondary)
                if !canAssign {
                    AttentionBanner(
                        title: "Nothing can be assigned yet",
                        message:
                            "Nothing can be assigned yet: a first run only tracks what it finds. Manage a tool from the Library first, or finish now and come back."
                    )
                }
                if let error = workspace.library.errorMessage {
                    AttentionBanner(title: "Couldn’t prepare assignments", message: error)
                }
            }
        }
    }

    private var doneCard: some View {
        VStack(alignment: .leading, spacing: Space.xxl) {
            HStack(spacing: Space.xl) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: Size.heroSymbol)).foregroundStyle(AgentTheme.ok)
                VStack(alignment: .leading, spacing: Space.xs) {
                    Text("Your assignments are saved").font(AgentFont.title)
                    Text("Review installation changes to make them available in your apps.")
                        .font(AgentFont.body).foregroundStyle(.secondary)
                }
                Spacer()
            }
            Text("Make it yours").font(AgentFont.title)
            VStack(spacing: 0) {
                nextStepRow(
                    "Review app changes", detail: "Compare your saved assignments with this Mac.",
                    symbol: "arrow.triangle.2.circlepath", destination: .syncCenter)
                Hairline(indent: Hairline.afterLeading(Size.tile))
                nextStepRow(
                    "Set up a backup", detail: "Keep a local backup or choose an encrypted sync folder.",
                    symbol: "externaldrive", destination: .settings)
                Hairline(indent: Hairline.afterLeading(Size.tile))
                nextStepRow(
                    "Find useful skills", detail: "Choose whether to review recent work in Insights.",
                    symbol: "lightbulb", destination: .insights)
            }
            .standardPanel()
        }
    }

    private func nextStepRow(_ title: String, detail: String, symbol: String, destination: AppSection) -> some View {
        Button {
            onFinish()
            workspaceNavigate(destination)
        } label: {
            HStack(spacing: Space.lg) {
                Image(systemName: symbol).font(.system(size: Size.symbol)).foregroundStyle(.secondary).frame(width: Size.tile)
                VStack(alignment: .leading, spacing: Space.xxs) {
                    Text(title).font(AgentFont.bodySemibold)
                    Text(detail).font(AgentFont.body).foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: "chevron.right").font(AgentFont.caption).foregroundStyle(.tertiary)
            }.padding(Space.xl).contentShape(Rectangle())
        }.buttonStyle(.plain)
    }

    private var isDone: Bool { workspace.library.lastReceipt != nil }

    private var canAssign: Bool {
        workspace.library.state?.library.rows.contains(where: \.isAssignable) ?? false
    }

    // MARK: - Footer

    private var footer: some View {
        HStack(spacing: Space.lg) {
            if step != .assign || !isDone {
                Button("Set up later", action: onFinish)
                    .buttonStyle(.plain).foregroundStyle(.secondary)
            }
            Spacer()
            if step != .found, !(step == .assign && isDone) {
                Button("Back") { step = OnboardingStep(rawValue: step.rawValue - 1) ?? .found }
                    .buttonStyle(.glass)
            }
            if step == .assign {
                // The thorough route: audit this Mac and have the assistant
                // read the results, category by category, on the Checkup tab.
                Button("Check this Mac…", action: finishToSetup)
                    .buttonStyle(.glass)
                    .help("Find what is broken, duplicated, or unmanaged, and walk through what to change.")
            }
            Button(primaryTitle, action: advance)
                .primaryActionStyle()
                .keyboardShortcut(.defaultAction)
        }
        .controlSize(.large)
        .padding(.horizontal, WorkspaceLayout.pageInset)
        .padding(.vertical, Space.xl)
    }

    private var primaryTitle: String {
        switch step {
        case .found, .apps: "Continue"
        case .assign:
            if isDone { "Go to Home" }
            // A first run that found nothing a client already owns has nothing
            // to assign. Rather than trapping a person behind a disabled
            // button, the step offers a plain finish.
            else if canAssign { "Choose tools to assign…" }
            else { "Done" }
        }
    }

    private func advance() {
        switch step {
        case .found: step = .apps
        case .apps: step = .assign
        case .assign:
            if isDone {
                finishToHome()
            } else if canAssign {
                workspace.library.discardReview()
                isAssigning = true
            } else {
                // Nothing to assign: finishing is the only sensible move, so
                // "Done" ends onboarding and lands on Home the same way the
                // done state's "Go to Home" does.
                finishToHome()
            }
        }
    }

    /// Ends onboarding and navigates Home through the shell. One mechanism for
    /// every exit here, so "Go to Home", "Done", and the next-step rows all
    /// leave the wizard the same way rather than one going through the
    /// navigation state and the others through the shell.
    private func finishToHome() {
        onFinish()
        workspaceNavigate(.overview)
    }

    /// Ends onboarding on the Apps screen with the full setup wizard open,
    /// for a person who wants the audit and the assistant's read right away.
    private func finishToSetup() {
        onFinish()
        workspaceNavigate(.checkup)
    }


    private func clientScope(_ client: ClientKind) -> String {
        switch client {
        case .codex: "Agent configuration shared by Codex app and CLI"
        case .claude: "Claude Code skills, plugins, and MCP configuration"
        case .gemini: "Gemini CLI extensions and local configuration"
        case .kiro: "Kiro CLI skills and MCP configuration"
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
                Text("Choose tools to assign").font(AgentFont.title)
                Spacer()
            }.padding(Space.xxl)
            Hairline()
            if let library = session.state?.library {
                let visible = library.filteredRows(matching: search)
                HStack(spacing: Space.xl) {
                    InventorySearchField(placeholder: "Search your library", text: $search)
                    Button(search.isEmpty ? "Select all" : "Select results") { setSelected(visible, to: true) }
                        .disabled(!visible.contains(where: \.isAssignable))
                    Button("Clear") { setSelected(visible, to: false) }
                        .disabled(!visible.contains { selection.contains($0.artifactID) })
                }
                .font(AgentFont.body).buttonStyle(.plain)
                .padding(.horizontal, Space.xxl).padding(.bottom, Space.lg)
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
                            .collectionRowChrome(selected: false)
                    }
                    .collectionListChrome()
                }
            } else {
                ProgressView("Loading library…").frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            Hairline()
            HStack {
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Spacer()
                Text(selection.isEmpty ? "Nothing selected yet." : "\(selection.count) selected")
                    .foregroundStyle(.secondary)
                Button("Continue") { isReviewing = true }
                    .primaryActionStyle()
                    .disabled(selection.isEmpty || session.isBusy)
            }.padding(Space.xxl)
        }
        .sheetSize(SheetSize.large)
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
