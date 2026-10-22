import AgentToolingCore
import AgentToolingTestSupport
import AppKit
import SwiftUI
import Testing

@testable import AgentToolingApp

/// Start your library (S08) draws at the stage's size in both appearances, in
/// each of its states, still and at the sample world's clock; drawing it runs
/// nothing; a third copy makes its row taller rather than drawing over the
/// next; content that arrives late leaves the stage's window as it was; and
/// the editor it opens draws at the stage's sheet size.
@Suite("Launchpad library renders", .serialized, .timeLimit(.minutes(5)))
@MainActor
struct LaunchpadLibraryRenderTests {
    @Test(arguments: [RenderAppearance.light, .dark])
    func theScreenDrawsInEachState(appearance: RenderAppearance) async throws {
        let fixture = try await LaunchpadFixture()
        defer { fixture.remove() }
        let model = try await LaunchpadLibraryAdditionsTests.library(fixture)
        try expectDrawn(fixture.stage(model.flow), size: WindowSize.stage, appearance: appearance)
        Self.tickAsTheMockupDoes(model)
        try expectDrawn(fixture.stage(model.flow), size: WindowSize.stage, appearance: appearance)
        _ = await model.commit()
        #expect(model.rows.prefix(2).allSatisfy { $0.state == .added })
        try expectDrawn(fixture.stage(model.flow), size: WindowSize.stage, appearance: appearance)
        // A pick whose fetch fails, said under the cards.
        model.services = LaunchpadLibraryAdditionsTests.services(fetches: LibraryFetchLog(), failing: true)
        model.togglePick("skills-sh:anthropics/skills/mcp-builder")
        _ = await model.commit()
        #expect(model.cardRefusals.count == 1)
        try expectDrawn(fixture.stage(model.flow), size: WindowSize.stage, appearance: appearance)

        let kept = try await LaunchpadFixture()
        defer { kept.remove() }
        let leftAlone = try await Self.keptInStepByAnotherTool(kept, hasGit: false)
        try expectDrawn(kept.stage(leftAlone.flow), size: WindowSize.stage, appearance: appearance)

        let refused = try await LaunchpadFixture()
        defer { refused.remove() }
        let renamed = try await Self.claudesCopyRefused(refused)
        try expectDrawn(refused.stage(renamed.flow), size: WindowSize.stage, appearance: appearance)

        let three = try await LaunchpadFixture()
        defer { three.remove() }
        let copies = try await LaunchpadLibraryAdditionsTests.threeCopies(three)
        try expectDrawn(three.stage(copies.flow), size: WindowSize.stage, appearance: appearance)

        let empty = try await LaunchpadFixture(.emptyMac)
        defer { empty.remove() }
        let none = try await LaunchpadLibraryAdditionsTests.library(empty)
        try expectDrawn(empty.stage(none.flow), size: WindowSize.stage, appearance: appearance)
    }

    /// Drawing the screen, ticks and picks included, reads nothing: no app is
    /// checked, no tool is looked for, no catalog is asked and no file an app
    /// reads changes.
    @Test func drawingTheScreenRunsNothing() async throws {
        var fixture = try await LaunchpadFixture()
        defer { fixture.remove() }
        let catalog = LibraryCountingCatalog()
        fixture.environment.sessions.marketplaceProviders = { _ in [catalog] }
        let model = try await LaunchpadLibraryAdditionsTests.library(fixture)
        let checks = (fixture.observer.fullChecks, fixture.observer.scopedChecks.count)
        let searches = fixture.setup.searchPathCalls
        let files = try LaunchpadLibraryAdditionsTests.files(under: fixture.home)

        try expectDrawn(fixture.stage(model.flow), size: WindowSize.stage)
        Self.tickAsTheMockupDoes(model)
        try expectDrawn(fixture.stage(model.flow), size: WindowSize.stage)

        #expect(await catalog.searches == 0)
        #expect(fixture.observer.fullChecks == checks.0)
        #expect(fixture.observer.scopedChecks.count == checks.1)
        #expect(fixture.setup.searchPathCalls == searches)
        #expect(try LaunchpadLibraryAdditionsTests.files(under: fixture.home) == files)
    }

