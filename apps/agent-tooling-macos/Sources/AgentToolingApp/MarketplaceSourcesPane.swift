import AgentToolingCore
import AppKit
import SwiftUI

extension MarketplaceView {

    var filteredPackages: [MarketplacePackage] {
        let searchTerm = normalizedQuery
        let matches = session.packages.filter { package in
            componentFilter.matches(package)
                && clientFilter.matches(package)
                && classificationFilter.matches(package)
                && matchesSelectedCategory(package)
                && matchesSelectedSource(package)
                && (searchTerm.isEmpty
                    || [
                        package.presentationName, package.originName, package.publisher, package.summary,
                        package.components.map(\.displayName).joined(separator: " "),
                    ]
                    .joined(separator: " ")
                    .localizedCaseInsensitiveContains(searchTerm))
        }
        return MarketplaceSorting.sorted(matches, by: sortOrder, searchTerm: searchTerm)
    }

    /// Whether the listing matches the selected category, or there is none. A
    /// listing with no category never matches a specific category selection.
    func matchesSelectedCategory(_ package: MarketplacePackage) -> Bool {
        guard let categoryFilter else { return true }
        return package.category == categoryFilter
    }

    var selectedPackage: MarketplacePackage? { session.packages.first { $0.id == selectedPackageID } }

    var hasActiveFilter: Bool {
        !normalizedQuery.isEmpty || componentFilter != .all || clientFilter != .all || classificationFilter != .all
            || categoryFilter != nil || selectedSourceID != nil
    }

