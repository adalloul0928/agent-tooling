import AgentToolingCore
import AgentToolingTestSupport
import SwiftUI
import Testing

@testable import AgentToolingApp

/// Put tools in apps (S10) in the gallery, in the stage's own window: the
/// sample world's grid as the fragment draws it, a cell turned off, This Mac
/// only, the grid with nothing to place, and a Mac whose apps could not all
/// be checked.
///
/// Enabled only when `AGENT_TOOLING_SCREEN_GALLERY` names an output folder.
@Suite("Gallery · Launchpad place", .serialized, .enabled(if: GalleryOutput.isOn))
@MainActor
struct GalleryLaunchpadPlaceTests {
    private static let both: [RenderAppearance] = [.light, .dark]
    private static let source = "Sources/AgentToolingApp/Launchpad/Screens/LaunchpadPlaceScreen.swift"

    /// The fragment's still: Release Notes into Codex and Supabase into
    /// Claude Code, the cursor on Release Notes in Codex.
    @Test func theSampleWorldsGrid() async throws {
        for appearance in Self.both {
            let fixture = try await LaunchpadFixture()
            defer { fixture.remove() }
            let (flow, placement) = try await loaded(fixture)
            try galleryStageSnapshot(
                fixture.stage(flow), screen: "S10 Put in apps", state: "2 changes so far", appearance: appearance,
                source: Self.source)
            #expect(placement.changeCount == 2)
        }
    }

    /// Space on Release Notes in Codex: Add, and Gemini CLI no longer gets it
    /// through Codex's folder.
    @Test func aCellTurnedOff() async throws {
        for appearance in Self.both {
            let fixture = try await LaunchpadFixture()
            defer { fixture.remove() }
            let (flow, placement) = try await loaded(fixture)
            let releaseNotes = try #require(placement.items.first)
            placement.toggle(.init(item: releaseNotes.artifactID, app: .codex))
            try galleryStageSnapshot(
                fixture.stage(flow), screen: "S10 Put in apps", state: "Release Notes turned off in Codex",
                appearance: appearance, source: Self.source)
        }
    }

    @Test func thisMacOnly() async throws {
        for appearance in Self.both {
            let fixture = try await LaunchpadFixture()
            defer { fixture.remove() }
            let (flow, placement) = try await loaded(fixture)
            await placement.choose(.thisMacOnly, decisions: flow.decisions)
            try galleryStageSnapshot(
                fixture.stage(flow), screen: "S10 Put in apps", state: "This Mac only", appearance: appearance,
                source: Self.source)
        }
    }

    /// The ↩-through path: Start your library added nothing.
    @Test func nothingToPlace() async throws {
        for appearance in Self.both {
            let fixture = try await LaunchpadFixture()
            defer { fixture.remove() }
            let (_, sample) = try await fixture.flow(at: .afterRead)
            let flow = fixture.flow(.continueFirstRun(.place), workspace: sample.workspace)
            flow.seedOverride = fixture.seed
            let placement = try #require(LaunchpadPlaceScreen.placement(for: flow))
            await placement.load(decisions: flow.decisions)
            try galleryStageSnapshot(
                fixture.stage(flow), screen: "S10 Put in apps", state: "nothing to place", appearance: appearance,
                source: Self.source)
        }
    }

    /// More rows than the stage holds: the rows scroll inside the card.
    @Test func moreRowsThanFit() async throws {
        for appearance in Self.both {
            let fixture = try await LaunchpadFixture()
            defer { fixture.remove() }
            let (flow, sample) = try await fixture.flow(at: .afterLibrary)
            flow.decisions.added += try LaunchpadPlaceRenderTests.plugins(["GitHub", "Sentry", "Linear"], in: sample)
            let placement = try #require(LaunchpadPlaceScreen.placement(for: flow))
            await placement.load(decisions: flow.decisions)
            try galleryStageSnapshot(
                fixture.stage(flow), screen: "S10 Put in apps", state: "six rows, scrolling", appearance: appearance,
                source: Self.source)
        }
    }

