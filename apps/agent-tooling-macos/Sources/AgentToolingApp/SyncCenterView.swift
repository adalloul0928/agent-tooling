import AgentToolingCore
import Foundation
import SwiftUI

/// This Mac's own receipts, behind a protocol.
///
/// Reading them opens the store, which a render test must be able to answer
/// without doing.
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
/// actually holds comes from the last read-only check and is the only thing the
/// app columns count.
struct SyncCenterView: View {
    let workspace: WorkspaceLaunch.Workspace
    let requests: WorkspaceRequestSession
    /// The one client this visit is scoped to, or every client.
    let client: ClientKind?
    let onShowAllClients: () -> Void
    let onReviewChanges: () -> Void
    let onReviewRequest: (PendingAgentRequest) -> Void

    @Environment(AppNavigationState.self) private var navigation
    @Environment(\.availableClients) private var enabledClients
    @Environment(\.workspaceNavigate) private var navigate
    @Environment(\.operationReceiptReader) private var receiptReader
    @State private var showingClientSelection = false
    @State private var receipts: [OperationReceipt] = []

    var body: some View {
        VStack(spacing: 0) {
            PageToolbar(title: "Clients", context: toolbarContext) {
                Button("Choose apps…") { showingClientSelection = true }
                    .buttonStyle(.glass)
                    .popover(isPresented: $showingClientSelection) {
                        ManagedClientsPopover(device: workspace.device).frame(width: 380)
                    }
                Button {
                    Task { await workspace.device.refresh() }
                } label: {
                    Label(
                        workspace.device.isChecking ? "Refreshing…" : refreshButtonTitle,
                        systemImage: "arrow.clockwise")
                }
                .buttonStyle(.glass)
                .disabled(workspace.device.isChecking)
                .help(refreshHelp)
                .accessibilityLabel(refreshButtonTitle)

                Button {
                    if client != nil { onShowAllClients() }
                    onReviewChanges()
                } label: {
                    Label(
                        workspace.deployment.isBusy ? "Preparing…" : reviewButtonTitle,
                        systemImage: "arrow.triangle.2.circlepath")
                }
                .buttonStyle(.glassProminent)
                .tint(AgentTheme.selection)
                .disabled(workspace.deployment.isBusy)
                .help(reviewHelp)
                .accessibilityLabel(reviewButtonTitle)
            }

            if let client {
                clientScopeBar(client)
            }

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text(introText)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 2)

                    ForEach(Array(problems.enumerated()), id: \.offset) { _, problem in
                        AttentionBanner(title: "Apps need attention", message: problem)
                    }

                    if let plan = workspace.deployment.plan, !plan.items.isEmpty {
                        preparedPlanBanner(plan)
                    }

                    if !workspace.deployment.results.isEmpty { resultsCard }

                    if !scopedRequests.isEmpty {
                        pendingRequestsCard
                    }

                    conduit

                    ToolingMatrixView(rows: matrixRows, clients: visibleClients) { section in
                        navigate(section)
                    }

                    HStack(alignment: .top, spacing: 16) {
                        clientsCard.frame(maxWidth: .infinity)
                        receiptsCard.frame(maxWidth: .infinity)
                    }
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
        .onChange(of: workspace.device.enabledClients) { _, _ in
            if let client, !workspace.device.isEnabled(client) { onShowAllClients() }
        }
    }

    // MARK: - Header

    private var toolbarContext: String {
        if let client {
            let verdict = workspace.device.verdict(for: client)
            let pending = scopedRequests.count
            return "\(client.rawValue) · \(verdict.text)"
                + (pending == 0 ? "" : " · \(pending) request\(pending == 1 ? "" : "s") waiting")
        }
        if !scopedRequests.isEmpty {
            return
                "\(scopedRequests.count) review request\(scopedRequests.count == 1 ? "" : "s") waiting"
        }
        if sortedTargets.isEmpty { return "Refresh to discover your local apps" }
        let attention = workspace.device.attentionCount
        return attention == 0
            ? "Local apps match your configuration"
            : "\(attention) \(attention == 1 ? "item needs" : "items need") attention"
    }