    var normalizedQuery: String {
        query.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The empty state names the source and the filter that produced the
    /// emptiness, so nothing reads as a failure that is really a filter.
    var emptyPackageMessage: String {
        guard hasActiveFilter else {
            guard session.canReachCatalog else { return WorkspaceMarketplaceSession.noProviderNote }
            return "Refresh the catalogs. Nothing this workspace records has published a package yet."
        }
        if let source = selectedSource, componentFilter != .all {
            return
                "\(source.name) publishes no \(componentFilter.rawValue.lowercased()) packages. Native client catalogs list plugins; skills come from skills.sh searches and from Agent Plugins folders and Git checkouts you add."
        }
        if let source = selectedSource, let classification = classificationFilter.classification {
            return "Nothing from \(source.name) is classified \(classification.displayName). \(classification.definition)"
        }
        if let source = selectedSource {
            return "\(source.name) has nothing matching the current filters."
        }
        if componentFilter == .skills {
            return
                "No skills matched. Describe what you need in the search field and press Return — skills.sh answers searches with community skills. Local folders and Git checkouts of Agent Plugins packages also publish skills here."
        }
        if let classification = classificationFilter.classification {
            return "No package here is classified \(classification.displayName). \(classificationFilter.measurement)"
        }
        return "Try a different package name, publisher, component, app, or provenance."
    }

    var selectedSource: ToolingSource? {
        guard let selectedSourceID else { return nil }
        return session.sources.first { $0.id == selectedSourceID }
    }

    var selectedSourceID: UUID? {
        get { selectedSourceIDStorage.flatMap(UUID.init(uuidString:)) }
        nonmutating set { selectedSourceIDStorage = newValue?.uuidString }
    }

    /// Native catalogs do not carry a source identifier, so each package is
    /// matched back to the row that produced it by its catalog prefix.
    func matches(_ source: ToolingSource, _ package: MarketplacePackage) -> Bool {
        switch source.kind {
        case .localFolder, .gitRepository:
            package.sourceID == source.id
        case .claudeMarketplace:
            package.id.hasPrefix("claude:")
        case .openAIPluginDirectory:
            package.id.hasPrefix("codex:")
        case .mcpRegistry:
            package.id.hasPrefix("mcp-registry:")
        case .skillsShRegistry:
            package.id.hasPrefix("skills-sh:")
        case .agentPlugins, .geminiExtensionGallery:
            false
        }
    }

    func matchesSelectedSource(_ package: MarketplacePackage) -> Bool {
        guard let source = selectedSource else { return true }
        return matches(source, package)
    }

    /// A one-line inventory per source, so an empty component filter is
    /// explained by the catalog rather than looking like a failure.
    func contentsSummary(for source: ToolingSource) -> String? {
        let packages = session.packages.filter { matches(source, $0) }
        guard !packages.isEmpty else { return nil }
        let counts: [(String, Int)] = [
            ("skill", packages.filter { $0.components.contains(.skill) }.count),
            ("plugin", packages.filter { $0.components.contains(.plugin) }.count),
            ("MCP server", packages.filter { $0.components.contains(.mcpServer) }.count),
        ]
        let parts = counts.filter { $0.1 > 0 }.map { "\($0.1) \($0.0)\($0.1 == 1 ? "" : "s")" }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// Whether this workspace recorded the row, or the row is one of the
    /// catalogs every build knows about.
    ///
    /// A reference row's identity is derived from its kind, so it is exactly
    /// the one `MarketplaceCatalogs` would derive; anything else came from a
    /// record somebody added, and only those can be taken away.
    func isRecorded(_ source: ToolingSource) -> Bool {
        source.id != MarketplaceCatalogs.builtInSourceID(for: source.kind)
    }

    var sortedSources: [ToolingSource] {
        session.sources.sorted {
            let nameOrder = $0.name.localizedCaseInsensitiveCompare($1.name)
            return nameOrder == .orderedSame ? $0.id.uuidString < $1.id.uuidString : nameOrder == .orderedAscending
        }
    }

    /// What this Mac can defend about a listing, which is whether the workspace
    /// holds it. Installation is measured on the Apps screen and nowhere else,
    /// so no catalog's own claim about it reaches this line.
    func localState(for package: MarketplacePackage) -> String {
        guard let match = session.libraryMatch(for: package) else {
            return "Not in your library"
        }
        return "In your library as \(match.displayName); where it is installed is decided on Apps"
    }

    func symbol(for kind: SourceKind) -> String {
        switch kind {
        case .localFolder: "folder"
        case .gitRepository: "arrow.triangle.branch"
        case .claudeMarketplace, .openAIPluginDirectory, .geminiExtensionGallery: "storefront"
        case .agentPlugins: "puzzlepiece.extension"
        case .mcpRegistry: "network"
        case .skillsShRegistry: "sparkles"
        }
    }

    func canOpen(_ location: String) -> Bool {
        if MarketplaceLocation.webURL(from: location) != nil { return true }
        return FileManager.default.fileExists(atPath: location)
    }

    func open(_ location: String) {
        if let url = MarketplaceLocation.webURL(from: location) {
            NSWorkspace.shared.open(url)
        } else if FileManager.default.fileExists(atPath: location) {
            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: location)])
        }
    }
}

