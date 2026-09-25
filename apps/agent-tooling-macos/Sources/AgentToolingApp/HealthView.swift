import AgentToolingCore
import SwiftUI

/// The connection Health screen: every managed client's listed connections,
/// grouped by client and by state, with the one honest offer on each row.
///
/// Two things are kept apart, the way the rest of the app keeps them apart.
/// Checking reads: it runs each client's own list command and shows what came
/// back. Re-authenticating is the one action that changes anything, and it
/// changes it in the client — the command it will run is shown in the button's
/// help and again in the confirmation before anything runs. Nothing here runs
/// on its own.
struct HealthView: View {
    let session: WorkspaceHealthSession
    let device: WorkspaceDeviceSession

    /// All connections, or only the ones worth looking at. Defaults to the
    /// needs-attention view whenever there is anything to attend to, so opening
    /// the screen lands on the problems rather than a long settled list.
    private enum Filter: Hashable {
        case needsAttention
        case all
    }

    @State private var filter: Filter = .needsAttention
    @State private var didChooseFilter = false
    @State private var showingBulkConfirmation = false

    var body: some View {
        VStack(spacing: 0) {
            PageToolbar(title: "Apps", context: statusLine) {
                Button {
                    Task { await session.check() }
                } label: {
                    Label(session.isChecking ? "Checking…" : "Check now", systemImage: "arrow.clockwise")
                }
                .buttonStyle(.glass)
                .disabled(session.isChecking)
                .help("Read each managed app's connections again. This runs each app's own list command and changes nothing.")

                reauthenticateAllButton
            }

            content
        }
        .onAppear(perform: settleDefaultFilter)
        .onChange(of: session.attentionCount) { _, _ in settleDefaultFilter() }
    }

    // MARK: - Toolbar

    @ViewBuilder
    private var reauthenticateAllButton: some View {
        let eligible = session.reauthenticatableEntries
        Button {
            showingBulkConfirmation = true
        } label: {
            if let progress = session.bulkProgress {
                Label("Signing in \(progress.completed) of \(progress.total)…", systemImage: "person.badge.key")
            } else {
                Label("Re-authenticate all (\(eligible.count))", systemImage: "person.badge.key")
            }
        }
        .buttonStyle(.glass)
        .disabled(eligible.isEmpty || session.bulkProgress != nil || session.isChecking)
        .help(bulkHelp(eligible))
        .popover(isPresented: $showingBulkConfirmation, arrowEdge: .bottom) {
            BulkReauthenticateConfirmation(
                entries: eligible,
                commandText: { session.loginCommandText(for: $0) },
                onConfirm: {
                    showingBulkConfirmation = false
                    Task { await session.reauthenticateAll() }
                },
                onCancel: { showingBulkConfirmation = false })
        }
    }

    private func bulkHelp(_ eligible: [ConnectionHealthEntry]) -> String {
        guard !eligible.isEmpty else { return "No connections can be signed in to from here." }
        let commands = eligible.compactMap { session.loginCommandText(for: $0) }
        return "Signs in to \(eligible.count) connection\(eligible.count == 1 ? "" : "s"), one at a time:\n"
            + commands.joined(separator: "\n")
    }

    private var statusLine: String {
        guard let checkedAt = session.lastCheckedAt else {
            return "Connections have not been checked yet."
        }
        let attention = session.attentionCount
        let checked = "Checked \(SnapshotTime.compact(checkedAt))"
        if attention == 0 { return "\(checked) · everything is connected" }
        return "\(checked) · \(attention) need\(attention == 1 ? "s" : "") attention"
    }

    // MARK: - Body

