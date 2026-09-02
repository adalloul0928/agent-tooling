import AgentToolingCore
import SwiftUI

struct OverviewView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let navigate: (AppSection) -> Void
    @State private var selectedReceipt: ActivityReceipt?
    @State private var revealed = false

    var body: some View {
        VStack(spacing: 0) {
            PageToolbar(title: "This Mac", context: lastScanText) {
                profileMenu

                Button {
                    Task { await model.runDoctor() }
                } label: {
                    Label(model.isRunningDoctor ? "Checking…" : "Check Now", systemImage: "arrow.clockwise")
                }
                .buttonStyle(.bordered)
                .disabled(model.isInteractionLocked)

                Button {
                    Task { await model.runSync() }
                } label: {
                    HStack(spacing: 6) {
                        Label(model.isSyncing ? "Preparing…" : "Review Sync", systemImage: "arrow.triangle.2.circlepath")
                        if model.attentionCount > 0 {
                            Text("\(model.attentionCount)")
                                .contentTransition(.numericText())
                                .font(.caption2.weight(.semibold))
                                .padding(.horizontal, 6)
                                .frame(height: 16)
                                .background(Capsule().fill(Color.white.opacity(0.25)))
                        }
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(model.isInteractionLocked)
            }

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    SyncConduitView(
                        managedCount: managedCount,
                        discoveredCount: discoveredCount,
                        profileName: model.activeProfile?.name ?? "No configuration",
                        desiredCount: desiredCount,
                        pendingCount: model.attentionCount,
                        terminals: terminals,
                        onLibrary: { navigate(.skills) },
                        onProfile: { navigate(.profiles) },
                        onClient: { _ in navigate(.syncCenter) }
                    )

                    HStack(alignment: .top, spacing: 16) {
                        VStack(alignment: .leading, spacing: 16) {
                            attentionCard
                            if !recommendations.isEmpty {
                                recommendationsCard
                            }
                        }
                        .frame(maxWidth: .infinity)

                        activityCard
                            .frame(maxWidth: .infinity)
                    }
                    .opacity(revealed ? 1 : 0)
                    .offset(y: revealed ? 0 : 10)
                    .animation(reduceMotion ? nil : .easeOut(duration: 0.45).delay(0.35), value: revealed)
                }
                .frame(maxWidth: 1_100)
                .padding(EdgeInsets(top: 4, leading: 22, bottom: 22, trailing: 22))
                .frame(maxWidth: .infinity)
            }
            .scrollIndicators(.hidden)
        }
        .sheet(item: $selectedReceipt) { receipt in
            ReceiptDetailSheet(receipt: receipt)
        }
        .onAppear {
            DispatchQueue.main.async { revealed = true }
        }
    }

    private var profileMenu: some View {
        Menu {
            ForEach(model.profiles) { profile in
                Button {
                    model.applyProfile(id: profile.id)
                } label: {
                    if profile.id == model.activeProfileID {
                        Label(profile.name, systemImage: "checkmark")
                    } else {
                        Text(profile.name)
                    }
                }
            }
            Divider()
            Button("Manage Configurations…") { navigate(.profiles) }
        } label: {
            HStack(spacing: 7) {
                KindTile(kind: .profile, size: 18)
                Text(model.activeProfile?.name ?? "No configuration")
                    .lineLimit(1)
            }
        }
        .menuStyle(.button)
        .buttonStyle(.bordered)
        .fixedSize()
        .disabled(model.isInteractionLocked)
        .accessibilityLabel("Active configuration")
    }

    private var attentionCard: some View {
        TitledCard("Needs attention", count: attentionItems.isEmpty ? nil : "\(attentionItems.count)") {
            if attentionItems.isEmpty {
                InfoRow("No local issues found", detail: "Account sign-in and fresh-session checks remain manual.") {
                    StatusGlyph(state: .healthy, size: 16)
                }
            } else {
                ForEach(attentionItems) { item in
                    InfoRow(item.title, detail: item.detail) {
                        StatusGlyph(state: item.state, size: 16)
                    } trailing: {
                        Button("Review") { navigate(.syncCenter) }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                    }
                    if item.id != attentionItems.last?.id { Divider().opacity(0.35) }
                }
            }
        }
    }

    private var recommendationsCard: some View {
        TitledCard("Recommendations", count: "\(recommendations.count) new") {
            ForEach(Array(recommendations.enumerated()), id: \.element.id) { index, recommendation in
                Button {
                    navigate(.insights)
                } label: {
                    InfoRow(recommendation.title, detail: recommendation.summary) {
                        Image(systemName: "lightbulb")
                            .font(.system(size: 15, weight: .medium))
                            .foregroundStyle(AgentTheme.blue)
                            .frame(width: 18)
                    } trailing: {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.tertiary)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityHint("Opens Insights")
                if index < recommendations.count - 1 { Divider().opacity(0.35) }
            }
        }
    }

    private var activityCard: some View {
        TitledCard("Recent activity") {
            Button("Show All") { navigate(.activity) }
                .buttonStyle(.plain)
                .foregroundStyle(AgentTheme.blue)
        } content: {
            if model.activities.isEmpty {
                Text("Checks and reviewed changes will appear here.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .padding(14)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                ForEach(recentActivities) { receipt in
                    Button {
                        selectedReceipt = receipt
                    } label: {
                        ActivityCompactRow(receipt: receipt)
                    }
                    .buttonStyle(.plain)
                    if receipt.id != recentActivities.last?.id { Divider().opacity(0.35) }
                }
            }
        }
    }

    private var lastScanText: String {
        guard let date = model.targetObservations.map(\.lastScannedAt).max() else {
            return "Not checked yet"
        }
        return "Checked \(date.formatted(.relative(presentation: .named)))"
    }

    private var managedCount: Int {
        model.skills.filter(\.owned).count + model.plugins.count + model.mcpServers.filter(\.isManagedDefinition).count
    }

    private var discoveredCount: Int {
        model.skills.filter { !$0.owned }.count + model.mcpServers.filter { !$0.isManagedDefinition }.count
    }

    private var desiredCount: Int {
        guard let profile = model.activeProfile else { return 0 }
        let effective = model.effectiveProfile(for: profile.id) ?? profile
        return effective.enabledPlugins.count + effective.requiredMCPs.count
    }

    private var terminals: [ConduitTerminal] {
        [ClientKind.claude, .codex, .gemini].map { client in
            let verdict = model.clientVerdict(for: client)
            return ConduitTerminal(client: client, state: verdict.state, text: verdict.text)
        }
    }

    private var recommendations: [ToolRecommendation] {
        Array((model.insightsReport?.recommendations ?? []).prefix(2))
    }

    private var recentActivities: [ActivityReceipt] {
        var seenTitles = Set<String>()
        return Array(model.activities.filter { seenTitles.insert($0.displayTitle).inserted }.prefix(5))
    }

    private var attentionItems: [OverviewAttention] {
        let targets = model.targetObservations
            .filter { !$0.isCommandAvailable }
            .map {
                OverviewAttention(
                    id: $0.id,
                    title: $0.installed ? "\($0.surface.displayName) command is unavailable" : "\($0.surface.displayName) was not found",
                    detail: $0.notes.first ?? "The expected local path was checked.",
                    state: .attention
                )
            }
        let configurationChecks = (model.activeProfile?.checks ?? [])
            .filter { $0.state == .attention || $0.state == .unavailable }
            .map { OverviewAttention(id: "profile-\($0.id)", title: $0.name, detail: $0.detail, state: $0.state) }
        let servers = model.mcpServers
            .filter { $0.aggregateState == .attention || $0.aggregateState == .unavailable }
            .map { OverviewAttention(id: "mcp-\($0.id)", title: $0.name, detail: $0.summary, state: $0.aggregateState) }
        return Array((targets + configurationChecks + servers).prefix(4))
    }
}

