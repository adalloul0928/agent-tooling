import Foundation
import Testing

@testable import AgentToolingCore

private struct Candidate: PaletteSearchable {
    var paletteTitle: String
    var paletteSubtitle: String = ""
    var paletteKeywords: [String] = []
    var palettePriority: Int = 0
}

@Suite("Command palette matching")
struct CommandPaletteMatcherTests {
    @Test("Ranks an exact name above a prefix, a word, and a loose match")
    func ranksByHowDirectlyTheNameMatches() {
        let ranked = CommandPaletteMatcher.rank(
            [
                Candidate(paletteTitle: "Sync Center"),
                Candidate(paletteTitle: "sentry"),
                Candidate(paletteTitle: "Sentry Releases"),
                Candidate(paletteTitle: "Local sentry mirror"),
            ],
            query: "sentry"
        )

        #expect(ranked.map(\.paletteTitle) == ["sentry", "Sentry Releases", "Local sentry mirror"])
    }

    @Test("Finds items by subtitle, keyword, and a typed subsequence")
    func findsItemsBeyondTheName() {
        #expect(CommandPaletteMatcher.score(query: "mcp", title: "linear", subtitle: "MCP server · This Mac") != nil)
        #expect(CommandPaletteMatcher.score(query: "doctor", title: "Check Setup", keywords: ["doctor", "scan"]) != nil)
        #expect(CommandPaletteMatcher.score(query: "rlnts", title: "Release Notes") != nil)
        #expect(CommandPaletteMatcher.score(query: "zzz", title: "Release Notes") == nil)
    }

    @Test("Keeps actions above objects when the text match is equal")
    func breaksTiesWithPriority() {
        let ranked = CommandPaletteMatcher.rank(
            [
                Candidate(paletteTitle: "Check Setup", palettePriority: 0),
                Candidate(paletteTitle: "Check Setup", paletteSubtitle: "Action", palettePriority: 10),
            ],
            query: "check setup"
        )

        #expect(ranked.first?.paletteSubtitle == "Action")
    }

    @Test("An empty query keeps every candidate, and a long query is bounded")
    func handlesEmptyAndOversizedQueries() {
        let candidates = [Candidate(paletteTitle: "Skills"), Candidate(paletteTitle: "Plugins")]

        #expect(CommandPaletteMatcher.rank(candidates, query: "  ").count == 2)
        #expect(CommandPaletteMatcher.rank(candidates, query: "skills", limit: 1).count == 1)
        let oversized = String(repeating: "s", count: CommandPaletteMatcher.maximumQueryLength + 40)
        #expect(CommandPaletteMatcher.normalized(oversized).count == CommandPaletteMatcher.maximumQueryLength)
    }
}
