import AgentToolingCore
import AppKit
import SwiftUI

extension MarketplaceView {

    var wideMarketplaceControls: some View {
        HStack(spacing: Space.md) {
            componentSelector
                .fixedSize()
            marketplaceFilterMenu(compact: false)
            marketplaceSortMenu(compact: false)
        }
        .fixedSize(horizontal: true, vertical: false)
    }

    var compactMarketplaceControls: some View {
        HStack(spacing: Space.md) {
            componentSelector
                .fixedSize()
            marketplaceFilterMenu(compact: true)
            marketplaceSortMenu(compact: true)
        }
        .fixedSize(horizontal: true, vertical: false)
    }

    var stackedMarketplaceControls: some View {
        VStack(alignment: .leading, spacing: Space.lg) {
            componentSelector.fixedSize()
            HStack(spacing: Space.md) {
                marketplaceFilterMenu(compact: false)
                marketplaceSortMenu(compact: false)
            }
        }
    }

    var componentSelector: some View {
        WorkspaceSegmentedPicker("Package component", selection: $componentFilter) {
            ForEach(MarketplaceComponentFilter.allCases) { filter in Text(filter.rawValue).tag(filter) }
        }
    }

    func marketplaceFilterMenu(compact: Bool) -> some View {
        let activeCount =
            (clientFilter == .all ? 0 : 1) + (classificationFilter == .all ? 0 : 1) + (categoryFilter == nil ? 0 : 1)
        let categories = availableCategories
        return Menu {
            Menu("App") {
                ForEach(MarketplaceClientFilter.allCases.filter { workspace.device.isEnabled($0.client) }) { filter in
                    Button {
                        clientFilter = filter
                    } label: {
                        if clientFilter == filter {
                            Label(filter.rawValue, systemImage: "checkmark")
                        } else {
                            Text(filter.rawValue)
                        }
                    }
                }
            }
            Menu("Provenance") {
                ForEach(MarketplaceClassificationFilter.allCases) { filter in
                    Button {
                        classificationFilter = filter
                    } label: {
                        if classificationFilter == filter {
                            Label(filter.rawValue, systemImage: "checkmark")
                        } else {
                            Text(filter.rawValue)
                        }
                    }
                }
            }
            if !categories.isEmpty {
                Menu("Category") {
                    Button {
                        categoryFilter = nil
                    } label: {
                        if categoryFilter == nil {
                            Label("Any category", systemImage: "checkmark")
                        } else {
                            Text("Any category")
                        }
                    }
                    Divider()
                    ForEach(categories, id: \.self) { category in
                        Button {
                            categoryFilter = category
                        } label: {
                            if categoryFilter == category {
                                Label(category.capitalized, systemImage: "checkmark")
                            } else {
                                Text(category.capitalized)
                            }
                        }
                    }
                }
            }
        } label: {
            MarketplaceMenuButtonLabel(
                systemImage: "line.3.horizontal.decrease",
                title: compact ? nil : "Filters",
                badge: activeCount == 0 ? nil : activeCount
            )
        }
        .inventoryMenuStyle()
        .fixedSize()
        .help(activeCount == 0 ? "Filter packages by app, provenance, or category" : "\(CountNoun("filter").phrase(activeCount)) active")
        .accessibilityLabel("Package filters")
        .accessibilityValue(activeCount == 0 ? "No app, provenance, or category filter" : "\(activeCount) active")
    }

