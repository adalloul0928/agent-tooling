import AgentToolingCore
import AppKit
import SwiftUI

// MARK: - Live indicator

struct MCPLiveIndicator: View {
    let connectedAt: Date
    let expiresAt: Date?

    var body: some View {
        TimelineView(.periodic(from: connectedAt, by: 1)) { context in
            HStack(spacing: Space.sm) {
                Circle()
                    .fill(AgentTheme.ok)
                    .frame(width: Size.dot, height: Size.dot)
                    .opacity(Int(context.date.timeIntervalSince(connectedAt)) % 2 == 0 ? 1 : 0.35)
                Text(label(at: context.date))
                    .font(AgentFont.caption.monospacedDigit())
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
                Hairline(.vertical).frame(height: Size.compactRowHeight)
                counter("Resources", observation.declaresResources ? "\(observation.resourceCount)" : "—")
                Hairline(.vertical).frame(height: Size.compactRowHeight)
                counter("Prompts", observation.declaresPrompts ? "\(observation.promptCount)" : "—")
                Hairline(.vertical).frame(height: Size.compactRowHeight)
                counter("Handshake", "\(Int(observation.handshakeMilliseconds.rounded())) ms")
                Hairline(.vertical).frame(height: Size.compactRowHeight)
                counter("Inventory", "\(Int(observation.inventoryMilliseconds.rounded())) ms")
            }
            .padding(.vertical, Space.lg)
            Hairline()
            LabeledValueRow("Reported by server") {
                Text(identity)
                    .font(AgentFont.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
            if observation.unannotatedToolCount > 0 || observation.destructiveToolCount > 0 {
                Hairline()
                LabeledValueRow("Before you run") {
                    Text(warning)
                        .font(AgentFont.caption)
                        .foregroundStyle(.secondary)
                        .wrapsLines()
                }
            }
            Hairline()
            LabeledValueRow("Recorded") {
                Text(
                    "Nothing. This is what one live test saw at \(observation.observedAt.formatted(date: .omitted, time: .standard)), not this connection's saved status."
                )
                .font(AgentFont.caption)
                .foregroundStyle(.secondary)
                .wrapsLines()
            }
        }
    }

    private func counter(_ title: String, _ value: String) -> some View {
        VStack(spacing: Space.xxs) {
            Text(value).font(AgentFont.title.monospacedDigit())
            Text(title).font(AgentFont.micro).foregroundStyle(.secondary)
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
        VStack(alignment: .leading, spacing: Space.sm) {
            HStack {
                Text("Tools this connection offered").font(AgentFont.heading)
                Spacer()
                Text("\(tools.count)").font(AgentFont.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
            .padding(.horizontal, Space.xxs)

            VStack(spacing: 0) {
                ForEach(Array(visibleTools.enumerated()), id: \.element.id) { index, tool in
                    row(tool)
                    if index < visibleTools.count - 1 { Hairline() }
                }
                if tools.count > Self.visibleLimit {
                    Hairline()
                    Text("\(tools.count - Self.visibleLimit) more tools are not listed here.")
                        .font(AgentFont.caption)
                        .foregroundStyle(.secondary)
                        .padding(Space.xl)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .standardPanel()
        }
    }

    private var visibleTools: [MCPLiveTool] { Array(tools.prefix(Self.visibleLimit)) }

    private func row(_ tool: MCPLiveTool) -> some View {
        HStack(alignment: .top, spacing: Space.lg) {
            Image(systemName: tool.safety.symbolName)
                .font(AgentFont.bodyMedium)
                .foregroundStyle(tool.safety == .readOnly ? Color.secondary : AgentTheme.warning)
                .frame(width: Size.glyphSlot)
                .padding(.top, 1)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: Space.xxs) {
                HStack(spacing: Space.sm) {
                    Text(tool.name)
                        .font(AgentFont.monoBody.weight(.medium))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    MCPSafetyTag(text: tool.safety.label, isWarning: tool.safety != .readOnly)
                    if tool.declaresIdempotent { MCPSafetyTag(text: "Idempotent", isWarning: false) }
                    if tool.declaresOpenWorld { MCPSafetyTag(text: "Open world", isWarning: false) }
                }
                if let summary = tool.summary {
                    Text(summary)
                        .font(AgentFont.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .wrapsLines()
                }
            }
            Spacer(minLength: Space.lg)
            Button(selectedToolName == tool.name ? "Selected" : "Run…") {
                selectedToolName = tool.name
            }
            .secondaryActionStyle()
            .controlSize(.small)
            .disabled(isBusy || selectedToolName == tool.name)
        }
        .padding(.horizontal, Space.xl)
        .padding(.vertical, Space.lg)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(tool.name), \(tool.safety.label)")
    }
}

struct MCPSafetyTag: View {
    let text: String
    let isWarning: Bool

    var body: some View {
        Text(text)
            .font(AgentFont.microMedium)
            .foregroundStyle(isWarning ? AgentTheme.warning : Color.secondary)
            .padding(.horizontal, Space.sm)
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
            HStack(spacing: Space.lg) {
                SymbolTile(symbol: target.isProcessLaunch ? "bolt.badge.clock" : "network", size: Size.tileLarge)
                VStack(alignment: .leading, spacing: Space.xxs) {
                    Text(target.isProcessLaunch ? "Start \(serverName) for a live test" : "Open a live test session")
                        .font(AgentFont.title)
                    Text("This is the only thing Agent Tooling will run or contact.")
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(Space.xxxl)
            Hairline()

            ScrollView {
                VStack(alignment: .leading, spacing: Space.xl) {
                    VStack(alignment: .leading, spacing: Space.sm) {
                        SectionCaption(text: target.isProcessLaunch ? "Exact command" : "Exact endpoint")
                        Text(target.displayCommand)
                            .font(AgentFont.monoBody)
                            .textSelection(.enabled)
                            .wrapsLines()
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(Space.lg)
                            .standardPanel()
                    }

                    Text(MCPTestConnectionPolicy.consentSummary(for: target, serverName: serverName))
                        .font(AgentFont.body)
                        .foregroundStyle(.secondary)
                        .wrapsLines()

                    VStack(spacing: 0) {
                        ForEach(Array(boundaries.enumerated()), id: \.offset) { index, item in
                            HStack(alignment: .top, spacing: Space.lg) {
                                Image(systemName: item.symbol)
                                    .foregroundStyle(.secondary)
                                    .frame(width: Size.glyphSlot)
                                Text(item.text)
                                    .font(AgentFont.caption)
                                    .foregroundStyle(.secondary)
                                    .wrapsLines()
                                Spacer(minLength: 0)
                            }
                            .padding(Space.lg)
                            if index < boundaries.count - 1 { Hairline() }
                        }
                    }
                    .standardPanel()
                }
                .padding(Space.xxxl)
            }

            Hairline()
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .secondaryActionStyle()
                    .keyboardShortcut(.cancelAction)
                Button(target.isProcessLaunch ? "Start and connect" : "Connect") {
                    onConfirm()
                    dismiss()
                }
                .primaryActionStyle()
                .keyboardShortcut(.defaultAction)
            }
            .padding(Space.xl)
        }
        .sheetSize(SheetSize.medium)
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
                "No client configuration changes, and the result is not saved as this connection's status. It is one observation, shown once."
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
