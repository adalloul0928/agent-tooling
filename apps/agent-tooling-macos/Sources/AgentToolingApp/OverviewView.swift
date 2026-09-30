import AgentToolingCore
import SwiftUI

private struct LibraryDestinationStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.hoverSuppressed) private var suppressed
    @State private var hovering = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color.primary.opacity(configuration.isPressed ? 0.08 : hovering && !suppressed ? 0.035 : 0))
            }
            .onHover { hovering = $0 }
            .animation(reduceMotion ? nil : AgentMotion.quick, value: hovering)
            .animation(reduceMotion ? nil : AgentMotion.quick, value: configuration.isPressed)
    }
}

/// Home: what this Mac has, what needs a look, and the one path between them.
///
/// Every number on this screen was produced by another screen. Home reads the
/// library, the report Insights kept, the catalog Discover last reached, the
/// review queue and the last check of this Mac's apps, and it composes them —
/// it does not go and get any of them itself, and it never states a verdict a
/// screen behind it would not state.
///
/// Two things that look like claims here are not. A recommendation is a stored
/// Insights finding, never a personal suggestion Home made up. An update is a
/// catalog's own word about the package a row came from, and before any catalog
/// has been asked this screen says nothing about updates at all.
///
/// Nothing on this screen writes to an app. The two actions it offers are a
/// read-only check and preparing a plan somebody still has to approve.
struct OverviewView: View {
    let workspace: WorkspaceLaunch.Workspace
    /// What the catalogs published, so a plugin row can be compared with the
    /// package it came from.
    let catalog: WorkspaceMarketplaceSession
    /// The report Insights kept. Home never starts a scan.
    let insights: WorkspaceInsightsSession
    /// What a local integration asked for and nobody has decided yet.
    let requests: WorkspaceRequestSession

    @Environment(AppNavigationState.self) private var navigation
    @Environment(\.workspaceNavigate) private var navigate
    @Environment(\.availableClients) private var enabledClients
    @AppStorage("onboarding.skipped.v2") private var onboardingSkipped = false

    /// The last few applied plans this Mac recorded, read once off the body. See
    /// `recentChangesCard`.
    @State private var recentReceipts: [OperationReceipt] = []

