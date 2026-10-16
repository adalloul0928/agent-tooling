import Testing

@testable import AgentToolingApp
@testable import AgentToolingCore

/// The title of the Apps screen's review buttons. On a page narrowed to one app
/// the toolbar counted every app's changes, while the line under the title and
/// the changes card counted that app's alone, so one page showed two counts for
/// one plan.
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

    @Test("A page for one app counts that app's changes")
    func onePageCountsItsOwnApp() {
        #expect(SyncCenterView.reviewTitle(for: plan, scopedTo: .claude) == "Review 2 changes…")
        #expect(SyncCenterView.reviewTitle(for: plan, scopedTo: .codex) == "Review 1 change…")
    }

    @Test("Every app's page counts every app's changes")
    func everyAppCountsTheWholePlan() {
        #expect(SyncCenterView.reviewTitle(for: plan, scopedTo: nil) == "Review 3 changes…")
    }

    @Test("Nothing for this app, or no plan yet, reads as the plain title")
    func nothingToCountReadsPlain() {
        #expect(SyncCenterView.reviewTitle(for: plan, scopedTo: .gemini) == ActionTitles.reviewChanges(count: nil))
        #expect(SyncCenterView.reviewTitle(for: nil, scopedTo: .claude) == ActionTitles.reviewChanges(count: nil))
    }
}
