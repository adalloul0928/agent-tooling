import AgentToolingCore

/// How many skills, plugins and connections something holds, in the Library's
/// own nouns and in the order its tabs list them.
///
/// An app's holdings are counted on its Apps tile and page, on the setup
/// stage, on Checkup, and on another Mac's sheet. Each of those once joined
/// the three counts by hand, two of them in a different order, so one Claude
/// Code read "17 skills · 8 connections · 5 plugins" on its tile and "17
/// skills · 5 plugins · 8 connections" in the old setup wizard. This is the
/// one order.
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

extension LibraryCounts {
    /// Counts a list of library kinds, a plugin's bundled tools for instance.
    /// A kind that is none of the three is not counted here.
    init(kinds: [ArtifactKind]) {
        self.init(
            skills: kinds.count { $0 == .skill },
            plugins: kinds.count { $0 == .nativePlugin || $0 == .package },
            connections: kinds.count { $0 == .mcpServer })
    }

    /// Only the counts above zero, in the same order: "2 skills", "1
    /// connection". For what something contains, where a kind it has none of
    /// is not worth a word.
    var presentPhrases: [String] {
        zip([skills, plugins, connections], phrases).filter { $0.0 > 0 }.map(\.1)
    }
}

extension WorkspaceLibraryReadModel {
    /// What the library holds, in a sentence: "It holds 11 tools. 3 of them
    /// come inside plugins." Setup says it when the library is first read,
    /// and again on Done.
    var holdingsSentence: String {
        let nested = nestedToolCount
        let holds = "It holds \(CountNoun("tool").phrase(toolCount))."
        guard nested > 0 else { return holds }
        return nested == 1
            ? "\(holds) One of them comes inside a plugin."
            : "\(holds) \(nested) of them come inside plugins."
    }
}

extension WorkspaceLibraryReadModelRow {
    /// What a plugin bundles, by kind, in the Library's nouns and order:
    /// "Includes 2 skills · 1 connection". Nil when it bundles nothing.
    ///
    /// The install sheet, a project's Plugins tab and the old onboarding each
    /// counted the same children their own way, "3 bundled items", "3 tools"
    /// and this breakdown, and "tools" is also what a connection's own tools
    /// are called. Anything bundled that is none of the Library's three kinds
    /// is still counted, as an item.
    var includedSummary: String? {
        guard !includedChildren.isEmpty else { return nil }
        let kinds = includedChildren.map(\.kind)
        let counts = LibraryCounts(kinds: kinds)
        let others = kinds.count - counts.skills - counts.plugins - counts.connections
        let parts = counts.presentPhrases + (others > 0 ? [CountNoun("item").phrase(others)] : [])
        return "Includes " + parts.joined(separator: " · ")
    }
}
