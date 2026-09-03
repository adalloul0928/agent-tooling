import Foundation

/// Anything the one palette can find: a named object on a screen, or an action.
public protocol PaletteSearchable {
    var paletteTitle: String { get }
    var paletteSubtitle: String { get }
    var paletteKeywords: [String] { get }
    /// Ranking tiebreaker for equal text matches, highest first. Actions sit
    /// above objects so typing "check" reaches Check Setup before a receipt.
    var palettePriority: Int { get }
}

extension PaletteSearchable {
    public var paletteSubtitle: String { "" }
    public var paletteKeywords: [String] { [] }
    public var palettePriority: Int { 0 }
}

/// Ranks palette candidates against a typed query. Matching is text only: it
/// reads names the app already holds and never resolves or fetches anything.
public enum CommandPaletteMatcher {
    public static let maximumQueryLength = 128

    public static func score(query: String, title: String, subtitle: String = "", keywords: [String] = []) -> Int? {
        let needle = normalized(query)
        guard !needle.isEmpty else { return 1 }
        let haystack = title.lowercased()
        if haystack == needle { return 1_000 }
        if haystack.hasPrefix(needle) { return 800 }
        if haystack.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).contains(where: { $0.hasPrefix(needle) }) { return 650 }
        if haystack.contains(needle) { return 500 }
        if keywords.contains(where: { $0.lowercased().contains(needle) }) { return 400 }
        if subtitle.lowercased().contains(needle) { return 300 }
        if isSubsequence(needle, of: haystack) { return 200 }
        return nil
    }

    public static func rank<Item: PaletteSearchable>(_ items: [Item], query: String, limit: Int = 40) -> [Item] {
        let scored = items.compactMap { item -> (Item, Int)? in
            guard
                let score = score(
                    query: query,
                    title: item.paletteTitle,
                    subtitle: item.paletteSubtitle,
                    keywords: item.paletteKeywords
                )
            else { return nil }
            return (item, score)
        }
        return
            scored
            .sorted { lhs, rhs in
                if lhs.1 != rhs.1 { return lhs.1 > rhs.1 }
                if lhs.0.palettePriority != rhs.0.palettePriority { return lhs.0.palettePriority > rhs.0.palettePriority }
                if lhs.0.paletteTitle.count != rhs.0.paletteTitle.count { return lhs.0.paletteTitle.count < rhs.0.paletteTitle.count }
                return lhs.0.paletteTitle.localizedCaseInsensitiveCompare(rhs.0.paletteTitle) == .orderedAscending
            }
            .prefix(limit)
            .map(\.0)
    }

    static func normalized(_ query: String) -> String {
        String(query.trimmingCharacters(in: .whitespacesAndNewlines).prefix(maximumQueryLength)).lowercased()
    }

    private static func isSubsequence(_ needle: String, of haystack: String) -> Bool {
        var remaining = Substring(haystack)
        for character in needle {
            guard let index = remaining.firstIndex(of: character) else { return false }
            remaining = remaining[remaining.index(after: index)...]
        }
        return true
    }
}
