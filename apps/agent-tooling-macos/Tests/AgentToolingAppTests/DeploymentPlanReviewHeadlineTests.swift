import Testing

@testable import AgentToolingApp
@testable import AgentToolingCore

/// The one line at the top of the plan sheet that states what the review found.
/// Each part counts with the shared noun, so one of anything is singular, and
/// the verb agrees with its count: a single command step read "1 step run a
/// command".
@Suite("Plan review headline")
struct DeploymentPlanReviewHeadlineTests {
    private func key() -> WorkspaceDeploymentInstallKey {
        .init(artifactID: ArtifactID(), physicalDestinationID: WorkspaceObjectID())
    }

    @Test("Nothing found says nothing")
    func quietReviewHasNoHeadline() {
        #expect(DeploymentPlanReview().headline == nil)
    }

    @Test("One step that runs a command is singular, verb included")
    func oneCommand() {
        let review = DeploymentPlanReview(commands: [key(): "claude plugin install example"])
        #expect(review.headline == "1 step runs a command")
    }

    @Test("Several steps that run commands are plural, verb included")
    func severalCommands() {
        let review = DeploymentPlanReview(commands: [key(): "a", key(): "b"])
        #expect(review.headline == "2 steps run a command")
    }

    @Test("Each part is counted and the parts are joined in order")
    func everyPartCounted() {
        let incomplete = ContentRiskReport(findings: [], filesScanned: 0, coverageNotes: [], reachedScanLimit: true)
        let review = DeploymentPlanReview(
            contentRisks: [key(): incomplete],
            commands: [key(): "a"],
            withoutCommand: [key(): "No install command is recorded.", key(): "Not found."])
        #expect(review.headline == "1 package scan incomplete · 1 step runs a command · 2 steps cannot run yet")
    }
}