    private func clientScopeBar(_ client: ClientKind) -> some View {
        HStack(spacing: 10) {
            Button {
                onShowAllClients()
            } label: {
                Label("All Clients", systemImage: "chevron.backward")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .help("Back to all clients")
            .accessibilityLabel("Back to All Clients")

            Divider().frame(height: 20)
            ClientDisc(client: client, size: 24)
            Text("Showing \(client.rawValue) only")
                .font(.callout.weight(.semibold))
            Spacer()
            let verdict = workspace.device.verdict(for: client)
            StatusBadge(state: verdict.state, text: verdict.text)
        }
        .padding(.horizontal, 18)
        .frame(minHeight: 44)
        .background(AgentTheme.controlBackground.opacity(0.62))
        .overlay(alignment: .bottom) { Divider().opacity(0.45) }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Client scope: \(client.rawValue) only")
    }

    // MARK: - Cards

    /// The signature path: library → what is asked for → each app's own verdict.
    private var conduit: some View {
        SyncConduitView(
            managedCount: managedCount,
            discoveredCount: discoveredCount,
            profileName: "Assignments",
            desiredCount: desiredCount,
            pendingCount: attentionCount,
            terminals: visibleClients.map { client in
                let verdict = workspace.device.verdict(for: client)
                return ConduitTerminal(client: client, state: verdict.state, text: verdict.text)
            },
            // A terminal scopes this screen to one app. It never starts a check
            // and never writes anything.
            onLibrary: { navigate(.skills) },
            onProfile: { navigate(.projects) },
            onClient: { navigation.openClient($0) })
    }

    private func preparedPlanBanner(_ plan: WorkspaceDeploymentPlan) -> some View {
        AttentionBanner(
            title: plan.items.count == 1 ? "1 change ready" : "\(plan.items.count) changes ready",
            message:
                "Nothing has been written yet. Open the review to see each step, and what is not being installed."
        ) {
            Button("Review changes", action: onReviewChanges)
                .buttonStyle(.borderedProminent)
                .tint(AgentTheme.selection)
                .disabled(workspace.deployment.isBusy)
        }
    }

    /// What the last run actually did. Only a step that succeeded counts, so a
    /// saved assignment never turns up here as an installation.
    private var resultsCard: some View {
        TitledCard("What just happened", count: "last run") {
            ForEach(workspace.deployment.results) { result in
                InfoRow(result.title, detail: resultSummary(result)) {
                    StatusGlyph(state: result.failed == 0 ? .healthy : .attention, size: 16)
                } trailing: {
                    Text("\(result.succeeded) installed")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.tertiary)
                }
                if result.id != workspace.deployment.results.last?.id { Divider().opacity(0.35) }
            }
        }
    }

