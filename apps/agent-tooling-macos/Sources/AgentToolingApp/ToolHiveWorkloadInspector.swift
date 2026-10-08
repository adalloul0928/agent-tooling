import AgentToolingCore
import SwiftUI

/// A read-only detail sheet for an already discovered ToolHive workload.
struct ToolHiveWorkloadInspector: View {
    @Environment(\.dismiss) private var dismiss

    let workload: MCPRuntimeServer
    /// Taken explicitly rather than from the environment so a test can hand in
    /// a scripted runtime without the sheet ever reaching a real `thv`.
    let inspector: any MCPRuntimeInspecting

    @State private var inspectionRequestID = UUID()
    @State private var logRequestID: UUID?
    @State private var inspection: ToolHiveInspectionResult<ToolHiveWorkloadStatus>?
    @State private var inspectionError: String?
    @State private var isInspecting = false
    @State private var proxyLogs = false
    @State private var logSnapshot: ToolHiveLogSnapshot?
    @State private var logError: String?
    @State private var isLoadingLogs = false

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: Space.xl) {
                VStack(alignment: .leading, spacing: Space.xxs) {
                    Text(workload.name).font(AgentFont.titleLarge)
                    Text("ToolHive workload").font(AgentFont.body).foregroundStyle(.secondary)
                }
                Spacer()
                Button {
                    inspectionRequestID = UUID()
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .secondaryActionStyle()
                .help("Refresh status")
                .accessibilityLabel("Refresh status")
                .disabled(isInspecting)
                Button("Done") { dismiss() }.primaryActionStyle()
            }
            .padding(Space.xxl)
            Hairline()
            ScrollView {
                VStack(alignment: .leading, spacing: Space.xxl) {
                    statusSection
                    logSection
                }
                .padding(Space.xxl)
                .frame(maxWidth: 620, alignment: .leading)
                .frame(maxWidth: .infinity)
            }
        }
        .frame(minWidth: 640, idealWidth: 720, minHeight: 480, idealHeight: 560)
        .background(AgentTheme.contentBackground)
        .task(id: inspectionRequestID) {
            await refreshInspection()
        }
        .task(id: logRequestID) {
            guard logRequestID != nil else { return }
            await refreshLogs()
        }
        .onChange(of: proxyLogs) { _, _ in
            logSnapshot = nil
            logError = nil
        }
    }

    @ViewBuilder private var statusSection: some View {
        VStack(alignment: .leading, spacing: Space.lg) {
            HStack(alignment: .firstTextBaseline) {
                Label("ToolHive status", systemImage: "server.rack")
                    .font(AgentFont.heading)
                Spacer()
                if isInspecting { ProgressView().controlSize(.small) }
            }

            if let inspection {
                inspectionBody(inspection)
            } else if let inspectionError {
                statusFailure(inspectionError)
            } else {
                ProgressView("Inspecting this workload…")
                    .controlSize(.small)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(Space.xl)
        .standardPanel()
    }

    @ViewBuilder private func inspectionBody(_ inspection: ToolHiveInspectionResult<ToolHiveWorkloadStatus>) -> some View {
        switch inspection {
        case .available(let status, let diagnostic):
            HStack(spacing: Space.md) {
                Text(status.status)
                    .font(AgentFont.title)
                Spacer()
                Text(status.transport)
                    .font(AgentFont.caption)
                    .foregroundStyle(.secondary)
            }
            if let health = status.health {
                LabeledValueRow("Reported health") { Text(health) }
            }
            if let diagnostic {
                Text(diagnostic)
                    .font(AgentFont.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
            DisclosureGroup("Workload details") {
                VStack(alignment: .leading, spacing: Space.md) {
                    detail("Package", status.package)
                    detail("URL", status.url)
                    detail("Port", String(status.port))
                    detail("Transport", status.transport)
                    if let proxyMode = status.proxyMode { detail("Proxy mode", proxyMode) }
                    if let group = status.group { detail("Group", group) }
                    if let uptime = status.uptime { detail("Reported uptime", uptime) }
                }
                .padding(.top, Space.md)
            }
            .font(AgentFont.body)

        case .unavailable(let diagnostic):
            statusFailure(diagnostic.isEmpty ? "ToolHive is not available on this Mac." : diagnostic)
        case .unsupportedResponse(let diagnostic):
            statusFailure(diagnostic)
        case .commandFailed(let diagnostic):
            statusFailure(diagnostic)
        }
    }

    private func statusFailure(_ detail: String) -> some View {
        HStack(alignment: .top, spacing: Space.md) {
            Image(systemName: "exclamationmark.triangle")
                .foregroundStyle(.secondary)
            Text(detail)
                .font(AgentFont.body)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
        }
    }

    private var logSection: some View {
        VStack(alignment: .leading, spacing: Space.lg) {
            HStack {
                Label("Log snapshot", systemImage: "text.alignleft")
                    .font(AgentFont.heading)
                Spacer()
                if isLoadingLogs { ProgressView().controlSize(.small) }
            }
            Text("Load the latest output from this workload or its proxy.")
                .font(AgentFont.caption)
                .foregroundStyle(.secondary)

            Picker("Log source", selection: $proxyLogs) {
                Text("Workload").tag(false)
                Text("Proxy").tag(true)
            }
            .pickerStyle(.segmented)
            .disabled(isLoadingLogs)

            HStack {
                Button("Refresh logs") { logRequestID = UUID() }
                    .secondaryActionStyle()
                    .disabled(isLoadingLogs)
                if let snapshot = logSnapshot, snapshot.isTruncated {
                    Label("Truncated", systemImage: "ellipsis")
                        .font(AgentFont.caption)
                        .foregroundStyle(.secondary)
                }
            }

            if let logError {
                statusFailure(logError)
            } else if let snapshot = logSnapshot {
                if let diagnostic = snapshot.diagnostic {
                    Text(diagnostic).font(AgentFont.body).foregroundStyle(.secondary).textSelection(.enabled)
                }
                ScrollView {
                    Text(snapshot.output.isEmpty ? "No log output returned." : snapshot.output)
                        .font(AgentFont.mono)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                        .padding(Space.lg)
                }
                .frame(minHeight: 110, maxHeight: 240)
                .background(AgentTheme.fillSubtle, in: RoundedRectangle.control)
            }
        }
        .padding(Space.xl)
        .standardPanel()
    }

    private func detail(_ title: String, _ value: String) -> some View {
        LabeledValueRow(title) {
            Text(value)
                .font(AgentFont.mono)
                .textSelection(.enabled)
        }
    }

    private func refreshInspection() async {
        isInspecting = true
        inspectionError = nil
        defer { isInspecting = false }
        do {
            inspection = try await inspector.workloadStatus(workload.name)
        } catch is CancellationError {
            return
        } catch {
            inspection = nil
            inspectionError = error.localizedDescription
        }
    }

    private func refreshLogs() async {
        isLoadingLogs = true
        logError = nil
        defer { isLoadingLogs = false }
        do {
            logSnapshot = try await inspector.workloadLogs(workload.name, proxy: proxyLogs)
        } catch is CancellationError {
            return
        } catch {
            logError = error.localizedDescription
        }
    }
}

/// What this Mac runs MCP servers with, and what the managed runtime is holding.
///
/// Nothing is probed until somebody presses Check: opening the sheet starts no
/// process, and the first thing it says is that it has not looked yet.
struct MCPRuntimesSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var session: MCPRuntimeSession
    @State private var inspecting: MCPRuntimeServer?
    private let inspector: any MCPRuntimeInspecting

    /// `session` is supplied when something has already checked — a test that
    /// wants the layout a full answer produces, rather than the one a sheet
    /// nobody has pressed Check on shows.
    init(inspector: any MCPRuntimeInspecting, session: MCPRuntimeSession? = nil) {
        self.inspector = inspector
        _session = State(initialValue: session ?? MCPRuntimeSession(inspector: inspector))
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: Space.lg) {
                SymbolTile(symbol: "shippingbox", size: Size.tileLarge)
                VStack(alignment: .leading, spacing: Space.xxs) {
                    Text("MCP runtimes").font(AgentFont.title)
                    Text(subtitle).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer()
                if session.isBusy { ProgressView().controlSize(.small) }
                Button(session.lastCheckedAt == nil ? "Check" : "Check again") {
                    Task { await session.refresh() }
                }
                .secondaryActionStyle()
                .disabled(session.isBusy)
            }
            .padding(Space.xxxl)
            Hairline()

            ScrollView {
                VStack(alignment: .leading, spacing: Space.xl) {
                    if let message = session.errorMessage {
                        AttentionBanner(title: "This Mac's runtimes could not be read", message: message)
                    }

                    if session.statuses.isEmpty {
                        EmptyStateView(
                            symbol: "shippingbox",
                            title: "Not checked yet",
                            message:
                                "Agent Tooling starts no runtime on its own. Check reads which runtimes this Mac has "
                                + "and, where one manages workloads, what it is holding. Nothing is started or stopped."
                        )
                        .frame(minHeight: 220)
                    } else {
                        TitledCard("Runtimes", count: "\(session.statuses.count)") {
                            ForEach(Array(session.statuses.enumerated()), id: \.element.id) { index, status in
                                InfoRow(status.displayName, detail: status.detail) {
                                    StatusGlyph(state: status.isAvailable ? .healthy : .unavailable, size: Size.glyphLarge)
                                } trailing: {
                                    if let version = status.version {
                                        Text(version)
                                            .font(AgentFont.caption.monospacedDigit())
                                            .foregroundStyle(.secondary)
                                    }
                                }
                                if index < session.statuses.count - 1 { Hairline() }
                            }
                        }

                        TitledCard("Managed workloads", count: "\(session.workloads.count)") {
                            if session.workloads.isEmpty {
                                LabeledValueRow("Workloads") {
                                    Text(
                                        "None. A runtime that manages workloads reports them here; direct client "
                                            + "configuration has none by design."
                                    )
                                    .font(AgentFont.caption)
                                    .foregroundStyle(.secondary)
                                    .wrapsLines()
                                }
                            } else {
                                ForEach(Array(session.workloads.enumerated()), id: \.element.id) { index, workload in
                                    InfoRow(workload.name, detail: workloadClause(workload)) {
                                        KindTile(kind: .mcpServer, size: Size.tile, ghost: true)
                                    } trailing: {
                                        Button("Inspect…") { inspecting = workload }
                                            .secondaryActionStyle()
                                            .controlSize(.small)
                                    }
                                    if index < session.workloads.count - 1 { Hairline() }
                                }
                            }
                        }

                        Text(
                            "Read only. Agent Tooling never starts, stops or reconfigures a runtime from this sheet."
                        )
                        .font(AgentFont.caption)
                        .foregroundStyle(.secondary)
                        .wrapsLines()
                    }
                }
                .padding(Space.xxxl)
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            Hairline()
            HStack {
                Spacer()
                Button("Done") { dismiss() }
                    .primaryActionStyle()
                    .keyboardShortcut(.defaultAction)
            }
            .padding(Space.xl)
        }
        .sheetSize(SheetSize.large)
        .background(AgentTheme.contentBackground)
        .sheet(item: $inspecting) { workload in
            ToolHiveWorkloadInspector(workload: workload, inspector: inspector)
        }
    }

    private var subtitle: String {
        guard let checked = session.lastCheckedAt else { return "What this Mac runs MCP servers with" }
        return "Checked \(checked.formatted(date: .omitted, time: .shortened))"
    }

    private func workloadClause(_ workload: MCPRuntimeServer) -> String {
        [workload.status, workload.transport, workload.isRemote ? "Remote" : nil]
            .compactMap { $0 }
            .filter { !$0.isEmpty }
            .joined(separator: " · ")
    }
}
