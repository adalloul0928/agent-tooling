import AgentToolingCore
import AgentToolingTestSupport
import AppKit
import SwiftUI
import Testing

@testable import AgentToolingApp

/// Home's Finish setting up card (P01) draws in both appearances in each of
/// its states, from the workspace's own record as Home mounts it and from
/// hand-made checklists; so do the sidebar chip, the connection check's
/// confirmation in each phase, and the tips. Drawing any of them checks no
/// app, runs no connection check and writes nothing.
@Suite("Finish setting up renders", .serialized, .timeLimit(.minutes(5)))
@MainActor
struct FinishSetupRenderTests {
    /// The card's width on Home at the default window size.
    static let cardSize = CGSize(width: 1_154, height: 420)

    @Test(arguments: [RenderAppearance.light, .dark])
    func theCardDrawsThreeOfSeven(appearance: RenderAppearance) throws {
        let list = try #require(FinishSetupChecklist.make(Self.facts(.juniper), now: FinishSetupFixture.doneAt))

        try expectDrawn(Self.card(list), size: Self.cardSize, appearance: appearance)
    }

    @Test(arguments: [RenderAppearance.light, .dark])
    func aSetupLeftForLaterLeadsWithResume(appearance: RenderAppearance) throws {
        let list = try #require(FinishSetupChecklist.make(Self.facts(.deferred(.place)), now: FinishSetupFixture.doneAt))
        #expect(list.lead != nil)

        try expectDrawn(Self.card(list), size: Self.cardSize, appearance: appearance)
    }

    @Test func everyRowDoneDraws() throws {
        let list = try #require(FinishSetupChecklist.make(Self.facts(.allDone), now: FinishSetupFixture.doneAt))

        try expectDrawn(Self.card(list), size: Self.cardSize, appearance: .dark)
    }

    /// Mounted as Home mounts it, the card reads the workspace's own record,
    /// draws, and runs nothing: no check of the apps and no connection check.
    @Test func theCardReadsTheWorkspacesRecordAndRunsNothing() async throws {
        let observer = CountingDeviceObserver([])
        let store = StubSetupProgressStore(FinishSetupFixture.record(.juniper))
        let fixture = try await ShellRenderFixture(deviceObserver: observer, setupProgressStore: store)
        defer { fixture.remove() }
        let saves = store.saveCount

        try expectDrawn(
            FinishSetupCard(workspace: fixture.workspace).finishSetupEnvironment().padding(Space.xl), size: Self.cardSize)

        #expect(observer.fullChecks == 0)
        #expect(observer.scopedChecks.isEmpty)
        #expect(fixture.workspace.health.lastCheckedAt == nil)
        #expect(store.saveCount == saves)
    }

    /// A workspace made before Launchpad, and a hidden card, draw nothing.
    @Test func noRecordOrAHiddenCardDrawsNothing() async throws {
        for record in [nil, FinishSetupFixture.record(.hidden)] {
            let fixture = try await ShellRenderFixture(setupProgressStore: StubSetupProgressStore(record))
            defer { fixture.remove() }

            #expect(fittingSize(of: FinishSetupCard(workspace: fixture.workspace).finishSetupEnvironment()) == nil)
        }
    }

    /// Where Home shows no card, the card is no view at all: in Home's page
    /// stack it takes no spacing slot, so Home draws as it did before.
    @Test func noCardTakesNoPlaceInHomesStack() async throws {
        let fixture = try await ShellRenderFixture(setupProgressStore: StubSetupProgressStore(nil))
        defer { fixture.remove() }
        let stack = VStack(spacing: Space.lg) {
            Color.clear.frame(width: Size.rowHeight, height: Size.rowHeight)
            FinishSetupCard(workspace: fixture.workspace)
            Color.clear.frame(width: Size.rowHeight, height: Size.rowHeight)
        }
        .finishSetupEnvironment()

        #expect(fittingSize(of: stack)?.height == Size.rowHeight * 2 + Space.lg)
    }

    /// Hidden with rows left, the chip stands above the sidebar's foot and
    /// counts them; shown, there is no chip.
    @Test(arguments: [RenderAppearance.light, .dark])
    func theChipDrawsWhileTheCardIsHidden(appearance: RenderAppearance) async throws {
        let hidden = try await ShellRenderFixture(setupProgressStore: StubSetupProgressStore(FinishSetupFixture.record(.hidden)))
        defer { hidden.remove() }
        let shown = try await ShellRenderFixture(setupProgressStore: StubSetupProgressStore(FinishSetupFixture.record(.juniper)))
        defer { shown.remove() }

        try expectDrawn(
            FinishSetupSidebarChip(workspace: hidden.workspace, openHome: {}).finishSetupEnvironment(),
            size: CGSize(width: Size.sidebarIdeal, height: Size.rowHeight), appearance: appearance)
        #expect(fittingSize(of: FinishSetupSidebarChip(workspace: shown.workspace, openHome: {}).finishSetupEnvironment()) == nil)
        let chip = try #require(fittingSize(of: FinishSetupChip(left: 4) {}))
        #expect(chip.height == Size.pillHeight)
    }

