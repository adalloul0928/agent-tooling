import AgentToolingCore
import AgentToolingTestSupport
import AppKit
import SwiftUI
import Testing

@testable import AgentToolingApp

/// Put tools in apps (S10) draws at the stage's size in both appearances: the
/// sample world's grid, a grid with nothing to place, and the grid with more
/// rows than the stage holds. The Where control is the system's own, with One
/// project unavailable until this Mac tracks a project. Drawing the screen
/// runs no app and writes nothing; content that changes after the stage laid
/// out leaves its window as it was.
@Suite("Launchpad place renders", .serialized, .timeLimit(.minutes(5)))
@MainActor
struct LaunchpadPlaceRenderTests {
    @Test(arguments: [RenderAppearance.light, .dark])
    func theSampleWorldsGridDraws(appearance: RenderAppearance) async throws {
        let fixture = try await LaunchpadFixture()
        defer { fixture.remove() }
        let (flow, sample) = try await fixture.flow(at: .afterLibrary)
        let head = try fixture.head(of: sample.workspace)
        let placement = try #require(LaunchpadPlaceScreen.placement(for: flow))
        await placement.load(decisions: flow.decisions)

        try expectDrawn(fixture.stage(flow), size: WindowSize.stage, appearance: appearance)

        // Drawing it checked no app, ran nothing and wrote nothing.
        #expect(try fixture.head(of: sample.workspace) == head)
        #expect(fixture.observer.fullChecks == 0)
        #expect(fixture.observer.scopedChecks.isEmpty)
    }

    @Test(arguments: [RenderAppearance.light, .dark])
    func nothingToPlaceDraws(appearance: RenderAppearance) async throws {
        let fixture = try await LaunchpadFixture()
        defer { fixture.remove() }
        let (_, sample) = try await fixture.flow(at: .afterRead)
        let flow = fixture.flow(.continueFirstRun(.place), workspace: sample.workspace)
        let placement = try #require(LaunchpadPlaceScreen.placement(for: flow))
        await placement.load(decisions: flow.decisions)
        #expect(placement.items.isEmpty)

        try expectDrawn(fixture.stage(flow), size: WindowSize.stage, appearance: appearance)
    }

    /// The grid arrives after the stage has laid out, once its what-if plan
    /// is worked out: it takes its place under the Where row and leaves the
    /// stage's window exactly as it was.
    @Test func theGridArrivingLateKeepsTheStageInItsWindow() async throws {
        let fixture = try await LaunchpadFixture()
        defer { fixture.remove() }
        let (flow, _) = try await fixture.flow(at: .afterLibrary)
        let placement = try #require(LaunchpadPlaceScreen.placement(for: flow))
        #expect(placement.items.isEmpty)

        let layout = try await LateContentHarness.heightAfterChange(
            fixture.stage(flow), windowSize: WindowSize.stage, styleMask: LateContentHarness.stageWindowStyle
        ) {
            await placement.load(decisions: flow.decisions)
        }

        #expect(placement.items.count == 3)
        #expect(layout.hostHeight == layout.windowHeight)
    }

    /// More rows than the stage holds: the rows scroll inside the grid's
    /// card, the captions stay in the slot, and the stage never grows.
    @Test(arguments: [RenderAppearance.light, .dark])
    func moreRowsThanFitScrollInsideTheGrid(appearance: RenderAppearance) async throws {
        let fixture = try await LaunchpadFixture()
        defer { fixture.remove() }
        let (flow, sample) = try await fixture.flow(at: .afterLibrary)
        flow.decisions.added += try Self.plugins(["GitHub", "Sentry", "Linear"], in: sample)
        let placement = try #require(LaunchpadPlaceScreen.placement(for: flow))

        let layout = try await LateContentHarness.heightAfterChange(
            fixture.stage(flow), windowSize: WindowSize.stage, styleMask: LateContentHarness.stageWindowStyle
        ) {
            await placement.load(decisions: flow.decisions)
        }

        #expect(placement.items.map(\.name) == ["Release Notes", "Frontend Design", "Supabase", "GitHub", "Sentry", "Linear"])
        #expect(layout.hostHeight == layout.windowHeight)
        try expectDrawn(fixture.stage(flow), size: WindowSize.stage, appearance: appearance)
    }