    @ViewBuilder
    private var content: some View {
        if session.lastCheckedAt == nil {
            EmptyStateView(
                symbol: "waveform.path.ecg",
                title: "Nothing has been checked yet",
                message: "Check each managed app's connections to see which are connected and which need signing in again.",
                actionTitle: session.isChecking ? "Checking…" : "Check now",
                isActionEnabled: !session.isChecking,
                action: { Task { await session.check() } })
        } else if session.entries.isEmpty && session.results.allSatisfy({ $0.unavailableReason == nil }) {
            EmptyStateView(
                symbol: "checkmark.circle",
                title: "No connections found",
                message: "None of the managed apps listed an MCP connection or connector.")
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    filterPicker
                    if let error = session.errorMessage {
                        AttentionBanner(title: "Some connections still need attention", message: error)
                    }
                    ForEach(session.results, id: \.client) { result in
                        clientGroup(result)
                    }
                    if visibleResults.allSatisfy({ visibleEntries(in: $0).isEmpty && $0.unavailableReason == nil }) {
                        everythingConnectedNote
                    }
                }
                .padding(WorkspaceLayout.pageInset)
            }
        }
    }

    private var filterPicker: some View {
        WorkspaceSegmentedPicker(
            "Which connections",
            selection: Binding(
                get: { filter },
                set: {
                    filter = $0
                    didChooseFilter = true
                })
        ) {
            Text("Needs attention").tag(Filter.needsAttention)
            Text("All").tag(Filter.all)
        }
        .fixedSize()
    }

    private var everythingConnectedNote: some View {
        EmptyStateView(
            symbol: "checkmark.circle",
            title: "Everything is connected",
            message: "No connection needs attention. Switch to All to see every listed connection.")
        .frame(height: 220)
    }

    // MARK: - One client's connections

    @ViewBuilder
    private func clientGroup(_ result: ConnectionHealthClientResult) -> some View {
        let entries = visibleEntries(in: result)
        if let reason = result.unavailableReason {
            TitledCard(result.client.rawValue) {
                InfoRow(
                    "Could not be checked",
                    detail: reason,
                    leading: { StatusGlyph(state: .pending) })
            }
        } else if !entries.isEmpty {
            TitledCard(result.client.rawValue, count: "\(entries.count)") {
                ForEach(Array(entries.enumerated()), id: \.element.id) { index, entry in
                    if index > 0 { Divider().opacity(0.4) }
                    HealthRow(
                        entry: entry,
                        action: session.action(for: entry),
                        actionState: session.actionState[entry.id] ?? .idle,
                        commandText: session.loginCommandText(for: entry),
                        authorizationURL: session.authorizationURLs[entry.id],
                        onReauthenticate: { Task { await session.reauthenticate(entry) } },
                        onOpenConnectors: { session.openConnectorsPage() },
                        onOpenAuthorizationPage: { session.reopenAuthorizationPage(for: entry) })
                }
            }
        }
    }

    /// The entries a client shows under the current filter, ordered so the ones
    /// worth looking at come first within the client.
    private func visibleEntries(in result: ConnectionHealthClientResult) -> [ConnectionHealthEntry] {
        let entries = filter == .all ? result.entries : result.entries.filter { $0.status.needsAttention }
        return entries.sorted { lhs, rhs in
            if lhs.status.needsAttention != rhs.status.needsAttention {
                return lhs.status.needsAttention && !rhs.status.needsAttention
            }
            return lhs.displayName.localizedCaseInsensitiveCompare(rhs.displayName) == .orderedAscending
        }
    }

    private var visibleResults: [ConnectionHealthClientResult] { session.results }

    /// Lands on the needs-attention view the first time there is anything to
    /// attend to, and never overrides a choice a person has made since.
    private func settleDefaultFilter() {
        guard !didChooseFilter else { return }
        filter = session.attentionCount > 0 ? .needsAttention : .all
    }
}

/// One connection: its state glyph, its name and where it came from, the
/// command or URL it points at, any failure detail, and the one thing a person
/// can do about it.
private struct HealthRow: View {
    let entry: ConnectionHealthEntry
    let action: ConnectionHealthAction
    let actionState: WorkspaceHealthSession.ActionState
    let commandText: String?
    /// Where the running sign-in sent the person, so the row can name it and
    /// offer to open it again if the browser tab was closed early.
    let authorizationURL: URL?
    let onReauthenticate: () -> Void
    let onOpenConnectors: () -> Void
    let onOpenAuthorizationPage: () -> Void

    @State private var showingHelp = false

