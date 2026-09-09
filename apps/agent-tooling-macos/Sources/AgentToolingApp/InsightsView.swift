import AgentToolingCore
import SwiftUI

struct InsightsView: View {
    @Environment(AppModel.self) private var model
    @Environment(AppNavigationState.self) private var navigation
    @State private var includeClaude = true
    @State private var includeCodex = true
    @State private var lookbackDays = 30
    @State private var maximumConversations = 25
    @State private var includeMarketplaceRecommendations = false
    @State private var selection: InsightSelection = .opportunities
    @State private var scanError: String?
    @State private var isPresentingClearConfirmation = false
    @State private var scanTask: Task<Void, Never>?
    @State private var showingScanOptions = false

    var body: some View {
        VStack(spacing: 0) {
            PageToolbar(title: "Insights", context: toolbarContext) {
                Button("Scan options", systemImage: "slider.horizontal.3") { showingScanOptions.toggle() }
                    .buttonStyle(.glass)
                    .popover(isPresented: $showingScanOptions) {
                        ScrollView { scanConfiguration.padding(18) }.frame(width: 590, height: 520)
                    }
                if model.isScanningInsights {
                    Button(role: .cancel) {
                        scanTask?.cancel()
                    } label: {
                        Label("Cancel scan", systemImage: "xmark")
                    }
                    .buttonStyle(.glass)
                    .keyboardShortcut(.cancelAction)
                    .accessibilityHint("Stops the scan before saving a new report")
                } else {
                    Button {
                        startScan()
                    } label: {
                        Label("Scan recent work", systemImage: "magnifyingglass")
                    }
                    .buttonStyle(.glassProminent)
                    .tint(AgentTheme.selection)
                    .disabled(!canScan)
                    .keyboardShortcut(.return, modifiers: [.command])
                    .accessibilityHint("Reads selected local chat history and saves only aggregate findings")
                }
            }

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    if model.isScanningInsights {
                        scanningState
                    } else if let scanError {
                        errorState(scanError)
                    }

                    if let report = model.visibleInsightsReport {
                        reportContent(report)
                    } else if !model.isScanningInsights && scanError == nil {
                        firstRunState
                    }
                }
                .frame(maxWidth: 1_100, alignment: .leading)
                .padding(.horizontal, WorkspaceLayout.pageInset)
                .padding(.top, WorkspaceLayout.contentTopInset)
                .padding(.bottom, WorkspaceLayout.pageInset)
                .frame(maxWidth: .infinity, alignment: .topLeading)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .confirmationDialog(
            "Clear saved insights?",
            isPresented: $isPresentingClearConfirmation,
            titleVisibility: .visible
        ) {
            Button("Clear Saved Insights", role: .destructive) {
                model.clearInsightsReport()
                scanError = nil
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This removes the saved aggregate report. Client chat history will not be changed.")
        }
    }

    private var scanConfiguration: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Scan recent work")
                .font(.subheadline.weight(.semibold))
                .padding(.horizontal, 15)
                .frame(minHeight: 43, alignment: .leading)
            Divider().opacity(0.32)

            VStack(alignment: .leading, spacing: 0) {
                VStack(alignment: .leading, spacing: 5) {
                    Text("Look for repeated work, underused skills, and tools that may help next time.")
                        .font(.callout)
                    Text(
                        "Chat text is processed transiently. The app saves only aggregate counts and recommendations—not messages or excerpts."
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                }
                .padding(15)

                Divider()

                VStack(spacing: 14) {
                    configurationRow("Sources", detail: "Local history only") {
                        VStack(alignment: .leading, spacing: 9) {
                            if model.isClientEnabled(.claude) {
                                Toggle(isOn: $includeClaude) {
                                    HStack(spacing: 8) {
                                        ClientBrandIcon(client: .claude, size: 16)
                                        Text("Claude Code")
                                    }
                                }
                            }
                            if model.isClientEnabled(.codex) {
                                Toggle(isOn: $includeCodex) {
                                    HStack(spacing: 8) {
                                        ClientBrandIcon(client: .codex, size: 16)
                                        Text("Codex")
                                    }
                                }
                            }
                        }
                        .toggleStyle(.checkbox)
                    }

                    Divider()

                    configurationRow("Review period", detail: "How far back to inspect") {
                        WorkspaceSegmentedPicker("Review period", selection: $lookbackDays) {
                            Text("7 days").tag(7)
                            Text("30 days").tag(30)
                            Text("90 days").tag(90)
                        }
                        .labelsHidden()
                        .frame(maxWidth: 330)
                        .accessibilityLabel("Review period")
                    }

                    Divider()

                    configurationRow("Conversation limit", detail: "Per selected source") {
                        WorkspaceSegmentedPicker("Conversation limit", selection: $maximumConversations) {
                            Text("10 chats").tag(10)
                            Text("25 chats").tag(25)
                            Text("50 chats").tag(50)
                        }
                        .labelsHidden()
                        .frame(maxWidth: 330)
                        .accessibilityLabel("Maximum conversations per source")
                    }

                    Divider()

                    configurationRow("Catalog suggestions", detail: "Optional network access") {
                        VStack(alignment: .leading, spacing: 5) {
                            Toggle(
                                "Include established plugins, skills, and MCP servers from connected catalogs",
                                isOn: $includeMarketplaceRecommendations
                            )
                            .toggleStyle(.checkbox)
                            .fixedSize(horizontal: false, vertical: true)
                            .accessibilityHint("Refreshes connected catalogs with privacy-filtered capability searches")
                            Text(
                                "Only broad capability topics from an audited list are used as online queries; chat text and local names stay on this Mac."
                            )
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                .padding(15)

                if !includeClaude && !includeCodex {
                    Divider()
                    Label("Select Claude Code, Codex, or both to scan.", systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(15)
                        .accessibilityLabel("A conversation source is required")
                }
            }
        }
        .standardPanel()
    }

    private var scanningState: some View {
        HStack(spacing: 12) {
            ProgressView()
                .controlSize(.small)
            VStack(alignment: .leading, spacing: 2) {
                Text("Reviewing recent work")
                    .font(.callout.weight(.medium))
                Text("The scan is read-only. No skill, plugin, or MCP server will be installed.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 4)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Scanning recent work. No tools will be installed.")
    }

    private var firstRunState: some View {
        ContentUnavailableView {
            Label("No insights yet", systemImage: "doc.text.magnifyingglass")
        } description: {
            Text("Find repeated work and useful tools in your recent conversations. Choose your sources and review period in Scan options.")
        }
        .frame(maxWidth: .infinity, minHeight: 230)
    }

    private func errorState(_ message: String) -> some View {
        InsightPanel("The scan could not finish") {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "exclamationmark.triangle")
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 4) {
                    Text(message)
                        .font(.callout)
                        .textSelection(.enabled)
                    Button("Try again") {
                        startScan()
                    }
                    .buttonStyle(.link)
                    .disabled(!canScan)
                }
                Spacer()
            }
            .padding(15)
        }
    }

    private func reportContent(_ report: InsightsReport) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            reportSummary(report)
            HStack(spacing: 10) {
                Text("View")
                    .font(.callout.weight(.medium))
                Picker("View", selection: $selection) {
                    Text("Opportunities").tag(InsightSelection.opportunities)
                    Text("Skill health").tag(InsightSelection.skillHealth)
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .frame(width: 180, alignment: .leading)
            }
            .accessibilityLabel("Insight category")

            switch selection {
            case .opportunities:
                opportunitiesSection(report.recommendations)
            case .skillHealth:
                skillHealthSection(report)
            }

            DisclosureGroup("Scan coverage · \(report.conversationsScanned) conversations") {
                coverageSection(report.coverage).padding(.top, 10)
                if let discovery = report.marketplaceDiscovery,
                    discovery.queriesAttempted > 0 || discovery.queriesFailed > 0 || discovery.wasCancelled
                {
                    catalogDiscoverySection(discovery)
                }
            }
            .font(.callout).foregroundStyle(.secondary)
        }
    }

    private func reportSummary(_ report: InsightsReport) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text("Last scan")
                .font(.headline)
            Text(report.generatedAt, format: .relative(presentation: .named))
                .foregroundStyle(.secondary)
            Text("·")
                .foregroundStyle(.tertiary)
                .accessibilityHidden(true)
            Text(
                "\(report.conversationsScanned) \(report.conversationsScanned == 1 ? "conversation" : "conversations") reviewed"
            )
            .foregroundStyle(.secondary)
            Spacer()
            Button("Clear results") {
                isPresentingClearConfirmation = true
            }
            .buttonStyle(.link)
            .accessibilityHint("Removes the saved aggregate report after confirmation")
        }
        .font(.callout)
        .padding(.horizontal, 4)
    }

