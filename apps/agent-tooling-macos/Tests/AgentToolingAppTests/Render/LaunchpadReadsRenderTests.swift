import AgentToolingCore
import AgentToolingTestSupport
import AppKit
import SwiftUI
import Testing

@testable import AgentToolingApp

/// Your apps, the read and what was found draw at the stage's size in light
/// and dark, still and at the sample world's clock; the four tiles stand at
/// the same place on every face (x 136 / 332 / 528 / 724, y 170) and Your
/// apps' ⌘ keys sit at y 306; drawing Your apps and What Agent Tooling reads
/// runs nothing; and content that arrives after the stage laid out leaves
/// its window as it was.
@Suite("Launchpad reads renders", .serialized, .timeLimit(.minutes(5)))
@MainActor
struct LaunchpadReadsRenderTests {
    @Test(arguments: [RenderAppearance.light, .dark])
    func everyFaceDraws(appearance: RenderAppearance) async throws {
        let gate = GatedCommandRunner()
        let fixture = try await LaunchpadFixture(readGate: gate)
        defer { fixture.remove() }
        let flow = fixture.flow()
        flow.choosePath(.startHere)
        try expectDrawn(fixture.stage(flow), size: WindowSize.stage, appearance: appearance)
        LaunchpadStageView.footer(for: flow).primary?.action()
        try expectDrawn(fixture.stage(flow), size: WindowSize.stage, appearance: appearance)

        let read = LaunchpadReadSession.of(flow)
        LaunchpadStageView.footer(for: flow).primary?.action()
        await gate.waitUntilCalled(times: 3)
        #expect(LaunchpadTileSequenceScreen.face(flow) == .reading)
        try expectDrawn(fixture.stage(flow), size: WindowSize.stage, appearance: appearance)
        gate.release()
        await waitUntil { read.phase == .finished }
        try expectDrawn(fixture.stage(flow), size: WindowSize.stage, appearance: appearance)
        LaunchpadStageView.footer(for: flow).primary?.action()
        #expect(LaunchpadTileSequenceScreen.face(flow) == .found)
        try expectDrawn(fixture.stage(flow), size: WindowSize.stage, appearance: appearance)

        let empty = try await LaunchpadFixture(.emptyMac)
        defer { empty.remove() }
        let nothing = empty.flow()
        nothing.choosePath(.startHere)
        try expectDrawn(empty.stage(nothing), size: WindowSize.stage, appearance: appearance)
    }

    @Test(arguments: [RenderAppearance.light, .dark])
    func aRerunsFacesDraw(appearance: RenderAppearance) async throws {
        let fixture = try await LaunchpadFixture()
        defer { fixture.remove() }
        let workspace = try await fixture.sample(.afterRead).workspace
        let flow = fixture.flow(.rerun, workspace: workspace)
        try expectDrawn(fixture.stage(flow), size: WindowSize.stage, appearance: appearance)
        LaunchpadStageView.footer(for: flow).primary?.action()
        try expectDrawn(fixture.stage(flow), size: WindowSize.stage, appearance: appearance)
        let read = LaunchpadReadSession.of(flow)
        LaunchpadStageView.footer(for: flow).primary?.action()
        await waitUntil { read.phase == .finished }
        LaunchpadStageView.footer(for: flow).primary?.action()
        try expectDrawn(fixture.stage(flow), size: WindowSize.stage, appearance: appearance)
    }

    /// Popovers draw on their own: where Agent Tooling looked, and an
    /// entry's copies with their file counts.
    @Test(arguments: [RenderAppearance.light, .dark])
    func thePopoversDraw(appearance: RenderAppearance) async throws {
        let fixture = try await LaunchpadFixture()
        defer { fixture.remove() }
        try expectDrawn(
            LaunchpadLookedPopover(client: .kiro, homeURL: fixture.home),
            size: CGSize(width: Size.infoPopover, height: Size.infoPopover), appearance: appearance)
        let workspace = try await fixture.sample(.afterRead).workspace
        let state = try #require(workspace.library.state)
        let rows = LibraryRowPresence.rows(
            in: state, observations: workspace.device.observations, managed: workspace.device.managedClients)
        for row in rows {
            try expectDrawn(
                LaunchpadFoundRowPopover(row: row, copies: row.copies, home: fixture.home) {},
                size: CGSize(width: Size.infoPopover, height: Size.infoPopover), appearance: appearance)
        }
    }

