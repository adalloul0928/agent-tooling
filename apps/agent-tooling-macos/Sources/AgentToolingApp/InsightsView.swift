import AgentToolingCore
import SwiftUI

/// What this Mac's own recent work suggests.
///
/// Everything on this screen is a reading, never a change: the scan reads chat
/// history that already exists, the report keeps counts and recommendations
/// rather than anything anybody said, and the only thing an action here can do
/// is open a screen.
struct InsightsView: View {
    let workspace: WorkspaceLaunch.Workspace
    /// The workspace's one insights session, so a scan started here is the
    /// report Home shows.
    let session: WorkspaceInsightsSession
    @Environment(AppNavigationState.self) private var navigation
    @Environment(\.availableClients) private var enabledClients
    @State private var includeClaude = true
    @State private var includeCodex = true
    @State private var includeKiro = true
    @State private var lookbackDays = 30
    @State private var maximumConversations = 25
    /// Off unless somebody turns it on: a local scan must never start reaching
    /// a network because a screen remembered a switch for them.
    @State private var includeCatalogSuggestions = false
    @State private var selection: InsightSelection = .opportunities
    @State private var isPresentingClearConfirmation = false
    @State private var showingScanOptions = false
    /// Why the last "create with Codex" could not be handed to the creator.
    /// Shown beside the report rather than as an alert, because nothing was
    /// changed and there is nothing to acknowledge.
    @State private var routeError: String?
    @State private var failedRecommendation: ToolRecommendation?

