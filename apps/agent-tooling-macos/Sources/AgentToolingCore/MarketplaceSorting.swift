import Foundation

/// The orders the Marketplace can actually justify. There is no "popular" or
/// "trending" here: the app observes no downloads, stars, or ratings, so it
/// offers no order that would imply it does.
public enum MarketplaceSortOrder: String, Codable, CaseIterable, Identifiable, Sendable {
    case relevance
    case name
    case recentlyUpdated

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .relevance: "Relevance"
        case .name: "Name"
        case .recentlyUpdated: "Recently updated"
        }
    }

    /// Exactly what the order is computed from, for the control's help text.
    public var measurement: String {
        switch self {
        case .relevance:
            "Ranks how closely the search term matches the package name, then its publisher, summary, and components. Without a search term this is name order."
        case .name:
            "Sorts by package name, ignoring case."
        case .recentlyUpdated:
            "Sorts by the update date the catalog published, or for a local package the newest file change on this Mac. Listings that publish no date sort last."
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

    private static func byName(_ lhs: MarketplacePackage, _ rhs: MarketplacePackage) -> Bool {
        let order = lhs.name.localizedCaseInsensitiveCompare(rhs.name)
        if order != .orderedSame { return order == .orderedAscending }
        return lhs.id < rhs.id
    }
}
