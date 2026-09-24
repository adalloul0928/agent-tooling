import AgentToolingCore
import AppKit
import SwiftUI

extension MarketplaceView {

    var wideMarketplaceControls: some View {
        HStack(spacing: 8) {
            componentSelector
                .fixedSize()
            marketplaceFilterMenu(compact: false)
            marketplaceSortMenu(compact: false)
        }
        .fixedSize(horizontal: true, vertical: false)
    }

    var compactMarketplaceControls: some View {
        HStack(spacing: 8) {
            componentSelector
                .fixedSize()
            marketplaceFilterMenu(compact: true)
            marketplaceSortMenu(compact: true)
        }
        .fixedSize(horizontal: true, vertical: false)
    }

    var stackedMarketplaceControls: some View {
        VStack(alignment: .leading, spacing: 10) {
            componentSelector.fixedSize()
            HStack(spacing: 8) {
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
        let activeCount = (clientFilter == .all ? 0 : 1) + (classificationFilter == .all ? 0 : 1)
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
        } label: {
            MarketplaceMenuButtonLabel(
                systemImage: "line.3.horizontal.decrease",
                title: compact ? nil : "Filters",
                badge: activeCount == 0 ? nil : activeCount
            )
        }
        .inventoryMenuStyle()
        .fixedSize()
        .help(activeCount == 0 ? "Filter packages by app or provenance" : "\(activeCount) filters active")
        .accessibilityLabel("Package filters")
        .accessibilityValue(activeCount == 0 ? "No app or provenance filter" : "\(activeCount) active")
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
        "\(count) \(count == 1 ? "result" : "results")"
    }

    var hasActiveTokenFilter: Bool {
        selectedSourceID != nil || clientFilter != .all || classificationFilter != .all
    }

    func clearFilters() {
        query = ""
        componentFilter = .all
        clientFilter = .all
        classificationFilter = .all
        selectedSourceID = nil
    }

}

private struct MarketplaceMenuButtonLabel: View {
    let systemImage: String
    var title: String?
    var badge: Int?

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: systemImage)
            if let title {
                Text(title).lineLimit(1)
            }
            if let badge {
                Text(badge, format: .number)
                    .font(.caption2.monospacedDigit().weight(.semibold))
                    .foregroundStyle(.secondary)
            }
        }
        .font(.system(size: 13))
    }
}

struct ActiveFilterToken: View {
    let title: String
    let accessibilityName: String
    let remove: () -> Void

    var body: some View {
        Button(action: remove) {
            HStack(spacing: 5) {
                Text(title)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: 190, alignment: .leading)
                Image(systemName: "xmark")
                    .font(.system(size: 8, weight: .bold))
                    .accessibilityHidden(true)
            }
            .font(.caption.weight(.medium))
            .foregroundStyle(AgentTheme.blue)
            .padding(.horizontal, 9)
            .frame(height: 23)
            .background(AgentTheme.blue.opacity(0.12), in: Capsule())
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

    func matches(_ package: MarketplacePackage) -> Bool {
        switch self {
        case .all: true
        case .skills: package.components.contains(.skill)
        case .plugins: package.components.contains(.plugin)
        case .mcpServers: package.components.contains(.mcpServer)
        }
    }
}