    var body: some View {
        VStack(spacing: 0) {
            PageToolbar(title: "Insights", context: toolbarContext) {
                Button("Scan options…", systemImage: "slider.horizontal.3") { showingScanOptions.toggle() }
                    .buttonStyle(.glass)
                    .popover(isPresented: $showingScanOptions) {
                        ScrollView { scanConfiguration.padding(Space.xxl) }.sheetSize(SheetSize.medium)
                    }
                if session.isScanning {
                    Button(role: .cancel) {
                        session.cancelScan()
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
                    .buttonStyle(.glass)
                    .disabled(!canScan)
                    .accessibilityHint("Reads selected local chat history and saves only aggregate findings")
                    Button {
                        startScan(deepDive: true)
                    } label: {
                        Label(deepDiveButtonTitle, systemImage: "sparkles")
                    }
                    .primaryActionStyle()
                    .disabled(!canScan || deepDiveClient == nil || session.isDeepDiving)
                    .keyboardShortcut(.return, modifiers: [.command])
                    .help(deepDiveHelp)
                    .accessibilityHint(deepDiveHelp)
                }
            }
            Hairline()

            // With nothing to show yet the empty state takes the pane rather
            // than sitting at the top of a page that is otherwise blank.
            if session.report == nil, !session.isScanning, session.errorMessage == nil, routeError == nil {
                firstRunState
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: WorkspaceLayout.sectionSpacing) {
                        if session.isScanning {
                            scanningState
                        } else if let message = session.errorMessage {
                            errorState(message)
                        }
                        if let message = routeError {
                            InsightPanel("The skill creator could not open") {
                                VStack(alignment: .leading, spacing: Space.sm) {
                                    Text(message).font(AgentFont.body).textSelection(.enabled).wrapsLines()
                                    Button("Try again") {
                                        if let failedRecommendation { draftWithAssistant(failedRecommendation) }
                                    }
                                    .inlineActionStyle()
                                }.padding(Space.xl)
                            }
                        }

                        if let report = session.report {
                            reportContent(report)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, WorkspaceLayout.pageInset)
                    .padding(.top, WorkspaceLayout.contentTopInset)
                    .padding(.bottom, WorkspaceLayout.pageInset)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .confirmationDialog(
            "Clear saved insights?",
            isPresented: $isPresentingClearConfirmation,
            titleVisibility: .visible
        ) {
            Button("Clear saved insights", role: .destructive) { session.clear() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This removes the saved aggregate report. Client chat history will not be changed.")
        }
    }

    // MARK: - Scan options

    private var scanConfiguration: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Scan recent work")
                .font(AgentFont.heading)
                .padding(.horizontal, Space.xl)
                // The strip and the hairline under it make one header height.
                .frame(minHeight: Size.headerHeight - Hairline.width, alignment: .leading)
            Hairline()

            VStack(alignment: .leading, spacing: 0) {
                VStack(alignment: .leading, spacing: Space.xs) {
                    Text("Look for repeated work, underused skills, and tools that may help next time.")
                        .font(AgentFont.body)
                    Text(AssistantRunCopy.transientNote)
                        .font(AgentFont.caption)
                        .foregroundStyle(.secondary)
                        .wrapsLines()
                }
                .padding(Space.xl)

                Hairline()

                VStack(spacing: Space.xl) {
                    configurationRow("Sources", detail: "Local history only") {
                        VStack(alignment: .leading, spacing: Space.md) {
                            if workspace.device.isEnabled(.claude) {
                                Toggle(isOn: $includeClaude) {
                                    HStack(spacing: Space.md) {
                                        ClientBrandIcon(client: .claude, size: Size.brandMark)
                                        Text("Claude Code")
                                    }
                                }
                            }
                            if workspace.device.isEnabled(.codex) {
                                Toggle(isOn: $includeCodex) {
                                    HStack(spacing: Space.md) {
                                        ClientBrandIcon(client: .codex, size: Size.brandMark)
                                        Text("Codex")
                                    }
                                }
                            }
                            if workspace.device.isEnabled(.kiro) {
                                Toggle(isOn: $includeKiro) {
                                    HStack(spacing: Space.md) {
                                        ClientBrandIcon(client: .kiro, size: Size.brandMark)
                                        Text("Kiro CLI")
                                    }
                                }
                            }
                        }
                        .toggleStyle(.checkbox)
                    }

                    Hairline()

                    configurationRow("Review period", detail: "How far back to inspect") {
                        WorkspaceSegmentedPicker("Review period", selection: $lookbackDays) {
                            Text("7 days").tag(7)
                            Text("30 days").tag(30)
                            Text("90 days").tag(90)
                        }
                        .labelsHidden()
                        .frame(maxWidth: Size.segmentedPickerMax)
                        .accessibilityLabel("Review period")
                    }

                    Hairline()

                    configurationRow("Conversation limit", detail: "Per selected source") {
                        // The row's title names the noun, so each segment is the
                        // count alone: three "N conversations" do not fit the
                        // picker, and "chats" would be a second name for them.
                        WorkspaceSegmentedPicker("Conversation limit", selection: $maximumConversations) {
                            Text("10").tag(10)
                            Text("25").tag(25)
                            Text("50").tag(50)
                        }
                        .labelsHidden()
                        .frame(maxWidth: Size.segmentedPickerMax)
                        .accessibilityLabel("Maximum conversations per source")
                    }

                    Hairline()

                    configurationRow("Catalog suggestions", detail: "Optional network access") {
                        VStack(alignment: .leading, spacing: Space.xs) {
                            Toggle(
                                "Include established plugins, skills, and connections from connected catalogs",
                                isOn: $includeCatalogSuggestions
                            )
                            .toggleStyle(.checkbox)
                            .disabled(!session.canReachCatalog)
                            .wrapsLines()
                            // Offering a switch that reaches nothing would be a
                            // claim this build cannot keep, so it stays off
                            // until a catalog exists to ask.
                            Text(
                                session.canReachCatalog
                                    ? "Leave this off to keep the scan entirely local. Turning it on sends up to four search terms to the catalogs Discover lists — chosen from a fixed vocabulary this app ships, never words taken from your conversations."
                                    : "This Mac has no catalog to ask, so a scan answers from local history alone."
                            )
                            .font(AgentFont.caption)
                            .foregroundStyle(.secondary)
                            .wrapsLines()
                        }
                    }
                }
                .padding(Space.xl)

                if let warning = sourceWarning {
                    Hairline()
                    Label(warning, systemImage: "exclamationmark.triangle")
                        .font(AgentFont.caption)
                        .foregroundStyle(.secondary)
                        .padding(Space.xl)
                        .accessibilityLabel("A conversation source is required")
                }
            }
        }
        .standardPanel()
    }

    // MARK: - States

    private var scanningState: some View {
        HStack(spacing: Space.lg) {
            ProgressView()
                .controlSize(.small)
            VStack(alignment: .leading, spacing: Space.xxs) {
                Text(Self.scanningTitle)
                    .font(AgentFont.bodyMedium)
                Text(Self.scanningDetail)
                    .font(AgentFont.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, Space.xs)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Self.scanningAccessibilityLabel)
    }

    /// What the scanning state says. VoiceOver hears the same two lines, so a
    /// scan is not "reviewing" on screen and "scanning" out loud.
    nonisolated static let scanningTitle = "Reviewing recent work"
    nonisolated static let scanningDetail = "The scan is read-only. No skill, plugin, or connection will be installed."
    nonisolated static var scanningAccessibilityLabel: String { "\(scanningTitle). \(scanningDetail)" }

    private var firstRunState: some View {
        EmptyStateView(
            symbol: "doc.text.magnifyingglass",
            title: "No insights yet",
            message:
                "Find repeated work and useful tools in your recent conversations. Choose your sources and review period in Scan options."
        )
    }

    private func errorState(_ message: String) -> some View {
        InsightPanel("The scan could not finish") {
            HStack(alignment: .top, spacing: Space.lg) {
                Image(systemName: "exclamationmark.triangle")
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: Space.xs) {
                    Text(message)
                        .font(AgentFont.body)
                        .textSelection(.enabled)
                    Button("Try again") {
                        startScan()
                    }
                    .inlineActionStyle()
                    .disabled(!canScan)
                }
                Spacer()
            }
            .padding(Space.xl)
        }
    }

    // MARK: - Report

    private func reportContent(_ report: InsightsReport) -> some View {
        VStack(alignment: .leading, spacing: WorkspaceLayout.sectionSpacing) {
            reportSummary(report)
            HStack(spacing: Space.lg) {
                WorkspaceSegmentedPicker("Insight category", selection: $selection) {
                    Text("Worth adding").tag(InsightSelection.opportunities)
                    Text("Skill health").tag(InsightSelection.skillHealth)
                }
                .fixedSize()
            }
            .accessibilityLabel("Insight category")

            switch selection {
            case .opportunities:
                deepDiveSection(report)
                opportunitiesSection(ToolRecommendation.distinct(report.recommendations))
            case .skillHealth:
                skillHealthSection(report)
            }

            DisclosureGroup("Scan coverage · \(InsightCount.conversation.phrase(report.conversationsScanned))") {
                coverageSection(report.coverage).padding(.top, Space.lg)
                if let discovery = report.marketplaceDiscovery,
                    discovery.queriesAttempted > 0 || discovery.queriesFailed > 0 || discovery.wasCancelled
                {
                    catalogDiscoverySection(discovery)
                }
            }
            .font(AgentFont.body).foregroundStyle(.secondary)
        }
    }

    private func reportSummary(_ report: InsightsReport) -> some View {
        HStack(alignment: .center, spacing: 0) {
            summaryStat(
                report.conversationsScanned, "Conversations scanned", tint: .primary)
            Hairline(.vertical).frame(height: Size.compactRowHeight).padding(.horizontal, Space.xs)
            summaryStat(
                ToolRecommendation.distinct(report.recommendations).count, "Worth adding",
                tint: report.recommendations.isEmpty ? .secondary : AgentTheme.selection)
            Hairline(.vertical).frame(height: Size.compactRowHeight).padding(.horizontal, Space.xs)
            summaryStat(
                report.qualityFindings.count, "Skill findings",
                tint: report.qualityFindings.isEmpty ? .secondary : AgentTheme.warning)
            Spacer(minLength: Space.xl)
            VStack(alignment: .trailing, spacing: Space.xs) {
                Text("Last scan \(report.generatedAt, format: .relative(presentation: .named))")
                    .font(AgentFont.body)
                    .foregroundStyle(.secondary)
                Button("Clear results…") {
                    isPresentingClearConfirmation = true
                }
                .inlineActionStyle()
                .font(AgentFont.body)
                .accessibilityHint("Removes the saved aggregate report after confirmation")
            }
            .padding(.trailing, Space.xl)
        }
        .padding(.vertical, Space.lg)
        .standardPanel()
    }

    private func summaryStat(_ count: Int, _ label: String, tint: Color) -> some View {
        VStack(alignment: .leading, spacing: Space.xxs) {
            Text(count, format: .number)
                .font(AgentFont.stat)
                .foregroundStyle(tint)
            Text(label)
                .font(AgentFont.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, Space.xl)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(label): \(count)")
    }

    private func coverageSection(_ coverage: [ConversationScanCoverage]) -> some View {
        InsightPanel("Scan coverage") {
            if coverage.isEmpty {
                Text("No history source reported coverage for this scan.")
                    .font(AgentFont.body)
                    .foregroundStyle(.secondary)
                    .padding(Space.xl)
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(coverage.enumerated()), id: \.element.id) { index, source in
                        CoverageRow(coverage: source)
                        if index < coverage.count - 1 {
                            Hairline()
                        }
                    }
                }
            }
        }
    }

    /// What the person's own assistant concluded, above the keyword pass. It
    /// is the slow, considered read; the keyword rows below are the instant one.
    @ViewBuilder private func deepDiveSection(_ report: InsightsReport) -> some View {
        if session.isDeepDiving {
            InsightPanel("Deep dive") {
                HStack(spacing: Space.lg) {
                    ProgressView().controlSize(.small)
                    VStack(alignment: .leading, spacing: Space.xxs) {
                        Text("\(deepDiveClient?.rawValue ?? "Your assistant") is reading your recent conversations…")
                            .font(AgentFont.bodyMedium)
                        Text(
                            "This takes a few minutes. The findings below are the instant keyword pass; the considered read replaces them here when it lands."
                        )
                        .font(AgentFont.caption).foregroundStyle(.secondary).wrapsLines()
                    }
                    Spacer()
                }
                .padding(Space.xl)
            }
        } else if let message = session.deepDiveMessage {
            InsightPanel("Deep dive") {
                HStack(alignment: .top, spacing: Space.lg) {
                    Image(systemName: "exclamationmark.triangle").foregroundStyle(AgentTheme.warning)
                    Text(message).font(AgentFont.body).wrapsLines()
                    Spacer()
                }
                .padding(Space.xl)
            }
        } else if let dive = report.deepDive {
            InsightPanel("Deep dive — what \(dive.client.rawValue) sees in your recent work") {
                VStack(alignment: .leading, spacing: 0) {
                    VStack(alignment: .leading, spacing: Space.sm) {
                        Text(dive.summary).font(AgentFont.body).wrapsLines()
                        Text(
                            "\(InsightCount.conversation.phrase(dive.conversationsConsidered)) read · "
                                + dive.generatedAt.formatted(.relative(presentation: .named))
                        )
                        .font(AgentFont.micro).foregroundStyle(.secondary)
                    }
                    .padding(Space.xl)
                    if !dive.themes.isEmpty {
                        Hairline()
                        ForEach(Array(dive.themes.enumerated()), id: \.element.id) { index, theme in
                            HStack(alignment: .top, spacing: Space.lg) {
                                Image(systemName: "repeat").foregroundStyle(.secondary).frame(width: Size.tile)
                                VStack(alignment: .leading, spacing: Space.xs) {
                                    Text(theme.title).font(AgentFont.bodySemibold)
                                    Text(theme.detail).font(AgentFont.caption).foregroundStyle(.secondary)
                                        .wrapsLines()
                                    Text(themeMetadata(theme)).font(AgentFont.micro).foregroundStyle(.secondary)
                                }
                                Spacer()
                            }
                            .padding(.horizontal, Space.xl).padding(.vertical, Space.lg)
                            if index < dive.themes.count - 1 { Hairline(indent: Hairline.afterLeading(Size.tile)) }
                        }
                    }
                    if !dive.recommendations.isEmpty {
                        Hairline()
                        ForEach(Array(dive.recommendations.enumerated()), id: \.element.id) { index, recommendation in
                            RecommendationRow(recommendation: recommendation, assistant: draftingClient) { open(recommendation) }
                            if index < dive.recommendations.count - 1 { Hairline(indent: Hairline.afterLeading(Size.tile)) }
                        }
                    }
                }
            }
        }
    }

    private func themeMetadata(_ theme: DeepDiveTheme) -> String {
        var parts = ["Seen in \(InsightCount.conversation.phrase(theme.conversationCount))"]
        if !theme.clients.isEmpty { parts.append(theme.clients.map(\.rawValue).joined(separator: ", ")) }
        return parts.joined(separator: " · ")
    }

    private func opportunitiesSection(_ recommendations: [ToolRecommendation]) -> some View {
        InsightPanel("Worth adding — keyword pass") {
            if recommendations.isEmpty {
                EmptyStateView(
                    symbol: "checkmark.circle",
                    title: "Nothing worth adding right now",
                    message: "The scan did not find a repeated workflow or catalog match strong enough to recommend."
                )
                .frame(maxWidth: .infinity, minHeight: Size.emptyStatePanelHeight)
            } else {
                LazyVStack(spacing: 0) {
                    ForEach(Array(recommendations.enumerated()), id: \.element.id) { index, recommendation in
                        RecommendationRow(recommendation: recommendation, assistant: draftingClient) {
                            open(recommendation)
                        }
                        if index < recommendations.count - 1 {
                            Hairline(indent: Hairline.afterLeading(Size.tile))
                        }
                    }
                }
            }
        }
    }

    private func catalogDiscoverySection(_ discovery: MarketplaceDiscoverySummary) -> some View {
        InsightPanel("Catalog search") {
            HStack(alignment: .top, spacing: Space.lg) {
                Image(systemName: catalogDiscoverySymbol(discovery))
                    .foregroundStyle(.secondary)
                    .frame(width: Size.tileSmall, height: Size.tileSmall)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: Space.xs) {
                    Text(catalogDiscoveryTitle(discovery))
                        .font(AgentFont.bodyMedium)
                    Text(catalogDiscoveryDetail(discovery))
                        .font(AgentFont.caption)
                        .foregroundStyle(.secondary)
                        .wrapsLines()
                }
                Spacer()
            }
            .padding(Space.xl)
            .accessibilityElement(children: .combine)
        }
    }