    /// An empty library reads "Nothing was found in these apps yet." in the
    /// list's place: here, an empty Mac with Kiro CLI turned on while
    /// missing.
    @Test(arguments: [RenderAppearance.light, .dark])
    func anEmptyLibraryDraws(appearance: RenderAppearance) async throws {
        let fixture = try await LaunchpadFixture(.emptyMac)
        defer { fixture.remove() }
        let flow = fixture.flow()
        flow.choosePath(.startHere)
        LaunchpadDetection.of(flow).toggle(.kiro)
        flow.seedOverride = LaunchpadDetection.of(flow).seed(findsProjectsFromClaudeHistory: true)
        #expect(LaunchpadStageView.footer(for: flow).primary?.title == "Manage 1 app")
        LaunchpadStageView.footer(for: flow).primary?.action()
        let read = LaunchpadTileSequenceScreen.read(flow)
        LaunchpadStageView.footer(for: flow).primary?.action()
        await waitUntil { read.phase == .finished }
        LaunchpadStageView.footer(for: flow).primary?.action()

        #expect(flow.step == .found)
        #expect(flow.workspace?.library.state?.library.rows.isEmpty == true)
        try expectDrawn(fixture.stage(flow), size: WindowSize.stage, appearance: appearance)
    }

    /// A library that could not be made draws its reason: on the read, with
    /// Try again, and on the empty Mac under Continue without apps.
    @Test(arguments: [RenderAppearance.light, .dark])
    func aLibraryThatCouldNotBeMadeDraws(appearance: RenderAppearance) async throws {
        let fixture = try await LaunchpadFixture()
        defer { fixture.remove() }
        try Data("{".utf8).write(to: fixture.support.appending(path: "workspace.json"))
        let flow = fixture.flow()
        flow.choosePath(.startHere)
        LaunchpadStageView.footer(for: flow).primary?.action()
        let read = LaunchpadReadSession.of(flow)
        LaunchpadStageView.footer(for: flow).primary?.action()
        await waitUntil { read.failure != nil }
        try expectDrawn(fixture.stage(flow), size: WindowSize.stage, appearance: appearance)

        let empty = try await LaunchpadFixture(.emptyMac)
        defer { empty.remove() }
        try Data("{".utf8).write(to: empty.support.appending(path: "workspace.json"))
        let nothing = empty.flow()
        nothing.choosePath(.startHere)
        LaunchpadStageView.footer(for: nothing).primary?.action()
        await waitUntil { LaunchpadReadSession.of(nothing).failure != nil }
        #expect(nothing.step == .apps)
        try expectDrawn(empty.stage(nothing), size: WindowSize.stage, appearance: appearance)
    }

    /// The tiles never move: on Your apps, What Agent Tooling reads, the
    /// read, what was found and the empty Mac, each app's tile is the same
    /// 64 pt square, centred on its column, its top at y 170.
    @Test func theTilesNeverMove() async throws {
        let gate = GatedCommandRunner()
        let fixture = try await LaunchpadFixture(readGate: gate)
        defer { fixture.remove() }
        let flow = fixture.flow()
        flow.choosePath(.startHere)
        var faces: [(String, [String: CGRect])] = []
        faces.append(("S02", try frames(fixture.stage(flow))))
        LaunchpadStageView.footer(for: flow).primary?.action()
        faces.append(("S04", try frames(fixture.stage(flow))))
        let read = LaunchpadReadSession.of(flow)
        LaunchpadStageView.footer(for: flow).primary?.action()
        await gate.waitUntilCalled(times: 3)
        faces.append(("S05", try frames(fixture.stage(flow))))
        gate.release()
        await waitUntil { read.phase == .finished }
        LaunchpadStageView.footer(for: flow).primary?.action()
        faces.append(("S06", try frames(fixture.stage(flow))))
        let empty = try await LaunchpadFixture(.emptyMac)
        defer { empty.remove() }
        let nothing = empty.flow()
        nothing.choosePath(.startHere)
        faces.append(("V01", try frames(empty.stage(nothing))))

        let centres: [ClientKind: CGFloat] = [.codex: 136, .claude: 332, .gemini: 528, .kiro: 724]
        for (face, found) in faces {
            for client in ClientKind.allCases {
                let tile = try #require(found[LaunchpadFrames.tile(client)], "\(face) drew no tile for \(client)")
                #expect(tile.minY == StageLayout.Grid.contentTop + StageLayout.Header.heroHeight + StageLayout.Well.tileTop)
                #expect(tile.minY == 170, "\(face) \(client)")
                #expect(tile.midX == centres[client], "\(face) \(client)")
                #expect(tile.size == CGSize(width: Size.stageTile, height: Size.stageTile), "\(face) \(client)")
            }
        }
        // Your apps' keys sit level, at y 306, on S02 and the empty Mac.
        for (face, found) in faces where face == "S02" || face == "V01" {
            for client in ClientKind.allCases {
                let keys = try #require(found[LaunchpadFrames.keys(client)], "\(face) drew no keys for \(client)")
                #expect(keys.minY == 306, "\(face) \(client)")
                #expect(keys.midX == centres[client], "\(face) \(client)")
            }
        }
        #expect(faces.first { $0.0 == "S04" }?.1[LaunchpadFrames.keys(.codex)] == nil)
    }

