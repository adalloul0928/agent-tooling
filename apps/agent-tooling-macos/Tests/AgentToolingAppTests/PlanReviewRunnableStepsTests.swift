import Testing

@testable import AgentToolingApp
@testable import AgentToolingCore

/// The plan sheet's button counts the steps that will run and takes its verb
/// from the same steps. A step no command could be built for is listed, marked
/// as not running, and decides neither the count nor the verb.
@Suite("Plan review runnable steps")
struct PlanReviewRunnableStepsTests {
    private let digest = ContentDigest(value: "a")

    private func item(_ action: WorkspaceDeploymentAction) -> WorkspaceDeploymentItem {
        WorkspaceDeploymentItem(
            artifactID: ArtifactID(),
            displayName: "Example",
            physicalDestinationID: WorkspaceObjectID(),
            surface: .claudeCode,
            scope: .user,
            logicalProjectID: nil,
            action: action,
            desiredEnabled: nil,
            reasons: [.manual]
        )
    }

    private func key(_ item: WorkspaceDeploymentItem) -> WorkspaceDeploymentInstallKey {
        .init(artifactID: item.artifactID, physicalDestinationID: item.physicalDestinationID)
    }

    /// What the sheet derives its button from.
    private func buttonLabel(_ items: [WorkspaceDeploymentItem], review: DeploymentPlanReview) -> String {
        let runnable = review.runnableSteps(of: items)
        return PlanReviewLabels.actionLabel(
            listedCount: items.count, runnableCount: runnable.count,
            hasRemoval: runnable.contains(where: \.isRemoval))
    }

    @Test("Only a removal step is a removal")
    func onlyRemovalsRemove() {
        #expect(item(.removeContent(installed: digest)).isRemoval)
        #expect(!item(.installContent(digest: digest)).isRemoval)
        #expect(!item(.updateContent(from: nil, to: digest)).isRemoval)
        #expect(!item(.updateContent(from: digest, to: digest)).isRemoval)
        #expect(!item(.installNativePackage(route: .init(client: .claude, externalPluginID: "x"))).isRemoval)
        #expect(!item(.configureManagedConnection(transport: .http)).isRemoval)
    }

    @Test("A step no command could be built for does not run")
    func stepsWithoutACommandAreLeftOut() {
        let package = item(.installNativePackage(route: .init(client: .claude, externalPluginID: "x")))
        let removal = item(.removeContent(installed: digest))
        let install = item(.installContent(digest: digest))
        let review = DeploymentPlanReview(withoutCommand: [key(package): "No install command is recorded."])

        #expect(review.runnableSteps(of: [package, removal, install]) == [removal, install])
        #expect(DeploymentPlanReview().runnableSteps(of: [package, removal]) == [package, removal])
    }

    @Test("The button counts and words only the steps that will run")
    func buttonFollowsRunnableSteps() {
        let package = item(.installNativePackage(route: .init(client: .claude, externalPluginID: "x")))
        let removal = item(.removeContent(installed: digest))
        let install = item(.installContent(digest: digest))
        let review = DeploymentPlanReview(withoutCommand: [key(package): "No install command is recorded."])

        #expect(buttonLabel([package, install], review: review) == "Install 1 change")
        #expect(buttonLabel([package, removal, install], review: review) == "Apply 2 changes")
        #expect(buttonLabel([package], review: review) == "Nothing can run yet")
    }
}