    /// Four app columns: they share what the item column leaves, their words
    /// wrap, and the stage keeps its size.
    @Test(arguments: [RenderAppearance.light, .dark])
    func fourAppsShareTheGrid(appearance: RenderAppearance) async throws {
        let fixture = try await LaunchpadFixture()
        defer { fixture.remove() }
        let (flow, sample) = try await fixture.flow(at: .afterLibrary)
        try await Self.addKiro(to: sample, fixture: fixture)
        let placement = try #require(LaunchpadPlaceScreen.placement(for: flow))
        await placement.load(decisions: flow.decisions)

        #expect(placement.apps == [.codex, .claude, .gemini, .kiro])
        #expect(StageLayout.Matrix.appColumnWidth(count: 4) * 4 + StageLayout.Matrix.itemColumn == StageLayout.Grid.contentWidth)
        #expect(placement.cells[.init(item: placement.items[2].artifactID, app: .kiro)] == .unavailable("Kiro CLI takes no plugins"))
        try expectDrawn(fixture.stage(flow), size: WindowSize.stage, appearance: appearance)
    }

    /// Kiro CLI turned on and read as found, from Gemini CLI's reading with
    /// none of its contents: a fourth app column.
    static func addKiro(to sample: LaunchpadSample, fixture: LaunchpadFixture) async throws {
        var kiro = try #require(fixture.observations[.gemini])
        kiro.surface = .kiroCLI
        kiro.version = "kiro-cli 2.23.0"
        kiro.configurationPaths = []
        kiro.discoveredSkills = []
        kiro.discoveredPlugins = []
        kiro.discoveredMCPServers = []
        kiro.skillMetadata = [:]
        kiro.pluginMetadata = [:]
        kiro.mcpMetadata = [:]
        await sample.workspace.device.setEnabled(.kiro, true)
        await sample.workspace.device.adopt([kiro])
    }

    /// The sample world's plugins named `names`, as if this setup had added
    /// them from their apps' catalogs.
    static func plugins(_ names: [String], in sample: LaunchpadSample) throws -> [LaunchpadLibraryDecisions.Added] {
        let artifacts = sample.workspace.library.state?.snapshot.document.artifacts ?? []
        return try names.map { name in
            let plugin = try #require(
                artifacts.first { $0.identity.displayName == name && $0.identity.kind == .nativePlugin },
                "the sample world has \(name)")
            let app = plugin.nativeRoutes.first?.client ?? .claude
            return .init(artifactID: plugin.identity.id, name: name, source: .catalog(app))
        }
    }

    /// One project cannot be chosen on a Mac that tracks no project, and the
    /// control says why: the system's segmented control, its third segment
    /// off and carrying the help.
    @Test func oneProjectWaitsForATrackedProject() async throws {
        let fixture = try await LaunchpadFixture()
        defer { fixture.remove() }
        let (flow, _) = try await fixture.flow(at: .afterLibrary)
        let placement = try #require(LaunchpadPlaceScreen.placement(for: flow))
        await placement.load(decisions: flow.decisions)
        #expect(placement.projects.isEmpty)
        let stage = PlaceHostedStage(fixture.stage(flow))
        defer { stage.close() }

        let control = try #require(stage.segmentedControls.first, "the Where control is the system's segmented control")
        #expect(control.segmentCount == 3)
        #expect((0..<3).map { control.label(forSegment: $0) } == ["Every Mac", "This Mac only", "One project"])
        #expect(control.isEnabled(forSegment: 0))
        #expect(control.isEnabled(forSegment: 1))
        #expect(!control.isEnabled(forSegment: 2))
        #expect(control.toolTip(forSegment: 2) == "Track a project first, on Projects.")
        #expect(control.selectedSegment == 0)
    }
}

/// The stage in a real window of its own, so a test can find the AppKit
/// controls SwiftUI draws it with.
@MainActor
private final class PlaceHostedStage {
    private let window: NSWindow
    private let host: NSView

    init(_ view: some View) {
        window = NSWindow(
            contentRect: CGRect(origin: .zero, size: WindowSize.stage), styleMask: LateContentHarness.stageWindowStyle,
            backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        host = NSHostingView(rootView: AnyView(view))
        window.contentView = host
        window.orderFrontRegardless()
        settle()
    }

    /// Lets the window take in what changed and lay it out.
    func settle() {
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        host.layoutSubtreeIfNeeded()
    }

    var segmentedControls: [NSSegmentedControl] { Self.views(in: host) }

    func close() {
        window.orderOut(nil)
    }

    private static func views<View: NSView>(in root: NSView) -> [View] {
        root.subviews.flatMap { subview in ((subview as? View).map { [$0] } ?? []) + views(in: subview) }
    }
}
