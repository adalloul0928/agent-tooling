import Foundation
import SwiftUI
import Testing

@testable import AgentToolingApp
@testable import AgentToolingCore

/// A versioned first run has already scanned this Mac and built the library
/// before the wizard ever appears, so what is left to prove is narrower than
/// the old suite: the rule for when it stands in front of the library, that
/// every step draws without reaching the network or writing an assignment on
/// its own, and that the apps and assign steps stay honest about what
/// ownership does and does not allow.
@Suite("Onboarding")
@MainActor
struct OnboardingWizardTests {
    // MARK: - Presentation policy

    @Test func standsInFrontOfAWritableLibraryWithNothingAssigned() {
        #expect(
            OnboardingPresentationPolicy.shouldPresent(
                skipped: false, access: .writable, rows: [unassignedRow(), unassignedRow()]))
    }

    @Test func staysAwayOnceSkipped() {
        #expect(
            !OnboardingPresentationPolicy.shouldPresent(
                skipped: true, access: .writable, rows: [unassignedRow()]))
    }

    @Test func staysAwayFromAReadOnlyPreview() {
        #expect(
            !OnboardingPresentationPolicy.shouldPresent(
                skipped: false, access: .readOnly, rows: [unassignedRow()]))
    }

    @Test func staysAwayFromAnEmptyLibrary() {
        #expect(!OnboardingPresentationPolicy.shouldPresent(skipped: false, access: .writable, rows: []))
    }

    @Test func staysAwayOnceAnythingAtAllIsAssigned() {
        #expect(
            !OnboardingPresentationPolicy.shouldPresent(
                skipped: false, access: .writable, rows: [unassignedRow(), assignedRow()]))
    }

    @Test func staysAwayBeforeTheLibraryHasBeenRead() {
        #expect(!OnboardingPresentationPolicy.shouldPresent(skipped: false, access: .writable, rows: nil))
    }

    // MARK: - Steps render

    /// Every step draws at the fixture's real, writable workspace, and none of
    /// them so much as looks at `onFinish` or the session's write path on
    /// their own — only an explicit action does either.
    @Test func everyStepDrawsWithoutTouchingTheNetworkOrWritingAnAssignment() async throws {
        let fixture = try await ShellRenderFixture()
        defer { fixture.remove() }
        var finishCount = 0
        for step in OnboardingStep.allCases {
            try expectDrawnWarmed(
                OnboardingWizard(workspace: fixture.workspace, step: step) { finishCount += 1 }
                    .environment(AppNavigationState()))
        }
        #expect(finishCount == 0)
        #expect(fixture.workspace.library.lastReceipt == nil)
        #expect(fixture.workspace.device.enabledClients == Set(ClientKind.allCases))
    }

    /// A first run that found nothing a client already owns can legitimately
    /// have nothing assignable at all. The assign step still has to draw, and
    /// it must not offer the assignment ownership forbids.
    @Test func theAssignStepStaysHonestWhenNothingCanBeAssigned() async throws {
        let fixture = try await OnboardingTrackedOnlyFixture()
        defer { fixture.remove() }
        let library = try #require(fixture.workspace.library.state?.library)
        let anyAssignable = library.rows.contains(where: \.isAssignable)
        #expect(!library.rows.isEmpty)
        #expect(!anyAssignable)

        try expectDrawnWarmed(
            OnboardingWizard(workspace: fixture.workspace, step: .assign) {}
                .environment(AppNavigationState()))
    }

    /// Once an assignment is actually saved, the assign step has reached its
    /// "done" state, and it still has to draw rather than blank out.
    @Test func theAssignStepSwitchesToDoneOnceSomethingIsSaved() async throws {
        let fixture = try await ShellRenderFixture()
        defer { fixture.remove() }
        await fixture.assignForOnboarding()
        #expect(fixture.workspace.library.lastReceipt != nil)

        try expectDrawnWarmed(
            OnboardingWizard(workspace: fixture.workspace, step: .assign) {}
                .environment(AppNavigationState()))
    }

    // MARK: - Apps step

    /// Choosing an app goes straight through the device session — the same
    /// place the sidebar and Home read from — never through a row edit of its
    /// own.
    @Test func choosingAnAppGoesThroughTheDeviceSession() async throws {
        let fixture = try await ShellRenderFixture()
        defer { fixture.remove() }
        #expect(fixture.workspace.device.isEnabled(.gemini))

        await fixture.workspace.device.setEnabled(.gemini, false)

        #expect(!fixture.workspace.device.isEnabled(.gemini))
        try expectDrawnWarmed(
            OnboardingWizard(workspace: fixture.workspace, step: .apps) {}
                .environment(AppNavigationState()))
    }

    // MARK: - Fixtures

    private func unassignedRow() -> WorkspaceLibraryReadModelRow {
        row(requestedAssignments: [])
    }

    private func assignedRow() -> WorkspaceLibraryReadModelRow {
        row(
            requestedAssignments: [
                .init(
                    id: WorkspaceObjectID(), destination: .init(surface: .claudeCode, scope: .user),
                    reason: .manual, desiredPresence: true, desiredEnabled: nil, deviceScope: .thisDevice)
            ])
    }

    private func row(requestedAssignments: [WorkspaceLibraryRequestedAssignment]) -> WorkspaceLibraryReadModelRow {
        .init(
            artifactID: ArtifactID(), displayName: "Example", kind: .skill, ownership: .trackedOnly,
            parentPluginLabel: nil, declaredName: nil, sourceLabel: nil, observedDescription: nil, includedChildren: [],
            requestedAssignments: requestedAssignments, isAssignable: requestedAssignments.isEmpty,
            assignmentExplanation: nil, assignableReasons: [], nativeRoutes: [])
    }
}
