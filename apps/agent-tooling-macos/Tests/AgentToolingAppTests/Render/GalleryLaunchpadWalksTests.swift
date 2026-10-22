import AgentToolingCore
import AgentToolingTestSupport
import AppKit
import SwiftUI
import Testing

@testable import AgentToolingApp

/// Captures rerun and join flows from the end-to-end walks, in light and dark,
/// before each primary action advances. Uses scripted services and scratch
/// preferences. Enabled by `AGENT_TOOLING_SCREEN_GALLERY`.
@Suite("Gallery · Launchpad walks", .serialized, .enabled(if: GalleryOutput.isOn))
@MainActor
struct GalleryLaunchpadWalksTests {
    @Test func aRerunOnAWorkspaceMadeBeforeLaunchpad() async throws {
        let stage = try await EndToEndStage.legacy()
        defer { stage.remove() }
        let flow = stage.flow
        let workspace = try #require(flow.workspace)

        try stage.press()
        try await stage.readThenContinue()
        try stage.press()
        try await stage.startYourLibrary { _ in try Self.snap(stage, "s08-library", "rerun", "LaunchpadLibraryScreen.swift") }
        try await stage.putInApps { placement in
            try Self.snap(stage, "s10-place", "rerun", "LaunchpadPlaceScreen.swift")
            await Self.settle(placement, flow: flow)
        }
        let review = try await stage.letYourAppsAsk { hookUp in
            hookUp.toggle(.gemini)
            try Self.snap(stage, "s11-ask", "rerun", "LaunchpadAskScreen.swift")
        }
        try Self.snap(stage, "s12-review", "rerun", "LaunchpadReviewPanel.swift")
        let apps: Set<ClientKind> = [.codex, .claude]
        try await stage.install(review, runner: stage.helperRunner(for: apps)) {
            try await stage.fixture.endToEndObservations(afterConnecting: apps)
        }
        flow.advance()
        #expect(flow.step == .assistant)
        try stage.press()
        await waitUntil { workspace.device.assistantRuns != nil }
        #expect(flow.step == .behave)
        try Self.snap(stage, "s16-behave", "rerun", "LaunchpadBehaveScreen.swift")
        try stage.press()
        #expect(flow.step == .macs)
        try stage.press()
        #expect(flow.step == .done)
        _ = try await stage.done()
        try Self.snap(stage, "s22-done", "rerun", "LaunchpadDoneScreen.swift")
    }

    @Test func cedarJoinsWithTheDetour() async throws {
        let juniper = try await JoinPublishedJuniper.make()
        defer { juniper.remove() }
        var cedar = try await JoinCedar()
        defer { cedar.remove() }
        try cedar.fixture.installHelperInApplications()
        let (flow, join) = await cedar.joinStage()
        let stage = EndToEndStage(fixture: cedar.fixture, flow: flow, repository: nil)

        join.update(address: juniper.address)
        await join.check.checkNow(join.request)
        try stage.press()
        await waitUntil { flow.step == .arrivals }
        let arrivals = try #require(LaunchpadArrivalsScreen.arrivals(for: flow))
        await arrivals.load()

        // The detour: Let your apps ask, on the footer's Arrivals, 2 of 3.
        LaunchpadArrivalsScreen.connectHere(flow)
        let helperReview = try await stage.letYourAppsAsk { _ in
            try Self.snap(stage, "s11-ask", "Cedar walk", "LaunchpadAskScreen.swift")
        }
        try await stage.install(helperReview, runner: stage.helperRunner(for: [.codex, .claude])) {
            try await stage.fixture.endToEndObservations(afterConnecting: [.codex, .claude])
        }
        flow.advance()
        #expect(flow.step == .arrivals)

        // You joined's own review, then This Mac's two steps and Done.
        await arrivals.load()
        try stage.press()
        await waitUntil { flow.presentedReview != nil }
        let review = try #require(flow.presentedReview)
        await review.prepare()
        try await stage.install(review, runner: AnsweringRunner()) {
            try await stage.fixture.endToEndObservations(afterConnecting: [], supabaseInClaudeCode: true)
        }
        flow.advance()
        #expect(flow.step == .assistant)
        try Self.snap(stage, "s15-assistant", "Cedar walk", "LaunchpadAssistantScreen.swift")
        try stage.press()
        #expect(flow.step == .behave)
        try Self.snap(stage, "s16-behave", "Cedar walk", "LaunchpadBehaveScreen.swift")
        try stage.press()
        #expect(flow.step == .done)
        _ = try await stage.done()
        try Self.snap(stage, "s22-done", "Cedar walk", "LaunchpadDoneScreen.swift")
    }

    /// The stage at its step, in both appearances, with the app's own
    /// preferences in a scratch suite inside the fixture and Start your
    /// library's fetches answered from memory.
    private static func snap(_ stage: EndToEndStage, _ screen: String, _ state: String, _ file: String) throws {
        for appearance in [RenderAppearance.light, .dark] {
            let view = try PreferencesGalleryState.isolated(
                stage.fixture.stage(stage.flow)
                    .environment(\.launchpadLibraryServices, LaunchpadLibraryAdditionsTests.services(fetches: LibraryFetchLog())),
                in: stage.fixture.support)
            try galleryStageSnapshot(
                view, screen: screen, state: state, appearance: appearance,
                source: "Sources/AgentToolingApp/Launchpad/Screens/\(file)")
        }
    }

    /// Put in apps reads its grid again each time it is drawn, and Continue
    /// waits for that read: the walk lets it land before it presses on.
    private static func settle(_ placement: LaunchpadPlacement, flow: LaunchpadFlow) async {
        await placement.load(decisions: LaunchpadPlaceScreen.decisions(for: flow))
    }
}
