import AgentToolingCore
import AgentToolingTestSupport
import AppKit
import SwiftUI
import Testing

@testable import AgentToolingApp

/// Done (S22) and Home's Finish setting up card (P01) in the gallery: Done
/// as the fragment draws it (Juniper's own numbers), Cedar's, the empty Mac's
/// and the ↩-through walk's, and the sample world's walk as the stage leaves
/// it; the card in each state, the sidebar chip, the connection check's
/// confirmation in each phase and the tips.
///
/// Enabled only when `AGENT_TOOLING_SCREEN_GALLERY` names an output folder.
@Suite("Gallery · Launchpad Done and Home", .serialized, .enabled(if: GalleryOutput.isOn))
@MainActor
struct GalleryLaunchpadDoneTests {
    private static let both: [RenderAppearance] = [.light, .dark]
    private static let doneSource = "Sources/AgentToolingApp/Launchpad/Screens/LaunchpadDoneScreen.swift"
    private static let cardSource = "Sources/AgentToolingApp/FinishSetupCard.swift"
    /// The card on Home at the default window size, with the page's margin.
    private static let cardCanvas = CGSize(width: 1_186, height: 440)
    private static let popoverCanvas = CGSize(width: Size.fieldWide, height: 300)

    @Test func doneAsTheFragmentDrawsIt() async throws {
        let fixture = try await LaunchpadFixture()
        defer { fixture.remove() }
        let (flow, _) = try await LaunchpadDoneRenderTests.juniperAtDone(fixture)
        let moments: [(String, LaunchpadDoneSummary.Inputs)] = [
            ("Juniper, as drawn", FinishSetupFixture.juniperInputs()),
            ("Cedar, as its note says", FinishSetupFixture.cedarInputs()),
            ("empty Mac", FinishSetupFixture.emptyMacInputs()),
            ("pressing return through", FinishSetupFixture.returnThroughInputs()),
        ]
        for (state, inputs) in moments {
            for appearance in Self.both {
                try galleryStageSnapshot(
                    Self.stage(flow, LaunchpadDoneSummary(inputs)), screen: "S22 Done", state: state, appearance: appearance,
                    source: Self.doneSource)
            }
        }
    }

    @Test func doneOnTheSampleWorld() async throws {
        for appearance in Self.both {
            let fixture = try await LaunchpadFixture()
            defer { fixture.remove() }
            let (flow, _) = try await LaunchpadDoneRenderTests.juniperAtDone(fixture)
            try galleryStageSnapshot(
                fixture.stage(flow), screen: "S22 Done", state: "sample world, Juniper", appearance: appearance,
                source: Self.doneSource)
        }
        let cedar = try await LaunchpadFixture(.cedar)
        defer { cedar.remove() }
        let (flow, sample) = try await cedar.flow(at: .cedarJoined)
        defer { sample.remove() }
        flow.go(to: .done)
        await LaunchpadDoneScreen.model(flow).appear(flow)
        try galleryStageSnapshot(
            cedar.stage(flow), screen: "S22 Done", state: "sample world, Cedar joined, Install later", appearance: .dark,
            source: Self.doneSource)
    }

    @Test func homesCardInEachState() throws {
        var moved = FinishSetupFixture.juniperFacts(record: FinishSetupFixture.record(.juniper))
        moved.offersMove = true
        var checked = FinishSetupFixture.juniperFacts(record: FinishSetupFixture.record(.juniper))
        checked.connectionCheck = .init(
            checkedAt: FinishSetupFixture.doneAt, signInOffers: [FinishSetupFixture.sentry],
            needsAuthentication: [FinishSetupFixture.sentry], connected: [])
        var returned = FinishSetupFixture.returnThroughInputs().facts
        returned.record = FinishSetupFixture.record(.returnThrough)
        // Left at Put in apps: two skills made yours, no connection and no
        // sharing yet, as Home shows it after the tracker's first look.
        var deferred = FinishSetupFixture.juniperFacts(record: FinishSetupFixture.record(.deferred(.place)))
        deferred.helperConnectedApps = []
        deferred.sync = nil
        deferred = FinishSetupFixture.afterFirstLook(deferred)
        let states: [(String, FinishSetupFacts)] = [
            ("3 of 7 done", FinishSetupFixture.juniperFacts(record: FinishSetupFixture.record(.juniper))),
            ("left for later at Put in apps", deferred),
            ("every row done", FinishSetupFixture.juniperFacts(record: FinishSetupFixture.record(.allDone))),
            ("pressing return through, 1 of 6", returned),
            ("outside Applications", moved),
            ("after a connection check", checked),
        ]
        for (state, facts) in states {
            let list = try #require(FinishSetupChecklist.make(facts, now: FinishSetupFixture.doneAt))
            for appearance in Self.both {
                try gallerySnapshot(
                    Self.onHome(FinishSetupCardBody(list: list)), area: "Home", screen: "P01 Finish setting up", state: state,
                    size: Self.cardCanvas, appearance: appearance, source: Self.cardSource)
            }
        }
    }

