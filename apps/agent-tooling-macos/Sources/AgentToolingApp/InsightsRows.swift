import AgentToolingCore
import SwiftUI

struct InsightPanel<Content: View>: View {
    let title: String
    let content: Content

    init(_ title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title)
                .font(AgentFont.heading)
                .padding(.horizontal, Space.xl)
                .frame(maxWidth: .infinity, minHeight: 43, alignment: .leading)
            Hairline()
            content
        }
        .standardPanel()
    }
}

enum InsightSelection: Hashable {
    case opportunities
    case skillHealth
}

struct CoverageRow: View {
    let coverage: ConversationScanCoverage

    var body: some View {
        HStack(alignment: .top, spacing: Space.lg) {
            ClientDisc(client: coverage.client, size: Size.disc)
            VStack(alignment: .leading, spacing: Space.xs) {
                HStack(alignment: .firstTextBaseline, spacing: Space.sm) {
                    Text(coverage.sourceName)
                        .font(AgentFont.bodyMedium)
                    Label(statusText, systemImage: statusSymbol)
                        .font(AgentFont.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text("\(coverage.conversationsScanned) chats · \(coverage.itemsInspected) items")
                        .font(AgentFont.caption)
                        .foregroundStyle(.secondary)
                }
                Text(coverage.detail)
                    .font(AgentFont.caption)
                    .foregroundStyle(.secondary)
                    .wrapsLines()
                if let latestItemAt = coverage.latestItemAt {
                    Text("Latest item \(latestItemAt.formatted(.relative(presentation: .named)))")
                        .font(AgentFont.micro)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.horizontal, Space.xl)
        .padding(.vertical, Space.lg)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            "\(coverage.sourceName), \(statusText), \(coverage.conversationsScanned) conversations, \(coverage.itemsInspected) items. \(coverage.detail)"
        )
    }

    private var statusText: String {
        switch coverage.status {
        case .scanned: "Scanned"
        case .degraded: "Limited coverage"
        case .unavailable: "Unavailable"
        }
    }

    private var statusSymbol: String {
        switch coverage.status {
        case .scanned: "checkmark"
        case .degraded: "exclamationmark.triangle"
        case .unavailable: "slash.circle"
        }
    }
}

struct RecommendationRow: View {
    let recommendation: ToolRecommendation
    let action: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: Space.lg) {
            KindTile(kind: recommendationKind, size: Size.tile)

            VStack(alignment: .leading, spacing: Space.xs) {
                Text(recommendation.title)
                    .font(AgentFont.bodySemibold)
                Text(displaySummary)
                    .font(AgentFont.body)
                    .wrapsLines()
                Text(recommendation.rationale)
                    .font(AgentFont.caption)
                    .foregroundStyle(.secondary)
                    .wrapsLines()
                Text(metadata)
                    .font(AgentFont.micro)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: Space.xxl)

            Button(actionTitle, action: action)
                .secondaryActionStyle()
                .controlSize(.small)
                .accessibilityHint(actionHint)
        }
        .padding(.horizontal, Space.xl)
        .padding(.vertical, Space.lg)
    }

    private var recommendationKind: ToolingKind {
        switch recommendation.kind {
        case .useExistingSkill, .createCustomSkill, .marketplaceSkill: .skill
        case .mcpServer: .mcpServer
        case .plugin: .plugin
        }
    }

    private var actionTitle: String {
        switch recommendation.kind {
        case .useExistingSkill: "Open skill"
        case .createCustomSkill: "Create with Codex"
        case .marketplaceSkill, .mcpServer, .plugin:
            recommendation.marketplacePackageID == nil ? "Browse Discover" : "Review in Discover"
        }
    }

    private var actionHint: String {
        switch recommendation.kind {
        case .useExistingSkill: "Opens the installed skill details"
        case .createCustomSkill: "Opens a Codex draft you review file by file. Nothing is created and nothing is installed"
        case .marketplaceSkill, .mcpServer, .plugin: "Opens Discover without installing anything"
        }
    }

