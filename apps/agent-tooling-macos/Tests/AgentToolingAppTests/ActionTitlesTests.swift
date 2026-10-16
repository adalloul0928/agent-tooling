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

    @Test("A whole plan reviewed from one app's page says all of it")
    func allChanges() {
        #expect(ActionTitles.reviewAllChanges(count: 3) == "Review all 3 changes…")
        #expect(ActionTitles.reviewAllChanges(count: 2) == "Review all 2 changes…")
        // "All 1 change" says nothing "1 change" does not.
        #expect(ActionTitles.reviewAllChanges(count: 1) == ActionTitles.reviewChanges(count: 1))
        #expect(ActionTitles.reviewAllChanges(count: 0) == ActionTitles.reviewChanges(count: nil))
    }

    @Test("Menus title-case the command; the palette uses the window's sentence case")
    func commandTitles() {
        #expect(ActionTitles.reviewChangesCommand(.menu) == "Review Changes…")
        #expect(ActionTitles.reviewChangesCommand(.palette) == "Review changes…")
        // The palette names the same review the window's button does.
        #expect(ActionTitles.reviewChangesCommand(.palette) == ActionTitles.reviewChanges(count: nil))
    }

    /// The one read of this Mac's apps was "Check Setup" in the menus and the
    /// palette and "Check apps" on Apps. Setup is what Checkup audits.
    @Test("Reading the apps again has one name, title-cased only in menus")
    func checkAppsHasOneName() {
        #expect(ActionTitles.checkApps == "Check apps")
        #expect(ActionTitles.checkAppsCommand(.palette) == ActionTitles.checkApps)
        #expect(ActionTitles.checkAppsCommand(.menu) == "Check Apps")
        #expect(ActionTitles.checkingAppsMenu == "Checking Apps…")
        // It reads and changes nothing, so it opens nothing and takes no ellipsis.
        for title in [ActionTitles.checkApps, ActionTitles.checkAppsCommand(.menu)] {
            #expect(!title.hasSuffix("\u{2026}"), "\(title) ends in an ellipsis")
            #expect(!title.localizedCaseInsensitiveContains("setup"), "\(title) names setup")
        }
    }

    @Test("Creating a skill names the assistant that writes the draft")
    func createSkillNamesTheAssistant() {
        #expect(ActionTitles.createSkill(with: .claude) == "Create with Claude Code…")
        #expect(ActionTitles.createSkill(with: .codex) == "Create with Codex…")
    }

    @Test("Every title ends in the one-character ellipsis, because each opens a sheet")
    func titlesEndInEllipsis() {
        let titles =
            [nil, 0, 1, 3].map { ActionTitles.reviewChanges(count: $0) }
            + [1, 3].map { ActionTitles.reviewAllChanges(count: $0) }
            + [ActionTitles.reviewChangesCommand(.menu), ActionTitles.reviewChangesCommand(.palette)]
            + [ActionTitles.createSkill(with: .claude)]
        for title in titles {
            #expect(title.hasSuffix("\u{2026}"), "\(title) does not end in an ellipsis")
            #expect(!title.hasSuffix("..."), "\(title) ends in three full stops")
        }
    }
}