    /// Drawing Your apps and What Agent Tooling reads runs nothing: no read,
    /// no command, no sign-in, no check.
    @Test func drawingYourAppsAndTheConsentRunsNothing() async throws {
        let fixture = try await LaunchpadFixture()
        defer { fixture.remove() }
        let runners = RunnerCount()
        var environment = fixture.environment
        environment.makeRunner = { _ in runners.made() }
        let flow = LaunchpadFlow(entry: .firstRun, environment: environment)
        flow.choosePath(.startHere)
        try expectDrawn(fixture.stage(flow), size: WindowSize.stage)
        LaunchpadStageView.footer(for: flow).primary?.action()
        #expect(flow.step == .reads)
        try expectDrawn(fixture.stage(flow), size: WindowSize.stage)
        flow.seedOverride?.findsProjectsFromClaudeHistory = false
        try expectDrawn(fixture.stage(flow), size: WindowSize.stage)

        #expect(runners.count == 0)
        #expect(fixture.firstReads.started.isEmpty)
        #expect(fixture.signIn.shellProbes == 0)
        #expect(fixture.signIn.reads.isEmpty)
        #expect(fixture.observer.fullChecks == 0)
        #expect(fixture.observer.scopedChecks.isEmpty)
        #expect(!fixture.hasWorkspace)
    }

    /// What was found arriving after the read laid out, with its list, its
    /// header tally and its smaller well, leaves the stage's window as it
    /// was.
    @Test func whatWasFoundArrivingLateKeepsTheStageInItsWindow() async throws {
        let fixture = try await LaunchpadFixture()
        defer { fixture.remove() }
        let flow = fixture.flow()
        flow.choosePath(.startHere)
        LaunchpadStageView.footer(for: flow).primary?.action()
        let read = LaunchpadReadSession.of(flow)
        LaunchpadStageView.footer(for: flow).primary?.action()
        await waitUntil { read.phase == .finished }

        let layout = try await LateContentHarness.heightAfterChange(
            fixture.stage(flow), windowSize: WindowSize.stage, styleMask: LateContentHarness.stageWindowStyle
        ) {
            LaunchpadStageView.footer(for: flow).primary?.action()
        }

        #expect(flow.step == .found)
        #expect(layout.hostHeight == layout.windowHeight)
    }

    /// The list scrolls to keep the keyboard's place in view. With twelve
    /// entries, six a column, the card shows four rows; ↓ to the first
    /// column's sixth brings it inside the card.
    @Test func theKeyboardsPlaceStaysInsideTheList() async throws {
        let fixture = try await LaunchpadFixture()
        defer { fixture.remove() }
        let (flow, sample) = try await fixture.flow(at: .afterRead)
        let workspace = sample.workspace
        // Four more skills in Claude Code, read again and taken in.
        for number in 1...4 {
            try fixture.world.home.plantSkill(
                ".claude/skills/extra-\(number)", name: "extra-\(number)", description: "One more skill, number \(number).")
        }
        let reread = await fixture.world.registry.scanAll(
            homeURL: fixture.home, runner: fixture.world.scriptedRunner(), clients: [.claude])
        await workspace.device.adopt(reread)
        let state = try #require(workspace.library.state)
        let rows = LibraryRowPresence.rows(
            in: state, observations: workspace.device.observations, managed: workspace.device.managedClients)
        try #require(rows.count == 12)
        let columns = LibraryRowPresence.columns(rows)
        let sixth = columns.leading[5]
        let highlight = LaunchpadFoundHighlight.of(flow)
        let box = FramesBox()
        let view = fixture.stage(flow).environment(\.launchpadReportsFrames, true)
            .onPreferenceChange(LaunchpadFrames.self) { box.frames = $0 }
        var hiddenBefore = false

        _ = try await LateContentHarness.heightAfterChange(
            view, windowSize: WindowSize.stage, styleMask: LateContentHarness.stageWindowStyle
        ) {
            if let card = box.frames[LaunchpadFrames.listCard], let row = box.frames[LaunchpadFrames.row(sixth.id)] {
                hiddenBefore = row.minY >= card.maxY
            }
            for _ in 0..<6 { highlight.move(by: 1, in: columns.leading + columns.trailing) }
        }

        #expect(hiddenBefore)
        #expect(highlight.row == sixth.id)
        let card = try #require(box.frames[LaunchpadFrames.listCard])
        let row = try #require(box.frames[LaunchpadFrames.row(sixth.id)])
        #expect(card.insetBy(dx: -1, dy: -1).contains(row), "\(row) is outside \(card)")
    }

