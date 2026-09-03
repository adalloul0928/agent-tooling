import AgentToolingCore
import SwiftUI

/// Holds which capabilities inside each MCP server a person has said they want.
///
/// The record is written beside the workspace database rather than into a
/// client's configuration, because Agent Tooling does not enforce it. Every
/// place these toggles appear says so.
@MainActor
@Observable
final class MCPCapabilityModel {
    private(set) var record = MCPCapabilityIntentRecord()
    private(set) var lastError: String?
    private(set) var recordPath: String?
    private var store: MCPCapabilityIntentStore?

    /// Opens the record for a workspace. Safe to call on every appearance.
    func activate(workspaceRoot: URL) {
        let candidate = MCPCapabilityIntentStore(workspaceRootURL: workspaceRoot)
        guard store?.fileURL != candidate.fileURL else { return }
        store = candidate
        recordPath = candidate.fileURL.path(percentEncoded: false)
        do {
            record = try candidate.load()
            lastError = nil
        } catch {
            record = MCPCapabilityIntentRecord()
            lastError = error.localizedDescription
        }
    }

    func intent(for serverID: String) -> MCPCapabilityIntent {
        record.intent(for: serverID) ?? MCPCapabilityIntent(serverID: serverID)
    }

    func summary(for serverID: String) -> String? {
        record.intent(for: serverID)?.summary
    }

    func isEnabled(tool: String, serverID: String) -> Bool {
        intent(for: serverID).isEnabled(tool)
    }

    func setEnabled(_ enabled: Bool, tool: String, serverID: String) {
        var intent = intent(for: serverID)
        intent.setEnabled(enabled, tool: tool)
        record.update(intent)
        persist()
    }

    /// Records what a live test just observed so the row can show a count and
    /// stale decisions do not linger.
    func observe(toolNames: [String], serverID: String) {
        var intent = intent(for: serverID)
        intent.observe(toolNames: toolNames)
        record.update(intent)
        persist()
    }

    private func persist() {
        guard let store else { return }
        do {
            try store.save(record)
            lastError = nil
        } catch {
            lastError = error.localizedDescription
        }
    }
}

/// The "3/4 enabled" mark on a collection row. Absent until a live test has
/// told the app what the server actually exposes.
struct MCPCapabilityBadge: View {
    @Environment(MCPCapabilityModel.self) private var capabilities
    let serverID: String
    var selected = false

    var body: some View {
        if let summary = capabilities.summary(for: serverID) {
            Text(summary)
                .font(.caption2.weight(.medium).monospacedDigit())
                .foregroundStyle(selected ? Color.white.opacity(0.9) : Color.secondary)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(
                    Capsule().fill(selected ? Color.white.opacity(0.18) : AgentTheme.separator.opacity(0.28))
                )
                .accessibilityLabel("\(summary) capabilities")
        }
    }
}

/// Per-tool switches for one server, with the enforcement boundary stated in
/// the same card rather than in a tooltip.
struct MCPCapabilitySection: View {
    @Environment(MCPCapabilityModel.self) private var capabilities
    let serverID: String
    let serverName: String
    /// False when the console refused this definition, so the empty state does
    /// not send a person to a test that cannot happen.
    let canRunLiveTest: Bool
    /// Safety verdicts from the current live connection, when one has run.
    let observedSafety: [String: MCPToolSafety]

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 8) {
                Text("Capabilities").font(.subheadline.weight(.semibold))
                Spacer()
                if let summary = intent.summary {
                    Text(summary)
                        .font(.caption.weight(.medium).monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 2)

            VStack(spacing: 0) {
                if toolNames.isEmpty {
                    HStack(spacing: 10) {
                        Image(systemName: "questionmark.circle").foregroundStyle(.secondary)
                        Text(emptyMessage)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 0)
                    }
                    .padding(14)
                } else {
                    ForEach(Array(toolNames.enumerated()), id: \.element) { index, name in
                        toolRow(name)
                        if index < toolNames.count - 1 { Divider().opacity(0.45) }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .standardPanel()

            if !toolNames.isEmpty {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "info.circle").foregroundStyle(.secondary)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(MCPCapabilityIntent.enforcementNotice)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        if let recordPath = capabilities.recordPath {
                            LocationText(path: recordPath)
                        }
                        if let failure = capabilities.lastError {
                            Label(failure, systemImage: "exclamationmark.triangle")
                                .font(.caption)
                                .foregroundStyle(AgentTheme.warning)
                        }
                    }
                }
                .padding(.horizontal, 2)
            }
        }
    }

    private var intent: MCPCapabilityIntent { capabilities.intent(for: serverID) }

    private var toolNames: [String] { intent.knownToolNames }

    private var emptyMessage: String {
        canRunLiveTest
            ? "No tool list yet. Run a live test above and Agent Tooling will record what \(serverName) exposes."
            : "No tool list yet. Agent Tooling learns a server's tools from a live test, which this definition cannot run, "
                + "so there is nothing to choose between."
    }

    @ViewBuilder
    private func toolRow(_ name: String) -> some View {
        let enabled = intent.isEnabled(name)
        HStack(spacing: 11) {
            if let safety = observedSafety[name] {
                Image(systemName: safety.symbolName)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(safety == .readOnly ? Color.secondary : AgentTheme.warning)
                    .frame(width: 16)
                    .help(safety.detail)
            } else {
                Image(systemName: "circle.dashed")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.tertiary)
                    .frame(width: 16)
            }
            Text(name)
                .font(.system(.callout, design: .monospaced))
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 16)
            Toggle(
                "",
                isOn: Binding(
                    get: { enabled },
                    set: { capabilities.setEnabled($0, tool: name, serverID: serverID) }
                )
            )
            .labelsHidden()
            .toggleStyle(.switch)
            .controlSize(.mini)
            .accessibilityLabel("Want \(name)")
        }
        .padding(.horizontal, 14)
        .frame(minHeight: 38)
    }
}
