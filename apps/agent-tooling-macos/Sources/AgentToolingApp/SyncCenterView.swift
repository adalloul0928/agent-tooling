import AgentToolingCore
import SwiftUI

protocol OperationReceiptReading: Sendable {
    func recentReceipts(store: WorkspaceRevisionStore, limit: Int) throws -> [OperationReceipt]
}

struct LiveOperationReceiptReader: OperationReceiptReading {
    func recentReceipts(store: WorkspaceRevisionStore, limit: Int) throws -> [OperationReceipt] {
        try store.operationReceipts(limit: limit)
    }
}

extension EnvironmentValues {
    @Entry var operationReceiptReader: any OperationReceiptReading = LiveOperationReceiptReader()
}

/// Apps: what this Mac's clients look like, what would change in them, and the
/// one reviewed step that changes anything.
///
/// Two claims are kept apart everywhere on this screen. What somebody asked for
/// lives in the library and is never drawn as an installation; what a client
/// actually holds comes from the last read-only check and is the only thing a
/// tile counts.
///
/// One row of tiles is the whole cast: each app this Mac manages, once. Picking
/// a tile narrows the lists under it to that app and nothing else changes: no
/// second toolbar, no other page. Times are the moment something happened, not
/// a clock running against it.
struct SyncCenterView: View {
    let workspace: WorkspaceLaunch.Workspace
    let requests: WorkspaceRequestSession
    /// The one client this visit is narrowed to, or every client.
    let client: ClientKind?
    let onShowAllClients: () -> Void
    let onReviewChanges: () -> Void
    let onReviewRequest: (PendingAgentRequest) -> Void

    @Environment(AppNavigationState.self) private var navigation
    @Environment(\.availableClients) private var enabledClients
    @Environment(\.workspaceNavigate) private var navigate
    @Environment(\.operationReceiptReader) private var receiptReader
    @State private var showingClientSelection = false
    @State private var isChoosingDestination = false
    @State private var receipts: [OperationReceipt] = []

    var body: some View {
        VStack(spacing: 0) {
            PageToolbar(title: "Apps", context: statusLine) {
                Button("Choose apps…") { showingClientSelection = true }
                    .buttonStyle(.glass)
                    .popover(isPresented: $showingClientSelection) {
                        ManagedClientsPopover(device: workspace.device).frame(width: 380)
                    }
                Button {
                    Task { await workspace.device.refresh() }
                } label: {
                    Label(
                        workspace.device.isChecking ? "Checking…" : "Check apps",
                        systemImage: "arrow.clockwise")
                }
                .buttonStyle(.glass)
                .disabled(workspace.device.isChecking)
                .help("Read what each app holds on this Mac. Nothing is changed.")
                .accessibilityLabel("Check apps")

                Button(action: onReviewChanges) {
                    Label(
                        workspace.deployment.isBusy ? "Preparing…" : reviewTitle,
                        systemImage: "arrow.down.circle")
                }
                .buttonStyle(.glassProminent)
                .tint(AgentTheme.selection)
                .disabled(workspace.deployment.isBusy)
                .help("See exactly what would change in each app before anything is written.")
                .accessibilityLabel(reviewTitle)
            }

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    ForEach(Array(problems.enumerated()), id: \.offset) { _, problem in
                        AttentionBanner(title: "Apps need attention", message: problem)
                    }

                    appTiles

                    if let plan = workspace.deployment.plan {
                        let items = scoped(plan.items)
                        if !items.isEmpty { changesCard(items) }
                    }

                    if !scopedRequests.isEmpty { pendingRequestsCard }

                    receiptsCard

                    linkedDestinationsCard
                }
                .frame(maxWidth: 1_200, alignment: .leading)
                .padding(.horizontal, WorkspaceLayout.pageInset)
                .padding(.top, WorkspaceLayout.contentTopInset)
                .padding(.bottom, WorkspaceLayout.pageInset)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .scrollIndicators(.hidden)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .sheet(isPresented: $isChoosingDestination) {
            WorkspaceLinkDestinationSheet(session: workspace.deployment)
        }
        .task {
            // The shell opens the workspace without reading its library, so a
            // screen that arrives first has to read it or it would report a
            // full library as an empty one. A library another screen already
            // read is left alone.
            if workspace.library.state == nil { await workspace.library.refresh() }
            await requests.refresh()
        }
        // Re-read after a run, so "Recent changes" is what just happened rather
        // than what happened before it.
        .task(id: workspace.deployment.results.count) { await loadReceipts() }
        // What would change is a read, so it is worked out as soon as a check
        // has landed in the library, and again after every later check, rather
        // than waiting for somebody to ask. Asking opens the review; this only
        // fills the tiles and the line under the title.
        .task(id: scanStamp) {
            guard scanStamp != nil else { return }
            await workspace.deployment.prepare()
        }
        .onChange(of: workspace.device.enabledClients) { _, _ in
            if let client, !workspace.device.isEnabled(client) { onShowAllClients() }
        }
    }

