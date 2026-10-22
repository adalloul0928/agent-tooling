import AgentToolingTestSupport
import Foundation
import Testing

@testable import AgentToolingCore

/// Has it never asks for a look first: an app that already holds exactly
/// what was asked for has nothing to show, so it is not one of the exclusions
/// a person must read before an install runs.
@Suite("Operation plan risk classifier · Has it")
struct OperationPlanRiskClassifierHasItTests {
    private let skill = ArtifactID(fixtureUUID("00000000-0000-0000-0000-000000000601"))

    @Test func anAppThatAlreadyHasItNeedsNoReview() {
        let plan = WorkspaceDeploymentPlan(items: [install()], exclusions: [hasIt()])
        #expect(OperationPlanRiskClassifier.classify(plan) == .direct)
        #expect(OperationPlanRiskClassifier.classify(WorkspaceDeploymentPlan(items: [], exclusions: [hasIt()])) == .direct)
    }

    @Test func anythingElseThatWillNotHappenStillCountsAndHasItIsLeftOut() {
        let unreachable = WorkspaceDeploymentExclusion(
            artifactID: skill, physicalDestinationID: nil, reason: .noDestination, detail: "Codex is not installed on this Mac.")
        let plan = WorkspaceDeploymentPlan(items: [install()], exclusions: [hasIt(), unreachable, hasIt()])
        #expect(OperationPlanRiskClassifier.classify(plan) == .needsReview([.exclusions(count: 1)]))
    }

    private func install() -> WorkspaceDeploymentItem {
        .init(
            artifactID: skill, displayName: "Release Notes", physicalDestinationID: WorkspaceObjectID(), surface: .codexCLI,
            scope: .user, logicalProjectID: nil,
            action: .installContent(digest: .init(algorithm: .sha256TreeV1, value: String(repeating: "a", count: 64))),
            desiredEnabled: nil, reasons: [.manual])
    }

    private func hasIt() -> WorkspaceDeploymentExclusion {
        .init(
            artifactID: skill, physicalDestinationID: WorkspaceObjectID(), reason: .alreadyPresent,
            detail: "This destination already holds the approved version.")
    }
}