    @Test func theChipTheConfirmationAndTheTips() throws {
        for appearance in Self.both {
            try gallerySnapshot(
                FinishSetupChip(left: 4) {}.padding(Space.xl), area: "Home", screen: "P01 sidebar chip",
                state: "card hidden, 4 left", size: CGSize(width: Size.sidebarIdeal, height: Size.rowHeight * 2),
                appearance: appearance, source: "Sources/AgentToolingApp/FinishSetupChip.swift")

            let commands = ConnectionsCheckFlow.listCommands(for: [.claude, .codex])
            let sentry = [
                ConnectionsCheckConfirmation.SignIn(
                    connection: "Sentry", command: "claude mcp login plugin:sentry:sentry --no-browser")
            ]
            let phases: [(String, ConnectionsCheckConfirmation)] = [
                ("before the check", .init(phase: .confirm, listCommands: commands, signIns: sentry)),
                ("checking", .init(phase: .checking, listCommands: commands, signIns: sentry)),
                ("Sentry needs a sign-in", .init(phase: .signIn, listCommands: commands, signIns: sentry, who: "Sentry in Claude Code")),
                (
                    "plain return pressed",
                    .init(phase: .signIn, listCommands: commands, signIns: sentry, who: "Sentry in Claude Code", showsHint: true)
                ),
                ("nothing to sign in to", .init(phase: .finished, listCommands: commands, signIns: [])),
                (
                    "a sign-in only its app can run",
                    .init(
                        phase: .finished, listCommands: commands, signIns: [],
                        signInElsewhere: LaunchpadCopy.FinishSetup.signInFromApps("Gmail in Claude Code", count: 1))
                ),
            ]
            for (state, view) in phases {
                try gallerySnapshot(
                    view, area: "Home", screen: "P01 Check your connections?", state: state, size: Self.popoverCanvas,
                    appearance: appearance, source: "Sources/AgentToolingApp/ConnectionsCheckConfirmation.swift")
            }

            let helper = "/Applications/Agent Tooling.app/Contents/Helpers/agent-tooling"
            let tips: [(String, CompanionTipsPopover)] = [
                ("Raycast without the extension", .init(raycast: .appOnly, helperPath: helper)),
                ("Raycast with the extension", .init(raycast: .extensionInstalled, helperPath: helper)),
                ("no Raycast, a local build", .init(raycast: .absent, helperPath: nil)),
            ]
            for (state, view) in tips {
                try gallerySnapshot(
                    view, area: "Home", screen: "P01 Use it from Raycast or Terminal", state: state, size: Self.popoverCanvas,
                    appearance: appearance, source: "Sources/AgentToolingApp/CompanionTipsPopover.swift")
            }
        }
    }

    // MARK: - Helpers

    /// Done drawn from `summary` in the stage, with Done's own footer from
    /// `flow`.
    private static func stage(_ flow: LaunchpadFlow, _ summary: LaunchpadDoneSummary) -> some View {
        SetupStage(managedClients: [.codex, .claude, .gemini]) {
            LaunchpadDoneContent(summary: summary)
        } footer: {
            StageFooterBar(info: flow.info, spec: LaunchpadStageView.footer(for: flow))
        } overlay: {
            EmptyView()
        }
        .environment(\.stageMotion, .still)
        .environment(\.snapshotNow, ClientHomeFixture.now)
    }

    /// The card on Home's canvas, at the page's margin.
    private static func onHome(_ card: some View) -> some View {
        ZStack(alignment: .top) {
            AgentTheme.contentBackground
            AgentTheme.canvasGradient
            card.padding(Space.xl)
        }
        .environment(\.snapshotNow, FinishSetupFixture.doneAt)
    }
}