    /// Three managed apps holding three different copies of Frontend Design:
    /// the chooser's third cell starts a second row of cells, and the screen
    /// is that much taller, so nothing is drawn over the row under it.
    @Test func aThirdCopyMakesItsRowTallerRatherThanCoveringTheNext() async throws {
        let two = try await LaunchpadFixture()
        defer { two.remove() }
        let twoCopies = try await LaunchpadLibraryAdditionsTests.library(two)
        let three = try await LaunchpadFixture()
        defer { three.remove() }
        let threeCopies = try await LaunchpadLibraryAdditionsTests.threeCopies(three)

        let before = try Self.scrolledHeight(two.stage(twoCopies.flow))
        let after = try Self.scrolledHeight(three.stage(threeCopies.flow))

        #expect(after - before == StageLayout.CopyChooser.extraHeight(forCopies: 3), "\(before) → \(after)")
    }

    /// A row's refusal arriving after the stage laid out takes the row's own
    /// line and leaves the stage's window exactly as it was.
    @Test func aRefusalArrivingLateKeepsTheStageInItsWindow() async throws {
        let fixture = try await LaunchpadFixture()
        defer { fixture.remove() }
        try fixture.world.home.plant(
            ".claude/skills/webapp-testing/SKILL.md",
            "---\nname: webapp-check\ndescription: Drives a local web app.\n---\n\nStart the app.\n")
        let model = try await LaunchpadLibraryAdditionsTests.library(fixture)
        let testing = try #require(model.rows.first { $0.copies.contains { $0.path.hasSuffix("/.claude/skills/webapp-testing") } })
        let claudeCopy = try #require(testing.copies.first { $0.readers == [.claude] }).path

        let layout = try await LateContentHarness.heightAfterChange(
            fixture.stage(model.flow), windowSize: WindowSize.stage, styleMask: LateContentHarness.stageWindowStyle
        ) {
            model.choose(claudeCopy, for: testing.id)
            _ = await model.commit()
        }

        guard case .refused = model.rows.first(where: { $0.id == testing.id })?.state else {
            Issue.record("Webapp Testing's mismatched SKILL.md is refused on its row")
            return
        }
        #expect(layout.hostHeight == layout.windowHeight)
    }

    /// The same for the chooser row: Claude Code's copy refused, its reason
    /// arriving under the chooser, and the window as it was.
    @Test func aCopysRefusalArrivingLateKeepsTheStageInItsWindow() async throws {
        let fixture = try await LaunchpadFixture()
        defer { fixture.remove() }
        let model = try await LaunchpadLibraryAdditionsTests.libraryWithClaudesCopyRenamed(fixture)
        let design = try #require(model.rows.first { $0.name == "Frontend Design" })

        let layout = try await LateContentHarness.heightAfterChange(
            fixture.stage(model.flow), windowSize: WindowSize.stage, styleMask: LateContentHarness.stageWindowStyle
        ) {
            model.toggle(design.id)
            _ = await model.commit()
        }

        #expect(model.copyRefusal(for: try #require(model.rows.first { $0.id == design.id })) != nil)
        #expect(layout.hostHeight == layout.windowHeight)
    }

    @Test(arguments: [RenderAppearance.light, .dark])
    func theEditorDrawsAtTheStagesSheetSize(appearance: RenderAppearance) throws {
        try expectDrawn(Self.editor(), size: SheetSize.stageSheet, appearance: appearance)
    }

    /// The editor at the stage's sheet size taking work that starts after it
    /// laid out keeps its window as it was.
    @Test func theEditorsLateContentKeepsItsWindow() async throws {
        let state = EditorState()
        let layout = try await LateContentHarness.heightAfterChange(
            EditorHost(state: state), windowSize: SheetSize.stageSheet, styleMask: LateContentHarness.stageWindowStyle
        ) {
            state.isBusy = true
            state.errorMessage = LaunchpadCopy.Library.Failures.notSaved
        }
        #expect(layout.hostHeight == layout.windowHeight)
    }

