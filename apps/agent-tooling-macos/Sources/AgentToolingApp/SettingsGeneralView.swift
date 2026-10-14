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
                    updatesCard
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
                .font(AgentFont.body)
                .foregroundStyle(.secondary)
                .padding(Space.xl)
                .frame(maxWidth: .infinity, alignment: .leading)

                if let runtimes, !runtimes.statuses.isEmpty {
                    ForEach(runtimes.statuses, id: \.id) { status in
                        Hairline()
                        statusRow(status)
                    }
                    if let error = runtimes.mcpRuntimeError {
                        Hairline()
                        Text(error)
                            .font(AgentFont.caption)
                            .foregroundStyle(.secondary)
                            .padding(Space.xl)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    Hairline()
                    HStack {
                        Text(workloadSummary)
                            .font(AgentFont.body)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button("Refresh") { Task { await runtimes.refresh() } }
                            .secondaryActionStyle()
                            .controlSize(.small)
                            .disabled(runtimes.isRefreshingMCPRuntimes)
                    }
                    .padding(Space.xl)
                } else {
                    Hairline()
                    HStack {
                        Text("Connection mode check").font(AgentFont.bodyMedium)
                        Spacer()
                        Button("Check Modes") { Task { await runtimes?.refresh() } }
                            .secondaryActionStyle()
                            .controlSize(.small)
                            .disabled(runtimes?.isRefreshingMCPRuntimes == true)
                    }
                    .padding(Space.xl)
                }
            }
        }
    }

    private func statusRow(_ status: MCPRuntimeStatus) -> some View {
        InfoRow(status.displayName, detail: rowDetail(status)) {
            Image(systemName: status.id == "toolhive" ? "server.rack" : "app.connected.to.app.below.fill")
                .foregroundStyle(.secondary)
                .frame(width: Size.glyphSlot)
        } trailing: {
            Text(runtimeAvailabilityLabel(for: status))
                .font(AgentFont.caption)
                .foregroundStyle(.secondary)
        }
        .help(status.detail)
    }

    /// The row's own line. Direct configuration always says what it reported;
    /// ToolHive says its version when it answered, and otherwise a plain
    /// sentence rather than the shell's own words, which stay in the tooltip.
    private func rowDetail(_ status: MCPRuntimeStatus) -> String {
        guard status.id == "toolhive" else {
            return status.version.map { "\(status.detail) Version \($0)." } ?? status.detail
        }
        if status.isAvailable, status.capabilities.contains(.health) {
            return status.version.map { "\(status.detail) Version \($0)." } ?? status.detail
        }
        // Not runnable at all reads as not installed; runnable but unreadable
        // reads as a check that could not complete. The raw diagnostic (for
        // example "env: thv: No such file or directory") stays in the tooltip.
        return status.isAvailable
            ? "ToolHive could not be checked."
            : "ToolHive (thv) is not installed on this Mac."
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
                    Image(systemName: "switch.2").foregroundStyle(.secondary).frame(width: Size.glyphSlot)
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
            }
        }
    }

    /// How this Mac handles updates to what it manages. One cadence, and per
    /// kind the choice between installing a found update at once and leaving
    /// it on Home with an Update button.
    private var updatesCard: some View {
        let policy = workspace.device.updatePolicy
        let updates = workspace.updates
        return TitledCard("Updates") {
            VStack(alignment: .leading, spacing: 0) {
                InfoRow(
                    "Check for updates",
                    detail: updatesCheckDetail
                ) {
                    Image(systemName: "arrow.triangle.2.circlepath").foregroundStyle(.secondary).frame(width: Size.glyphSlot)
                } trailing: {
                    HStack(spacing: Space.md) {
                        Button(updates.isChecking ? "Checking…" : "Check now") {
                            Task { await updates.check() }
                        }
                        .secondaryActionStyle()
                        .disabled(updates.isBusy)
                        Picker("Check for updates", selection: binding(\.cadence)) {
                            ForEach(UpdateCheckCadence.allCases, id: \.self) { Text($0.title).tag($0) }
                        }
                        .labelsHidden()
                        .frame(width: Size.pickerWidth)
                    }
                }
                Hairline()
                policyRow(
                    "Skills", kind: .skill, symbol: "doc.text",
                    detail: "Skills that follow a repository. Installing replaces the copies this app put in your apps.")
                Hairline()
                policyRow(
                    "Plugins", kind: .plugin, symbol: "puzzlepiece.extension",
                    detail: "Compared with their catalog. Installing asks the app to update its own package.")
                Hairline()
                policyRow(
                    "MCP servers", kind: .mcpServer, symbol: "point.3.connected.trianglepath.dotted",
                    detail: "Compared with the catalog entry of the same name, when there is one.")
            }
        }
    }

    private var updatesCheckDetail: String {
        if let last = workspace.device.lastUpdateCheck {
            return "Last checked \(SnapshotTime.compact(last)). \(workspace.device.updatePolicy.cadence.detail)"
        }
        return "Not checked yet. \(workspace.device.updatePolicy.cadence.detail)"
    }

    private func policyRow(_ title: String, kind: ToolingItemKind, symbol: String, detail: String) -> some View {
        InfoRow(title, detail: detail) {
            Image(systemName: symbol).foregroundStyle(.secondary).frame(width: Size.glyphSlot)
        } trailing: {
            Picker(title, selection: Binding(
                get: { workspace.device.updatePolicy.policy(for: kind) },
                set: { value in
                    var policy = workspace.device.updatePolicy
                    policy.setPolicy(value, for: kind)
                    Task { await workspace.device.setUpdatePolicy(policy) }
                })
            ) {
                ForEach(UpdateInstallPolicy.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            .labelsHidden()
            .frame(width: Size.pickerWidth)
        }
    }

    private func binding<Value>(_ keyPath: WritableKeyPath<UpdatePolicy, Value>) -> Binding<Value> {
        Binding(
            get: { workspace.device.updatePolicy[keyPath: keyPath] },
            set: { value in
                var policy = workspace.device.updatePolicy
                policy[keyPath: keyPath] = value
                Task { await workspace.device.setUpdatePolicy(policy) }
            })
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
                        Image(systemName: "building.2.crop.circle").foregroundStyle(.secondary).frame(width: Size.glyphSlot)
                    } trailing: {
                        PathInfoButton(path: policyPath.path(percentEncoded: false))
                    }
                } else {
                    Text(
                        "Agent Tooling was not told where an organization policy file would be on this Mac, so it cannot rule one out. If your organization sets one, it may decide a setting shown elsewhere as changeable."
                    )
                    .font(AgentFont.body)
                    .foregroundStyle(.secondary)
                    .padding(Space.xl)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }
}
