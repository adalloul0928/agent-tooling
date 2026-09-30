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
    /// One app chosen is that app's page, not the Apps page with a filter: it
    /// draws differently from every-app, and the sidebar highlights the app.
    @Test func theScreenDrawsOneClientOnItsOwn() async throws {
        let fixture = try await ShellRenderFixture()
        defer { fixture.remove() }
        await fixture.workspace.device.refresh()
        let navigation = AppNavigationState()
        navigation.openClient(.claude)

        let one = try rasterize(
            AppShellView(
                workspace: fixture.workspace, initialSection: .syncCenter, navigation: navigation
            )
            .frame(width: shellWindowSize.width, height: shellWindowSize.height)
            .scriptedReceipts())
        try expectDrawn(
            AppShellView(
                workspace: fixture.workspace, initialSection: .syncCenter, navigation: navigation
            )
            .frame(width: shellWindowSize.width, height: shellWindowSize.height)
            .scriptedReceipts())
        let all = try rasterize(
            AppShellView(workspace: fixture.workspace, initialSection: .syncCenter, navigation: AppNavigationState())
                .frame(width: shellWindowSize.width, height: shellWindowSize.height)
                .scriptedReceipts())
        #expect(one.tiffRepresentation != all.tiffRepresentation, "one app's page drew the same as every app")

        // The sidebar lists the apps under Apps and highlights the chosen one.
        try expectDrawn(
            SidebarView(workspace: fixture.workspace, selection: .constant(.syncCenter))
                .environment(navigation)
                .frame(width: 240, height: 520))
    }

    /// Only managed apps hang under Apps. One this Mac has not set up is not a
    /// dimmed row; it is absent until "Choose apps…" brings it in.
    @Test func theSidebarListsOnlyManagedApps() async throws {
        let fixture = try await ShellRenderFixture()
        defer { fixture.remove() }
        await fixture.workspace.device.refresh()
        let device = fixture.workspace.device
        #expect(device.availableClients.contains(.gemini))
        await device.setEnabled(.gemini, false)

        #expect(!device.managedClients.contains(.gemini))
        // What the sidebar hangs under Apps is exactly the managed set.
        #expect(device.managedClients == device.availableClients.filter(device.isEnabled))
        try expectDrawn(
            SidebarView(workspace: fixture.workspace, selection: .constant(.syncCenter))
                .environment(AppNavigationState())
                .frame(width: 240, height: 520))
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
    /// One app's page draws its review card empty, mid-run, and with a kept
    /// review in it.
    @Test func theClientPageDrawsItsReviewInEveryState() async throws {
        let services = StubSetupServices(restored: ShellRenderFixture.setupCheckup(home: URL(filePath: "/Users/example")))
        let audit = ShellRenderFixture.setupCheckup(home: URL(filePath: "/Users/example")).audit
        try services.keep(clientReviews: [
            .claude: ClientReview(
                client: .claude, installedVersion: "2.1.285", latestVersion: "2.1.287",
                notes: [.init(client: .claude, version: "2.1.287", source: "https://raw.githubusercontent.com/anthropics/claude-code/main/CHANGELOG.md", body: "- Added thing")],
                review: ShellRenderFixture.setupReview(over: audit), dismissedRecommendationIDs: [], completedAt: .now)
        ])
        let fixture = try await ShellRenderFixture(setupServices: services)
        defer { fixture.remove() }
        await fixture.workspace.device.refresh()
        let navigation = AppNavigationState()
        navigation.openClient(.claude)
        let withReview = try rasterize(
            AppShellView(workspace: fixture.workspace, initialSection: .syncCenter, navigation: navigation)
                .frame(width: shellWindowSize.width, height: shellWindowSize.height).scriptedReceipts())
        try expectDrawn(
            AppShellView(workspace: fixture.workspace, initialSection: .syncCenter, navigation: navigation)
                .frame(width: shellWindowSize.width, height: shellWindowSize.height).scriptedReceipts())

        let plain = try await ShellRenderFixture(setupServices: StubSetupServices())
        defer { plain.remove() }
        await plain.workspace.device.refresh()
        let without = try rasterize(
            AppShellView(workspace: plain.workspace, initialSection: .syncCenter, navigation: navigation)
                .frame(width: shellWindowSize.width, height: shellWindowSize.height).scriptedReceipts())
        #expect(withReview.tiffRepresentation != without.tiffRepresentation, "the kept review changed nothing on the page")
    }

}

extension View {
    /// This Mac's own receipts, scripted. The review queue is scripted where
    /// the workspace is opened; receipts are still the screen's own read.
    fileprivate func scriptedReceipts(_ receipts: [OperationReceipt] = []) -> some View {
        environment(\.operationReceiptReader, StubOperationReceiptReader(receipts: receipts))
    }
}
