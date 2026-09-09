import AgentToolingCore
import SwiftUI

/// A read-only detail sheet for an already discovered ToolHive workload.
struct ToolHiveWorkloadInspector: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    let workload: MCPRuntimeServer

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
            inspection = try await model.inspectToolHiveWorkload(workload.name)
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
            logSnapshot = try await model.toolHiveLogs(workload.name, proxy: proxyLogs)
        } catch is CancellationError {
            return
        } catch {
            logError = error.localizedDescription
        }
    }
}