    @Test(arguments: [RenderAppearance.light, .dark])
    func theConfirmationDrawsInEachPhase(appearance: RenderAppearance) throws {
        let commands = ConnectionsCheckFlow.listCommands(for: [.claude, .codex])
        let sentry = [
            ConnectionsCheckConfirmation.SignIn(connection: "Sentry", command: "claude mcp login plugin:sentry:sentry --no-browser")
        ]
        let phases: [(ConnectionsCheckConfirmation.Phase, String?)] = [
            (.confirm, nil), (.checking, nil), (.signIn, "Sentry in Claude Code"), (.signingIn, "Sentry in Claude Code"),
            (.finished, nil),
        ]
        for (phase, who) in phases {
            let view = ConnectionsCheckConfirmation(phase: phase, listCommands: commands, signIns: sentry, who: who)
            try expectDrawn(view, size: CGSize(width: Size.fieldWide, height: Self.cardSize.height), appearance: appearance)
        }
        let elsewhere = ConnectionsCheckConfirmation(
            phase: .finished, listCommands: commands, signIns: [],
            signInElsewhere: LaunchpadCopy.FinishSetup.signInFromApps("Gmail in Claude Code", count: 1))
        try expectDrawn(elsewhere, size: CGSize(width: Size.fieldWide, height: Self.cardSize.height), appearance: appearance)
    }

    @Test(arguments: [RenderAppearance.light, .dark])
    func theTipsDraw(appearance: RenderAppearance) throws {
        for raycast: CompanionPresence.Raycast in [.absent, .appOnly, .extensionInstalled] {
            let view = CompanionTipsPopover(
                raycast: raycast, helperPath: "/Applications/Agent Tooling.app/Contents/Helpers/agent-tooling")
            try expectDrawn(view, size: CGSize(width: Size.fieldWide, height: Self.cardSize.height), appearance: appearance)
        }
        try expectDrawn(
            CompanionTipsPopover(raycast: .appOnly, helperPath: nil),
            size: CGSize(width: Size.fieldWide, height: Self.cardSize.height))
    }

    /// Rows keep their height whatever their caption says, so a row that
    /// ticks or a caption that changes after a connection check never moves
    /// Home under the card.
    @Test func aRowChangingAfterACheckKeepsTheCardsHeight() throws {
        var facts = Self.facts(.juniper)
        let before = try #require(FinishSetupChecklist.make(facts, now: FinishSetupFixture.doneAt))
        facts.connectionCheck = .init(
            checkedAt: FinishSetupFixture.doneAt, signInOffers: [FinishSetupFixture.sentry],
            needsAuthentication: [FinishSetupFixture.sentry], connected: [])
        let after = try #require(FinishSetupChecklist.make(facts, now: FinishSetupFixture.doneAt))
        #expect(after.rows[3].caption == "Sentry in Claude Code needs you to sign in")
        #expect(after.rows[3].actionTitle == "Sign in…")

        let heights = try [before, after].map { list in
            try #require(fittingSize(of: FinishSetupCardBody(list: list).frame(width: Self.cardSize.width))).height
        }
        #expect(heights[0] == heights[1])
        // P01's card: a 44 header over its hairline, seven 44 rows with
        // their hairlines drawn inside them, and the 36 foot.
        #expect(heights[0] == Size.headerHeight + Hairline.width + Size.rowHeight * 7 + StageLayout.FinishSetup.footRow)
    }

    /// A row ticking after Home laid out, as the tracker ticks it, changes
    /// the row in place: Home stays inside its window.
    @Test func aRowTickingAfterLayoutKeepsHomeInItsWindow() async throws {
        let store = StubSetupProgressStore(FinishSetupFixture.record(.juniper))
        let fixture = try await ShellRenderFixture(setupProgressStore: store)
        defer { fixture.remove() }
        let home = ScrollView {
            FinishSetupCard(workspace: fixture.workspace).padding(Space.xl)
        }
        .finishSetupEnvironment()

        let layout = try await LateContentHarness.heightAfterChange(home) {
            fixture.workspace.setupProgress.tick(.signInConnections, place: .home, summary: "Sentry signed in")
        }

        #expect(layout.hostHeight == layout.windowHeight)
        #expect(store.saved?.ticks.map(\.item).last == .signInConnections)
    }

    // MARK: - Helpers

    static func facts(_ shape: FinishSetupFixture.Shape) -> FinishSetupFacts {
        FinishSetupFixture.juniperFacts(record: FinishSetupFixture.record(shape))
    }

    static func card(_ list: FinishSetupChecklist) -> some View {
        FinishSetupCardBody(list: list)
            .padding(Space.xl)
            .environment(\.snapshotNow, FinishSetupFixture.doneAt)
    }
}
