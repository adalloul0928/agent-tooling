import Foundation

extension String {
    /// The first letter capitalised, the rest left as written.
    var capitalizedFirst: String {
        guard let first else { return self }
        return first.uppercased() + dropFirst()
    }
}

/// A thing the app counts, by the name the app gives it everywhere, with the
/// plural that goes with it. One noun per thing keeps a count from saying
/// "servers" on one screen and "connections" on the next, and keeps "1 skills"
/// from happening at all.
struct CountNoun: Equatable {
    let singular: String
    let plural: String

    /// A noun whose plural adds an "s", unless `plural` says otherwise
    /// ("copy", "copies").
    init(_ singular: String, plural: String? = nil) {
        self.singular = singular
        self.plural = plural ?? singular + "s"
    }

    static let skill = CountNoun("skill")
    static let plugin = CountNoun("plugin")
    static let connection = CountNoun("connection")
    static let change = CountNoun("change")

    /// The noun that agrees with `count`: the singular for exactly one, the
    /// plural for anything else, zero included.
    func word(for count: Int) -> String {
        count == 1 ? singular : plural
    }

    /// The count and its noun: "1 connection", "2 connections", "0 connections".
    func phrase(_ count: Int) -> String {
        "\(count) \(word(for: count))"
    }
}
