import AgentToolingCore
import AgentToolingTestSupport
import AppKit
import SwiftUI
import Testing

@testable import AgentToolingApp

/// Start your library (S08) in the gallery, in its states and both
/// appearances, beside the editor sheet it opens at the stage's sheet size.
///
/// Enabled only when `AGENT_TOOLING_SCREEN_GALLERY` names an output folder.
@Suite("Gallery · Launchpad library", .serialized, .enabled(if: GalleryOutput.isOn))
@MainActor
struct GalleryLaunchpadLibraryTests {
    private static let both: [RenderAppearance] = [.light, .dark]
    private static let screen = "S08 Start your library"
    private static let source = "Sources/AgentToolingApp/Launchpad/Screens/LaunchpadLibraryScreen.swift"

    @Test func theMockupsChoicesAndNothingTicked() async throws {
        for appearance in Self.both {
            let fixture = try await LaunchpadFixture()
            defer { fixture.remove() }
            let model = try await LaunchpadLibraryAdditionsTests.library(fixture)
            try snapshot(fixture, model, "nothing ticked", appearance)
            LaunchpadLibraryRenderTests.tickAsTheMockupDoes(model)
            try snapshot(fixture, model, "the mockup's ticks and pick", appearance)
            for row in model.readyRows where !model.ticked.contains(row.id) { model.toggle(row.id) }
            try snapshot(fixture, model, "every skill ticked", appearance)
        }
    }

    @Test func afterAddAndRefused() async throws {
        for appearance in Self.both {
            let fixture = try await LaunchpadFixture()
            defer { fixture.remove() }
            try fixture.world.home.plant(
                ".claude/skills/webapp-testing/SKILL.md",
                "---\nname: webapp-check\ndescription: Drives a local web app.\n---\n\nStart the app.\n")
            let model = try await LaunchpadLibraryAdditionsTests.library(fixture)
            LaunchpadLibraryRenderTests.tickAsTheMockupDoes(model)
            for row in model.readyRows where !model.ticked.contains(row.id) { model.toggle(row.id) }
            _ = await model.commit()
            try snapshot(fixture, model, "added, one refused", appearance)
        }
    }

    /// The fragment's refusal, on the row it draws: Claude Code's copy of
    /// Frontend Design calls itself frontend-ui, so the row stays a chooser
    /// with the sentence under it.
    @Test func theFragmentsRefusalOnItsChooserRow() async throws {
        for appearance in Self.both {
            let fixture = try await LaunchpadFixture()
            defer { fixture.remove() }
            let model = try await LaunchpadLibraryRenderTests.claudesCopyRefused(fixture)
            try snapshot(fixture, model, "Claude Code's copy refused", appearance)
        }
    }

    @Test func threeCopiesAndAFailedFetch() async throws {
        for appearance in Self.both {
            let fixture = try await LaunchpadFixture()
            defer { fixture.remove() }
            let model = try await LaunchpadLibraryAdditionsTests.threeCopies(fixture)
            try snapshot(fixture, model, "three different copies", appearance)

            let failing = try await LaunchpadFixture()
            defer { failing.remove() }
            let fetch = try await LaunchpadLibraryAdditionsTests.library(
                failing, services: LaunchpadLibraryAdditionsTests.services(fetches: LibraryFetchLog(), failing: true))
            fetch.togglePick("claude:supabase@claude-plugins-official")
            fetch.togglePick("skills-sh:anthropics/skills/mcp-builder")
            _ = await fetch.commit()
            try snapshot(failing, fetch, "a fetch that failed", appearance)
        }
    }

    /// Adding while a skills.sh pick is fetched, with Stop in the footer.
    @Test func fetchingAPick() async throws {
        for appearance in Self.both {
            let fixture = try await LaunchpadFixture()
            defer { fixture.remove() }
            let model = try await LaunchpadLibraryAdditionsTests.library(
                fixture, services: LaunchpadLibraryAdditionsTests.heldFetch())
            LaunchpadLibraryRenderTests.tickAsTheMockupDoes(model)
            model.togglePick("skills-sh:anthropics/skills/mcp-builder")
            model.addAndMoveOn()
            await waitUntil { model.isFetching }
            try snapshot(fixture, model, "adding, a pick fetched", appearance)
            model.stopAdding()
            await model.commitTask?.value
        }
    }

    @Test func leftAloneNeedsGitAndEmptyMacs() async throws {
        for appearance in Self.both {
            let fixture = try await LaunchpadFixture()
            defer { fixture.remove() }
            let model = try await LaunchpadLibraryRenderTests.keptInStepByAnotherTool(fixture, hasGit: false)
            try snapshot(fixture, model, "kept in step by Example Manager, Needs Git", appearance)

            let empty = try await LaunchpadFixture(.emptyMac)
            defer { empty.remove() }
            let none = try await LaunchpadLibraryAdditionsTests.library(empty)
            try snapshot(empty, none, "no apps, the catalogs alone", appearance)

            let yours = try await LaunchpadFixture()
            defer { yours.remove() }
            let flow = try await LaunchpadLibraryAdditionsTests.flow(yours)
            let workspace = try #require(flow.workspace)
            let skills = yours.home.appending(path: ".claude/skills", directoryHint: .isDirectory)
            _ = await workspace.setup.adopt(
                paths: ["release-notes", "frontend-design", "webapp-testing"].map {
                    skills.appending(path: $0).path(percentEncoded: false)
                })
            await workspace.library.refresh()
            let all = LaunchpadLibraryAdditions.of(flow)
            all.services = LaunchpadLibraryAdditionsTests.services(fetches: LibraryFetchLog())
            await all.load()
            try snapshot(yours, all, "every skill yours already", appearance)
        }
    }

    @Test func theEditorAtTheStagesSheetSize() async throws {
        for appearance in Self.both {
            try gallerySnapshot(
                LaunchpadLibraryRenderTests.editor(), area: "Launchpad", screen: "S08 Write your own…",
                state: "skill editor at the stage sheet size", size: SheetSize.stageSheet, appearance: appearance,
                source: "Sources/AgentToolingApp/SkillEditorSheet.swift")
        }
    }

    private func snapshot(
        _ fixture: LaunchpadFixture, _ model: LaunchpadLibraryAdditions, _ state: String, _ appearance: RenderAppearance
    ) throws {
        try galleryStageSnapshot(
            fixture.stage(model.flow), screen: Self.screen, state: state, appearance: appearance, source: Self.source)
    }
}
