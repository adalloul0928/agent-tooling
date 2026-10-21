import AgentToolingCore
import AgentToolingTestSupport
import SwiftUI
import Testing

@testable import AgentToolingApp

/// Your other Macs (S17), Join (J01, V08, Finish joining) and You joined (J02)
/// in the gallery, in the stage's own window: each state the fragments draw,
/// and the ones they specify.
///
/// Enabled only when `AGENT_TOOLING_SCREEN_GALLERY` names an output folder.
@Suite("Gallery · Launchpad macs", .serialized, .enabled(if: GalleryOutput.isOn), .timeLimit(.minutes(5)))
@MainActor
struct GalleryLaunchpadMacsTests {
    private static let both: [RenderAppearance] = [.light, .dark]
    private static let screens = "Sources/AgentToolingApp/Launchpad/Screens"

    @Test func yourOtherMacs() async throws {
        let states: [(MacsScene.S17, String)] = [
            (.typed, "before connecting"), (.empty, "no address: Skip for now"), (.connected, "shared"),
            (.refused, "a refused publish"), (.scp, "the scp form (V9)"), (.alreadyConnected, "already shared (rerun)"),
            (.unreachable, "the check could not reach: Try again"),
        ]
        for appearance in Self.both {
            for (state, title) in states {
                let scene = try await MacsScene.s17(state)
                try galleryStageSnapshot(
                    scene.view, screen: "S17 Your other Macs", state: title, appearance: appearance,
                    source: "\(Self.screens)/LaunchpadMacsScreen.swift")
                await scene.close()
            }
        }
    }

    /// The join consent strip with synthetic app observations.
    @Test func join() async throws {
        let states: [(MacsScene.J01, String, String)] = [
            (.joining, "J01 Join", "joining, step 3"), (.ready, "J01 Join", "checks passed"),
            (.typo, "V08 Couldn’t reach that repository", "a typo"), (.finish, "J01 Join", "Finish joining"),
        ]
        for appearance in Self.both {
            for (state, screen, title) in states {
                let scene = try await MacsScene.j01(state)
                try galleryStageSnapshot(
                    scene.view, screen: screen, state: title, appearance: appearance,
                    source: "\(Self.screens)/LaunchpadJoinScreen.swift")
                await scene.close()
            }
        }
    }

    @Test func youJoined() async throws {
        let states: [(MacsScene.J02, Int, String)] = [
            (.ready, 0, "arrivals ready"), (.checking, 0, "checking what Juniper shares"),
            (.underThePanel, 0, "the review over it"), (.notWorkedOut, 0, "what Juniper shares could not be worked out"),
            (.ready, 9, "more arrivals than fit, scrolling"),
        ]
        for appearance in Self.both {
            for (state, sharing, title) in states {
                let scene = try await MacsScene.j02(state, sharing: sharing)
                try galleryStageSnapshot(
                    scene.view, screen: "J02 You joined", state: title, appearance: appearance,
                    source: "\(Self.screens)/LaunchpadArrivalsScreen.swift")
                await scene.close()
            }
        }
    }
}
