import AgentToolingCore
import AgentToolingTestSupport
import AppKit
import SwiftUI
import Testing

@testable import AgentToolingApp

/// What the setup stage leaves on the shell, mounted where the plan puts it:
/// Home's top slot holds the one-time notice, then the Finish setting up card,
/// both above Home's own cards; the sidebar holds the card's chip above its
/// sync foot; and the shell's detail column holds the tracker that ticks the
/// card's rows. Home is checked at 1180 × 760, the size the card was drawn at.
@Suite("Launchpad · what setup leaves on the shell", .serialized, .timeLimit(.minutes(5)))
@MainActor
struct LaunchpadHomeMountTests {
    static let homeSize = CGSize(width: 1180, height: 760)
    /// The heading of Home's first own card, which the notice and the card
    /// come before.
    private static let homesFirstCard = "Waiting for your review"

    /// Juniper's walk handed off: Home leads with its card, 3 of 7 done,
    /// before Home's own cards in reading order, and draws at 1180 × 760.
    @Test(arguments: [RenderAppearance.light, .dark])
    func homeLeadsWithTheFinishSettingUpCard(appearance: RenderAppearance) async throws {
        let fixture = try await LaunchpadFixture()
        defer { fixture.remove() }
        let workspace = try await Self.handedOff(fixture)
        let shell = Self.shell(workspace)

        try expectDrawn(shell, size: Self.homeSize, appearance: appearance)
        let home = AccessibilityProbe(shell, size: Self.homeSize)
        defer { home.close() }
        #expect(home.contains("Finish setting up, 3 of 7 done"))
        // Each row reads as one element, its title first.
        #expect(home.elements.contains { $0.label.hasPrefix(LaunchpadCopy.FinishSetup.makeSkillsYours) })
        #expect(home.elements.contains { $0.label.hasPrefix(LaunchpadCopy.FinishSetup.trackProjects) })
        let list = try #require(FinishSetupChecklist.make(FinishSetupFacts.live(workspace: workspace), now: ClientHomeFixture.now))
        #expect(list.rows.first { $0.item == .trackProjects }?.caption == "4 folders Claude Code has worked in")
        #expect(!home.contains(AssistantRunCopy.noticeTitle), "a new setup chose its runs")
        // In reading order, the card comes before Home's own cards.
        let card = try #require(Self.index(in: home) { $0.hasPrefix(LaunchpadCopy.FinishSetup.title) })
        let homesOwn = try #require(Self.index(in: home) { $0 == Self.homesFirstCard })
        #expect(card < homesOwn, "the card leads Home")
        try galleryShellSnapshot(
            shell, area: "Launchpad", screen: "p01-home", state: "mounted-1180", size: Self.homeSize, appearance: appearance,
            source: "Sources/AgentToolingApp/OverviewView.swift")
    }

    /// A workspace made before setup: no card, and the notice until the
    /// runs are chosen.
    @Test func aWorkspaceMadeBeforeSetupShowsTheNoticeUntilItsRunsAreChosen() async throws {
        let fixture = try await LaunchpadFixture()
        defer { fixture.remove() }
        var preferences = fixture.seed.preferences
        preferences.assistantRuns = nil
        let workspace = try await WorkspaceLaunch.create(
            observations: fixture.orderedObservations, preferences: preferences, supportRoot: fixture.support,
            homeRoot: fixture.home, beforeRecord: { _ in }, services: fixture.environment.sessions)
        await workspace.library.refresh()

        let home = AccessibilityProbe(Self.shell(workspace), size: Self.homeSize)
        defer { home.close() }
        #expect(home.contains(AssistantRunCopy.noticeTitle))
        #expect(!home.elements.contains { $0.label.hasPrefix(LaunchpadCopy.FinishSetup.title) }, "no card before setup")
        // In reading order, the notice comes before Home's own cards.
        let notice = try #require(Self.index(in: home) { $0 == AssistantRunCopy.noticeTitle })
        let homesOwn = try #require(Self.index(in: home) { $0 == Self.homesFirstCard })
        #expect(notice < homesOwn, "the notice leads Home")

        await AssistantRunsNotice.keepOn(workspace).value
        home.settle()
        #expect(workspace.device.assistantRuns == .existingBehaviour)
        #expect(!home.contains(AssistantRunCopy.noticeTitle))
    }