    private var pendingRequestsCard: some View {
        let visible = Array(scopedRequests.prefix(8))
        return TitledCard(
            "Waiting for review",
            count: "\(scopedRequests.count) request\(scopedRequests.count == 1 ? "" : "s")"
        ) {
            Text(
                "These are untrusted local requests. Review or reject each one in Agent Tooling; none has changed a client."
            )
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 14)
            .padding(.top, 12)
            ForEach(visible) { request in
                InfoRow(
                    request.title,
                    detail:
                        "\(request.kind.displayName) · \(request.createdAt.formatted(.relative(presentation: .named)))"
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
                Text(
                    "\(scopedRequests.count - visible.count) more requests are waiting. Review these to reveal the rest."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(14)
            }
        }
    }

    private var clientsCard: some View {
        TitledCard(client?.rawValue ?? "Apps", count: "read-only check") {
            if sortedTargets.isEmpty {
                EmptyStateView(
                    symbol: "arrow.clockwise",
                    title: client.map { "\($0.rawValue) has not been checked" }
                        ?? "Apps have not been checked",
                    message: client.map {
                        "Refresh checks to inspect \($0.rawValue)'s known configuration paths and command-line tools."
                    } ?? "Check apps to inspect known configuration paths and command-line tools."
                )
                .frame(height: 210)
            } else {
                ForEach(sortedTargets) { target in
                    InfoRow(
                        target.surface.displayName,
                        detail: target.version ?? "Command-line tool not found"
                    ) {
                        if let client = target.surface.client {
                            ClientDisc(client: client, size: 28)
                        } else {
                            SymbolTile(symbol: "app", size: 28)
                        }
                    } trailing: {
                        StatusBadge(
                            state: target.isCommandAvailable ? .healthy : .attention,
                            text: target.isCommandAvailable
                                ? "Available" : (target.installed ? "Configuration only" : "Not found")
                        )
                    }
                    if target.id != sortedTargets.last?.id { Divider().opacity(0.35) }
                }
            }
        }
    }

    private var receiptsCard: some View {
        TitledCard(
            "Recent changes",
            count: scopedReceipts.count > 4
                ? "showing 4 of \(scopedReceipts.count)" : "\(scopedReceipts.count) saved"
        ) {
            if scopedReceipts.isEmpty {
                Text(
                    client.map {
                        "No saved change targets \($0.rawValue). Review All Changes returns to the complete client view before preparing a plan."
                    }
                        ?? "No files have been changed. Review changes creates a plan before anything is written."
                )
                .font(.callout)
                .foregroundStyle(.secondary)
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                ForEach(recentReceipts) { receipt in
                    InfoRow(receipt.title, detail: receipt.verificationSummary) {
                        StatusGlyph(state: receipt.state, size: 16)
                    } trailing: {
                        Text(receipt.createdAt, style: .relative)
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                    if receipt.id != recentReceipts.last?.id { Divider().opacity(0.35) }
                }
            }
        }
    }

    // MARK: - Data

    private var libraryModel: WorkspaceLibraryReadModel? { workspace.library.state?.library }

    /// The library in the shape the surviving services already speak. Absent
    /// until the library has been read once; there is no empty one to stand in
    /// for it, and pretending otherwise would report a real library as empty.
    private var inventory: VersionedInventoryProjection.Inventory? {
        libraryModel.map(VersionedInventoryProjection.inventory)
    }

    private var sortedTargets: [TargetObservation] {
        workspace.device.observations
            .filter { client == nil || $0.surface.client == client }
            .sorted {
                $0.surface.displayName.localizedStandardCompare($1.surface.displayName)
                    == .orderedAscending
            }
    }

    private var visibleClients: [ClientKind] {
        client.map { workspace.device.isEnabled($0) ? [$0] : [] } ?? enabledClients
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

    /// Everything worth looking at: the changes a plan is holding, and the
    /// requests nobody has decided yet.
    private var attentionCount: Int {
        (workspace.deployment.plan?.items.count ?? 0) + scopedRequests.count
    }

    private var problems: [String] {
        [
            workspace.deployment.errorMessage, workspace.device.errorMessage, requests.errorMessage,
        ]
        .compactMap { $0 }
    }

    /// What this Mac is looking after, and what it has merely noticed.
    private var managedCount: Int {
        guard let libraryModel else { return 0 }
        return libraryModel.rows
            .filter { $0.ownership != .trackedOnly }
            .reduce(0) { $0 + 1 + $1.childCount }
    }

    private var discoveredCount: Int {
        libraryModel?.rows.count { $0.ownership == .trackedOnly } ?? 0
    }

    /// How many library items are asked for anywhere this scope can see. Asked
    /// for, not installed.
    private var desiredCount: Int {
        guard let libraryModel else { return 0 }
        return libraryModel.rows.count { row in
            row.requestedAssignments.contains { assignment in
                guard let client else { return true }
                return assignment.destination.surface.client == client
            }
        }
    }

    private var matrixRows: [ToolingMatrixRow] {
        [
            ToolingMatrixRow(
                id: .skills, title: "Skills", symbol: "doc.text",
                libraryCount: libraryCount(.skill),
                installedCounts: installedCounts(\.discoveredSkills), kind: .skill),
            ToolingMatrixRow(
                id: .mcpServers, title: "MCP servers", symbol: "server.rack",
                libraryCount: libraryCount(.mcpServer),
                installedCounts: installedCounts(\.discoveredMCPServers), kind: .mcpServer),
            ToolingMatrixRow(
                id: .plugins, title: "Plugins", symbol: "puzzlepiece.extension",
                libraryCount: libraryCount(.plugin),
                installedCounts: installedCounts(\.discoveredPlugins), kind: .plugin),
        ]
    }

    /// What the library knows about, scoped to one client by where its items
    /// are asked for. A requested destination is what makes an item belong to a
    /// client's column here; it never makes it installed.
    private func libraryCount(_ kind: LibraryColumn) -> Int {
        guard let inventory else { return 0 }
        switch kind {
        case .skill: return scopedCount(inventory.skills.map(\.clients))
        case .mcpServer: return scopedCount(inventory.mcpServers.map(\.clients))
        case .plugin: return scopedCount(inventory.plugins.map(\.clients))
        }
    }

    private func scopedCount(_ clientLists: [[ClientState]]) -> Int {
        guard let client else { return clientLists.count }
        return clientLists.count { states in states.contains { $0.client == client } }
    }

    /// What the last check actually found in each app, by name.
    ///
    /// This is the only honest source for these columns: the read model records
    /// what somebody asked for, and asking is not installing.
    private func installedCounts(_ discovered: KeyPath<TargetObservation, [String]>)
        -> [ClientKind: Int]
    {
        Dictionary(
            uniqueKeysWithValues: visibleClients.map { client in
                let names = workspace.device.observations
                    .filter { $0.surface.client == client }
                    .flatMap { $0[keyPath: discovered] }
                return (client, Set(names).count)
            })
    }

    private enum LibraryColumn { case skill, mcpServer, plugin }

    private func loadReceipts() async {
        let store = workspace.store
        let reader = receiptReader
        receipts =
            (try? await Task.detached { try reader.recentReceipts(store: store, limit: 50) }.value) ?? []
    }

    // MARK: - Copy

    private var introText: String {
        if let client {
            return
                "Showing only \(client.rawValue)'s local state and saved changes. Refresh Checks scans local apps and keeps this scope."
        }
        return "Compare local state first. Review the exact plan before Agent Tooling changes a client."
    }

    private var refreshButtonTitle: String { client == nil ? "Check apps" : "Refresh Checks" }

    private var refreshHelp: String {
        client.map {
            "Re-scan local apps, then continue showing only \($0.rawValue)."
        } ?? "Scan this Mac for each client's command and configuration state."
    }

    private var reviewButtonTitle: String { client == nil ? "Review Changes" : "Review All Changes" }

    private var reviewHelp: String {
        client == nil
            ? "Prepare one reviewable plan for client changes."
            : "Return to All Clients and prepare one reviewable plan for every client change."
    }

    private func resultSummary(_ result: WorkspaceDeploymentSession.Result) -> String {
        if result.failed == 0 {
            return result.succeeded == 1 ? "1 installed." : "\(result.succeeded) installed."
        }
        return
            "\(result.succeeded) installed, \(result.failed) could not be. Nothing partial was left behind."
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