    private var metadata: String {
        var parts = [confidenceText]
        if recommendation.supportingConversationCount > 0 {
            parts.append(
                "Based on \(recommendation.supportingConversationCount) \(recommendation.supportingConversationCount == 1 ? "conversation" : "conversations")"
            )
        }
        if let sourceName = recommendation.sourceName, !sourceName.isEmpty {
            parts.append("Source: \(sourceName)")
        }
        return parts.joined(separator: " · ")
    }

    private var displaySummary: String {
        let normalized = recommendation.summary
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
        guard normalized.count > 240 else { return normalized }
        var preview = String(normalized.prefix(240))
        if let boundary = preview.lastIndex(of: " ") {
            preview.removeSubrange(boundary...)
        }
        return preview + "…"
    }

    private var confidenceText: String {
        switch recommendation.confidence {
        case .high: "Strong pattern match"
        case .medium: "Possible pattern match"
        case .exploratory: "Exploratory match"
        }
    }
}

struct QualityFindingRow: View {
    let finding: SkillQualityFinding
    let openSkill: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: Space.lg) {
            Image(systemName: symbol)
                .font(AgentFont.title)
                .foregroundStyle(severityColor)
                .frame(width: Size.tile, height: Size.tile)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: Space.xs) {
                Text(finding.title)
                    .font(AgentFont.bodySemibold)
                Text(finding.detail)
                    .font(AgentFont.body)
                    .wrapsLines()
                Text(finding.recommendedAction)
                    .font(AgentFont.caption)
                    .foregroundStyle(.secondary)
                    .wrapsLines()
            }
            Spacer(minLength: Space.xxl)
            Button("Open skill", action: openSkill)
                .secondaryActionStyle()
                .controlSize(.small)
                .accessibilityHint("Opens this skill for review")
        }
        .padding(.horizontal, Space.xl)
        .padding(.vertical, Space.lg)
    }

    private var symbol: String {
        switch finding.severity {
        case .information: "info.circle"
        case .warning: "exclamationmark.triangle.fill"
        case .actionRequired: "exclamationmark.circle.fill"
        }
    }

    private var severityColor: Color {
        switch finding.severity {
        case .information: .secondary
        case .warning: AgentTheme.warning
        case .actionRequired: AgentTheme.failure
        }
    }
}

struct SkillUsageRow: View {
    let metric: SkillUsageMetric
    let openSkill: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: Space.lg) {
            Image(systemName: "chart.bar")
                .font(AgentFont.titleRegular)
                .foregroundStyle(.secondary)
                .frame(width: Size.tile, height: Size.tile)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: Space.xs) {
                Text(metric.skillName)
                    .font(AgentFont.bodySemibold)
                Text(metric.usageSummary)
                    .font(AgentFont.body)
                Text(evidenceDetail)
                    .font(AgentFont.caption)
                    .foregroundStyle(.secondary)
                    .wrapsLines()
            }
            Spacer(minLength: Space.xxl)
            Button("Open skill", action: openSkill)
                .secondaryActionStyle()
                .controlSize(.small)
                .accessibilityHint("Opens this skill for review")
        }
        .padding(.horizontal, Space.xl)
        .padding(.vertical, Space.lg)
    }

    private var evidenceDetail: String {
        var parts: [String] = []
        if !metric.observedClients.isEmpty {
            let clients = metric.observedClients
                .map(\.rawValue)
                .sorted()
                .joined(separator: ", ")
            parts.append("Observed in \(clients)")
        }
        if let lastObservedAt = metric.lastObservedAt {
            parts.append("Last observed \(lastObservedAt.formatted(.relative(presentation: .named)))")
        }
        if parts.isEmpty {
            parts.append("No supported activation evidence was available in the selected history")
        }
        return parts.joined(separator: " · ")
    }
}
