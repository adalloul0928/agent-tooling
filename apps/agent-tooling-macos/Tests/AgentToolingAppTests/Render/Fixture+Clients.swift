import Foundation
import SwiftUI

@testable import AgentToolingApp
@testable import AgentToolingCore

/// The shapes the Apps screen reaches for beyond the shared fixture: a request
/// waiting for review, and a receipt from a run that already happened.
///
/// Both are scripted. A render test that opened the real queue would draw
/// whatever this machine happened to have in it, and one that read real
/// receipts would draw a different screen on every Mac.
struct StubPendingRequestQueue: PendingRequestQueuing {
    var requests: [PendingAgentRequest] = []

    func pendingRequests(store: WorkspaceRevisionStore) throws -> [PendingAgentRequest] { requests }

    func resolve(id: UUID, expectedFingerprint: String, store: WorkspaceRevisionStore) throws
        -> PendingAgentRequest?
    {
        requests.first { $0.id == id }
    }

    func restore(_ request: PendingAgentRequest, store: WorkspaceRevisionStore) throws {}
}

struct StubOperationReceiptReader: OperationReceiptReading {
    var receipts: [OperationReceipt] = []

    func recentReceipts(store: WorkspaceRevisionStore, limit: Int) throws -> [OperationReceipt] {
        receipts
    }
}

extension ShellRenderFixture {
    /// One request in the shape a local integration writes, fingerprinted the
    /// way the queue admitted it, so the review sheet accepts it as current.
    nonisolated static func pendingRequest(
        kind: PendingRequestKind = .installSkill,
        componentID: String = "Standalone Skill",
        targets: [ClientKind] = [.claude]
    ) -> PendingAgentRequest {
        let inputs: [String]
        var details = PendingRequestReviewDetails()
        switch kind {
        case .installSkill:
            inputs = [componentID, ""]
        case .removeComponent:
            details.componentKind = "skill"
            inputs = ["skill", componentID]
        default:
            inputs = [componentID, ""]
        }
        let now = Date.now
        return .init(
            id: UUID(), kind: kind, title: "Install \(componentID)",
            summary: "A local client asked for \(componentID) in \(targets.map(\.rawValue).joined(separator: ", ")).",
            componentID: componentID, scope: .user, targets: targets,
            reason: "Requested while working in a project.", reviewDetails: details,
            createdAt: now, lastRequestedAt: now, repeatCount: 1,
            requestedByLabels: ["Claude Code"],
            fingerprint: PendingRequestQueueService.fingerprint(
                kind: kind, inputs: inputs, scope: .user, targets: targets))
    }

    /// One saved receipt, so "Recent changes" has something to show that is not
    /// an assignment being mistaken for an installation.
    nonisolated static func receipt(
        state: HealthState = .healthy, createdAt: Date = .now
    ) -> OperationReceipt {
        .init(
            planID: UUID(), kind: .installSkill, title: "Update 1 tool in Claude Code",
            state: state, targetSurfaces: [.claudeCode],
            results: [
                .init(
                    stepID: UUID(), status: .succeeded, output: "", startedAt: createdAt,
                    finishedAt: createdAt)
            ],
            createdAt: createdAt, verificationSummary: "succeeded 1 · failed 0 · skipped 0")
    }

    /// One plan item, in the shape `prepare()` produces, for rendering the
    /// review sheet on its own.
    static func deploymentPlan() -> WorkspaceDeploymentPlan {
        .init(
            items: [
                .init(
                    artifactID: Self.skill, displayName: "Standalone Skill",
                    physicalDestinationID: WorkspaceObjectID(), surface: .claudeCode, scope: .user,
                    logicalProjectID: nil,
                    action: .installContent(digest: .init(value: String(repeating: "a", count: 64))),
                    desiredEnabled: nil, reasons: [.manual])
            ],
            exclusions: [
                .init(
                    artifactID: Self.server, physicalDestinationID: nil, reason: .trackedOwnership,
                    detail: "Tracked items record what exists; they are not installed.")
            ])
    }
}