    // MARK: - Helpers

    /// Release Notes ticked, Claude Code's copy of Frontend Design chosen and
    /// Supabase picked, as the mockup's still has them.
    static func tickAsTheMockupDoes(_ model: LaunchpadLibraryAdditions) {
        guard let notes = model.rows.first(where: { $0.name == "Release Notes" }),
            let design = model.rows.first(where: { $0.name == "Frontend Design" }),
            let claude = design.copies.first(where: { $0.readers == [.claude] })
        else { return }
        model.toggle(notes.id)
        model.choose(claude.path, for: design.id)
        model.togglePick("claude:supabase@claude-plugins-official")
    }

    /// Juniper with Release Notes kept in step by Example Manager, on a Mac with or
    /// without Git.
    static func keptInStepByAnotherTool(_ fixture: LaunchpadFixture, hasGit: Bool) async throws -> LaunchpadLibraryAdditions {
        let flow = try await LaunchpadLibraryAdditionsTests.flow(fixture)
        guard let workspace = flow.workspace else { throw WorkspaceRevisionStoreError.notInitialized }
        let observations = workspace.device.observations.map { observation -> TargetObservation in
            var observation = observation
            if observation.surface.client == .claude {
                observation.skillMetadata["release-notes"]?.externalManager = ObservedExternalManager(tool: "Example Manager")
            }
            return observation
        }
        await workspace.device.adopt(observations)
        await workspace.library.refresh()
        let model = LaunchpadLibraryAdditions.of(flow)
        model.services = LaunchpadLibraryAdditionsTests.services(fetches: LibraryFetchLog(), hasGit: hasGit)
        await model.load()
        return model
    }

    /// The fragment's refusal on its own row: Frontend Design ticked with
    /// Claude Code's copy chosen, whose SKILL.md calls it frontend-ui, and
    /// Add pressed.
    static func claudesCopyRefused(_ fixture: LaunchpadFixture) async throws -> LaunchpadLibraryAdditions {
        let model = try await LaunchpadLibraryAdditionsTests.libraryWithClaudesCopyRenamed(fixture)
        guard let design = model.rows.first(where: { $0.name == "Frontend Design" }),
            let claude = design.copies.first(where: { $0.readers == [.claude] })
        else { return model }
        model.choose(claude.path, for: design.id)
        _ = await model.commit()
        return model
    }

    /// The editor as Start your library opens it.
    static func editor() -> some View {
        SkillEditorSheet(
            existingNames: ["Release Notes"], isBusy: false, canWrite: true, errorMessage: nil, size: SheetSize.stageSheet,
            offersPlacementNext: false
        ) { _, _ in }
        .environment(\.snapshotNow, ClientHomeFixture.now)
    }

    /// How tall the screen's scrolled content lays out on the stage: the
    /// height of the document its scroll view holds.
    static func scrolledHeight(_ view: some View) throws -> CGFloat {
        let host = NSHostingView(rootView: AnyView(view.frame(width: WindowSize.stage.width, height: WindowSize.stage.height)))
        host.frame = CGRect(origin: .zero, size: WindowSize.stage)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.orderFrontRegardless()
        defer { window.orderOut(nil) }
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        host.layoutSubtreeIfNeeded()
        let scroll = try #require(Self.scrollView(in: host), "the screen scrolls its content")
        return try #require(scroll.documentView, "the scroll view holds the content").frame.height
    }

    private static func scrollView(in view: NSView) -> NSScrollView? {
        if let scroll = view as? NSScrollView { return scroll }
        return view.subviews.lazy.compactMap(scrollView(in:)).first
    }
}

/// What the editor is handed, changed by a test after it laid out.
@MainActor @Observable
private final class EditorState {
    var isBusy = false
    var errorMessage: String?
}

private struct EditorHost: View {
    let state: EditorState

    var body: some View {
        SkillEditorSheet(
            existingNames: [], isBusy: state.isBusy, canWrite: true, errorMessage: state.errorMessage,
            size: SheetSize.stageSheet, offersPlacementNext: false
        ) { _, _ in }
    }
}