    private func skillHealthSection(_ report: InsightsReport) -> some View {
        VStack(alignment: .leading, spacing: WorkspaceLayout.sectionSpacing) {
            InsightPanel("Suggested improvements") {
                if report.qualityFindings.isEmpty {
                    EmptyStateView(
                        symbol: "checkmark.circle",
                        title: "No quality issues found",
                        message: "The managed skills inspected by this scan passed the available static checks."
                    )
                    .frame(maxWidth: .infinity, minHeight: Size.emptyStatePanelHeight)
                } else {
                    let findings = sortedFindings(report.qualityFindings)
                    LazyVStack(spacing: 0) {
                        ForEach(Array(findings.enumerated()), id: \.element.id) { index, finding in
                            QualityFindingRow(finding: finding) {
                                navigation.open(.skill(finding.skillID))
                            }
                            if index < findings.count - 1 {
                                Hairline(indent: Hairline.afterLeading(Size.tile))
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
                    .font(AgentFont.caption)
                    .foregroundStyle(.secondary)
                    .wrapsLines()
                    .padding(Space.xl)

                    if report.skillUsage.isEmpty {
                        Hairline()
                        Text("No installed skills were available for usage comparison.")
                            .font(AgentFont.body)
                            .foregroundStyle(.secondary)
                            .padding(Space.xl)
                    } else {
                        let usage = sortedUsage(report.skillUsage)
                        Hairline()
                        LazyVStack(spacing: 0) {
                            ForEach(Array(usage.enumerated()), id: \.element.id) { index, metric in
                                SkillUsageRow(metric: metric) {
                                    navigation.open(.skill(metric.skillID))
                                }
                                if index < usage.count - 1 {
                                    Hairline(indent: Hairline.afterLeading(Size.tile))
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    // MARK: - Option rows

    private func configurationLabel(_ title: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: Space.xxs) {
            Text(title)
                .font(AgentFont.bodyMedium)
            Text(detail)
                .font(AgentFont.caption)
                .foregroundStyle(.secondary)
        }
        .frame(width: Size.optionLabelColumn, alignment: .leading)
    }

    private func configurationRow(
        _ title: String,
        detail: String,
        @ViewBuilder content: () -> some View
    ) -> some View {
        HStack(alignment: .top, spacing: Space.huge) {
            configurationLabel(title, detail: detail)
            content()
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: - Scanning

    /// The apps this Mac manages, of the two whose history can be read at all.
    private var scannableClients: Set<ClientKind> {
        var clients: Set<ClientKind> = []
        if includeClaude, workspace.device.isEnabled(.claude) { clients.insert(.claude) }
        if includeCodex, workspace.device.isEnabled(.codex) { clients.insert(.codex) }
        if includeKiro, workspace.device.isEnabled(.kiro) { clients.insert(.kiro) }
        return clients
    }

    private var canScan: Bool {
        !scannableClients.isEmpty && !session.isScanning
    }

    /// The assistant that reads the digests: Claude Code when this Mac manages
    /// it, else Codex. Kiro has no print mode this app drives, so it is a
    /// source but never the reader.
    private var deepDiveClient: ClientKind? {
        WorkspaceInsightsSession.deepDiveClient(managed: workspace.device.managedClients)
    }

    private var deepDiveButtonTitle: String {
        deepDiveClient.map { "Deep dive with \($0.rawValue)" } ?? "Deep dive"
    }

    /// What the deep dive does, and that it runs on its own only while this
    /// Mac allows the daily one.
    private var deepDiveHelp: String {
        guard let client = deepDiveClient else { return AssistantRunCopy.noDeepDiveAssistant }
        return AssistantRunCopy.deepDiveHelp(
            reviewer: client, runsDaily: workspace.device.effectiveAssistantRuns.dailyDeepDive)
    }

    /// Why there is nothing to scan, when there is nothing to scan. An app this
    /// Mac is not managing is a different reason from one that is switched off
    /// here, and saying the wrong one sends someone to the wrong screen.
    private var sourceWarning: String? {
        guard scannableClients.isEmpty else { return nil }
        let managed = [ClientKind.claude, .codex, .kiro].contains { workspace.device.isEnabled($0) }
        return managed
            ? "Select at least one app to scan."
            : "This Mac is not managing Claude Code, Codex, or Kiro CLI, so there is no local chat history to review."
    }

    private var toolbarContext: String? {
        guard let report = session.report else { return nil }
        return "Updated \(report.generatedAt.formatted(.relative(presentation: .named)))"
    }

    private func startScan(deepDive: Bool = false) {
        guard canScan else { return }
        let options = InsightScanOptions(
            clients: scannableClients,
            lookbackDays: lookbackDays,
            maximumConversationsPerClient: maximumConversations,
            includeMarketplaceRecommendations: includeCatalogSuggestions && session.canReachCatalog
        )
        let reader = deepDive ? deepDiveClient : nil
        Task { await session.scan(options: options, deepDiveWith: reader) }
    }

    /// The assistant a recommendation to create a skill is drafted with: Claude
    /// Code when this Mac manages it, else Codex. The request names it, and the
    /// creator opens on it, so the row's button names it too.
    private var draftingClient: ClientKind {
        [ClientKind.claude, .codex].first(where: enabledClients.contains) ?? .codex
    }

    /// A recommendation opens a screen. Nothing here installs, nothing here
    /// writes to a client, and asking for a skill only hands the creator an
    /// instruction to draft — the draft is reviewed before it is saved.
    private func open(_ recommendation: ToolRecommendation) {
        switch recommendation.kind {
        case .createCustomSkill:
            draftWithAssistant(recommendation)
        case .useExistingSkill:
            if let skillID = recommendation.skillID {
                navigation.open(.skill(skillID))
            }
        case .marketplaceSkill, .mcpServer, .plugin:
            if let packageID = recommendation.marketplacePackageID {
                navigation.openMarketplacePackage(packageID)
            } else {
                navigation.open(.section(.marketplace))
            }
        }
    }

    /// Writes down what this recommendation would ask an assistant for and
    /// opens the creator on it. Nothing is generated here and nothing is
    /// saved: the creator shows every generated file before anything reaches
    /// the library. The assistant is the first managed one that has a skill
    /// creator; the creator lets the person switch before the first turn.
    private func draftWithAssistant(_ recommendation: ToolRecommendation) {
        let instruction = recommendation.draftInstruction ?? recommendation.summary
        guard !instruction.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        routeError = nil
        failedRecommendation = recommendation
        let client = draftingClient
        let request = SkillDraftRequest(
            client: client,
            instruction: instruction,
            targets: enabledClients.isEmpty ? [client] : enabledClients)
        let store = workspace.store
        Task {
            guard await WorkspaceSkillDraftSeed.save(request, in: store) else {
                routeError = "This Mac could not record what to ask \(client.rawValue) for. Nothing was changed."
                return
            }
            failedRecommendation = nil
            navigation.openSkillCreationRequest(request.id)
        }
    }

    // MARK: - Ordering

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
            "\(discovery.queriesSucceeded) privacy-filtered \(InsightCount.query.word(for: discovery.queriesSucceeded)) completed"
        let packages = "\(InsightCount.catalogResult.phrase(discovery.packagesReturned)) reviewed locally"
        if discovery.queriesFailed > 0 {
            return "\(successful); \(discovery.queriesFailed) failed. \(packages). No chat text or local names were sent."
        }
        return "\(successful). \(packages). No chat text or local names were sent."
    }
}
