import AgentToolingCore
import AppKit
import SwiftUI

// MARK: - Live indicator

struct MCPLiveIndicator: View {
    let connectedAt: Date
    let expiresAt: Date?

    var body: some View {
        TimelineView(.periodic(from: connectedAt, by: 1)) { context in
            HStack(spacing: 7) {
                Circle()
                    .fill(AgentTheme.ok)
                    .frame(width: 7, height: 7)
                    .opacity(Int(context.date.timeIntervalSince(connectedAt)) % 2 == 0 ? 1 : 0.35)
                Text(label(at: context.date))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Live connection open")
        }
    }

    private func label(at date: Date) -> String {
        let elapsed = max(0, Int(date.timeIntervalSince(connectedAt)))
        guard let expiresAt else { return "Live · \(elapsed)s" }
        let remaining = max(0, Int(expiresAt.timeIntervalSince(date)))
        return "Live · \(elapsed)s open · stops in \(remaining)s"
    }
}

// MARK: - Observation summary

struct MCPObservationSummary: View {
    let observation: MCPLiveObservation

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                counter("Tools", observation.declaresTools ? "\(observation.tools.count)" : "—")
                Divider().frame(height: 30).opacity(0.45)
                counter("Resources", observation.declaresResources ? "\(observation.resourceCount)" : "—")
                Divider().frame(height: 30).opacity(0.45)
                counter("Prompts", observation.declaresPrompts ? "\(observation.promptCount)" : "—")
                Divider().frame(height: 30).opacity(0.45)
                counter("Handshake", "\(Int(observation.handshakeMilliseconds.rounded())) ms")
                Divider().frame(height: 30).opacity(0.45)
                counter("Inventory", "\(Int(observation.inventoryMilliseconds.rounded())) ms")
            }
            .padding(.vertical, 11)
            Divider().opacity(0.45)
            LabeledValueRow("Reported by server") {
                Text(identity)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
            if observation.unannotatedToolCount > 0 || observation.destructiveToolCount > 0 {
                Divider().opacity(0.45)
                LabeledValueRow("Before you run") {
                    Text(warning)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Divider().opacity(0.45)
            LabeledValueRow("Recorded") {
                Text(
                    "Nothing. This is what one connection saw at \(observation.observedAt.formatted(date: .omitted, time: .standard)), not this server's saved status."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func counter(_ title: String, _ value: String) -> some View {
        VStack(spacing: 2) {
            Text(value).font(.title3.weight(.semibold).monospacedDigit())
            Text(title).font(.caption2).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .combine)
    }

    private var identity: String {
        let name = observation.serverName ?? "an unnamed server"
        let version = observation.serverVersion.map { " \($0)" } ?? ""
        return "\(name)\(version) · MCP \(observation.protocolVersion)"
    }

    private var warning: String {
        var parts: [String] = []
        if observation.destructiveToolCount > 0 {
            parts.append("\(observation.destructiveToolCount) declared destructive")
        }
        if observation.unannotatedToolCount > 0 {
            parts.append("\(observation.unannotatedToolCount) with no annotations, which MCP treats as able to change or delete data")
        }
        return parts.joined(separator: " · ")
    }
}

// MARK: - Tool inventory

struct MCPToolInventoryList: View {
    private static let visibleLimit = 60

    let tools: [MCPLiveTool]
    @Binding var selectedToolName: String?
    let isBusy: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack {
                Text("Tools this connection offered").font(.subheadline.weight(.semibold))
                Spacer()
                Text("\(tools.count)").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 2)

            VStack(spacing: 0) {
                ForEach(Array(visibleTools.enumerated()), id: \.element.id) { index, tool in
                    row(tool)
                    if index < visibleTools.count - 1 { Divider().opacity(0.45) }
                }
                if tools.count > Self.visibleLimit {
                    Divider().opacity(0.45)
                    Text("\(tools.count - Self.visibleLimit) more tools are not listed here.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(14)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .standardPanel()
        }
    }

    private var visibleTools: [MCPLiveTool] { Array(tools.prefix(Self.visibleLimit)) }

    private func row(_ tool: MCPLiveTool) -> some View {
        HStack(alignment: .top, spacing: 11) {
            Image(systemName: tool.safety.symbolName)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(tool.safety == .readOnly ? Color.secondary : AgentTheme.warning)
                .frame(width: 18)
                .padding(.top, 1)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 7) {
                    Text(tool.name)
                        .font(.system(.callout, design: .monospaced).weight(.medium))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    MCPSafetyTag(text: tool.safety.label, isWarning: tool.safety != .readOnly)
                    if tool.declaresIdempotent { MCPSafetyTag(text: "Idempotent", isWarning: false) }
                    if tool.declaresOpenWorld { MCPSafetyTag(text: "Open world", isWarning: false) }
                }
                if let summary = tool.summary {
                    Text(summary)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 12)
            Button(selectedToolName == tool.name ? "Selected" : "Run…") {
                selectedToolName = tool.name
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(isBusy || selectedToolName == tool.name)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(tool.name), \(tool.safety.label)")
    }
}

struct MCPSafetyTag: View {
    let text: String
    let isWarning: Bool

    var body: some View {
        Text(text)
            .font(.caption2.weight(.medium))
            .foregroundStyle(isWarning ? AgentTheme.warning : Color.secondary)
            .padding(.horizontal, 6)
            .padding(.vertical, 1)
            .background(
                Capsule().fill((isWarning ? AgentTheme.warning : AgentTheme.graphite).opacity(0.14))
            )
    }
}


// MARK: - Consent

/// The one screen that turns "Agent Tooling manages this definition" into
/// "Agent Tooling is about to run somebody else's code on your Mac".
struct MCPTestConsentSheet: View {
    @Environment(\.dismiss) private var dismiss
    let serverName: String
    let target: MCPTestTarget
    let onConfirm: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                SymbolTile(symbol: target.isProcessLaunch ? "bolt.badge.clock" : "network", size: 40)
                VStack(alignment: .leading, spacing: 2) {
                    Text(target.isProcessLaunch ? "Start \(serverName) for a live test" : "Open a live test session")
                        .font(.title3.weight(.semibold))
                    Text("This is the only thing Agent Tooling will run or contact.")
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(22)
            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    VStack(alignment: .leading, spacing: 7) {
                        SectionCaption(text: target.isProcessLaunch ? "Exact command" : "Exact endpoint")
                        Text(target.displayCommand)
                            .font(.system(.callout, design: .monospaced))
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(13)
                            .standardPanel()
                    }

                    Text(MCPTestConnectionPolicy.consentSummary(for: target, serverName: serverName))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    VStack(spacing: 0) {
                        ForEach(Array(boundaries.enumerated()), id: \.offset) { index, item in
                            HStack(alignment: .top, spacing: 10) {
                                Image(systemName: item.symbol)
                                    .foregroundStyle(.secondary)
                                    .frame(width: 18)
                                Text(item.text)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                                Spacer(minLength: 0)
                            }
                            .padding(13)
                            if index < boundaries.count - 1 { Divider().opacity(0.45) }
                        }
                    }
                    .standardPanel()
                }
                .padding(22)
            }

            Divider()
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .buttonStyle(.bordered)
                    .keyboardShortcut(.cancelAction)
                Button(target.isProcessLaunch ? "Start and connect" : "Connect") {
                    onConfirm()
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
            }
            .padding(16)
        }
        .frame(width: 640, height: 560)
        .background(AgentTheme.contentBackground)
    }

    private var boundaries: [(symbol: String, text: String)] {
        var items: [(String, String)] = []
        if target.isProcessLaunch {
            items.append(
                (
                    "shield.lefthalf.filled",
                    "Only this program starts. Shells, `env`, and privilege wrappers are refused, so the line above is what runs."
                )
            )
            items.append(
                (
                    "key.slash",
                    "It gets a fresh, minimal environment — PATH, HOME, TMPDIR, LANG, USER. None of your exported keys or tokens are passed, "
                        + "so a server that needs credentials will say so instead of using them."
                )
            )
        } else {
            items.append(("key.slash", "No Authorization header, cookies, or saved credentials are sent."))
        }
        items.append(
            (
                "stopwatch",
                "Every step is time-limited, and the whole session stops after "
                    + "\(MCPTestConnectionPolicy.sessionLifetimeSeconds) seconds or whenever you press Stop."
            )
        )
        items.append(
            (
                "doc.badge.gearshape",
                "No client configuration changes, and the result is not saved as this server's status. It is one observation, shown once."
            )
        )
        items.append(
            (
                "hand.raised",
                "Running a tool afterwards is a real call. Agent Tooling asks again before the first run of any tool "
                    + "that is not annotated read-only."
            )
        )
        return items
    }
}
