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

struct OverviewView: View {
    @Environment(AppModel.self) private var model
    @Environment(AppNavigationState.self) private var navigation
    @Environment(\.startOnboarding) private var startOnboarding
    @AppStorage("onboarding.completed.v1") private var onboardingCompleted = false
    let navigate: (AppSection) -> Void
    let onOpenPlugin: ((String) -> Void)?

    init(navigate: @escaping (AppSection) -> Void, onOpenPlugin: ((String) -> Void)? = nil) {
        self.navigate = navigate
        self.onOpenPlugin = onOpenPlugin
    }

    var body: some View {
        let attention = attentionItems
        let updates = updateItems
        return VStack(spacing: 0) {
            PageToolbar(title: "Home", context: lastScanText) {
                Button {
                    Task { await model.runDoctor() }
                } label: {
                    Image(systemName: "arrow.clockwise").frame(width: 16, height: 16)
                }
                .buttonStyle(.glass)
                .disabled(model.isInteractionLocked)
                .help("Re-scan local client commands, configurations, and installed tooling on this Mac")
                .accessibilityLabel("Refresh local checks")

                Button {
                    Task { await model.runSync() }
                } label: {
                    Label(model.isSyncing ? "Preparing…" : "Review changes", systemImage: "arrow.triangle.2.circlepath")
                }
                .buttonStyle(.glass)
                .disabled(model.isInteractionLocked)
            }

            ScrollView {
                VStack(alignment: .leading, spacing: WorkspaceLayout.sectionSpacing) {
                    if !onboardingCompleted { onboardingCard }
                    recommendationsSection
                    librarySection
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
            Button("Set up your library", action: startOnboarding)
                .buttonStyle(.glassProminent).controlSize(.large)
                .disabled(model.isInteractionLocked)
        }
        .padding(20)
        .standardPanel(cornerRadius: 14)
    }

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

    private var librarySection: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Your library").font(.system(size: 20, weight: .semibold))
                Spacer()
                Button("Discover more", systemImage: "arrow.right") { navigate(.marketplace) }
                    .buttonStyle(.plain)
                    .font(.system(size: 15))
                    .foregroundStyle(AgentTheme.blue)
            }
            HStack(spacing: 0) {
                libraryDestination("Skills", count: model.visibleSkills.count, kind: .skill, section: .skills)
                Divider().frame(height: 28).opacity(0.5)
                libraryDestination("Plugins", count: model.visiblePlugins.count, kind: .plugin, section: .plugins)
                Divider().frame(height: 28).opacity(0.5)
                libraryDestination("MCP servers", count: model.visibleMCPServers.count, kind: .mcpServer, section: .mcpServers)
            }
            .padding(4)
            .standardPanel(cornerRadius: 16)

            if let onOpenPlugin, !featuredInstalledPlugins.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 16) {
                        ForEach(featuredInstalledPlugins) { plugin in
                            Button {
                                onOpenPlugin(plugin.id)
                            } label: {
                                ToolIdentityIcon(packageID: plugin.id, size: 40)
                            }
                            .buttonStyle(.plain)
                            .help(plugin.name)
                            .accessibilityLabel("Open \(plugin.name)")
                            .accessibilityHint("Show plugin details")
                        }
                    }
                    .padding(.vertical, 4)
                }
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 16)
                .accessibilityElement(children: .contain)
                .accessibilityLabel("Installed plugins")
            }
        }
    }

    private var featuredInstalledPlugins: [Plugin] {
        var seenArtwork = Set<String>()
        return Array(
            model.visiblePlugins
                .filter { $0.installed && ToolIdentityAssets.asset(for: $0.id) != nil }
                .sorted {
                    let order = $0.name.localizedStandardCompare($1.name)
                    return order == .orderedSame ? $0.id < $1.id : order == .orderedAscending
                }
                .filter { plugin in
                    guard let artwork = ToolIdentityAssets.asset(for: plugin.id) else { return false }
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

    private func attentionSection(
        items attentionItems: [OverviewAttention],
        updates updateItems: [(plugin: Plugin, availability: UpdateAvailability)]
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
                ForEach(updateItems, id: \.plugin.id) { item in
                    HStack(alignment: .top, spacing: 14) {
                        ToolIdentityIcon(packageID: item.plugin.id, size: 36)
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Update available for \(item.plugin.name)").font(.system(size: 16, weight: .medium))
                            Text(item.availability.detail).font(.system(size: 15)).foregroundStyle(.secondary).lineLimit(2)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        Button("Review") {
                            if let onOpenPlugin { onOpenPlugin(item.plugin.id) } else { navigate(.plugins) }
                        }
                        .buttonStyle(.glass)
                    }
                    .padding(18)
                    if item.plugin.id != updateItems.last?.plugin.id { Divider().padding(.horizontal, 18) }
                }
            }
            .standardPanel(cornerRadius: 16)
        }
    }

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
                ForEach(model.availableClients) { client in
                    Button {
                        navigation.openClient(client)
                    } label: {
                        HStack(spacing: 10) {
                            ClientBrandIcon(client: client, size: 22)
                            Text(client.rawValue).font(.system(size: 15, weight: .medium))
                            let verdict = model.clientVerdict(for: client)
                            Text(verdict.state == .healthy ? "Found locally" : verdict.text)
                                .font(.system(size: 14)).foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 4)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            if model.availableClients.isEmpty {
                Text("Choose your apps to see their local setup here.")
                    .font(.system(size: 15)).foregroundStyle(.secondary)
            }
        }
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
        if recommendation.kind == .useExistingSkill,
            let skill = model.visibleSkills.first(where: { $0.id == recommendation.skillID })
        {
            return skill.displayName
        }
        return recommendation.title
    }

    /// Resolve artwork through exact package metadata, never through a title
    /// that might happen to resemble a familiar service or publisher.
    private func recommendationPackageID(_ recommendation: ToolRecommendation) -> String? {
        switch recommendation.kind {
        case .useExistingSkill:
            guard let skillID = recommendation.skillID else { return nil }
            return model.visiblePlugins.first(where: { $0.skills.contains(skillID) })?.id
        case .marketplaceSkill, .mcpServer, .plugin:
            guard let packageID = recommendation.marketplacePackageID else { return nil }
            if recommendation.marketplacePackage?.id == packageID
                || model.visibleMarketplacePackages.contains(where: { $0.id == packageID })
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
            if let skillID = recommendation.skillID, model.visibleSkills.contains(where: { $0.id == skillID }) {
                return "Open skill"
            }
            return "View suggestion"
        case .createCustomSkill: return "View suggestion"
        case .marketplaceSkill, .mcpServer, .plugin: return "Review in Discover"
        }
    }

    private func open(_ recommendation: ToolRecommendation) {
        switch recommendation.kind {
        case .useExistingSkill:
            if let skillID = recommendation.skillID, model.visibleSkills.contains(where: { $0.id == skillID }) {
                navigation.open(.skill(skillID))
            } else {
                navigate(.insights)
            }
        case .createCustomSkill:
            navigate(.insights)
        case .marketplaceSkill, .mcpServer, .plugin:
            if let packageID = recommendation.marketplacePackageID,
                model.visibleMarketplacePackages.contains(where: { $0.id == packageID })
            {
                navigation.openMarketplacePackage(packageID)
            } else {
                navigation.openMarketplaceRecommendation(recommendation, using: model)
            }
        }
    }

    private var lastScanText: String {
        guard let date = model.visibleTargetObservations.map(\.lastScannedAt).max() else { return "Not checked yet" }
        return "Checked \(date.formatted(.relative(presentation: .named)))"
    }

    /// These are stored Insights findings; Home never fabricates a personal recommendation.
    private var recommendations: [ToolRecommendation] {
        Array((model.visibleInsightsReport?.recommendations ?? []).prefix(4))
    }

    private var updateItems: [(plugin: Plugin, availability: UpdateAvailability)] {
        Array(model.pluginUpdateAvailability().filter { $0.availability.hasUpdate }.prefix(3))
    }

    private var attentionItems: [OverviewAttention] {
        let targets = model.visibleTargetObservations
            .filter { !$0.isCommandAvailable }
            .map {
                OverviewAttention(
                    id: $0.id,
                    title: $0.installed ? "\($0.surface.displayName) command is unavailable" : "\($0.surface.displayName) was not found",
                    detail: $0.notes.first ?? "The expected local path was checked.",
                    state: .attention, destination: .syncCenter)
            }
        let configurationChecks = (model.activeProfile?.checks ?? [])
            .filter { $0.state == .attention || $0.state == .unavailable }
            .map {
                OverviewAttention(id: "profile-\($0.id)", title: $0.name, detail: $0.detail, state: $0.state, destination: .profiles)
            }
        let servers = model.visibleMCPServers
            .filter { $0.aggregateState == .attention || $0.aggregateState == .unavailable }
            .map {
                OverviewAttention(
                    id: "mcp-\($0.id)", title: $0.name, detail: $0.summary, state: $0.aggregateState, destination: .mcpServers)
            }
        return Array((targets + configurationChecks + servers).prefix(3))
    }
}

private struct OverviewAttention: Identifiable {
    let id: String
    let title: String
    let detail: String
    let state: HealthState
    let destination: AppSection
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
                    .tint(AgentTheme.selection)
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
