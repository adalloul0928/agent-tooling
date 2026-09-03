import CryptoKit
import Foundation

public struct ReviewedOperationPlan: Codable, Hashable, Sendable {
    public var plan: OperationPlan
    public var digest: String

    public init(plan: OperationPlan, digest: String) {
        self.plan = plan
        self.digest = digest
    }
}

public enum OperationPlanApproval {
    public static func review(_ plan: OperationPlan) throws -> ReviewedOperationPlan {
        guard !plan.steps.isEmpty else { throw OperationPlanApprovalError.emptyPlan }
        return ReviewedOperationPlan(plan: plan, digest: try digest(plan))
    }

    public static func verify(
        _ plan: OperationPlan,
        confirmedPlanID: UUID,
        confirmedDigest: String
    ) throws {
        guard plan.id == confirmedPlanID else { throw OperationPlanApprovalError.planIDMismatch }
        let actualDigest = try digest(plan)
        guard actualDigest == confirmedDigest.lowercased() else {
            throw OperationPlanApprovalError.digestMismatch
        }
    }

    private static func digest(_ plan: OperationPlan) throws -> String {
        let data = try AgentToolingCoding.encoder().encode(plan)
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

enum OperationPlanApprovalError: LocalizedError, Sendable {
    case emptyPlan
    case planIDMismatch
    case digestMismatch

    var errorDescription: String? {
        switch self {
        case .emptyPlan: "The operation plan has no steps to review."
        case .planIDMismatch: "The confirmed plan identifier does not match the reviewed plan."
        case .digestMismatch: "The operation plan changed after review. Review the new plan before applying it."
        }
    }
}
