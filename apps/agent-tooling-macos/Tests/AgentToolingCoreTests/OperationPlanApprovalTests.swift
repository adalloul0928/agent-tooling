import Foundation
import Testing

@testable import AgentToolingCore

struct OperationPlanApprovalTests {
    @Test func approvalBindsConfirmationToExactImmutablePlan() throws {
        let plan = OperationPlan(
            kind: .doctor,
            title: "Review",
            summary: "Review this exact action",
            steps: [
                OperationStep(kind: .manual, title: "Verify", detail: "Verify manually", requiresUserAction: true)
            ]
        )
        let reviewed = try OperationPlanApproval.review(plan)

        try OperationPlanApproval.verify(
            plan,
            confirmedPlanID: plan.id,
            confirmedDigest: reviewed.digest
        )

        var changed = plan
        changed.title = "Changed after review"
        #expect(throws: OperationPlanApprovalError.self) {
            try OperationPlanApproval.verify(
                changed,
                confirmedPlanID: plan.id,
                confirmedDigest: reviewed.digest
            )
        }
    }

    @Test func emptyPlanCannotBeApproved() {
        let plan = OperationPlan(kind: .doctor, title: "Empty", summary: "Nothing", steps: [])
        #expect(throws: OperationPlanApprovalError.self) {
            _ = try OperationPlanApproval.review(plan)
        }
    }
}
