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
                .font(AgentFont.microMedium.monospacedDigit())
                .foregroundStyle(selected ? Color.white.opacity(0.9) : Color.secondary)
                .padding(.horizontal, Space.sm)
                .padding(.vertical, Space.xxs)
                .background(
                    Capsule().fill(selected ? Color.white.opacity(0.18) : AgentTheme.fillStrong)
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
        VStack(alignment: .leading, spacing: Space.sm) {
            HStack(spacing: Space.md) {
                Text("Capabilities").font(AgentFont.heading)
                Spacer()
                if let summary = intent.summary {
                    Text(summary)
                        .font(AgentFont.captionMedium.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, Space.xxs)

            VStack(spacing: 0) {
                if toolNames.isEmpty {
                    HStack(spacing: Space.lg) {
                        Image(systemName: "questionmark.circle").foregroundStyle(.secondary)
                        Text(emptyMessage)
                            .font(AgentFont.body)
                            .foregroundStyle(.secondary)
                            .wrapsLines()
                        Spacer(minLength: 0)
                    }
                    .padding(Space.xl)
                } else {
                    ForEach(Array(toolNames.enumerated()), id: \.element) { index, name in
                        toolRow(name)
                        if index < toolNames.count - 1 { Hairline() }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .standardPanel()

            if !toolNames.isEmpty {
                HStack(alignment: .top, spacing: Space.md) {
                    Image(systemName: "info.circle").foregroundStyle(.secondary)
                    VStack(alignment: .leading, spacing: Space.xs) {
                        Text(MCPCapabilityIntent.enforcementNotice)
                            .font(AgentFont.caption)
                            .foregroundStyle(.secondary)
                            .wrapsLines()
                        if let recordPath = capabilities.recordPath {
                            LocationText(path: recordPath)
                        }
                        if let failure = capabilities.lastError {
                            Label(failure, systemImage: "exclamationmark.triangle")
                                .font(AgentFont.caption)
                                .foregroundStyle(AgentTheme.warning)
                        }
                    }
                }
                .padding(.horizontal, Space.xxs)
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
        HStack(spacing: Space.lg) {
            if let safety = observedSafety[name] {
                Image(systemName: safety.symbolName)
                    .font(AgentFont.captionMedium)
                    .foregroundStyle(safety == .readOnly ? Color.secondary : AgentTheme.warning)
                    .frame(width: Size.glyphSlot)
                    .help(safety.detail)
            } else {
                Image(systemName: "circle.dashed")
                    .font(AgentFont.captionMedium)
                    .foregroundStyle(.tertiary)
                    .frame(width: Size.glyphSlot)
            }
            Text(name)
                .font(AgentFont.monoBody)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: Space.xl)
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
        .padding(.horizontal, Space.xl)
        .frame(minHeight: Size.compactRowHeight)
    }
}