    /// A place read that no list held ("Not listed before") is a line of its
    /// own: every column reserves room for it and the well grows by a line,
    /// so Runs and the sign-in strip move down rather than being drawn over.
    @Test func aPlaceNotListedBeforeGrowsTheWell() async throws {
        let fixture = try await LaunchpadFixture()
        defer { fixture.remove() }
        typealias Screen = LaunchpadTileSequenceScreen
        let manifest = FirstReadManifest.build(chosen: fixture.world.found, homeURL: fixture.home, includeProjectHistory: true)
        let stray = fixture.home.appending(path: ".claude/stray.json")

        #expect(Screen.readLines(manifest) == StageLayout.Reads.readLinesReserved)
        #expect(Screen.readLines(manifest, unlisted: [.claude: [stray]]) == 6)
        #expect(Screen.readLines(manifest, unlisted: [.codex: [stray]]) == 5)
        #expect(Screen.wellHeight(.reading, extraReadLines: 1) == Screen.wellHeight(.reading) + StageLayout.Reads.manifestLine)
        #expect(Screen.wellHeight(.found, extraReadLines: 1) == Screen.wellHeight(.found))

        // It draws, under way, in a stage that stays in its window.
        var environment = fixture.environment
        let quick = fixture.firstReads
        environment.firstRead = { client, manifest in
            guard client == .claude else { return quick.reading(client, manifest: manifest) }
            let (events, continuation) = AsyncStream.makeStream(of: FirstRead.Event.self)
            continuation.yield(.unlisted(.claude, stray))
            return FirstRead.Reading(events) { continuation.finish() }
        }
        let flow = LaunchpadFlow(entry: .firstRun, environment: environment)
        flow.choosePath(.startHere)
        LaunchpadStageView.footer(for: flow).primary?.action()
        let read = LaunchpadReadSession.of(flow)
        LaunchpadStageView.footer(for: flow).primary?.action()
        await waitUntil { read.unlisted[.claude] == [stray] }
        try expectDrawn(fixture.stage(flow), size: WindowSize.stage)
        let layout = try await LateContentHarness.heightAfterChange(
            fixture.stage(flow), windowSize: WindowSize.stage, styleMask: LateContentHarness.stageWindowStyle
        ) {}
        #expect(layout.hostHeight == layout.windowHeight)
        await read.stop()
    }

    /// Where each tile and each set of keys was drawn, in the window.
    private func frames(_ view: some View) throws -> [String: CGRect] {
        let box = FramesBox()
        _ = try rasterize(
            view.environment(\.launchpadReportsFrames, true).onPreferenceChange(LaunchpadFrames.self) { box.frames = $0 },
            size: WindowSize.stage)
        return box.frames
    }
}

/// The frames a stage reported.
private final class FramesBox: @unchecked Sendable {
    private let lock = NSLock()
    private var reported: [String: CGRect] = [:]

    var frames: [String: CGRect] {
        get { lock.withLock { reported } }
        set { lock.withLock { reported = newValue } }
    }
}

/// Counts the runners the stage asks for, and hands back one that refuses.
private final class RunnerCount: @unchecked Sendable {
    private let lock = NSLock()
    private var creations = 0

    var count: Int { lock.withLock { creations } }

    func made() -> any CommandRunning {
        lock.withLock { creations += 1 }
        return RefusingCommandRunner()
    }
}
