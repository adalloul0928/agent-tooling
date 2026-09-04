import AgentToolingCore
import SwiftUI

struct SyncCenterView: View {
    @Environment(AppModel.self) private var model
    @Environment(AppNavigationState.self) private var navigation
    let client: ClientKind?
    let onShowAllClients: () -> Void

    init(client: ClientKind? = nil, onShowAllClients: @escaping () -> Void = {}) {
        self.client = client
        self.onShowAllClients = onShowAllClients
    }

    var body: some View {
        VStack(spacing: 0) {
            PageToolbar(title: "Clients", context: toolbarContext) {
                Button {
                    Task { await model.runDoctor() }
                } label: {
                    Label(model.isRunningDoctor ? "Refreshing…" : refreshButtonTitle, systemImage: "arrow.clockwise")
                }
                .buttonStyle(.bordered)
                .disabled(model.isInteractionLocked)
                .help(refreshHelp)
                .accessibilityLabel(refreshButtonTitle)

                Button {
                    if client != nil { onShowAllClients() }
                    Task { await model.runSync() }
                } label: {
                    Label(model.isSyncing ? "Preparing…" : reviewButtonTitle, systemImage: "arrow.triangle.2.circlepath")
                }
                .buttonStyle(.borderedProminent)
                .disabled(model.isInteractionLocked)
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

                    if !scopedPendingRequests.isEmpty {
                        pendingRequestsCard
                    }

                    ToolingMatrixView(rows: matrixRows, clients: visibleClients)

                    HStack(alignment: .top, spacing: 16) {
                        clientsCard.frame(maxWidth: .infinity)
                        receiptsCard.frame(maxWidth: .infinity)
                    }
                }
                .padding(EdgeInsets(top: 4, leading: 22, bottom: 22, trailing: 22))
                .frame(maxWidth: 1_060)
                .frame(maxWidth: .infinity)
            }
            .scrollIndicators(.hidden)
        }
        .onAppear { model.refreshPendingRequests() }
    }

    private var toolbarContext: String {
        if let client {
            let verdict = model.clientVerdict(for: client)
            let pending = scopedPendingRequests.count
            return "\(client.rawValue) · \(verdict.text)"
                + (pending == 0 ? "" : " · \(pending) request\(pending == 1 ? "" : "s") waiting")
        }
        if !scopedPendingRequests.isEmpty {
            return "\(scopedPendingRequests.count) review request\(scopedPendingRequests.count == 1 ? "" : "s") waiting"
        }
        return model.attentionCount == 0
            ? "Clients match the desired configuration"
            : "\(model.attentionCount) \(model.attentionCount == 1 ? "item needs" : "items need") attention"
    }

    private var clientsCard: some View {
        TitledCard(client?.rawValue ?? "Clients", count: "read-only check") {
            if sortedTargets.isEmpty {
                EmptyStateView(
                    symbol: "arrow.clockwise",
                    title: client.map { "\($0.rawValue) has not been checked" } ?? "Clients have not been checked",
                    message: client.map {
                        "Refresh checks to inspect \($0.rawValue)'s known configuration paths and command-line tools."
                    } ?? "Check clients to inspect known configuration paths and command-line tools."
                )
                .frame(height: 210)
            } else {
                ForEach(sortedTargets) { target in
                    InfoRow(target.surface.displayName, detail: target.version ?? "Command-line tool not found") {
                        if let client = target.surface.client {
                            ClientDisc(client: client, size: 28)
                        } else {
                            SymbolTile(symbol: "app", size: 28)
                        }
                    } trailing: {
                        StatusBadge(
                            state: target.isCommandAvailable ? .healthy : .attention,
                            text: target.isCommandAvailable ? "Available" : (target.installed ? "Configuration only" : "Not found")
                        )
                    }
                    if target.id != sortedTargets.last?.id { Divider().opacity(0.35) }
                }
            }
        }
    }

    private var pendingRequestsCard: some View {
        let visible = Array(scopedPendingRequests.prefix(8))
        return TitledCard(
            "Waiting for review",
            count: "\(scopedPendingRequests.count) request\(scopedPendingRequests.count == 1 ? "" : "s")"
        ) {
            Text("These are untrusted local requests. Review or reject each one in Agent Tooling; none has changed a client.")
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
                    Button("Review") {
                        navigation.open(.pendingRequest(request.id))
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .accessibilityLabel("Review \(request.title)")
                }
                if request.id != visible.last?.id { Divider().opacity(0.35) }
            }
            if scopedPendingRequests.count > visible.count {
                Text("\(scopedPendingRequests.count - visible.count) more requests are waiting. Review these to reveal the rest.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(14)
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
                    } ?? "No files have been changed. Review changes creates a plan before anything is written."
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

    private var sortedTargets: [TargetObservation] {
        model.targetObservations
            .filter { client == nil || $0.surface.client == client }
            .sorted { $0.surface.displayName.localizedStandardCompare($1.surface.displayName) == .orderedAscending }
    }

    private var matrixRows: [ToolingMatrixRow] {
        [
            ToolingMatrixRow(
                id: .skills, title: "Skills", symbol: "doc.text",
                libraryCount: scopedLibraryCount(for: model.skills.map(\.clients)),
                installedCounts: installedCounts(for: model.skills.map(\.clients)), kind: .skill
            ),
            ToolingMatrixRow(
                id: .mcpServers, title: "MCP servers", symbol: "server.rack",
                libraryCount: scopedLibraryCount(for: model.mcpServers.map(\.clients)),
                installedCounts: installedCounts(for: model.mcpServers.map(\.clients)), kind: .mcpServer
            ),
            ToolingMatrixRow(
                id: .plugins, title: "Plugins", symbol: "puzzlepiece.extension",
                libraryCount: scopedLibraryCount(for: model.plugins.map(\.clients)),
                installedCounts: installedCounts(for: model.plugins.map(\.clients)), kind: .plugin
            ),
        ]
    }

    private func installedCounts(for clientLists: [[ClientState]]) -> [ClientKind: Int] {
        Dictionary(
            uniqueKeysWithValues: visibleClients.map { client in
                (
                    client,
                    clientLists.filter { states in
                        states.contains { $0.client == client && $0.reportsLocalPresence }
                    }.count
                )
            })
    }

    private var recentReceipts: [OperationReceipt] {
        Array(
            scopedReceipts.sorted {
                if $0.createdAt == $1.createdAt { return $0.id.uuidString < $1.id.uuidString }
                return $0.createdAt > $1.createdAt
            }.prefix(4))
    }

    private var scopedReceipts: [OperationReceipt] {
        model.operationReceipts.filter { receipt in
            guard let client else { return true }
            return receipt.targetSurfaces.contains { $0.client == client }
        }
    }

    private var scopedPendingRequests: [PendingAgentRequest] {
        model.pendingAgentRequests.filter { request in
            guard let client else { return true }
            return request.targets.contains(client)
        }
    }

    private var visibleClients: [ClientKind] {
        client.map { [$0] } ?? [.claude, .codex, .gemini]
    }

    private func scopedLibraryCount(for clientLists: [[ClientState]]) -> Int {
        guard let client else { return clientLists.count }
        return clientLists.count { states in states.contains { $0.client == client } }
    }

    private var introText: String {
        if let client {
            return "Showing only \(client.rawValue)'s local state and saved changes. Refresh Checks scans local apps and keeps this scope."
        }
        return "Compare local state first. Review the exact plan before Agent Tooling changes a client."
    }

    private var refreshButtonTitle: String { client == nil ? "Check Clients" : "Refresh Checks" }

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
            let verdict = model.clientVerdict(for: client)
            StatusBadge(state: verdict.state, text: verdict.text)
        }
        .padding(.horizontal, 18)
        .frame(minHeight: 44)
        .background(AgentTheme.controlBackground.opacity(0.62))
        .overlay(alignment: .bottom) { Divider().opacity(0.45) }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Client scope: \(client.rawValue) only")
    }
}