    /// The categories present in what the catalogs returned, sorted, so the
    /// Category filter offers exactly the labels a person could actually pick
    /// and nothing this app invented.
    var availableCategories: [String] {
        Array(Set(session.packages.compactMap(\.category))).sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    func marketplaceSortMenu(compact: Bool) -> some View {
        Menu {
            ForEach(MarketplaceSortOrder.allCases) { order in
                Button {
                    sortOrder = order
                } label: {
                    let title = order == .relevance ? "Smart (name until searching)" : order.displayName
                    if sortOrder == order {
                        Label(title, systemImage: "checkmark")
                    } else {
                        Text(title)
                    }
                }
            }
        } label: {
            MarketplaceMenuButtonLabel(
                systemImage: "arrow.up.arrow.down",
                title: compact ? nil : visibleSortName
            )
        }
        .inventoryMenuStyle()
        .fixedSize()
        .help("Sort: \(visibleSortName). \(sortOrder.measurement)")
        .accessibilityLabel("Sort packages")
        .accessibilityValue(visibleSortName)
    }

    var visibleSortName: String {
        sortOrder == .relevance && normalizedQuery.isEmpty ? "Smart" : sortOrder.displayName
    }

    func resultCountDescription(_ count: Int) -> String {
        CountNoun("result").phrase(count)
    }

    var hasActiveTokenFilter: Bool {
        selectedSourceID != nil || clientFilter != .all || classificationFilter != .all || categoryFilter != nil
    }

    func clearFilters() {
        query = ""
        componentFilter = .all
        clientFilter = .all
        classificationFilter = .all
        categoryFilter = nil
        selectedSourceID = nil
    }

}

private struct MarketplaceMenuButtonLabel: View {
    let systemImage: String
    var title: String?
    var badge: Int?

    var body: some View {
        HStack(spacing: Space.sm) {
            Image(systemName: systemImage)
            if let title {
                Text(title).lineLimit(1)
            }
            if let badge {
                Text(badge, format: .number)
                    .font(AgentFont.microSemibold.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
        .font(AgentFont.body)
    }
}

struct ActiveFilterToken: View {
    let title: String
    let accessibilityName: String
    let remove: () -> Void

    var body: some View {
        Button(action: remove) {
            HStack(spacing: Space.xs) {
                Text(title)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: Size.filterTokenLabelMax, alignment: .leading)
                Image(systemName: "xmark")
                    .font(AgentFont.microBold)
                    .accessibilityHidden(true)
            }
            .font(AgentFont.captionMedium)
            .foregroundStyle(AgentTheme.selection)
            .padding(.horizontal, Space.md)
            .frame(height: Size.pillHeight)
            .background(AgentTheme.selection.opacity(Opacity.tagWash), in: Capsule())
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .help("Remove \(accessibilityName) filter: \(title)")
        .accessibilityLabel("Remove \(accessibilityName) filter: \(title)")
    }
}

enum MarketplaceClientFilter: String, CaseIterable, Identifiable {
    case all = "Any app"
    case claude = "Claude Code"
    case codex = "Codex"
    case gemini = "Gemini CLI"

    var id: String { rawValue }

    var client: ClientKind? {
        switch self {
        case .all: nil
        case .claude: .claude
        case .codex: .codex
        case .gemini: .gemini
        }
    }

    func matches(_ package: MarketplacePackage) -> Bool {
        guard let client else { return true }
        return package.supportedClients.contains(client) || package.nativeInstalls.contains { $0.client == client }
    }
}

enum MarketplaceClassificationFilter: String, CaseIterable, Identifiable {
    case all = "Any provenance"
    case reference = "Reference"
    case official = "Official"
    case community = "Community"
    case unverified = "Unverified"

    var id: String { rawValue }

    var classification: PackageClassification? {
        switch self {
        case .all: nil
        case .reference: .reference
        case .official: .official
        case .community: .community
        case .unverified: .unverified
        }
    }

    var measurement: String {
        guard let classification else {
            return
                "Provenance says who a catalog verified, not whether a package is safe. Only the official MCP registry verifies a publisher at all."
        }
        return classification.definition
    }

    func matches(_ package: MarketplacePackage) -> Bool {
        guard let classification else { return true }
        return MarketplaceProvenanceClassifier.classify(package).classification == classification
    }
}

enum MarketplaceComponentFilter: String, CaseIterable, Identifiable {
    case all = "All"
    case skills = "Skills"
    case plugins = "Plugins"
    case mcpServers = "MCP"

    var id: String { rawValue }

    /// What the filter keeps, as it reads in a sentence: "publishes no MCP
    /// servers". The segment's own title is too short for one, and lowercasing
    /// it would turn MCP into "mcp".
    var listingNoun: String {
        switch self {
        case .all: "packages"
        case .skills: "skills"
        case .plugins: "plugins"
        case .mcpServers: "MCP servers"
        }
    }

    func matches(_ package: MarketplacePackage) -> Bool {
        switch self {
        case .all: true
        case .skills: package.components.contains(.skill)
        case .plugins: package.components.contains(.plugin)
        case .mcpServers: package.components.contains(.mcpServer)
        }
    }
}
