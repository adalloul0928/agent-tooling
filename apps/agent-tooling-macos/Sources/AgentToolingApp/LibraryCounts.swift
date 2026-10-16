/// How many skills, plugins and connections something holds, in the Library's
/// own nouns and in the order its tabs list them.
///
/// An app's holdings are counted on its Apps tile and page, in the setup
/// wizard and Checkup, and on another Mac's sheet. Each of those joined the
/// three counts by hand, two of them in a different order, so one Claude Code
/// read "17 skills · 8 connections · 5 plugins" on its tile and "17 skills · 5
/// plugins · 8 connections" in the wizard. This is the one order.
struct LibraryCounts: Equatable {
    let skills: Int
    let plugins: Int
    let connections: Int

    /// Each count with its noun, singular for one: "17 skills", "0 plugins",
    /// "1 connection". A zero is part of what a check found, so it is said.
    var phrases: [String] {
        [
            CountNoun.skill.phrase(skills),
            CountNoun.plugin.phrase(plugins),
            CountNoun.connection.phrase(connections),
        ]
    }

    /// The same counts on one line: "17 skills · 5 plugins · 8 connections".
    var summary: String { phrases.joined(separator: " · ") }
}