    var body: some View {
        HStack(alignment: .top, spacing: 11) {
            StatusGlyph(state: entry.status.healthState)
                .padding(.top, 2)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text(entry.displayName)
                        .font(.callout.weight(.medium))
                        .lineLimit(1)
                    sourceBadge
                    Spacer(minLength: 0)
                }
                if !entry.summary.isEmpty {
                    Text(entry.summary)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .textSelection(.enabled)
                }
                if case .failed(let detail) = entry.status, !detail.isEmpty {
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(AgentTheme.failure)
                        .fixedSize(horizontal: false, vertical: true)
                }
                resultText
            }
            Spacer(minLength: 12)
            trailing
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .frame(minHeight: 44)
        .accessibilityElement(children: .combine)
        .accessibilityValue(entry.status.label)
    }

    @ViewBuilder
    private var sourceBadge: some View {
        if let plugin = entry.pluginName, !plugin.isEmpty {
            HealthBadge(text: "Plugin · \(plugin)", tint: AgentTheme.plugin)
        } else if entry.isClaudeAIConnector {
            HealthBadge(text: "claude.ai connector", tint: AgentTheme.blue)
        }
    }

    @ViewBuilder
    private var resultText: some View {
        switch actionState {
        case .idle:
            EmptyView()
        case .running:
            VStack(alignment: .leading, spacing: 3) {
                Label(
                    authorizationURL == nil
                        ? "Signing in… waiting for the tool to print its sign-in page."
                        : "Signing in… finish in the browser, then this row updates itself.",
                    systemImage: "arrow.triangle.2.circlepath")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if let host = authorizationURL?.host() {
                    Button("Open the sign-in page at \(host) again", action: onOpenAuthorizationPage)
                        .buttonStyle(.link)
                        .font(.caption)
                        .help("Opens the same authorization page the sign-in printed, in case the browser tab was closed.")
                }
            }
        case .finished(let message):
            Text(message)
                .font(.caption)
                .foregroundStyle(AgentTheme.ok)
                .fixedSize(horizontal: false, vertical: true)
        case .failed(let message):
            Text(message)
                .font(.caption)
                .foregroundStyle(AgentTheme.failure)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder
    private var trailing: some View {
        switch action {
        case .reauthenticate:
            Button("Re-authenticate…", action: onReauthenticate)
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(actionState == .running)
                .help(commandText.map { "Runs \($0), then opens the sign-in page it prints in your browser. Nothing else is read or stored." }
                    ?? "Signs in to this connection again.")
        case .openClaudeAIConnectors:
            Button("Open claude.ai…", action: onOpenConnectors)
                .buttonStyle(.bordered)
                .controlSize(.small)
                .help("Opens https://claude.ai/customize/connectors, where a hosted connector is managed.")
        case .reconnectOnly(let guidance):
            Button("How to fix") { showingHelp = true }
                .buttonStyle(.borderless)
                .controlSize(.small)
                .help(guidance)
                .popover(isPresented: $showingHelp, arrowEdge: .bottom) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("How to fix this").font(.callout.weight(.semibold))
                        Text(guidance)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(16)
                    .frame(width: 320)
                }
        case .none:
            EmptyView()
        }
    }
}

private struct HealthBadge: View {
    let text: String
    let tint: Color

    var body: some View {
        Text(text)
            .font(.caption2.weight(.medium))
            .lineLimit(1)
            .padding(.horizontal, 8)
            .frame(height: 20)
            .background(tint.opacity(0.14), in: Capsule())
            .foregroundStyle(tint)
    }
}

/// The confirmation a person reads before signing in to several connections at
/// once: exactly which servers, and the exact command each will run.
private struct BulkReauthenticateConfirmation: View {
    let entries: [ConnectionHealthEntry]
    let commandText: (ConnectionHealthEntry) -> String?
    let onConfirm: () -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Sign in to \(entries.count) connection\(entries.count == 1 ? "" : "s")")
                .font(.headline)
            Text("Each sign-in prints a page to visit; Agent Tooling opens it in your browser, one server after another, and waits for the tool to confirm.")
                .font(.callout)
                .foregroundStyle(.secondary)
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(entries) { entry in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(entry.displayName).font(.callout.weight(.medium))
                            if let command = commandText(entry) {
                                Text(command)
                                    .font(.caption.monospaced())
                                    .foregroundStyle(.secondary)
                                    .textSelection(.enabled)
                            }
                        }
                    }
                }
            }
            .frame(maxHeight: 200)
            HStack {
                Spacer()
                Button("Cancel", action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Button("Sign in", action: onConfirm)
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .tint(AgentTheme.selection)
            }
        }
        .padding(18)
        .frame(width: 420)
    }
}
