import Foundation
import SwiftUI
import Testing

@testable import AgentToolingApp
@testable import AgentToolingCore

/// The setup wizard draws at every stop, and its stops come from what the
/// checkup holds rather than from a fixed list.
@Suite("Setup wizard renders")
@MainActor
struct SetupWizardRenderTests {
    @Test func everyStopDraws() async throws {
        let checkup = ShellRenderFixture.setupCheckup(home: URL(filePath: "/Users/example"))
        let fixture = try await ShellRenderFixture(setupServices: StubSetupServices(restored: checkup))
        defer { fixture.remove() }
        let stops: [SetupWizardStep] = [.apps, .audit, .review, .category(.cleanup), .category(.unmanaged), .category(.settings), .done]
        for stop in stops {
            try expectDrawn(
                SetupWizardSheet(workspace: fixture.workspace, session: fixture.workspace.setup, onClose: {}, initialStep: stop)
                    .frame(width: 860, height: 640))
        }
    }

    @Test func theStopsAreTheCategoriesTheCheckupHasSomethingIn() {
        let checkup = ShellRenderFixture.setupCheckup(home: URL(filePath: "/Users/example"))
        // The fixture: a broken link and a missing plugin (cleanup), an
        // unmanaged skill (unmanaged), and a settings recommendation.
        #expect(SetupWizardStep.categories(in: checkup) == [.cleanup, .unmanaged, .settings])
        var dismissedAll = checkup
        dismissedAll.dismissedFindingIDs = Set(checkup.audit.findings.map(\.id))
        dismissedAll.dismissedRecommendationIDs = Set(checkup.review!.recommendations.map(\.id))
        #expect(SetupWizardStep.categories(in: dismissedAll).isEmpty, "a dismissed item is not a stop")
    }

    /// Home's setup card reads the kept checkup. It sits in the status column,
    /// which a first-run Home stands its getting-started card in front of, so
    /// the comparison is made with onboarding out of the way.
    @Test func homeShowsTheLastCheckupAndOffersOneWhenThereIsNone() async throws {
        let preferences = try ShellRenderFixture.preferences()
        defer { preferences.remove() }
        let checked = try await ShellRenderFixture(
            setupServices: StubSetupServices(restored: ShellRenderFixture.setupCheckup(home: URL(filePath: "/Users/example"))))
        defer { checked.remove() }
        let unchecked = try await ShellRenderFixture(setupServices: StubSetupServices())
        defer { unchecked.remove() }
        try expectDrawn(renderShell(.overview, fixture: checked).defaultAppStorage(preferences.defaults))
        #expect(
            try rasterize(renderShell(.overview, fixture: checked).defaultAppStorage(preferences.defaults)).tiffRepresentation
                != rasterize(renderShell(.overview, fixture: unchecked).defaultAppStorage(preferences.defaults)).tiffRepresentation,
            "the checkup changed nothing on Home")
    }
}
