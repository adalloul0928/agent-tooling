import AgentToolingCore
import SwiftUI

/// Settings · General: appearance, this Mac's MCP connection modes, and where
/// an organization's managed policy would be. What used to live on Settings'
/// "General" and part of "Policy & Safety" before the workspace changed sat
/// beside backup and encrypted sync in one screen; those now have their own
/// screen under Settings · Sync.
struct SettingsGeneralView: View {
    let workspace: WorkspaceLaunch.Workspace
    @AppStorage("appearance") private var appearance = "System"
    @Environment(\.mcpRuntimeObserver) private var mcpRuntimeObserver
    @State private var runtimes: WorkspaceRuntimesSession?

    var body: some View {
        VStack(spacing: 0) {
            PageToolbar(title: AppSection.settings.navigationTitle, context: "This app, on this Mac") {}
            ScrollView {
                VStack(alignment: .leading, spacing: WorkspaceLayout.sectionSpacing) {
                    appearanceCard
                    runtimesCard
                    behaviorCard
                    managedPolicyCard
                }
                .padding(WorkspaceLayout.pageInset)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task {
            if runtimes == nil { runtimes = WorkspaceRuntimesSession(observer: mcpRuntimeObserver) }
            await runtimes?.refresh()
        }
    }

    private var appearanceCard: some View {
        TitledCard("Appearance") {
            AppearanceSettingsView(appearance: $appearance)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder
    private var runtimesCard: some View {
        TitledCard("MCP connection modes") {
            VStack(alignment: .leading, spacing: 0) {
                Text(
                    "Servers stay configured directly in each client by default. ToolHive is an optional, separate host for isolated workloads; Agent Tooling never moves servers into it automatically."
                )
                .font(.callout)
                .foregroundStyle(.secondary)
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)

                if let runtimes, !runtimes.statuses.isEmpty {
                    ForEach(runtimes.statuses, id: \.id) { status in
                        Divider()
                        statusRow(status)
                    }
                    if let error = runtimes.mcpRuntimeError {
                        Divider()
                        Text(error)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .padding(14)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    Divider()
                    HStack {
                        Text(workloadSummary)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button("Refresh") { Task { await runtimes.refresh() } }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                            .disabled(runtimes.isRefreshingMCPRuntimes)
                    }
                    .padding(14)
                } else {
                    Divider()
                    HStack {
                        Text("Connection mode check").font(.callout.weight(.medium))
                        Spacer()
                        Button("Check Modes") { Task { await runtimes?.refresh() } }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                            .disabled(runtimes?.isRefreshingMCPRuntimes == true)
                    }
                    .padding(14)
                }
            }
        }
    }

    private func statusRow(_ status: MCPRuntimeStatus) -> some View {
        InfoRow(status.displayName, detail: status.version.map { "\(status.detail) Version \($0)." } ?? status.detail) {
            Image(systemName: status.id == "toolhive" ? "server.rack" : "app.connected.to.app.below.fill")
                .foregroundStyle(.secondary)
                .frame(width: 20)
        } trailing: {
            Text(runtimeAvailabilityLabel(for: status))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func runtimeAvailabilityLabel(for status: MCPRuntimeStatus) -> String {
        if status.id == "toolhive", status.isAvailable, status.capabilities.isEmpty { return "Needs attention" }
        return status.isAvailable ? "Available" : "Not available"
    }

    private var workloadSummary: String {
        guard let runtimes, let toolHive = runtimes.toolHive else { return "" }
        guard toolHive.isAvailable, toolHive.capabilities.contains(.health) else {
            return "ToolHive is unavailable, so no workload count is shown."
        }
        guard runtimes.mcpRuntimeError == nil else { return "" }
        return runtimes.servers.isEmpty
            ? "No ToolHive workloads were reported by the last successful refresh."
            : runtimes.servers.count == 1 ? "1 ToolHive workload" : "\(runtimes.servers.count) ToolHive workloads"
    }

    private var behaviorCard: some View {
        TitledCard("Behavior") {
            VStack(alignment: .leading, spacing: 0) {
                InfoRow(
                    "Check health automatically",
                    detail: "Check this Mac's apps when Agent Tooling opens, instead of waiting for a manual refresh."
                ) {
                    Image(systemName: "switch.2").foregroundStyle(.secondary).frame(width: 20)
                } trailing: {
                    Toggle(
                        "Check health automatically",
                        isOn: Binding(
                            get: { workspace.device.automaticallyCheckHealth },
                            set: { value in Task { await workspace.device.setAutomaticallyCheckHealth(value) } })
                    )
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .disabled(workspace.device.isChecking)
                }
                Divider()
                Text(
                    "Recorded for this Mac now. The check Agent Tooling runs when it opens does not read this choice yet, so switching it off does not change that check today."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    @ViewBuilder
    private var managedPolicyCard: some View {
        TitledCard("Managed policy") {
            VStack(alignment: .leading, spacing: 0) {
                if let policyPath = workspace.settings.managedPolicyPath {
                    InfoRow(
                        "Location checked on this Mac",
                        detail: "Agent Tooling knows where to look for an organization policy on this Mac."
                    ) {
                        Image(systemName: "building.2.crop.circle").foregroundStyle(.secondary).frame(width: 20)
                    } trailing: {
                        PathInfoButton(path: policyPath.path(percentEncoded: false))
                    }
                } else {
                    Text(
                        "Agent Tooling was not told where an organization policy file would be on this Mac, so it cannot rule one out. If your organization sets one, it may decide a setting shown elsewhere as changeable."
                    )
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .padding(14)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                Divider()
                Text("Importing a policy file from here is being restored; nothing on this Mac is affected by that yet.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(14)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
}