struct MarketplaceSourceRow: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let source: ToolingSource
    let symbol: String
    var contents: String?
    var selected = false
    /// Present only on a catalog this workspace recorded. The rows every build
    /// knows about are references, so there is nothing there to remove.
    var removal: RemoveCatalogSourceButton?
    var onSelect: (() -> Void)?

    var body: some View {
        HStack(alignment: .top, spacing: Space.lg) {
            Button {
                onSelect?()
            } label: {
                HStack(alignment: .top, spacing: Space.lg) {
                    SymbolTile(symbol: symbol, size: Size.discLarge)
                    VStack(alignment: .leading, spacing: Space.xxs) {
                        Text(source.name).font(AgentFont.bodySemibold).lineLimit(1)
                        if let contents {
                            Text(contents).font(AgentFont.caption).foregroundStyle(.secondary)
                                .lineLimit(3).fixedSize(horizontal: false, vertical: true)
                                .help(contents)
                        } else {
                            Text(source.kind.displayName).font(AgentFont.caption).foregroundStyle(.secondary)
                        }
                        Text(source.trustSummary).font(AgentFont.micro).foregroundStyle(.secondary)
                            .lineLimit(3).fixedSize(horizontal: false, vertical: true)
                            .help(source.trustSummary)
                        if source.isOptionalBackup {
                            Text("Optional Git source")
                                .font(AgentFont.micro)
                                .foregroundStyle(.secondary)
                        }
                    }
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .frame(maxWidth: .infinity)
            .help(selected ? "Show packages from every source" : "Show only packages from \(source.name)")
            .accessibilityLabel(source.name)
            .accessibilityValue(
                [
                    selected ? "Selected" : "",
                    contents ?? source.kind.displayName,
                    source.trustSummary,
                    source.isOptionalBackup ? "Optional Git source" : "",
                ]
                .filter { !$0.isEmpty }
                .joined(separator: ", ")
            )
            .accessibilityAddTraits(selected ? .isSelected : [])
            .accessibilityHint(selected ? "Shows every source again" : "Shows only packages from this source")

            // Where the source is, and — for a catalog this workspace recorded
            // rather than one every build knows — the one control that forgets
            // it.
            if !source.location.isEmpty {
                PathInfoButton(path: source.location)
            }
            if let removal { removal }
        }
        .padding(Space.lg)
        .background(
            RoundedRectangle.control
                .fill(selected ? AgentTheme.selection.opacity(0.14) : .clear)
        )
        .animation(reduceMotion ? nil : AgentMotion.quick, value: selected)
    }
}

private enum MarketplaceLocation {
    static func webURL(from value: String) -> URL? {
        guard let components = URLComponents(string: value),
            ["http", "https"].contains(components.scheme?.lowercased() ?? ""),
            components.host?.isEmpty == false,
            components.user == nil,
            components.password == nil,
            let url = components.url
        else { return nil }
        return url
    }
}

/// Purpose first, with app compatibility and a dated fact when sorting by recency.
struct MarketplaceGalleryCard: View {
    @Environment(\.hoverSuppressed) private var hoverSuppressed
    let package: MarketplacePackage
    let selected: Bool
    let detail: String?
    /// Whether the workspace already holds this package. Never a catalog's own
    /// claim: a listing does not get to say what is in your library.
    let inLibrary: Bool
    let compact: Bool
    let open: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: open) {
            HStack(alignment: .top, spacing: compact ? Space.lg : Space.xl) {
                ToolIdentityIcon(packageID: package.id, fallback: marketplaceKind(for: package), size: compact ? 36 : 44)
                VStack(alignment: .leading, spacing: Space.sm) {
                    HStack(alignment: .firstTextBaseline, spacing: Space.md) {
                        Text(package.presentationName).font(compact ? AgentFont.title : AgentFont.titleLarge).lineLimit(1)
                            .help(package.presentationName)
                        Spacer(minLength: 0)
                        if let installs = package.installCount {
                            Label(CompactCountFormatter.string(for: installs), systemImage: "arrow.down.circle")
                                .font(AgentFont.captionMedium.monospacedDigit())
                                .foregroundStyle(.secondary)
                                .labelStyle(.titleAndIcon)
                                .help("\(installs.formatted()) installs — reported by \(package.sourceName)")
                        }
                    }
                    Text(package.summary).font(compact ? AgentFont.body : AgentFont.titleRegular).foregroundStyle(.secondary)
                        .lineLimit(2).frame(maxWidth: .infinity, minHeight: 38, alignment: .topLeading)
                    HStack(spacing: Space.md) {
                        ForEach(cardComponents, id: \.self) { component in
                            Text(component.displayName)
                                .font(AgentFont.microSemibold)
                                .padding(.horizontal, Space.sm).padding(.vertical, Space.xxs)
                                .background(AgentTheme.fillHover, in: Capsule())
                                .foregroundStyle(.secondary)
                        }
                        if let category = package.category, !compact {
                            Text(category.capitalized)
                                .font(AgentFont.microMedium)
                                .padding(.horizontal, Space.sm).padding(.vertical, Space.xxs)
                                .background(AgentTheme.selection.opacity(0.10), in: Capsule())
                                .foregroundStyle(.secondary)
                                .help("Filed under \(category) by \(package.sourceName)")
                        }
                        Text(detail ?? "From \(package.originName)")
                            .font(AgentFont.caption).foregroundStyle(.secondary).lineLimit(1)
                        Spacer(minLength: 0)
                        ForEach(package.supportedClients.sorted { $0.rawValue < $1.rawValue }) { client in
                            ClientBrandIcon(client: client, size: Size.brandMark).help("Available for \(client.rawValue)")
                        }
                    }
                }
                Image(systemName: inLibrary ? "checkmark.circle" : "chevron.right")
                    .font(AgentFont.bodyMedium)
                    .foregroundStyle(.secondary)
                    .help(inLibrary ? "Already in your library; view details" : "View package details")
            }
            .padding(compact ? Space.lg : Space.xxl).frame(maxWidth: .infinity, minHeight: compact ? 116 : 138, alignment: .topLeading)
            // A standing card, not floating text: material at rest, a lift on
            // hover, and the accent stroke only when this listing is open.
            .background(hovering && !hoverSuppressed ? AgentTheme.fillHover : Color.clear, in: RoundedRectangle.card)
            .background(AgentTheme.panelBrightening, in: RoundedRectangle.card)
            .background(.thickMaterial, in: RoundedRectangle.card)
            .overlay(
                RoundedRectangle.card
                    .strokeBorder(
                        selected ? AgentTheme.selection.opacity(0.65) : AgentTheme.hairlineStroke,
                        lineWidth: selected ? 1.5 : 0.5)
            )
            .contentShape(RoundedRectangle.card)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .accessibilityLabel(accessibilitySummary)
        .accessibilityHint("Open package details and installation options")
    }

    /// The component chips a card has room for: every kind when there are a
    /// few, and never a truncated lie when there are many. In the compact
    /// side-by-side layout the client icons need the room more.
    private var cardComponents: [ComponentKind] {
        guard !compact else { return [] }
        let sorted = package.components.sorted { $0.displayName < $1.displayName }
        return sorted.count <= 3 ? sorted : []
    }

    private var accessibilitySummary: String {
        var parts = ["\(package.presentationName), from \(package.originName)"]
        if let installs = package.installCount {
            parts.append("\(installs.formatted()) installs reported by \(package.sourceName)")
        }
        return parts.joined(separator: ". ")
    }
}

/// `217637` shown as `217.6K` where a full number would not fit. Rounding is
/// display-only; the exact count stays in the help text beside it.
enum CompactCountFormatter {
    static func string(for count: Int) -> String {
        let magnitude = abs(count)
        switch magnitude {
        case ..<1_000: return "\(count)"
        case ..<1_000_000: return scaled(count, by: 1_000, suffix: "K")
        default: return scaled(count, by: 1_000_000, suffix: "M")
        }
    }

    private static func scaled(_ count: Int, by divisor: Double, suffix: String) -> String {
        let value = (Double(count) / divisor * 10).rounded() / 10
        let text = value == value.rounded() ? String(Int(value)) : String(format: "%.1f", value)
        return "\(text)\(suffix)"
    }
}

/// The identity kind a listing presents when it has no icon of its own: a
/// plugin, an MCP server, or a skill, and otherwise a plain source. Internal
/// so both the detail pane and the gallery card can fall back to it.
func marketplaceKind(for package: MarketplacePackage) -> ToolingKind {
    if package.components.contains(.plugin) { return .plugin }
    if package.components.contains(.mcpServer) { return .mcpServer }
    if package.components.contains(.skill) { return .skill }
    return .source
}