private struct OverviewAttention: Identifiable {
    let id: String
    let title: String
    let detail: String
    let state: HealthState
}

struct ActivityCompactRow: View {
    let receipt: ActivityReceipt

    var body: some View {
        InfoRow(receipt.displayTitle, detail: receipt.detail) {
            StatusGlyph(state: receipt.state, size: 16)
        } trailing: {
            Text(receipt.date, style: .relative)
                .font(.caption)
                .foregroundStyle(.tertiary)
                .monospacedDigit()
        }
        .contentShape(Rectangle())
    }
}

struct ReceiptDetailSheet: View {
    @Environment(\.dismiss) private var dismiss
    let receipt: ActivityReceipt?

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    HStack(spacing: 12) {
                        KindTile(kind: .activity, size: 40)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(receipt?.displayTitle ?? "Receipt")
                                .font(.title3.weight(.semibold))
                            Text(receipt?.date.formatted() ?? "")
                                .font(.callout)
                                .foregroundStyle(.secondary)
                        }
                    }

                    if let receipt {
                        GroupBox("Result") {
                            VStack(spacing: 0) {
                                LabeledValueRow("Status") {
                                    StatusBadge(state: receipt.state, text: receipt.state.rawValue.capitalized)
                                }
                                Divider()
                                LabeledValueRow("Detail") {
                                    Text(receipt.detail)
                                        .textSelection(.enabled)
                                }
                                if let command = receipt.command {
                                    Divider()
                                    LabeledValueRow("Command") {
                                        Text(command)
                                            .font(.system(.caption, design: .monospaced))
                                            .textSelection(.enabled)
                                    }
                                }
                            }
                        }
                    }
                }
                .padding(24)
            }

            Divider()
            HStack {
                Spacer()
                Button("Done") { dismiss() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, 24)
            .frame(height: 58)
        }
        .frame(width: 580)
        .frame(minHeight: 360, idealHeight: 440, maxHeight: 620)
        .background(AgentTheme.contentBackground)
    }
}