    /// Hidden with rows left, the card leaves its chip above the sidebar's
    /// sync foot; pressing it shows the card again and opens Home.
    @Test func theSidebarsChipBringsTheHiddenCardBack() async throws {
        let fixture = try await LaunchpadFixture()
        defer { fixture.remove() }
        let workspace = try await Self.handedOff(fixture)
        workspace.setupProgress.setChecklistHidden(true, now: ClientHomeFixture.now)
        let selection = SelectionBox(.skills)

        let sidebar = AccessibilityProbe(
            SidebarView(workspace: workspace, selection: selection.binding).environment(AppNavigationState())
                .environment(\.snapshotNow, ClientHomeFixture.now),
            size: CGSize(width: Size.sidebarIdeal, height: Self.homeSize.height))
        defer { sidebar.close() }
        let label = LaunchpadCopy.FinishSetup.chipLabel(left: 4)
        #expect(sidebar.contains(label))

        #expect(sidebar.press(label))
        #expect(workspace.setupProgress.record?.hiddenAt == nil)
        #expect(selection.value == .overview)
    }

    /// The shell ticks the card's rows as they come true: a first run left
    /// for later after its install has Home tick what setup did, in setup,
    /// at the shell's first look.
    @Test func theShellsTrackerTicksWhatSetupDid() async throws {
        let fixture = try await LaunchpadFixture()
        defer { fixture.remove() }
        let sample = try await fixture.sample(.afterInstall)
        let workspace = sample.workspace
        workspace.setupProgress.deferSetup(at: .assistant, now: ClientHomeFixture.now)
        #expect(workspace.setupProgress.record?.ticks.isEmpty == true)

        let home = AccessibilityProbe(Self.shell(workspace), size: Self.homeSize)
        defer { home.close() }
        home.settle()

        let ticks = workspace.setupProgress.record?.ticks ?? []
        #expect(ticks.map(\.item).contains(.makeSkillsYours))
        #expect(ticks.allSatisfy { $0.place == .setup })
    }

    // MARK: - Helpers

    /// Juniper after its install, walked through Done's Go to Home, holding
    /// what P01 draws: shared just now, and the four project folders its read
    /// counted in Claude Code's history.
    private static func handedOff(_ fixture: LaunchpadFixture) async throws -> WorkspaceLaunch.Workspace {
        let (flow, sample) = try await fixture.flow(at: .afterInstall)
        flow.outcomes.sync = .init(
            address: "https://github.com/you/agent-tooling-workspace.git", publishedAt: ClientHomeFixture.now, upToDate: true)
        sample.workspace.setupProgress.recordEvidence { $0.projectFolderCount = 4 }
        flow.go(to: .done)
        await LaunchpadDoneScreen.model(flow).appear(flow)
        try #require(LaunchpadStageView.footer(for: flow).primary).action()
        #expect(flow.pendingHandOff == .overview)
        return sample.workspace
    }

    /// Where the first element called, or showing, what `matches` takes
    /// comes in Home's reading order.
    private static func index(in home: AccessibilityProbe, _ matches: (String) -> Bool) -> Int? {
        home.elements.firstIndex { matches($0.label) || $0.value.map(matches) == true }
    }

    /// The shell on Home, still, at the sample world's clock, reading nothing
    /// of this Mac.
    private static func shell(_ workspace: WorkspaceLaunch.Workspace) -> some View {
        AppShellView(workspace: workspace, initialSection: .overview)
            .environment(\.snapshotNow, ClientHomeFixture.now)
            .environment(\.stageMotion, .still)
            .environment(\.finishSetupServices, FinishSetupFixture.services)
            .environment(\.skillTrialOpening) { _ in RecordingSkillTrialOpening(available: []) }
    }
}

/// A selection a test hands a view as a binding and reads back.
@MainActor
private final class SelectionBox {
    var value: AppSection

    init(_ value: AppSection) {
        self.value = value
    }

    var binding: Binding<AppSection> {
        Binding(get: { self.value }, set: { self.value = $0 })
    }
}
