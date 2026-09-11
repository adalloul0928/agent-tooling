import AppKit
import Foundation
import SwiftUI
import Testing

@testable import AgentToolingApp
@testable import AgentToolingCore

/// Asking for something and installing it are two steps; these pin the hand-off
/// between them, which used to be missing entirely.
@Suite("Install flow") @MainActor
struct InstallFlowTests {
    @Test func reviewChangesOpensAppsAndIsConsumedOnce() {
        let navigation = AppNavigationState()
        navigation.openScreenRequest(.reviewChanges)
        #expect(navigation.requestedSection == .syncCenter)
        #expect(navigation.requestedScreenRequest == .reviewChanges)
        navigation.consumeScreenRequest(.reviewChanges)
        #expect(navigation.requestedScreenRequest == nil)
        #expect(ScreenRequest.reviewChanges.itemID == nil)
        #expect(ScreenRequest.named("review-changes") == .reviewChanges)
        #expect(ScreenRequest.named("nonsense") == nil)
    }

    @Test func theSavedAssignmentSheetOffersToInstall() async throws {
        let fixture = try await ShellRenderFixture()
        defer { fixture.remove() }
        await fixture.assignForOnboarding()
        #expect(fixture.workspace.library.lastReceipt != nil)
        let navigation = AppNavigationState()
        try expectDrawn(
            WorkspaceAssignmentSheet(session: fixture.workspace.library, artifactIDs: [ShellRenderFixture.skill])
                .environment(navigation))
    }

    /// The shell reads the library the moment the window is up. A cold launch
    /// that lands on Apps asking for the plan used to race that read, find no
    /// library, and quietly prepare nothing: no sheet, no error, no plan.
    @Test func preparingBeforeTheLibraryWasReadReadsItFirst() async throws {
        let fixture = try await ShellRenderFixture(readsLibrary: false)
        defer { fixture.remove() }
        #expect(fixture.workspace.library.state == nil)
        await fixture.workspace.deployment.prepare()
        #expect(fixture.workspace.library.state != nil)
        #expect(fixture.workspace.deployment.plan != nil)
        #expect(fixture.workspace.deployment.errorMessage == nil)
    }

    @Test func preparingWhileTheShellIsStillReadingWaitsForThatRead() async throws {
        let fixture = try await ShellRenderFixture(readsLibrary: false)
        defer { fixture.remove() }
        let shellRead = Task { @MainActor in await fixture.workspace.library.refresh() }
        await Task.yield()
        await fixture.workspace.deployment.prepare()
        await shellRead.value
        #expect(fixture.workspace.deployment.plan != nil)
        #expect(fixture.workspace.deployment.errorMessage == nil)
    }

    /// At launch SwiftUI cancels and restarts the Apps screen's task while it
    /// is waiting for the plan. The preparation is the session's own, so the
    /// restarted task joins it and the read is not lost with the cancelled one.
    @Test func aSecondPrepareJoinsTheOneInFlight() async throws {
        let fixture = try await ShellRenderFixture(readsLibrary: false)
        defer { fixture.remove() }
        let first = Task { @MainActor in await fixture.workspace.deployment.prepare() }
        await Task.yield()
        await fixture.workspace.deployment.prepare()
        #expect(fixture.workspace.deployment.plan != nil)
        #expect(fixture.workspace.deployment.errorMessage == nil)
        await first.value
    }

    @Test func aCancelledScreenDoesNotCancelThePreparation() async throws {
        let fixture = try await ShellRenderFixture(readsLibrary: false)
        defer { fixture.remove() }
        let screen = Task { @MainActor in await fixture.workspace.deployment.prepare() }
        await Task.yield()
        screen.cancel()
        await screen.value
        #expect(fixture.workspace.deployment.plan != nil)
        #expect(fixture.workspace.deployment.errorMessage == nil)
    }

    /// The whole route, through the shell's own wiring: a request to review
    /// changes lands on Apps, the plan gets prepared over a library the shell is
    /// still reading, and the request is consumed once it has been answered.
    @Test func theReviewChangesRouteLandsOnAppsAndPreparesThePlan() async throws {
        let fixture = try await ShellRenderFixture(readsLibrary: false)
        defer { fixture.remove() }
        let navigation = AppNavigationState()
        navigation.openScreenRequest(.reviewChanges)
        let host = NSHostingView(
            rootView: AnyView(
                AppShellView(workspace: fixture.workspace, initialSection: .syncCenter, navigation: navigation)
                    .environment(\.operationReceiptReader, StubOperationReceiptReader(receipts: []))
                    .frame(width: shellWindowSize.width, height: shellWindowSize.height)))
        host.frame = CGRect(origin: .zero, size: shellWindowSize)
        let window = NSWindow(
            contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.orderFrontRegardless()
        defer { window.orderOut(nil) }
        // The screen's tasks run on the main run loop, which turns while this
        // test sleeps. The request is consumed last, once the plan is there, so
        // that is the thing to wait for; the plan landing first is not the end.
        for _ in 0..<300 where navigation.requestedScreenRequest != nil {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(navigation.requestedScreenRequest == nil)
        #expect(fixture.workspace.deployment.plan != nil)
        #expect(fixture.workspace.deployment.errorMessage == nil)
    }

    @Test func askingTwiceIsRefusedAsAlreadyAskedFor() async throws {
        let fixture = try await ShellRenderFixture()
        defer { fixture.remove() }
        await fixture.assignForOnboarding()
        await fixture.workspace.library.reviewAssignments(
            artifactIDs: [ShellRenderFixture.skill],
            destinations: [.init(surface: .claudeCode, scope: .user)])
        await fixture.workspace.library.applyReviewedAssignments()
        #expect(fixture.workspace.library.lastRefusal == .contributionConflict)
        #expect(fixture.workspace.library.errorMessage?.contains("Apps screen") == true)
    }
}
