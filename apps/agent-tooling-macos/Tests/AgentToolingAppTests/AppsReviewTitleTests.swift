import Testing

@testable import AgentToolingApp
@testable import AgentToolingCore

/// The title of the Apps screen's review buttons. Both open one sheet, and it
/// applies the whole plan. On a page narrowed to one app the buttons counted
/// that app's changes alone, so "Review 2 changes…" opened a sheet that
/// applied three; now they count the whole plan and say "all" when it reaches
/// past the page's app.
@Suite("Apps review title")
@MainActor
struct AppsReviewTitleTests {
    private func step(in surface: TargetSurface) -> WorkspaceDeploymentItem {
        WorkspaceDeploymentItem(
            artifactID: ArtifactID(),
            displayName: "Example",
            physicalDestinationID: WorkspaceObjectID(),
            surface: surface,
            scope: .user,
            logicalProjectID: nil,
            action: .installContent(digest: ContentDigest(value: "a")),
            desiredEnabled: nil,
            reasons: [.manual]
        )
    }

    private var plan: WorkspaceDeploymentPlan {
        WorkspaceDeploymentPlan(
            items: [step(in: .claudeCode), step(in: .claudeCode), step(in: .codexCLI)], exclusions: [])
    }

    @Test("A page for one app counts every change the sheet applies, and says all")
    func onePageCountsTheWholePlan() {
        #expect(SyncCenterView.reviewTitle(for: plan, scopedTo: .claude) == "Review all 3 changes…")
        #expect(SyncCenterView.reviewTitle(for: plan, scopedTo: .codex) == "Review all 3 changes…")
        // An app with nothing of its own waiting still opens the whole plan.
        #expect(SyncCenterView.reviewTitle(for: plan, scopedTo: .gemini) == "Review all 3 changes…")
    }

    @Test("A page whose app holds the whole plan counts it without all")
    func onePageHoldingTheWholePlan() {
        let mine = WorkspaceDeploymentPlan(items: [step(in: .claudeCode), step(in: .claudeCode)], exclusions: [])
        #expect(SyncCenterView.reviewTitle(for: mine, scopedTo: .claude) == "Review 2 changes…")
    }

    @Test("One change elsewhere reads as one change, not all of one")
    func oneChangeElsewhere() {
        let theirs = WorkspaceDeploymentPlan(items: [step(in: .codexCLI)], exclusions: [])
        #expect(SyncCenterView.reviewTitle(for: theirs, scopedTo: .claude) == "Review 1 change…")
    }

    @Test("Every app's page counts every app's changes")
    func everyAppCountsTheWholePlan() {
        #expect(SyncCenterView.reviewTitle(for: plan, scopedTo: nil) == "Review 3 changes…")
    }

    @Test("No plan yet, or an empty one, reads as the plain title")
    func nothingToCountReadsPlain() {
        let empty = WorkspaceDeploymentPlan(items: [], exclusions: [])
        #expect(SyncCenterView.reviewTitle(for: nil, scopedTo: .claude) == ActionTitles.reviewChanges(count: nil))
        #expect(SyncCenterView.reviewTitle(for: empty, scopedTo: .claude) == ActionTitles.reviewChanges(count: nil))
        #expect(SyncCenterView.reviewTitle(for: empty, scopedTo: nil) == ActionTitles.reviewChanges(count: nil))
    }
}
