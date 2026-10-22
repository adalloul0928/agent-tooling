import Foundation

/// Extracts the first digit- or v-digit-prefixed version token for display,
/// retaining prerelease suffixes. Observations and capability comparisons keep
/// the raw output so recorded evidence continues to match.
public enum ClientVersionText {
    /// `"codex-cli 0.164.0"` → `"0.164.0"`, `"2.1.304 (Claude Code)"` →
    /// `"2.1.304"`, `"v1.2.3"` → `"1.2.3"`; `"nightly"` and nil → nil.
    public static func number(in line: String?) -> String? {
        guard let line else { return nil }
        let separators = CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "/@,;"))
        for word in line.components(separatedBy: separators) {
            if let number = number(inWord: word) { return number }
        }
        return nil
    }

    /// The dotted numbers of a version, stopping at the first part that does
    /// not start with a digit, and after the first part that carries a
    /// suffix: `0.144.0-alpha.4` reads as `[0, 144, 0]`, so a pre-release is
    /// never counted as older than the release it leads to. Nil when the text
    /// does not start with a number.
    static func numericComponents(of number: String) -> [Int]? {
        var values: [Int] = []
        for part in number.split(separator: ".", omittingEmptySubsequences: false) {
            let digits = part.prefix { $0.isASCII && $0.isNumber }
            guard !digits.isEmpty, let value = Int(digits) else { break }
            values.append(value)
            if digits.count < part.count { break }
        }
        return values.isEmpty ? nil : values
    }

    /// Orders two versions by their numbers, a missing part counting as 0.
    /// Nil when either has no number to compare.
    static func compare(_ lhs: String, _ rhs: String) -> ComparisonResult? {
        guard let left = numericComponents(of: lhs), let right = numericComponents(of: rhs) else { return nil }
        for index in 0..<max(left.count, right.count) {
            let one = index < left.count ? left[index] : 0
            let other = index < right.count ? right[index] : 0
            if one != other { return one < other ? .orderedAscending : .orderedDescending }
        }
        return .orderedSame
    }

    private static func number(inWord word: String) -> String? {
        let edges = CharacterSet(charactersIn: "()[]{}<>\"'`:.")
        var trimmed = word.trimmingCharacters(in: edges)
        if let first = trimmed.first, first == "v" || first == "V",
            let second = trimmed.dropFirst().first, second.isASCII, second.isNumber
        {
            trimmed.removeFirst()
        }
        guard let first = trimmed.first, first.isASCII, first.isNumber else { return nil }
        return trimmed
    }
}
