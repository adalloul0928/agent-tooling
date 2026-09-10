import AgentToolingCore
import SwiftUI

private struct LibraryDestinationStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hovering = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color.primary.opacity(configuration.isPressed ? 0.08 : hovering ? 0.035 : 0))
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

            ScrollView {
                VStack(alignment: .leading, spacing: WorkspaceLayout.sectionSpacing) {
                    if showsOnboarding { onboardingCard }
                    recommendationsSection
                    librarySection
                    if !enabledClients.isEmpty { conduit }
                    if !attention.isEmpty || !updates.isEmpty {
                        attentionSection(items: attention, updates: updates)
                    }
                    appFooter
                }
                .padding(.horizontal, WorkspaceLayout.pageInset)
                .padding(.top, WorkspaceLayout.contentTopInset)
                .padding(.bottom, WorkspaceLayout.pageInset)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .font(.system(size: 15))
            .scrollIndicators(.hidden)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
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
                .buttonStyle(.glassProminent).controlSize(.large)
                .disabled(workspace.library.isBusy)
        }
        .padding(20)
        .standardPanel(cornerRadius: 14)
    }

    // MARK: - Recommended for you

    private var recommendationsSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .firstTextBaseline, spacing: 24) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Recommended for you")
                        .font(.system(size: 20, weight: .semibold))
                    Text(
                        recommendations.isEmpty
                            ? "Find useful tools for the work you do."
                            : "Useful tools based on your recent work."
                    )
                    .font(.system(size: 15))
                    .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                if !recommendations.isEmpty {
                    Button("All suggestions") { navigate(.insights) }
                        .buttonStyle(.plain)
                        .font(.system(size: 15))
                        .foregroundStyle(AgentTheme.blue)
                }
            }

            if recommendations.isEmpty {
                VStack(alignment: .leading, spacing: 18) {
                    HStack(alignment: .top, spacing: 18) {
                        Image(systemName: "sparkle.magnifyingglass")
                            .font(.system(size: 32, weight: .regular))
                            .foregroundStyle(.secondary)
                            .frame(width: 48, height: 48)
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Explore what your apps can do")
                                .font(.system(size: 18, weight: .semibold))
                            Text("Browse skills, plugins, and connections, or review recent work in Insights.")
                                .font(.system(size: 15))
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    HStack(spacing: 12) {
                        Button("Browse Discover") { navigate(.marketplace) }
                            .buttonStyle(.glassProminent)
                        Button("Open Insights") { navigate(.insights) }
                            .buttonStyle(.glass)
                    }
                    .controlSize(.large)
                }
                .padding(24)
                .frame(maxWidth: .infinity, alignment: .leading)
                .standardPanel(cornerRadius: 18)
            } else {
                LazyVGrid(
                    columns: [GridItem(.flexible(), spacing: 16, alignment: .top), GridItem(.flexible(), alignment: .top)],
                    alignment: .leading, spacing: 12
                ) {
                    ForEach(recommendations) { recommendation in
                        recommendationRow(recommendation)
                    }
                }
            }
        }
    }

    private func recommendationRow(_ recommendation: ToolRecommendation) -> some View {
        Button {
            open(recommendation)
        } label: {
            HStack(alignment: .top, spacing: 14) {
                ToolIdentityIcon(
                    packageID: recommendationPackageID(recommendation) ?? "",
                    fallback: recommendationKind(recommendation), size: 40
                )
                .padding(.top, 2)
                VStack(alignment: .leading, spacing: 6) {
                    Text(recommendationTitle(recommendation))
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(2)
                    Text(recommendationSummary(recommendation))
                        .font(.system(size: 15))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                    Text(recommendationAction(recommendation))
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(AgentTheme.blue)
                        .padding(.top, 2)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(16)
            .frame(maxWidth: .infinity, minHeight: 112, alignment: .topLeading)
            .standardPanel(cornerRadius: 12)
            .contentShape(RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(LibraryDestinationStyle())
        .accessibilityHint(recommendationAction(recommendation))
    }

    // MARK: - Your library

    private var librarySection: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline, spacing: 24) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Your library").font(.system(size: 20, weight: .semibold))
                    Text(librarySummary)
                        .font(.system(size: 15))
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                Button("Discover more", systemImage: "arrow.right") { navigate(.marketplace) }
                    .buttonStyle(.plain)
                    .font(.system(size: 15))
                    .foregroundStyle(AgentTheme.blue)
            }
            HStack(spacing: 0) {
                libraryDestination("Skills", count: inventory?.skills.count ?? 0, kind: .skill, section: .skills)
                Divider().frame(height: 28).opacity(0.5)
                libraryDestination("Plugins", count: inventory?.plugins.count ?? 0, kind: .plugin, section: .plugins)
                Divider().frame(height: 28).opacity(0.5)
                libraryDestination(
                    "MCP servers", count: inventory?.mcpServers.count ?? 0, kind: .mcpServer, section: .mcpServers)
            }
            .padding(4)
            .standardPanel(cornerRadius: 16)

            if !featuredPlugins.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 16) {
                        ForEach(featuredPlugins) { row in
                            Button {
                                openPlugin(row)
                            } label: {
                                ToolIdentityIcon(packageID: row.nativeRoutes.first?.externalPluginID ?? "", size: 40)
                            }
                            .buttonStyle(.plain)
                            .help(row.displayName)
                            .accessibilityLabel("Open \(row.displayName)")
                            .accessibilityHint("Show plugin details")
                        }
                    }
                    .padding(.vertical, 4)
                }
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 16)
                .accessibilityElement(children: .contain)
                .accessibilityLabel("Plugins your apps registered")
            }
        }
    }

    /// What the library holds, counted the way the read model counts it: every
    /// tool, and how many of them arrived inside a plugin rather than on their
    /// own. Nothing here says any of them is installed.
    private var librarySummary: String {
        guard let library = libraryModel else { return "Reading your library…" }
        guard library.toolCount > 0 else { return "Nothing here yet." }
        let tools = "\(library.toolCount) \(library.toolCount == 1 ? "tool" : "tools")"
        guard library.nestedToolCount > 0 else { return tools }
        return "\(tools) · \(library.nestedToolCount) inside plugins"
    }

    /// Plugins an app's own registry named, with artwork this build ships, one
    /// per distinct mark. A row without a native route has no catalog identity
    /// to resolve, so it is not shown here rather than shown as a blank tile.
    private var featuredPlugins: [WorkspaceLibraryReadModelRow] {
        var seenArtwork = Set<String>()
        return Array(
            (libraryModel?.rows ?? [])
                .filter { $0.kind == .nativePlugin || $0.kind == .package }
                .sorted {
                    let order = $0.displayName.localizedStandardCompare($1.displayName)
                    return order == .orderedSame
                        ? $0.artifactID.rawValue.uuidString < $1.artifactID.rawValue.uuidString
                        : order == .orderedAscending
                }
                .filter { row in
                    guard let route = row.nativeRoutes.first,
                        let artwork = ToolIdentityAssets.asset(for: route.externalPluginID)
                    else { return false }
                    return seenArtwork.insert(artwork.asset).inserted
                }
                .prefix(10))
    }

    private func libraryDestination(_ title: String, count: Int, kind: ToolingKind, section: AppSection) -> some View {
        Button {
            navigate(section)
        } label: {
            HStack(spacing: 10) {
                KindTile(kind: kind, size: 26)
                Text(title).font(.system(size: 16, weight: .medium)).lineLimit(1)
                Spacer(minLength: 4)
                Text(count, format: .number)
                    .font(.system(size: 15)).monospacedDigit()
                    .foregroundStyle(.secondary)
                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 16)
            .frame(maxWidth: .infinity, minHeight: 64)
            .contentShape(RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(LibraryDestinationStyle())
        .accessibilityLabel("Open \(title), \(count) items")
    }

    // MARK: - The path to your apps

    /// The product's signature path, drawn from the same three facts the Apps
    /// screen draws it from: what the library holds, what is asked for, and
    /// what the last check found in each app. Configurations are gone, so the
    /// middle node states the asks rather than naming a profile.
    private var conduit: some View {
        SyncConduitView(
            managedCount: managedCount,
            discoveredCount: discoveredCount,
            profileName: "Assignments",
            desiredCount: desiredCount,
            pendingCount: pendingCount,
            terminals: enabledClients.map { client in
                let verdict = workspace.device.verdict(for: client)
                return ConduitTerminal(client: client, state: verdict.state, text: verdict.text)
            },
            onLibrary: { navigate(.skills) },
            onProfile: { navigate(.projects) },
            onClient: { navigation.openClient($0) })
    }

    /// What this Mac is looking after, and what it has merely noticed.
    private var managedCount: Int {
        (libraryModel?.rows ?? [])
            .filter { $0.ownership != .trackedOnly }
            .reduce(0) { $0 + 1 + $1.childCount }
    }

    private var discoveredCount: Int {
        libraryModel?.rows.count { $0.ownership == .trackedOnly } ?? 0
    }

    /// How many library items are asked for anywhere. Asked for, not installed.
    private var desiredCount: Int {
        libraryModel?.rows.count { !$0.requestedAssignments.isEmpty } ?? 0
    }

    /// Everything waiting on a person: the steps a prepared plan is holding, and
    /// the requests nobody has decided. A plan that has been applied has already
    /// re-read itself, so what is left here is what is still outstanding.
    private var pendingCount: Int {
        (workspace.deployment.plan?.items.count ?? 0) + requests.requests.count
    }

    // MARK: - Needs your attention

    private func attentionSection(
        items attentionItems: [OverviewAttention],
        updates updateItems: [(row: WorkspaceLibraryReadModelRow, availability: UpdateAvailability)]
    ) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Needs your attention").font(.system(size: 20, weight: .semibold))
            VStack(spacing: 0) {
                ForEach(attentionItems) { item in
                    HStack(alignment: .top, spacing: 14) {
                        StatusGlyph(state: item.state, size: 18).padding(.top, 2)
                        VStack(alignment: .leading, spacing: 6) {
                            Text(item.title).font(.system(size: 16, weight: .medium))
                            Text(item.detail).font(.system(size: 15)).foregroundStyle(.secondary).lineLimit(2)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        Button("Review") { navigate(item.destination) }.buttonStyle(.glass)
                    }
                    .padding(18)
                    if item.id != attentionItems.last?.id || !updateItems.isEmpty { Divider().padding(.horizontal, 18) }
                }
                ForEach(updateItems, id: \.row.artifactID) { item in
                    HStack(alignment: .top, spacing: 14) {
                        ToolIdentityIcon(
                            packageID: item.row.nativeRoutes.first?.externalPluginID ?? "",
                            fallback: .plugin, size: 36)
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Update available for \(item.row.displayName)").font(.system(size: 16, weight: .medium))
                            Text(item.availability.detail).font(.system(size: 15)).foregroundStyle(.secondary).lineLimit(2)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        Button("Review") { openPlugin(item.row) }
                            .buttonStyle(.glass)
                    }
                    .padding(18)
                    if item.row.artifactID != updateItems.last?.row.artifactID { Divider().padding(.horizontal, 18) }
                }
            }
            .standardPanel(cornerRadius: 16)
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
            let observed = workspace.device.observations.filter { $0.surface.client == client }
            return OverviewAttention(
                id: "client-\(client.rawValue)",
                title: observed.contains(where: \.installed)
                    ? "\(client.rawValue) command is unavailable"
                    : "\(client.rawValue) was not found",
                detail: observed.lazy.flatMap(\.notes).first ?? "The expected local path was checked.",
                state: .attention, destination: .syncCenter)
        }
        let queued = requests.requests.map { request in
            OverviewAttention(
                id: "request-\(request.id.uuidString)",
                title: request.title,
                detail: request.summary,
                state: .pending, destination: .syncCenter)
        }
        return Array((clients + queued).prefix(3))
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

    // MARK: - On this Mac

    private var appFooter: some View {
        VStack(alignment: .leading, spacing: 18) {
            Divider()
            HStack {
                Text("On this Mac").font(.system(size: 14, weight: .medium)).foregroundStyle(.secondary)
                Spacer()
                Button("Manage apps") { navigation.showAllClients() }
                    .buttonStyle(.plain).font(.system(size: 14)).foregroundStyle(AgentTheme.blue)
            }
            FlowLayout(spacing: 24) {
                ForEach(enabledClients) { client in
                    Button {
                        navigation.openClient(client)
                    } label: {
                        HStack(spacing: 10) {
                            ClientBrandIcon(client: client, size: 22)
                            Text(client.rawValue).font(.system(size: 15, weight: .medium))
                            let verdict = workspace.device.verdict(for: client)
                            Text(verdict.state == .healthy ? "Found locally" : verdict.text)
                                .font(.system(size: 14)).foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 4)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            if enabledClients.isEmpty {
                Text("Choose your apps to see their local setup here.")
                    .font(.system(size: 15)).foregroundStyle(.secondary)
            }
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
        return "Checked \(date.formatted(.relative(presentation: .named)))"
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
        navigation.showAllClients()
        Task { await workspace.deployment.prepare() }
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
