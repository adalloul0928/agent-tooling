import Foundation
import Testing

@testable import AgentToolingCore

/// Whether a plan runs from the button that made it or is shown first. Every
/// kind of step and every reason for showing a plan has a case here, because
/// the decision is what stands between one click and the review sheet.
@Suite("Operation plan risk classifier")
struct OperationPlanRiskClassifierTests {
    private let destination = WorkspaceObjectID()
    private let other = WorkspaceObjectID()
    private let skill = ArtifactID()

    @Test func anInstallWhereNothingIsRunsDirectly() {
        let plan = plan([item(.installContent(digest: digest("a")))])
        #expect(OperationPlanRiskClassifier.classify(plan) == .direct)
    }

    @Test func replacingOurOwnInstallIsAnUpdateAndRunsDirectly() {
        let plan = plan([item(.updateContent(from: digest("b"), to: digest("a")))])
        let context = OperationPlanRiskClassifier.Context(provenInstalls: [key()])
        #expect(OperationPlanRiskClassifier.classify(plan, context: context) == .direct)
    }

    @Test func replacingFilesWeCannotProveWePutThereNeedsReview() {
        let plan = plan([item(.updateContent(from: nil, to: digest("a")))])
        let verdict = OperationPlanRiskClassifier.classify(plan)
        #expect(verdict == .needsReview([.replacesUnprovenContent(count: 1)]))
        #expect(verdict.reasons.first?.summary == "1 step replaces files Agent Tooling did not put there.")
    }

    @Test func replacingACopySomebodyEditedSinceWeInstalledItNeedsReview() {
        let plan = plan([item(.updateContent(from: digest("e"), to: digest("a")))])
        let context = OperationPlanRiskClassifier.Context(provenInstalls: [key()], editedInstalls: [key()])
        let verdict = OperationPlanRiskClassifier.classify(plan, context: context)
        #expect(verdict == .needsReview([.replacesEditedCopies(count: 1)]))
        #expect(verdict.reasons.first?.summary == "1 step replaces a copy that was edited after Agent Tooling installed it.")
        // An edit only counts on a copy we can prove is ours; otherwise it is
        // the stronger reason, once.
        let unproven = OperationPlanRiskClassifier.Context(editedInstalls: [key()])
        #expect(OperationPlanRiskClassifier.classify(plan, context: unproven) == .needsReview([.replacesUnprovenContent(count: 1)]))
    }

    @Test func anyRemovalNeedsReview() {
        let plan = plan([
            item(.installContent(digest: digest("a"))),
            item(.removeContent(installed: digest("b")), artifact: ArtifactID()),
        ])
        #expect(OperationPlanRiskClassifier.classify(plan) == .needsReview([.removesContent(count: 1)]))
    }

    @Test func addingAConnectionAnAppDoesNotHaveRunsDirectly() {
        let plan = plan([item(.configureManagedConnection(transport: .stdio))])
        #expect(OperationPlanRiskClassifier.classify(plan) == .direct)
    }

    @Test func changingAConnectionAnAppAlreadyHasNeedsReview() {
        let plan = plan([item(.configureManagedConnection(transport: .http))])
        let context = OperationPlanRiskClassifier.Context(configuredConnections: [key()])
        #expect(OperationPlanRiskClassifier.classify(plan, context: context)
            == .needsReview([.reconfiguresConnection(count: 1)]))
    }

    @Test func handingAPackageToTheAppsOwnInstallerRunsDirectly() {
        let route = NativePackageRoute(client: .codex, externalPluginID: "browser")
        let plan = plan([item(.installNativePackage(route: route))])
        #expect(OperationPlanRiskClassifier.classify(plan) == .direct)
    }

    @Test func flaggedContentNeedsReviewAndLeadsTheReasons() {
        let plan = plan([item(.updateContent(from: nil, to: digest("a")))])
        let context = OperationPlanRiskClassifier.Context(flaggedContent: [key()])
        let verdict = OperationPlanRiskClassifier.classify(plan, context: context)
        #expect(verdict.reasons == [.contentFlagged(count: 1), .replacesUnprovenContent(count: 1)])
    }

    @Test func moreItemsThanFitUnderOneButtonNeedReview() {
        let items = (0..<(OperationPlanRiskClassifier.directItemLimit + 1)).map { _ in
            item(.installContent(digest: digest("a")), artifact: ArtifactID())
        }
        let verdict = OperationPlanRiskClassifier.classify(plan(items))
        #expect(verdict == .needsReview([.bulk(count: OperationPlanRiskClassifier.directItemLimit + 1)]))

        let atLimit = Array(items.prefix(OperationPlanRiskClassifier.directItemLimit))
        #expect(OperationPlanRiskClassifier.classify(plan(atLimit)) == .direct)
    }

    @Test func exclusionsNeedReviewSoThePersonLearnsWhatWillNotHappen() {
        let plan = WorkspaceDeploymentPlan(
            items: [item(.installContent(digest: digest("a")))],
            exclusions: [.init(artifactID: skill, physicalDestinationID: other, reason: .noDestination,
                               detail: "Codex is not installed on this Mac.")])
        #expect(OperationPlanRiskClassifier.classify(plan) == .needsReview([.exclusions(count: 1)]))
    }

    @Test func anAgentsRequestIsAlwaysShown() {
        let plan = plan([item(.installContent(digest: digest("a")))])
        let context = OperationPlanRiskClassifier.Context(requestedByAgent: true)
        #expect(OperationPlanRiskClassifier.classify(plan, context: context) == .needsReview([.requestedByAgent]))
    }

    @Test func reasonsAreOrderedBySeriousnessWhateverOrderTheyWereFound() {
        let reasons: [OperationPlanRiskClassifier.Reason] = [
            .bulk(count: 9), .exclusions(count: 1), .removesContent(count: 1),
            .contentFlagged(count: 1), .replacesUnprovenContent(count: 2),
        ]
        #expect(reasons.sorted() == [
            .contentFlagged(count: 1), .replacesUnprovenContent(count: 2),
            .removesContent(count: 1), .exclusions(count: 1), .bulk(count: 9),
        ])
    }

    @Test func anEmptyPlanIsDirectAndTheCallerDecidesItHasNothingToDo() {
        #expect(OperationPlanRiskClassifier.classify(plan([])) == .direct)
    }

    // MARK: Fixtures

    private func plan(_ items: [WorkspaceDeploymentItem]) -> WorkspaceDeploymentPlan {
        WorkspaceDeploymentPlan(items: items, exclusions: [])
    }

    private func item(_ action: WorkspaceDeploymentAction, artifact: ArtifactID? = nil) -> WorkspaceDeploymentItem {
        .init(artifactID: artifact ?? skill, displayName: "Example", physicalDestinationID: destination,
              surface: .claudeCode, scope: .user, logicalProjectID: nil, action: action,
              desiredEnabled: nil, reasons: [.manual])
    }

    private func key() -> WorkspaceDeploymentInstallKey {
        .init(artifactID: skill, physicalDestinationID: destination)
    }

    private func digest(_ character: Character) -> ContentDigest {
        .init(algorithm: .sha256TreeV1, value: String(repeating: String(character), count: 64))
    }
}
