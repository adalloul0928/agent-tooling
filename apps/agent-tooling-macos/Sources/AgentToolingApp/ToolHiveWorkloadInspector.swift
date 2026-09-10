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
            HStack(spacing: 14) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(workload.name).font(.title2.weight(.semibold))
                    Text("ToolHive workload").font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
                Button {
                    inspectionRequestID = UUID()
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.bordered)
                .help("Refresh status")
                .accessibilityLabel("Refresh status")
                .disabled(isInspecting)
                Button("Done") { dismiss() }.buttonStyle(.borderedProminent)
            }
            .padding(20)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    statusSection
                    logSection
                }
                .padding(20)
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
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Label("ToolHive status", systemImage: "server.rack")
                    .font(.headline)
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
        .padding(14)
        .standardPanel()
    }

    @ViewBuilder private func inspectionBody(_ inspection: ToolHiveInspectionResult<ToolHiveWorkloadStatus>) -> some View {
        switch inspection {
        case .available(let status, let diagnostic):
            HStack(spacing: 8) {
                Text(status.status)
                    .font(.title3.weight(.semibold))
                Spacer()
                Text(status.transport)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if let health = status.health {
                LabeledValueRow("Reported health") { Text(health) }
            }
            if let diagnostic {
                Text(diagnostic)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
            DisclosureGroup("Workload details") {
                VStack(alignment: .leading, spacing: 8) {
                    detail("Package", status.package)
                    detail("URL", status.url)
                    detail("Port", String(status.port))
                    detail("Transport", status.transport)
                    if let proxyMode = status.proxyMode { detail("Proxy mode", proxyMode) }
                    if let group = status.group { detail("Group", group) }
                    if let uptime = status.uptime { detail("Reported uptime", uptime) }
                }
                .padding(.top, 8)
            }
            .font(.callout)

        case .unavailable(let diagnostic):
            statusFailure(diagnostic.isEmpty ? "ToolHive is not available on this Mac." : diagnostic)
        case .unsupportedResponse(let diagnostic):
            statusFailure(diagnostic)
        case .commandFailed(let diagnostic):
            statusFailure(diagnostic)
        }
    }

    private func statusFailure(_ detail: String) -> some View {
        HStack(alignment: .top, spacing: 9) {
            Image(systemName: "exclamationmark.triangle")
                .foregroundStyle(.secondary)
            Text(detail)
                .font(.callout)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
        }
    }

    private var logSection: some View {
        VStack(alignment: .leading, spacing: 11) {
            HStack {
                Label("Log snapshot", systemImage: "text.alignleft")
                    .font(.headline)
                Spacer()
                if isLoadingLogs { ProgressView().controlSize(.small) }
            }
            Text("Load the latest output from this workload or its proxy.")
                .font(.caption)
                .foregroundStyle(.secondary)

            Picker("Log source", selection: $proxyLogs) {
                Text("Workload").tag(false)
                Text("Proxy").tag(true)
            }
            .pickerStyle(.segmented)
            .disabled(isLoadingLogs)

            HStack {
                Button("Refresh logs") { logRequestID = UUID() }
                    .buttonStyle(.bordered)
                    .disabled(isLoadingLogs)
                if let snapshot = logSnapshot, snapshot.isTruncated {
                    Label("Truncated", systemImage: "ellipsis")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            if let logError {
                statusFailure(logError)
            } else if let snapshot = logSnapshot {
                if let diagnostic = snapshot.diagnostic {
                    Text(diagnostic).font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
                }
                ScrollView {
                    Text(snapshot.output.isEmpty ? "No log output returned." : snapshot.output)
                        .font(.system(.caption, design: .monospaced))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                        .padding(10)
                }
                .frame(minHeight: 110, maxHeight: 240)
                .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 7))
            }
        }
        .padding(14)
        .standardPanel()
    }

    private func detail(_ title: String, _ value: String) -> some View {
        LabeledValueRow(title) {
            Text(value)
                .font(.system(.caption, design: .monospaced))
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
            HStack(spacing: 12) {
                SymbolTile(symbol: "shippingbox", size: 40)
                VStack(alignment: .leading, spacing: 2) {
                    Text("MCP runtimes").font(.title3.weight(.semibold))
                    Text(subtitle).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer()
                if session.isBusy { ProgressView().controlSize(.small) }
                Button(session.lastCheckedAt == nil ? "Check" : "Check again") {
                    Task { await session.refresh() }
                }
                .buttonStyle(.bordered)
                .disabled(session.isBusy)
            }
            .padding(22)
            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
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
                                    StatusGlyph(state: status.isAvailable ? .healthy : .unavailable, size: 15)
                                } trailing: {
                                    if let version = status.version {
                                        Text(version)
                                            .font(.caption.monospacedDigit())
                                            .foregroundStyle(.secondary)
                                    }
                                }
                                if index < session.statuses.count - 1 { Divider().opacity(0.45) }
                            }
                        }

                        TitledCard("Managed workloads", count: "\(session.workloads.count)") {
                            if session.workloads.isEmpty {
                                LabeledValueRow("Workloads") {
                                    Text(
                                        "None. A runtime that manages workloads reports them here; direct client "
                                            + "configuration has none by design."
                                    )
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                                }
                            } else {
                                ForEach(Array(session.workloads.enumerated()), id: \.element.id) { index, workload in
                                    InfoRow(workload.name, detail: workloadClause(workload)) {
                                        KindTile(kind: .mcpServer, size: 26, ghost: true)
                                    } trailing: {
                                        Button("Inspect…") { inspecting = workload }
                                            .buttonStyle(.bordered)
                                            .controlSize(.small)
                                    }
                                    if index < session.workloads.count - 1 { Divider().opacity(0.45) }
                                }
                            }
                        }

                        Text(
                            "Read only. Agent Tooling never starts, stops or reconfigures a runtime from this sheet."
                        )
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(22)
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            Divider()
            HStack {
                Spacer()
                Button("Done") { dismiss() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
            }
            .padding(16)
        }
        .frame(width: 680, height: 620)
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
