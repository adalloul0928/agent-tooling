import Foundation

/// The orders the Marketplace can actually justify. "Most installed" exists
/// only because skills.sh publishes install counts on its listings; the order
/// sorts by that published number and never by anything this app pretends to
/// have measured. There is still no "trending": the app observes no stars,
/// ratings, or download velocity, so it offers no order that would imply it does.
public enum MarketplaceSortOrder: String, Codable, CaseIterable, Identifiable, Sendable {
    case relevance
    case name
    case recentlyUpdated
    case installs

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .relevance: "Relevance"
        case .name: "Name"
        case .recentlyUpdated: "Recently updated"
        case .installs: "Most installed"
        }
    }

    /// Exactly what the order is computed from, for the control's help text.
    public var measurement: String {
        switch self {
        case .relevance:
            "Ranks how closely the search term matches the package name, then its publisher, summary, and components. Without a search term this is name order."
        case .name:
            "Sorts by the display name shown on the card, ignoring case. A reverse-DNS registry name sorts by its short last segment, so a listing is ordered by the words a person reads rather than by its publisher's domain."
        case .recentlyUpdated:
            "Sorts by the update date the catalog published, or for a local package the newest file change on this Mac. Listings that publish no date sort last."
        case .installs:
            "Sorts by the install count the catalog published for the listing (skills.sh reports one). Listings whose catalog publishes no count sort last."
        }
    }
}

/// A total, stable ordering for every sort. Ties always fall through to the
/// name and then the identifier, so the same input always produces the same
/// list and paging never drops or repeats a package.
public enum MarketplaceSorting {
    public static func sorted(
        _ packages: [MarketplacePackage],
        by order: MarketplaceSortOrder,
        searchTerm: String? = nil
    ) -> [MarketplacePackage] {
        let term = searchTerm?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        switch order {
        case .name:
            return packages.sorted(by: byName)
        case .relevance:
            guard !term.isEmpty else { return packages.sorted(by: byName) }
            let scores = Dictionary(
                packages.map { ($0.id, relevanceScore($0, searchTerm: term)) },
                uniquingKeysWith: { first, _ in first }
            )
            return packages.sorted { lhs, rhs in
                let lhsScore = scores[lhs.id] ?? 0
                let rhsScore = scores[rhs.id] ?? 0
                if lhsScore != rhsScore { return lhsScore > rhsScore }
                return byName(lhs, rhs)
            }
        case .recentlyUpdated:
            return packages.sorted { lhs, rhs in
                switch (lhs.lastUpdate?.date, rhs.lastUpdate?.date) {
                case (let lhsDate?, let rhsDate?):
                    if lhsDate != rhsDate { return lhsDate > rhsDate }
                    return byName(lhs, rhs)
                case (nil, .some): return false
                case (.some, nil): return true
                case (nil, nil): return byName(lhs, rhs)
                }
            }
        case .installs:
            return packages.sorted { lhs, rhs in
                switch (lhs.installCount, rhs.installCount) {
                case (let lhsCount?, let rhsCount?):
                    if lhsCount != rhsCount { return lhsCount > rhsCount }
                    return byName(lhs, rhs)
                case (nil, .some): return false
                case (.some, nil): return true
                case (nil, nil): return byName(lhs, rhs)
                }
            }
        }
    }

    /// Higher is a closer match. Only fields the listing actually carries are
    /// scored, and every component of the score is a plain substring test a
    /// person could repeat by hand.
    public static func relevanceScore(_ package: MarketplacePackage, searchTerm: String) -> Int {
        let term = searchTerm.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !term.isEmpty else { return 0 }
        let name = package.name.lowercased()
        let shortName = name.split(separator: "/").last.map(String.init) ?? name
        var score = 0

        if name == term {
            score += 100
        } else if shortName == term {
            score += 90
        } else if name.hasPrefix(term) || shortName.hasPrefix(term) {
            score += 70
        } else if name.contains(term) {
            score += 50
        }

        let publisher = package.publisher.lowercased()
        if publisher == term {
            score += 30
        } else if publisher.contains(term) {
            score += 18
        }

        if package.summary.lowercased().contains(term) { score += 12 }
        if package.components.contains(where: { $0.displayName.lowercased().contains(term) }) { score += 6 }
        if package.sourceName.lowercased().contains(term) { score += 4 }
        return score
    }

    /// The words a person reads on the card, which is what a name sort should
    /// order by. A reverse-DNS registry name such as `ac.inference.sh/mcp` is
    /// shown and ordered by its last segment, `mcp`, so listings sort by their
    /// human-facing label rather than by their publisher's domain. Anything
    /// without that shape is its own display name.
    public static func displayName(for package: MarketplacePackage) -> String {
        let name = package.name
        guard let slash = name.lastIndex(of: "/") else { return name }
        let tail = name[name.index(after: slash)...]
        return tail.isEmpty ? name : String(tail)
    }

    /// Orders by the display name first, then by the full name, then by the
    /// identifier, so the result is total and stable: two listings whose short
    /// names collide still fall through to a fixed order.
    private static func byName(_ lhs: MarketplacePackage, _ rhs: MarketplacePackage) -> Bool {
        let displayOrder = displayName(for: lhs).localizedCaseInsensitiveCompare(displayName(for: rhs))
        if displayOrder != .orderedSame { return displayOrder == .orderedAscending }
        let nameOrder = lhs.name.localizedCaseInsensitiveCompare(rhs.name)
        if nameOrder != .orderedSame { return nameOrder == .orderedAscending }
        return lhs.id < rhs.id
    }
}