    // MARK: - Header

    /// One line under the title. It says the most useful true thing and nothing
    /// else: what is waiting, or that nothing is, and when this Mac last looked.
    private var statusLine: String {
        if workspace.device.observations.isEmpty { return "Check your apps to see what they hold" }
        guard let plan = workspace.deployment.plan else {
            if workspace.deployment.isBusy { return "Working out what would change…" }
            return lastChecked.map { "Checked \(SnapshotTime.compact($0))" } ?? "Checked"
        }
        let waiting = scoped(plan.items).count
        if waiting > 0 { return "\(waiting) change\(waiting == 1 ? "" : "s") ready to install" }
        if !scopedRequests.isEmpty {
            return "\(scopedRequests.count) request\(scopedRequests.count == 1 ? "" : "s") waiting for review"
        }
        let attention = workspace.device.attentionCount
        if attention > 0 { return "\(attention) app\(attention == 1 ? " needs" : "s need") attention" }
        return lastChecked.map { "Up to date · checked \(SnapshotTime.compact($0))" } ?? "Up to date"
    }

    private var reviewTitle: String {
        let count = workspace.deployment.plan?.items.count ?? 0
        return count == 0 ? "Review changes" : "Review \(count) change\(count == 1 ? "" : "s")"
    }

    // MARK: - Tiles

    /// Each app this Mac manages, once. The tile is the app's whole verdict:
    /// whether its tool answered, when, what it holds, and what is waiting for
    /// it. Choosing one narrows the rest of the screen to it.
    private var appTiles: some View {
        Group {
            if enabledClients.isEmpty {
                EmptyStateView(
                    symbol: "macwindow.badge.plus",
                    title: "No apps chosen",
                    message: "Choose which apps this Mac looks after. Their software and configuration stay as they are.",
                    actionTitle: "Choose apps…",
                    action: { showingClientSelection = true }
                )
                .frame(height: 180)
            } else {
                HStack(alignment: .top, spacing: 12) {
                    ForEach(enabledClients) { app in
                        AppTile(
                            client: app,
                            verdict: workspace.device.verdict(for: app),
                            version: version(for: app),
                            held: held(for: app),
                            waiting: (workspace.deployment.plan?.items ?? []).count { $0.surface.client == app },
                            selected: client == app
                        ) {
                            if client == app { onShowAllClients() } else { navigation.openClient(app) }
                        }
                    }
                }
            }
        }
    }

    // MARK: - Cards

    /// What a prepared plan would put where, by app. Reading, not doing: the
    /// review is where each step is approved.
    private func changesCard(_ items: [WorkspaceDeploymentItem]) -> some View {
        TitledCard("Ready to install", count: "\(items.count)") {
            Button("Review…", action: onReviewChanges)
                .buttonStyle(.borderless)
                .disabled(workspace.deployment.isBusy)
        } content: {
            let groups = grouped(items)
            ForEach(groups) { group in
                InfoRow(group.client.rawValue, detail: summary(of: group.items)) {
                    ClientDisc(client: group.client, size: 30)
                } trailing: {
                    Text("\(group.items.count)")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.tertiary)
                }
                if group.id != groups.last?.id { Divider().opacity(0.35) }
            }
            Text("Nothing has been written. The review shows each step, and what is not being installed.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 14)
                .padding(.bottom, 12)
                .padding(.top, 4)
        }
    }

