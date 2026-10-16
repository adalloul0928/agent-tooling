import Testing

@testable import AgentToolingApp

/// Pins the words for opening the plan review. The bug these guard against: a
/// prepared plan with nothing in it read "Review 0 changes…" on Home and Apps,
/// because only a missing plan fell back to the plain title.
@Suite("Action titles")
struct ActionTitlesTests {
    @Test("No plan, and a plan with nothing in it, both read as the plain title")
    func noChangesReadsPlain() {
        #expect(ActionTitles.reviewChanges(count: nil) == "Review changes…")
        #expect(ActionTitles.reviewChanges(count: 0) == "Review changes…")
    }

    @Test("One change is singular")
    func oneChange() {
        #expect(ActionTitles.reviewChanges(count: 1) == "Review 1 change…")
    }

    @Test("More than one change is counted in the plural")
    func severalChanges() {
        #expect(ActionTitles.reviewChanges(count: 2) == "Review 2 changes…")
        #expect(ActionTitles.reviewChanges(count: 12) == "Review 12 changes…")
    }

    @Test("A count below zero never reaches the title")
    func negativeCountReadsPlain() {
        #expect(ActionTitles.reviewChanges(count: -1) == "Review changes…")
    }

    @Test("Menus title-case the command; the palette uses the window's sentence case")
    func commandTitles() {
        #expect(ActionTitles.reviewChangesCommand(.menu) == "Review Changes…")
        #expect(ActionTitles.reviewChangesCommand(.palette) == "Review changes…")
        // The palette names the same review the window's button does.
        #expect(ActionTitles.reviewChangesCommand(.palette) == ActionTitles.reviewChanges(count: nil))
    }

    @Test("Every title ends in the one-character ellipsis, because each opens a sheet")
    func titlesEndInEllipsis() {
        let titles =
            [nil, 0, 1, 3].map { ActionTitles.reviewChanges(count: $0) }
            + [ActionTitles.reviewChangesCommand(.menu), ActionTitles.reviewChangesCommand(.palette)]
        for title in titles {
            #expect(title.hasSuffix("\u{2026}"), "\(title) does not end in an ellipsis")
            #expect(!title.hasSuffix("..."), "\(title) ends in three full stops")
        }
    }
}
