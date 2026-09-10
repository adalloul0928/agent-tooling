import Foundation
import SwiftUI
import Testing

@testable import AgentToolingApp
@testable import AgentToolingCore

/// Apps draws what this Mac would change.
@Suite("Apps · Clients renders")
@MainActor
struct ClientsSectionRenderTests {
    @Test func theShellDrawsClients() async throws {
        let fixture = try await ShellRenderFixture()
        defer { fixture.remove() }

        try expectDrawn(renderShell(.syncCenter, fixture: fixture).scriptedReceipts())
    }

    /// The screen with something on it: a checked Mac, a request nobody has
    /// decided, and a receipt from a run that already happened.
    @Test func theScreenDrawsAQueueAndTheLastRun() async throws {
        let fixture = try await ShellRenderFixture(
            requestQueue: StubPendingRequestQueue(requests: [ShellRenderFixture.pendingRequest()]))
        defer { fixture.remove() }
        await fixture.workspace.device.refresh()

        try expectDrawn(
            renderShell(.syncCenter, fixture: fixture)
                .scriptedReceipts([ShellRenderFixture.receipt()]))
    }

    /// The affordance moved here from the dead `WorkspaceDeploymentView`: a
    /// destination this Mac points somewhere other than its app's own folder
    /// still draws, with the folder behind `LocationText` rather than in the
    /// row itself.
    @Test func theScreenDrawsALinkedDestination() async throws {
        let fixture = try await ShellRenderFixture()
        defer { fixture.remove() }
        await fixture.workspace.deployment.linkDestination(
            surface: .claudeCode, scope: .user, projectID: nil,
            to: fixture.root.appending(path: "external-destination", directoryHint: .isDirectory))
        #expect(fixture.workspace.deployment.linkedDestinations.count == 1)

        try expectDrawn(renderShell(.syncCenter, fixture: fixture).scriptedReceipts())
    }

    /// Scoped to one client, the screen keeps its scope bar and its verdict.
    @Test func theScreenDrawsOneClientOnItsOwn() async throws {
        let fixture = try await ShellRenderFixture()
        defer { fixture.remove() }
        await fixture.workspace.device.refresh()
        let navigation = AppNavigationState()
        navigation.openClient(.claude)

        try expectDrawn(
            AppShellView(
                workspace: fixture.workspace, initialSection: .syncCenter, navigation: navigation
            )
            .frame(width: shellWindowSize.width, height: shellWindowSize.height)
            .scriptedReceipts())
    }

    /// The review sheets draw on their own; the shell never opens one by itself,
    /// so nothing else would catch them failing to lay out.
    @Test func theRequestReviewSheetDraws() throws {
        let request = ShellRenderFixture.pendingRequest()

        try expectDrawn(
            PendingRequestReviewSheet(
                request: request,
                refusal: "Standalone Skill is not in your library, and approving a request never adds one.",
                onDefer: {}, onReject: {}, onContinue: {}))
    }

    @Test func thePlanReviewSheetDraws() async throws {
        let fixture = try await ShellRenderFixture()
        defer { fixture.remove() }

        try expectDrawn(
            PlanReviewSheet(
                workspace: fixture.workspace, plan: ShellRenderFixture.deploymentPlan()))
    }
}

extension View {
    /// This Mac's own receipts, scripted. The review queue is scripted where
    /// the workspace is opened; receipts are still the screen's own read.
    fileprivate func scriptedReceipts(_ receipts: [OperationReceipt] = []) -> some View {
        environment(\.operationReceiptReader, StubOperationReceiptReader(receipts: receipts))
    }
}