    var body: some View {
        let attention = attentionItems
        let updates = updateItems
        return VStack(spacing: 0) {
            PageToolbar(title: "Home", context: lastScanText) {
                Button {
                    Task { await workspace.device.refresh() }
                } label: {
                    Image(systemName: "arrow.clockwise").frame(width: 16, height: 16)
                }
                .buttonStyle(.glass)
                .disabled(workspace.device.isChecking)
                .help("Re-scan local client commands, configurations, and installed tooling on this Mac")
                .accessibilityLabel("Refresh local checks")

                Button {
                    reviewChanges()
                } label: {
                    Label(
                        workspace.deployment.isBusy ? "Preparing…" : "Review changes",
                        systemImage: "arrow.triangle.2.circlepath")
                }
                .buttonStyle(.glass)
                .disabled(workspace.deployment.isBusy)
                .help("Work out what would change in your apps. Nothing is written until you approve it.")
            }

            GeometryReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        if showsOnboarding { onboardingCard }
                        // Two columns where they fit; one column where they don't.
                        // A narrow window stacks the same cards instead of
                        // squeezing them past legibility.
                        ViewThatFits(in: .horizontal) {
                            HStack(alignment: .top, spacing: 16) {
                                reviewColumn(attention: attention, updates: updates)
                                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                                    .frame(minWidth: 420)
                                statusColumn
                                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                                    .frame(minWidth: 420)
                            }
                            VStack(spacing: 16) {
                                reviewColumn(attention: attention, updates: updates)
                                statusColumn
                            }
                            .frame(maxHeight: .infinity, alignment: .top)
                        }
                        // The dashboard fills the window rather than floating in
                        // its top third: the columns take all the height the
                        // page has, so no blank band is left under the cards at
                        // the default window size.
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                    }
                    .padding(.horizontal, WorkspaceLayout.pageInset)
                    .padding(.top, WorkspaceLayout.contentTopInset)
                    .padding(.bottom, WorkspaceLayout.pageInset)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    // Give the content at least the viewport's height so the
                    // columns have a full page to expand into, while a taller
                    // stacked layout can still scroll past it.
                    .frame(minHeight: proxy.size.height, alignment: .top)
                }
                .font(.system(size: 15))
                .scrollIndicators(.hidden)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // No ground of its own: the shell paints the shared translucent canvas
        // behind every section, so Home doubling it would only dim the glass.
    }

    // MARK: - Getting started

    /// The same rule the Library uses to decide whether to stand its own
    /// getting-started screen in front of itself: a workspace that holds things
    /// but has never been asked to put any of them anywhere. Home only points at
    /// it, so there is one place to get started rather than two.
    private var showsOnboarding: Bool {
        guard !onboardingSkipped, workspace.library.access == .writable, let library = libraryModel else {
            return false
        }
        return !library.rows.isEmpty && library.rows.allSatisfy { $0.requestedAssignments.isEmpty }
    }

    /// The left column of the wide layout, and the top of the stacked one.
    private func reviewColumn(
        attention: [OverviewAttention],
        updates: [(row: WorkspaceLibraryReadModelRow, availability: UpdateAvailability)]
    ) -> some View {
        VStack(spacing: 16) {
            reviewQueueCard(items: attention, updates: updates)
            // The recommendation card takes the slack at the bottom of the
            // column, so the page fills its height instead of leaving a band
            // of empty canvas under a short queue.
            recommendedCard
                .frame(maxHeight: .infinity, alignment: .top)
        }
    }

    /// The right column of the wide layout, and the bottom of the stacked one.
    private var statusColumn: some View {
        VStack(spacing: 16) {
            setupCard
            libraryCard
            appsCard
            HStack(alignment: .top, spacing: 16) {
                readyMiniCard
                recentChangesCard
            }
            .frame(maxHeight: .infinity, alignment: .top)
        }
    }

    private var onboardingCard: some View {
        HStack(spacing: 16) {
            Image(systemName: "tray.and.arrow.down")
                .font(.system(size: 25, weight: .regular))
                .foregroundStyle(.secondary)
                .frame(width: 36)
            VStack(alignment: .leading, spacing: 5) {
                Text("Bring your existing setup into Agent Tooling")
                    .font(.system(size: 17, weight: .semibold))
                Text("Choose the skills, plugins, and MCP servers you want to manage or track.")
                    .font(.system(size: 14)).foregroundStyle(.secondary)
            }
            Spacer(minLength: 16)
            Button("Set up your library") { navigate(.skills) }
                .buttonStyle(.borderedProminent).controlSize(.large)
                .disabled(workspace.library.isBusy)
        }
        .padding(20)
        .standardPanel()
    }

    // MARK: - Recommended for you

    private var recommendedCard: some View {
        BentoCard(
            symbol: "sparkles", title: "Recommended",
            action: recommendations.isEmpty ? nil : ("All suggestions", { navigate(.insights) }),
            fillsHeight: true
        ) {
            if recommendations.isEmpty {
                VStack(alignment: .leading, spacing: 14) {
                    Text("Explore what your apps can do")
                        .font(.system(size: 16, weight: .semibold))
                    Text("Browse skills, plugins, and connections, or review recent work in Insights.")
                        .font(.system(size: 14))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: 10) {
                        Button("Browse Discover") { navigate(.marketplace) }
                            .buttonStyle(.borderedProminent)
                        Button("Open Insights") { navigate(.insights) }
                            .buttonStyle(.glass)
                    }
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                VStack(spacing: 0) {
                    ForEach(recommendations) { recommendation in
                        recommendationRow(recommendation)
                        if recommendation.id != recommendations.last?.id {
                            Divider().padding(.leading, 60)
                        }
                    }
                }
            }
        }
    }

    private func recommendationRow(_ recommendation: ToolRecommendation) -> some View {
        Button {
            open(recommendation)
        } label: {
            HStack(alignment: .center, spacing: 12) {
                ToolIdentityIcon(
                    packageID: recommendationPackageID(recommendation) ?? "",
                    fallback: recommendationKind(recommendation), size: 32)
                VStack(alignment: .leading, spacing: 3) {
                    Text(recommendationTitle(recommendation))
                        .font(.system(size: 14.5, weight: .semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    Text(recommendationSummary(recommendation))
                        .font(.system(size: 13.5))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                Text(recommendationAction(recommendation))
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(AgentTheme.blue)
                    .lineLimit(1)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 11)
            .contentShape(Rectangle())
        }
        .buttonStyle(LibraryDestinationStyle())
        .accessibilityHint(recommendationAction(recommendation))
    }

    // MARK: - Your library

    private var libraryCard: some View {
        BentoCard(
            symbol: "books.vertical",
            title: libraryModel.map { "Library · \($0.toolCount)" } ?? "Library",
            action: ("Open", { navigate(.skills) })
        ) {
            HStack(alignment: .top, spacing: 8) {
                libraryKindCell("Skills", count: inventory?.skills.count ?? 0, kind: .skill, section: .skills)
                libraryKindCell("Plugins", count: inventory?.plugins.count ?? 0, kind: .plugin, section: .plugins)
                libraryKindCell("Servers", count: inventory?.mcpServers.count ?? 0, kind: .mcpServer, section: .mcpServers)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 16)
        }
    }

    private func libraryKindCell(_ title: String, count: Int, kind: ToolingKind, section: AppSection) -> some View {
        Button {
            navigate(section)
        } label: {
            VStack(spacing: 8) {
                KindTile(kind: kind, size: 40)
                Text(count, format: .number)
                    .font(.system(size: 19, weight: .bold)).monospacedDigit()
                Text(title)
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 6)
            .contentShape(RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(LibraryDestinationStyle())
        .accessibilityLabel("Open \(title), \(count) items")
    }

    // MARK: - Mini cards

    /// Whether a prepared plan has any step still outstanding. When it does
    /// not, there is nothing to review, and offering the button anyway would
    /// send a person to an empty review.
    private var hasChangesWaiting: Bool {
        !(workspace.deployment.plan?.items.isEmpty ?? true)
    }

    /// The steps a prepared plan is holding. A plan that has been applied has
    /// already re-read itself, so what shows here is what is still outstanding.
    private var readyMiniCard: some View {
        BentoCard(symbol: "arrow.down.circle", title: "Ready to install", fillsHeight: true) {
            VStack(alignment: .leading, spacing: 6) {
                Text(workspace.deployment.plan?.items.count ?? 0, format: .number)
                    .font(.system(size: 30, weight: .bold)).monospacedDigit()
                    .foregroundStyle(
                        (workspace.deployment.plan?.items.isEmpty ?? true) ? Color.secondary : AgentTheme.blue)
                HStack(spacing: 8) {
                    Text((workspace.deployment.plan?.items.count ?? 0) == 1 ? "change waiting" : "changes waiting")
                        .font(.system(size: 12.5))
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 4)
                    Button(workspace.deployment.isBusy ? "Preparing…" : "Review…") { reviewChanges() }
                        .buttonStyle(.glass)
                        .controlSize(.small)
                        .disabled(workspace.deployment.isBusy || !hasChangesWaiting)
                        .help(
                            hasChangesWaiting
                                ? "Review the changes this plan is holding."
                                : "There is nothing waiting to review. Assign a tool first, then prepare a plan.")
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 14)
            .padding(.top, 2)
        }
    }

    /// The last few things this Mac actually changed, read from the store's own
    /// receipts. This is history, not a claim: each row is what one applied plan
    /// recorded doing, worded the way the Activity screen words it.
    private var recentChangesCard: some View {
        BentoCard(
            symbol: "clock.arrow.circlepath", title: "Recent changes",
            action: ("Open Activity", { navigate(.activity) }), fillsHeight: true
        ) {
            VStack(alignment: .leading, spacing: 0) {
                if recentReceipts.isEmpty {
                    Text("Nothing has been changed yet.")
                        .font(.system(size: 13.5))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 16)
                        .padding(.bottom, 14)
                        .padding(.top, 2)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    ForEach(recentReceipts) { receipt in
                        HStack(alignment: .center, spacing: 10) {
                            StatusGlyph(state: receipt.state, size: 14)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(receipt.title)
                                    .font(.system(size: 13.5, weight: .medium))
                                    .lineLimit(1)
                                Text(receipt.outcomeTally)
                                    .font(.system(size: 12))
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            Text(SnapshotTime.compact(receipt.createdAt))
                                .font(.system(size: 12))
                                .foregroundStyle(.secondary)
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 9)
                        if receipt.id != recentReceipts.last?.id {
                            Divider().padding(.leading, 42)
                        }
                    }
                }
            }
        }
        // Reading the store is I/O, so it happens off the body: a receipt is a
        // record of something already done, and re-reading it on every layout
        // pass would put a file read in the render path for no gain.
        .task { await loadRecentReceipts() }
    }

    /// Reads the last three receipts the store kept. The store read is
    /// synchronous and throwing; a failure here only means the card stays
    /// empty, which reads the same as a Mac that has changed nothing yet.
    private func loadRecentReceipts() async {
        recentReceipts = (try? workspace.store.operationReceipts(limit: 3)) ?? []
    }

    // MARK: - Waiting for your review

    private func reviewQueueCard(
        items attentionItems: [OverviewAttention],
        updates updateItems: [(row: WorkspaceLibraryReadModelRow, availability: UpdateAvailability)]
    ) -> some View {
        BentoCard(
            symbol: "eye", title: "Waiting for your review",
            action: ("Open queue", { navigate(.syncCenter) })
        ) {
            VStack(spacing: 0) {
                if attentionItems.isEmpty && updateItems.isEmpty {
                    Text("Nothing is waiting on you.")
                        .font(.system(size: 14))
                        .foregroundStyle(.secondary)
                        .padding(16)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    ForEach(attentionItems) { item in
                        HStack(alignment: .center, spacing: 12) {
                            StatusGlyph(state: item.state, size: 17)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(item.title).font(.system(size: 14.5, weight: .semibold)).lineLimit(1)
                                Text(item.detail).font(.system(size: 13.5)).foregroundStyle(.secondary).lineLimit(1)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            Button("Review") { navigate(item.destination) }
                                .buttonStyle(.glass).controlSize(.small)
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 11)
                        if item.id != attentionItems.last?.id || !updateItems.isEmpty {
                            Divider().padding(.leading, 47)
                        }
                    }
                    ForEach(updateItems, id: \.row.artifactID) { item in
                        HStack(alignment: .center, spacing: 12) {
                            ToolIdentityIcon(
                                packageID: item.row.nativeRoutes.first?.externalPluginID ?? "",
                                fallback: .plugin, size: 30)
                            VStack(alignment: .leading, spacing: 3) {
                                Text("Update available for \(item.row.displayName)")
                                    .font(.system(size: 14.5, weight: .semibold)).lineLimit(1)
                                Text(item.availability.detail).font(.system(size: 13.5)).foregroundStyle(.secondary).lineLimit(1)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            Button("Review") { openPlugin(item.row) }
                                .buttonStyle(.glass).controlSize(.small)
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 11)
                        if item.row.artifactID != updateItems.last?.row.artifactID {
                            Divider().padding(.leading, 47)
                        }
                    }
                }
                Divider()
                Label("Nothing installs until you approve it here.", systemImage: "checkmark.shield")
                    .font(.system(size: 12.5))
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    /// What the last check and the review queue say is waiting, worst first.
    ///
    /// An app this Mac is not managing is not a problem it has, and an app
    /// nobody has checked yet is not one either — neither appears. A queued
    /// request appears as something to decide, never as something that happened.
    private var attentionItems: [OverviewAttention] {
        let unreachable = enabledClients.filter {
            workspace.device.verdict(for: $0).state == .attention
        }
        let clients = unreachable.map { client in
            // The verdict already says what is wrong in the same words the
            // sidebar and Apps use, so Home repeats it rather than working
            // out a second, possibly different, description from the scan.
            let verdict = workspace.device.verdict(for: client)
            return OverviewAttention(
                id: "client-\(client.rawValue)",
                title: "\(client.rawValue): \(verdict.text.lowercased())",
                detail: verdict.detail,
                state: .attention, destination: .syncCenter)
        }
        let queued = requests.requests.map { request in
            OverviewAttention(
                id: "request-\(request.id.uuidString)",
                title: request.title,
                detail: request.summary,
                state: .pending, destination: .syncCenter)
        }
        // Connections the last health check found broken. Nothing is checked
        // from here: a count appears only once somebody ran a check, so Home
        // never reports a problem it has not seen.
        let health = workspace.health.attentionCount
        let connections: [OverviewAttention] = health == 0 ? [] : [
            OverviewAttention(
                id: "health",
                title: health == 1 ? "1 connection needs attention" : "\(health) connections need attention",
                detail: "Sign in again or reconnect on the Health tab.",
                state: .attention, destination: .health)
        ]
        return Array((connections + clients + queued).prefix(3))
    }

    /// Plugins a catalog says have something newer. Before any catalog has been
    /// asked this is empty, because "not checked" is not news.
    private var updateItems: [(row: WorkspaceLibraryReadModelRow, availability: UpdateAvailability)] {
        let evaluation = updateEvaluation
        let rows = evaluation.rowsWithUpdates(in: libraryModel?.rows ?? [])
        return rows.prefix(3).compactMap { row in
            evaluation.availability[row.artifactID].map { (row, $0) }
        }
    }

    /// One evaluation, from the catalog this session reached and the record this
    /// Mac kept, so Home and Library › Plugins cannot disagree about a plugin.
    private var updateEvaluation: PluginUpdateEvaluation {
        PluginUpdateEvaluation(
            state: workspace.library.state,
            packages: catalog.packages.isEmpty ? nil : catalog.packages,
            sources: catalog.sources.isEmpty ? nil : catalog.sources)
    }

    // MARK: - Apps

    /// The last checkup in a sentence, and the way into the next one. Reads
    /// the setup session's kept checkup; never starts one.
    private var setupCard: some View {
        let setup = workspace.setup
        return BentoCard(
            symbol: "stethoscope", title: "Your setup",
            action: ("Checkup", { navigate(.checkup) })
        ) {
            HStack(spacing: 12) {
                if let checkup = setup.checkup {
                    let open = checkup.openFindings.count + checkup.openRecommendations.count
                    StatusGlyph(state: open == 0 ? .healthy : ((checkup.audit.highestSeverity ?? .info) >= .medium ? .attention : .pending), size: 18)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(open == 0 ? "Nothing needs attention" : "\(open) thing\(open == 1 ? "" : "s") to look at")
                            .font(.system(size: 14, weight: .medium))
                        Text("Checked \(SnapshotTime.compact(checkup.completedAt))" + (setup.isStale ? " · a new checkup is due" : ""))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                } else {
                    Image(systemName: "wand.and.stars").font(.system(size: 18)).foregroundStyle(.secondary).frame(width: 18)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("This Mac has not been checked yet").font(.system(size: 14, weight: .medium))
                        Text("Find what is broken, duplicated, or unmanaged, and have your assistant say what to do.")
                            .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 8)
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var appsCard: some View {
        BentoCard(
            symbol: "square.grid.2x2", title: "Apps",
            action: ("Manage", { navigation.showAllClients() })
        ) {
            if enabledClients.isEmpty {
                Text("Choose your apps to see their local setup here.")
                    .font(.system(size: 14)).foregroundStyle(.secondary)
                    .padding(16)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                HStack(alignment: .top, spacing: 6) {
                    ForEach(enabledClients) { client in
                        appBadge(client)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 16)
                .frame(maxWidth: .infinity)
            }
        }
    }

    /// One app: its mark on a tile, its health as a dot on the tile's corner,
    /// its name beneath. The verdict text lives in the help tag so the row of
    /// icons stays scannable.
    private func appBadge(_ client: ClientKind) -> some View {
        let verdict = workspace.device.verdict(for: client)
        return Button {
            navigation.openClient(client)
        } label: {
            VStack(spacing: 8) {
                ZStack(alignment: .bottomTrailing) {
                    RoundedRectangle(cornerRadius: 11, style: .continuous)
                        .fill(AgentTheme.controlBackground)
                        .overlay {
                            RoundedRectangle(cornerRadius: 11, style: .continuous)
                                .strokeBorder(AgentTheme.separator.opacity(0.35), lineWidth: 0.5)
                        }
                        .frame(width: 44, height: 44)
                        .overlay { ClientBrandIcon(client: client, size: 24) }
                    Circle()
                        .fill(statusDotColor(verdict.state))
                        .frame(width: 10, height: 10)
                        .overlay { Circle().strokeBorder(AgentTheme.controlBackground, lineWidth: 2) }
                        .offset(x: 3, y: 3)
                }
                Text(client.rawValue)
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("\(client.rawValue): \(verdict.text)")
        .accessibilityLabel("\(client.rawValue), \(verdict.text)")
    }

    private func statusDotColor(_ state: HealthState) -> Color {
        switch state {
        case .healthy: AgentTheme.ok
        case .attention: AgentTheme.warning
        case .pending: AgentTheme.blue
        case .unavailable: AgentTheme.failure
        }
    }

    // MARK: - Reading

    private var libraryModel: WorkspaceLibraryReadModel? { workspace.library.state?.library }

    /// The library in the shape the surviving services already speak. Absent
    /// until the library has been read once; there is no empty one to stand in
    /// for it, and pretending otherwise would report a real library as empty.
    private var inventory: VersionedInventoryProjection.Inventory? {
        libraryModel.map(VersionedInventoryProjection.inventory)
    }

    private var lastScanText: String {
        guard let date = workspace.device.observations.map(\.lastScannedAt).max() else { return "Not checked yet" }
        // The same phrasing the sidebar and Apps screen use for this very date,
        // so one moment does not read as "9m ago" in one place and "43 minutes
        // ago" in another.
        return "Checked \(SnapshotTime.compact(date))"
    }

    /// These are stored Insights findings; Home never fabricates a personal
    /// recommendation and never starts a scan to get one.
    private var recommendations: [ToolRecommendation] {
        Array((insights.report?.recommendations ?? []).prefix(4))
    }

    // MARK: - Acting

    /// Works out what would change, on the screen that can approve it. Preparing
    /// reads only; nothing is written until somebody says so there.
    private func reviewChanges() {
        // The same route "Install now…" takes: Apps prepares the plan and opens
        // it for review, so the person lands on the sheet rather than on a
        // screen they then have to ask again.
        navigation.showAllClients()
        navigation.openScreenRequest(.reviewChanges)
    }

    /// Reveals one plugin on the Plugins tab. Revealing is not acting on it.
    private func openPlugin(_ row: WorkspaceLibraryReadModelRow) {
        navigation.openItem(row.artifactID.rawValue.uuidString.lowercased(), in: .plugins)
    }

    private func recommendationSummary(_ recommendation: ToolRecommendation) -> String {
        let summary = recommendation.summary.trimmingCharacters(in: .whitespacesAndNewlines)
        var firstSentence = summary
        summary.enumerateSubstrings(in: summary.startIndex..<summary.endIndex, options: .bySentences) { sentence, _, _, stop in
            if let sentence { firstSentence = sentence.trimmingCharacters(in: .whitespacesAndNewlines) }
            stop = true
        }
        return firstSentence
    }

    private func recommendationTitle(_ recommendation: ToolRecommendation) -> String {
        if recommendation.kind == .useExistingSkill, let skill = skill(recommendation.skillID) {
            return skill.displayName
        }
        return recommendation.title
    }

    /// Resolve artwork through exact package metadata, never through a title
    /// that might happen to resemble a familiar service or publisher.
    private func recommendationPackageID(_ recommendation: ToolRecommendation) -> String? {
        switch recommendation.kind {
        case .useExistingSkill:
            guard let skillID = recommendation.skillID, let id = ArtifactID(uuidString: skillID) else { return nil }
            // The plugin this skill arrived inside, named by the identity its
            // own app registered rather than by anything a person typed.
            return libraryModel?.rows
                .first { $0.includedChildren.contains { $0.artifactID == id } }?
                .nativeRoutes.first?.externalPluginID
        case .marketplaceSkill, .mcpServer, .plugin:
            guard let packageID = recommendation.marketplacePackageID else { return nil }
            if recommendation.marketplacePackage?.id == packageID
                || catalog.packages.contains(where: { $0.id == packageID })
            {
                return packageID
            }
            return nil
        case .createCustomSkill: return nil
        }
    }

    private func recommendationKind(_ recommendation: ToolRecommendation) -> ToolingKind {
        switch recommendation.kind {
        case .useExistingSkill, .createCustomSkill, .marketplaceSkill: .skill
        case .mcpServer: .mcpServer
        case .plugin: .plugin
        }
    }

    private func recommendationAction(_ recommendation: ToolRecommendation) -> String {
        switch recommendation.kind {
        case .useExistingSkill:
            return skill(recommendation.skillID) == nil ? "View suggestion" : "Open skill"
        case .createCustomSkill: return "View suggestion"
        case .marketplaceSkill, .mcpServer, .plugin: return "Review in Discover"
        }
    }

    /// A recommendation opens a screen. Nothing here installs, nothing here
    /// queues anything, and nothing here writes to an app: asking for a skill to
    /// be drafted is a decision that stays on Insights, where the row says what
    /// it would do.
    private func open(_ recommendation: ToolRecommendation) {
        switch recommendation.kind {
        case .useExistingSkill:
            if let skillID = recommendation.skillID, skill(skillID) != nil {
                navigation.open(.skill(skillID))
            } else {
                navigate(.insights)
            }
        case .createCustomSkill:
            navigate(.insights)
        case .marketplaceSkill, .mcpServer, .plugin:
            if let packageID = recommendation.marketplacePackageID,
                catalog.packages.contains(where: { $0.id == packageID })
            {
                navigation.openMarketplacePackage(packageID)
            } else {
                navigate(.marketplace)
            }
        }
    }

    /// One skill this library actually holds, or nothing. A recommendation from
    /// an older report can name a skill that has since gone, and a row that
    /// offered to open it would open nothing.
    private func skill(_ id: String?) -> Skill? {
        guard let id else { return nil }
        return inventory?.skills.first { $0.id == id }
    }
}

/// One bento card: an eyebrow — small symbol, tracked-out label, optional
/// trailing action — above the card's own rows. The eyebrow is part of the
/// card, unlike `TitledCard`, because the dashboard reads as a set of labeled
/// tiles rather than as sections of a page.
private struct BentoCard<Content: View>: View {
    let symbol: String
    let title: String
    var action: (String, () -> Void)?
    /// Whether the card's own surface grows to the height its column gives it.
    /// A frame put on the card from outside stretches an invisible box; the
    /// panel background has to be the thing that stretches for the page to
    /// read as filled rather than as short cards over an empty canvas.
    var fillsHeight = false
    @ViewBuilder var content: Content

    init(
        symbol: String, title: String, action: (String, () -> Void)? = nil, fillsHeight: Bool = false,
        @ViewBuilder content: () -> Content
    ) {
        self.symbol = symbol
        self.title = title
        self.action = action
        self.fillsHeight = fillsHeight
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 7) {
                Image(systemName: symbol)
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(.secondary)
                Text(title.uppercased())
                    .font(.system(size: 11, weight: .bold))
                    .kerning(0.7)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 8)
                if let action {
                    Button(action.0, action: action.1)
                        .buttonStyle(.plain)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(AgentTheme.blue)
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 13)
            .padding(.bottom, 9)
            content
        }
        .frame(maxWidth: .infinity, maxHeight: fillsHeight ? .infinity : nil, alignment: .topLeading)
        .standardPanel(cornerRadius: 16)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(title)
    }
}

private struct OverviewAttention: Identifiable {
    let id: String
    let title: String
    let detail: String
    let state: HealthState
    let destination: AppSection
}

extension ArtifactID {
    fileprivate init?(uuidString: String) {
        guard let uuid = UUID(uuidString: uuidString) else { return nil }
        self.init(rawValue: uuid)
    }
}