    private var pendingRequestsCard: some View {
        let visible = Array(scopedRequests.prefix(8))
        return TitledCard(
            "Waiting for review",
            count: "\(scopedRequests.count) request\(scopedRequests.count == 1 ? "" : "s")"
        ) {
            Text("Local requests nobody has decided yet. None has changed an app.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 14)
                .padding(.top, 12)
            ForEach(visible) { request in
                InfoRow(
                    request.title,
                    detail: "\(request.kind.displayName) · \(SnapshotTime.compact(request.createdAt))"
                ) {
                    SymbolTile(symbol: "tray.and.arrow.down", size: 30)
                } trailing: {
                    Button("Review") { onReviewRequest(request) }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .accessibilityLabel("Review \(request.title)")
                }
                if request.id != visible.last?.id { Divider().opacity(0.35) }
            }
            if scopedRequests.count > visible.count {
                Text("\(scopedRequests.count - visible.count) more are waiting. Review these to reveal the rest.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(14)
            }
        }
    }

    private var receiptsCard: some View {
        TitledCard("Recent changes", count: scopedReceipts.isEmpty ? nil : "\(scopedReceipts.count)") {
            if scopedReceipts.count > recentReceipts.count {
                Button("See all", systemImage: "chevron.right") { navigate(.activity) }
                    .buttonStyle(.borderless)
                    .labelStyle(.titleAndIcon)
            }
        } content: {
            if scopedReceipts.isEmpty {
                Text(client.map { "Nothing has been changed in \($0.rawValue) yet." } ?? "Nothing has been changed yet.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .padding(14)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                ForEach(recentReceipts) { receipt in
                    InfoRow(receipt.title, detail: receipt.verificationSummary) {
                        StatusGlyph(state: receipt.state, size: 16)
                    } trailing: {
                        Text(SnapshotTime.standalone(receipt.createdAt))
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                    if receipt.id != recentReceipts.last?.id { Divider().opacity(0.35) }
                }
            }
        }
    }

    /// Where each app's tools go on this Mac, when that is not the app's own
    /// folder. Registering one moves nothing; it only says where a later
    /// install would write.
    private var linkedDestinationsCard: some View {
        TitledCard("Folders") {
            Button("Choose a folder…", systemImage: "folder.badge.plus") { isChoosingDestination = true }
                .buttonStyle(.borderless)
                .disabled(workspace.deployment.isBusy)
        } content: {
            if workspace.deployment.linkedDestinations.isEmpty {
                Text("Each app uses its own folder. Point one somewhere else if you keep a folder in step yourself.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .padding(14)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                ForEach(workspace.deployment.linkedDestinations) { destination in
                    InfoRow(
                        "\(destination.surface.displayName) · \(destination.projectName ?? destination.scope.displayName)"
                    ) {
                        SymbolTile(symbol: "folder", size: 30)
                    } trailing: {
                        HStack(spacing: 10) {
                            LocationText(path: destination.path)
                            Button("Use the app's own folder") {
                                Task { await workspace.deployment.unlinkDestination(destination.id) }
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                            .disabled(workspace.deployment.isBusy)
                        }
                    }
                    if destination.id != workspace.deployment.linkedDestinations.last?.id {
                        Divider().opacity(0.35)
                    }
                }
            }
        }
    }

    // MARK: - Data

    /// What the last check found in one app, counted by name across every
    /// surface the app has. Found, not asked for.
    private func held(for app: ClientKind) -> AppTile.Held? {
        let mine = workspace.device.observations.filter { $0.surface.client == app }
        guard !mine.isEmpty else { return nil }
        return AppTile.Held(
            skills: Set(mine.flatMap(\.discoveredSkills)).count,
            servers: Set(mine.flatMap(\.discoveredMCPServers)).count,
            plugins: Set(mine.flatMap(\.discoveredPlugins)).count)
    }

    private func version(for app: ClientKind) -> String? {
        workspace.device.observations.first { $0.surface.client == app && $0.version?.isEmpty == false }?.version
    }

    private var lastChecked: Date? {
        workspace.device.observations.map(\.lastScannedAt).max()
    }

    /// When the check the library currently holds was made. It moves only once
    /// a check has been recorded and read back, which is the moment a plan over
    /// it means anything.
    private var scanStamp: Date? {
        workspace.library.state?.snapshot.device.observations.map(\.lastScannedAt).max()
    }

    private func scoped(_ items: [WorkspaceDeploymentItem]) -> [WorkspaceDeploymentItem] {
        items.filter { client == nil || $0.surface.client == client }
    }

    private func grouped(_ items: [WorkspaceDeploymentItem]) -> [ClientGroup] {
        enabledClients.compactMap { app in
            let mine = items.filter { $0.surface.client == app }
            return mine.isEmpty ? nil : ClientGroup(client: app, items: mine)
        }
    }

    /// The names, up to a few, and how many more there are.
    private func summary(of items: [WorkspaceDeploymentItem]) -> String {
        let names = items.map(\.displayName)
        let shown = names.prefix(4).joined(separator: ", ")
        let more = names.count - min(names.count, 4)
        return more == 0 ? shown : "\(shown) and \(more) more"
    }

    private var scopedRequests: [PendingAgentRequest] {
        requests.requests.filter { request in
            guard let client else { return true }
            return request.targets.contains(client)
        }
    }

    private var scopedReceipts: [OperationReceipt] {
        receipts.filter { receipt in
            guard let client else { return true }
            return receipt.targetSurfaces.contains { $0.client == client }
        }
    }

    private var recentReceipts: [OperationReceipt] {
        Array(
            scopedReceipts.sorted {
                if $0.createdAt == $1.createdAt { return $0.id.uuidString < $1.id.uuidString }
                return $0.createdAt > $1.createdAt
            }.prefix(4))
    }

    private var problems: [String] {
        [
            workspace.deployment.errorMessage, workspace.device.errorMessage, requests.errorMessage,
        ]
        .compactMap { $0 }
    }

    private func loadReceipts() async {
        let store = workspace.store
        let reader = receiptReader
        receipts =
            (try? await Task.detached { try reader.recentReceipts(store: store, limit: 50) }.value) ?? []
    }
}

private struct ClientGroup: Identifiable {
    let client: ClientKind
    let items: [WorkspaceDeploymentItem]
    var id: ClientKind { client }
}

/// One app, once: its mark, its name, one clause, its verdict, and what is
/// waiting for it. The whole tile is the way to narrow the screen to it.
private struct AppTile: View {
    struct Held: Equatable {
        let skills: Int
        let servers: Int
        let plugins: Int
    }

    let client: ClientKind
    let verdict: ClientVerdict
    let version: String?
    let held: Held?
    let waiting: Int
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .top, spacing: 10) {
                    ClientDisc(client: client, size: 34)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(client.rawValue)
                            .font(.callout.weight(.semibold))
                            .lineLimit(1)
                        Text(clause)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 8)
                    StatusGlyph(state: verdict.state, size: 14)
                        .padding(.top, 2)
                }
                HStack(spacing: 8) {
                    Text(heldText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    Spacer(minLength: 6)
                    if waiting > 0 {
                        Text("\(waiting) to install")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(AgentTheme.selection)
                    }
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .standardPanel()
        .overlay {
            RoundedRectangle(cornerRadius: AgentTheme.panelCornerRadius, style: .continuous)
                .stroke(selected ? AgentTheme.selection : Color.clear, lineWidth: 1.5)
        }
        .help(selected ? "Show every app again" : "Show only \(client.rawValue)")
        .accessibilityLabel("\(client.rawValue), \(clause)")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    /// The tool's version and when it was last read, or why it could not be.
    private var clause: String {
        [version, verdict.text].compactMap { $0 }.joined(separator: " · ")
    }

    private var heldText: String {
        guard let held else { return "Not checked yet" }
        return "\(held.skills) skills · \(held.servers) servers · \(held.plugins) plugins"
    }
}

/// Which apps this Mac manages.
///
/// Unchecking one records a choice and nothing else: its software and its
/// configuration stay exactly where they are, and nothing is removed from it.
private struct ManagedClientsPopover: View {
    let device: WorkspaceDeviceSession

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Clients you use").font(.headline)
            Text(
                "Unchecked clients are hidden throughout Agent Tooling and excluded from checks and changes. Their software and configuration stay on this Mac."
            )
            .font(.caption).foregroundStyle(.secondary)
            ForEach(device.availableClients) { client in
                Toggle(
                    isOn: Binding(
                        get: { device.isEnabled(client) },
                        set: { enabled in Task { await device.setEnabled(client, enabled) } })
                ) {
                    HStack(spacing: 10) {
                        ClientBrandIcon(client: client, size: 20)
                        Text(client.rawValue)
                    }
                }
                .toggleStyle(.checkbox)
                .accessibilityLabel("Use \(client.rawValue)")
                .disabled(device.isChecking)
            }
            if device.enabledClients.isEmpty {
                Text("Select a client whenever you’re ready. Your local library remains available.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if let message = device.errorMessage {
                Text(message).font(.caption).foregroundStyle(AgentTheme.warning)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(16)
    }
}

/// Choosing which destination goes somewhere other than its app's own folder.
private struct WorkspaceLinkDestinationSheet: View {
    let session: WorkspaceDeploymentSession
    @Environment(\.dismiss) private var dismiss
    @State private var client: ClientKind = .codex
    @State private var folder: URL?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Send an app's tools somewhere else").font(.title3.weight(.semibold))
                Spacer()
                Button("Cancel") { dismiss() }.buttonStyle(.glass).keyboardShortcut(.cancelAction)
            }.padding(20)
            Divider()
            VStack(alignment: .leading, spacing: 18) {
                Text(
                    "Agent Tooling normally writes into each app's own folder. Point one somewhere else and it writes there instead — into the folder you name, under each tool's own name."
                )
                .foregroundStyle(.secondary)
                Text(
                    "Nothing already in that folder is replaced. If a tool's name is already taken there, the install stops and says so rather than writing over it."
                )
                .font(.callout).foregroundStyle(.secondary)
                Picker("App", selection: $client) {
                    ForEach(ClientKind.allCases) { value in Text(value.rawValue).tag(value) }
                }.frame(maxWidth: 280)
                HStack(spacing: 12) {
                    Button("Choose folder…") { choose() }
                    Text(folder?.path ?? "No folder chosen").foregroundStyle(.secondary).lineLimit(2)
                }
                Spacer(minLength: 0)
            }.padding(20)
            Divider()
            HStack {
                Text("This records where a later install would write. Nothing moves now.")
                    .font(.callout).foregroundStyle(.secondary)
                Spacer()
                Button("Use this folder") {
                    guard let folder else { return }
                    Task {
                        await session.linkDestination(
                            surface: surface, scope: .user,
                            projectID: nil, to: folder)
                        dismiss()
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(folder == nil || session.isBusy)
            }.padding(20)
        }
        .frame(width: 580, height: 420)
        .background(AgentTheme.contentBackground)
    }

    private var surface: TargetSurface {
        switch client {
        case .claude: .claudeCode
        case .codex: .codexCLI
        case .gemini: .geminiCLI
        }
    }

    private func choose() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.prompt = "Use Folder"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        folder = url.standardizedFileURL
    }
}