    /// A Mac that tracks a project: One project, and the menu to choose it.
    @Test func oneProject() async throws {
        for appearance in Self.both {
            let fixture = try await LaunchpadFixture()
            defer { fixture.remove() }
            let (flow, sample) = try await fixture.flow(at: .afterLibrary)
            let workspace = sample.workspace
            _ = try await workspace.service.createProject(.init(expectedRevisionID: try fixture.head(of: workspace), name: "storefront"))
            let project = try #require(try workspace.store.snapshot()?.document.logicalProjects.first)
            try await workspace.service.bindProjectRoot(
                projectID: project.id, rootPath: fixture.home.appending(path: "code/storefront").path(percentEncoded: false),
                expectedRevisionID: try fixture.head(of: workspace))
            let placement = try #require(LaunchpadPlaceScreen.placement(for: flow))
            await placement.load(decisions: flow.decisions)
            await placement.choose(.oneProject, decisions: flow.decisions)
            try galleryStageSnapshot(
                fixture.stage(flow), screen: "S10 Put in apps", state: "One project", appearance: appearance, source: Self.source)
        }
    }

    /// A Mac set to take only what names it: the grid opens on This Mac only,
    /// and a caption says why.
    @Test func aMacThatTakesOnlyWhatNamesIt() async throws {
        for appearance in Self.both {
            let fixture = try await LaunchpadFixture()
            defer { fixture.remove() }
            let (flow, sample) = try await fixture.flow(at: .afterLibrary)
            let workspace = sample.workspace
            _ = try await workspace.service.registerDevice(
                .init(
                    expectedRevisionID: try fixture.head(of: workspace), deviceID: workspace.store.deviceID, name: "Juniper",
                    receivesSharedAssignments: false))
            let placement = try #require(LaunchpadPlaceScreen.placement(for: flow))
            await placement.load(decisions: LaunchpadPlaceScreen.decisions(for: flow))
            #expect(placement.scope == .thisMacOnly)
            try galleryStageSnapshot(
                fixture.stage(flow), screen: "S10 Put in apps", state: "takes only what names it", appearance: appearance,
                source: Self.source)
        }
    }

    /// Kiro CLI turned on but never checked: no column, and the caption says
    /// when it gets one.
    @Test func anAppNotCheckedYet() async throws {
        for appearance in Self.both {
            let fixture = try await LaunchpadFixture()
            defer { fixture.remove() }
            let (flow, sample) = try await fixture.flow(at: .afterLibrary)
            await sample.workspace.device.setEnabled(.kiro, true)
            let placement = try #require(LaunchpadPlaceScreen.placement(for: flow))
            await placement.load(decisions: flow.decisions)
            try galleryStageSnapshot(
                fixture.stage(flow), screen: "S10 Put in apps", state: "Kiro CLI not checked", appearance: appearance,
                source: Self.source)
        }
    }

    /// Kiro CLI on and found: four app columns share what the item column
    /// leaves, and their words wrap.
    @Test func fourApps() async throws {
        for appearance in Self.both {
            let fixture = try await LaunchpadFixture()
            defer { fixture.remove() }
            let (flow, sample) = try await fixture.flow(at: .afterLibrary)
            try await LaunchpadPlaceRenderTests.addKiro(to: sample, fixture: fixture)
            let placement = try #require(LaunchpadPlaceScreen.placement(for: flow))
            await placement.load(decisions: flow.decisions)
            #expect(placement.apps == [.codex, .claude, .gemini, .kiro])
            try galleryStageSnapshot(
                fixture.stage(flow), screen: "S10 Put in apps", state: "four apps", appearance: appearance, source: Self.source)
        }
    }

    private func loaded(_ fixture: LaunchpadFixture) async throws -> (LaunchpadFlow, LaunchpadPlacement) {
        let (flow, _) = try await fixture.flow(at: .afterLibrary)
        let placement = try #require(LaunchpadPlaceScreen.placement(for: flow))
        await placement.load(decisions: flow.decisions)
        return (flow, placement)
    }
}