    private func coverageSection(_ coverage: [ConversationScanCoverage]) -> some View {
        InsightPanel("Scan coverage") {
            if coverage.isEmpty {
                Text("No history source reported coverage for this scan.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .padding(15)
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(coverage.enumerated()), id: \.element.id) { index, source in
                        CoverageRow(coverage: source)
                        if index < coverage.count - 1 {
                            Divider().padding(.leading, 45)
                        }
                    }
                }
            }
        }
    }

    private func opportunitiesSection(_ recommendations: [ToolRecommendation]) -> some View {
        InsightPanel("Opportunities") {
            if recommendations.isEmpty {
                ContentUnavailableView {
                    Label("No clear opportunities found", systemImage: "checkmark.circle")
                } description: {
                    Text("The scan did not find a repeated workflow or catalog match strong enough to recommend.")
                }
                .frame(maxWidth: .infinity, minHeight: 190)
            } else {
                LazyVStack(spacing: 0) {
                    ForEach(Array(recommendations.enumerated()), id: \.element.id) { index, recommendation in
                        RecommendationRow(recommendation: recommendation) {
                            open(recommendation)
                        }
                        if index < recommendations.count - 1 {
                            Divider().padding(.leading, 49)
                        }
                    }
                }
            }
        }
    }

    private func catalogDiscoverySection(_ discovery: MarketplaceDiscoverySummary) -> some View {
        InsightPanel("Catalog search") {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: catalogDiscoverySymbol(discovery))
                    .foregroundStyle(.secondary)
                    .frame(width: 22, height: 22)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 4) {
                    Text(catalogDiscoveryTitle(discovery))
                        .font(.callout.weight(.medium))
                    Text(catalogDiscoveryDetail(discovery))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
            }
            .padding(15)
            .accessibilityElement(children: .combine)
        }
    }

    private func skillHealthSection(_ report: InsightsReport) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            InsightPanel("Suggested improvements") {
                if report.qualityFindings.isEmpty {
                    ContentUnavailableView {
                        Label("No quality issues found", systemImage: "checkmark.circle")
                    } description: {
                        Text("The managed skills inspected by this scan passed the available static checks.")
                    }
                    .frame(maxWidth: .infinity, minHeight: 170)
                } else {
                    let findings = sortedFindings(report.qualityFindings)
                    LazyVStack(spacing: 0) {
                        ForEach(Array(findings.enumerated()), id: \.element.id) { index, finding in
                            QualityFindingRow(finding: finding) {
                                navigation.open(.skill(finding.skillID))
                            }
                            if index < findings.count - 1 {
                                Divider().padding(.leading, 49)
                            }
                        }
                    }
                }
            }

            InsightPanel("Observed skill use") {
                VStack(alignment: .leading, spacing: 0) {
                    Text(
                        "Counts are a lower bound based on the history sources listed in Scan coverage. “No observed use” is not the same as zero use."
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(15)

                    if report.skillUsage.isEmpty {
                        Divider()
                        Text("No installed skills were available for usage comparison.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .padding(15)
                    } else {
                        let usage = sortedUsage(report.skillUsage)
                        Divider()
                        LazyVStack(spacing: 0) {
                            ForEach(Array(usage.enumerated()), id: \.element.id) { index, metric in
                                SkillUsageRow(metric: metric) {
                                    navigation.open(.skill(metric.skillID))
                                }
                                if index < usage.count - 1 {
                                    Divider().padding(.leading, 49)
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    private func configurationLabel(_ title: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.callout.weight(.medium))
            Text(detail)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(width: 180, alignment: .leading)
    }

    private func configurationRow<Content: View>(
        _ title: String,
        detail: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        HStack(alignment: .top, spacing: 28) {
            configurationLabel(title, detail: detail)
            content()
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var canScan: Bool {
        (includeClaude || includeCodex) && !model.isScanningInsights
    }

    private var toolbarContext: String? {
        guard let report = model.visibleInsightsReport else { return nil }
        return "Updated \(report.generatedAt.formatted(.relative(presentation: .named)))"
    }

    @MainActor
    private func startScan() {
        guard canScan else { return }
        scanTask = Task { @MainActor in
            await scan()
            scanTask = nil
        }
    }

    @MainActor
    private func scan() async {
        guard canScan else { return }
        scanError = nil
        let previousReportID = model.visibleInsightsReport?.id
        var clients: Set<ClientKind> = []
        if includeClaude && model.isClientEnabled(.claude) { clients.insert(.claude) }
        if includeCodex && model.isClientEnabled(.codex) { clients.insert(.codex) }
        let options = InsightScanOptions(
            clients: clients,
            lookbackDays: lookbackDays,
            maximumConversationsPerClient: maximumConversations,
            includeMarketplaceRecommendations: includeMarketplaceRecommendations
        )
        await model.runInsightsScan(options: options)
        if model.visibleInsightsReport?.id != previousReportID {
        }
        if model.visibleInsightsReport?.id == previousReportID, let error = model.lastError {
            scanError = error
        }
    }

    @MainActor
    private func open(_ recommendation: ToolRecommendation) {
        switch recommendation.kind {
        case .createCustomSkill:
            let instruction = recommendation.draftInstruction ?? recommendation.summary
            let request = CodexSkillDraftRequest(instruction: instruction, targets: model.availableClients)
            guard model.saveCodexSkillDraftRequest(request) else { return }
            navigation.openSkillCreationRequest(request.id)
        case .useExistingSkill:
            if let skillID = recommendation.skillID {
                navigation.open(.skill(skillID))
            }
        case .marketplaceSkill, .mcpServer, .plugin:
            navigation.openMarketplaceRecommendation(recommendation, using: model)
        }
    }

    private func sortedFindings(_ findings: [SkillQualityFinding]) -> [SkillQualityFinding] {
        findings.sorted { lhs, rhs in
            let left = severityRank(lhs.severity)
            let right = severityRank(rhs.severity)
            if left != right { return left < right }
            return lhs.title.localizedCaseInsensitiveCompare(rhs.title) == .orderedAscending
        }
    }

    private func severityRank(_ severity: SkillQualitySeverity) -> Int {
        switch severity {
        case .actionRequired: 0
        case .warning: 1
        case .information: 2
        }
    }

    private func sortedUsage(_ usage: [SkillUsageMetric]) -> [SkillUsageMetric] {
        usage.sorted { lhs, rhs in
            let left = evidenceRank(lhs.evidenceLevel)
            let right = evidenceRank(rhs.evidenceLevel)
            if left != right { return left < right }
            if lhs.observedUses != rhs.observedUses { return lhs.observedUses < rhs.observedUses }
            return lhs.skillName.localizedCaseInsensitiveCompare(rhs.skillName) == .orderedAscending
        }
    }

    private func evidenceRank(_ evidence: SkillUsageEvidenceLevel) -> Int {
        switch evidence {
        case .noObservedUse: 0
        case .trackingUnavailable: 1
        case .inferred: 2
        case .exact: 3
        }
    }

    private func catalogDiscoverySymbol(_ discovery: MarketplaceDiscoverySummary) -> String {
        if discovery.wasCancelled { return "xmark.circle" }
        if discovery.queriesSucceeded == 0 { return "exclamationmark.triangle" }
        if discovery.queriesFailed > 0 { return "exclamationmark.triangle" }
        return "checkmark"
    }

    private func catalogDiscoveryTitle(_ discovery: MarketplaceDiscoverySummary) -> String {
        if discovery.wasCancelled { return "Catalog search was canceled" }
        if discovery.queriesSucceeded == 0 { return "Connected catalogs could not be searched" }
        if discovery.queriesFailed > 0 { return "Catalog search finished with limited coverage" }
        return "Connected catalogs searched"
    }

    private func catalogDiscoveryDetail(_ discovery: MarketplaceDiscoverySummary) -> String {
        let successful =
            "\(discovery.queriesSucceeded) privacy-filtered \(discovery.queriesSucceeded == 1 ? "query" : "queries") completed"
        let packages =
            "\(discovery.packagesReturned) \(discovery.packagesReturned == 1 ? "catalog result" : "catalog results") reviewed locally"
        if discovery.queriesFailed > 0 {
            return "\(successful); \(discovery.queriesFailed) failed. \(packages). No chat text or local names were sent."
        }
        return "\(successful). \(packages). No chat text or local names were sent."
    }
}

private struct InsightPanel<Content: View>: View {
    let title: String
    let content: Content

    init(_ title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title)
                .font(.subheadline.weight(.semibold))
                .padding(.horizontal, 15)
                .frame(maxWidth: .infinity, minHeight: 43, alignment: .leading)
            Divider().opacity(0.32)
            content
        }
        .standardPanel()
    }
}

private enum InsightSelection: Hashable {
    case opportunities
    case skillHealth
}

private struct CoverageRow: View {
    let coverage: ConversationScanCoverage

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            ClientDisc(client: coverage.client, size: 30)
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline, spacing: 7) {
                    Text(coverage.sourceName)
                        .font(.callout.weight(.medium))
                    Label(statusText, systemImage: statusSymbol)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text("\(coverage.conversationsScanned) chats · \(coverage.itemsInspected) items")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Text(coverage.detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if let latestItemAt = coverage.latestItemAt {
                    Text("Latest item \(latestItemAt.formatted(.relative(presentation: .named)))")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.horizontal, 15)
        .padding(.vertical, 12)
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

private struct RecommendationRow: View {
    let recommendation: ToolRecommendation
    let action: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 13) {
            KindTile(kind: recommendationKind, size: 28)

            VStack(alignment: .leading, spacing: 5) {
                Text(recommendation.title)
                    .font(.callout.weight(.semibold))
                Text(displaySummary)
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
                Text(recommendation.rationale)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Text(metadata)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 20)

            Button(actionTitle, action: action)
                .buttonStyle(.bordered)
                .controlSize(.small)
                .accessibilityHint(actionHint)
        }
        .padding(.horizontal, 15)
        .padding(.vertical, 13)
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
            recommendation.marketplacePackageID == nil ? "Browse Marketplace" : "Review in Marketplace"
        }
    }

    private var actionHint: String {
        switch recommendation.kind {
        case .useExistingSkill: "Opens the installed skill details"
        case .createCustomSkill: "Opens a reviewable Codex skill draft request"
        case .marketplaceSkill, .mcpServer, .plugin: "Opens the marketplace without installing anything"
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

private struct QualityFindingRow: View {
    let finding: SkillQualityFinding
    let openSkill: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 13) {
            Image(systemName: symbol)
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(severityColor)
                .frame(width: 24, height: 24)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(finding.title)
                    .font(.callout.weight(.semibold))
                Text(finding.detail)
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
                Text(finding.recommendedAction)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 20)
            Button("Open skill", action: openSkill)
                .buttonStyle(.bordered)
                .controlSize(.small)
                .accessibilityHint("Opens this skill for review")
        }
        .padding(.horizontal, 15)
        .padding(.vertical, 13)
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

private struct SkillUsageRow: View {
    let metric: SkillUsageMetric
    let openSkill: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 13) {
            Image(systemName: "chart.bar")
                .font(.system(size: 15, weight: .regular))
                .foregroundStyle(.secondary)
                .frame(width: 24, height: 24)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(metric.skillName)
                    .font(.callout.weight(.semibold))
                Text(metric.usageSummary)
                    .font(.callout)
                Text(evidenceDetail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 20)
            Button("Open skill", action: openSkill)
                .buttonStyle(.bordered)
                .controlSize(.small)
                .accessibilityHint("Opens this skill for review")
        }
        .padding(.horizontal, 15)
        .padding(.vertical, 13)
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
