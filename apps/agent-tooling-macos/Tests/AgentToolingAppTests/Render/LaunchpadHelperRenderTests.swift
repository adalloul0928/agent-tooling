import AgentToolingCore
import AgentToolingTestSupport
import AppKit
import SwiftUI
import Testing

@testable import AgentToolingApp

/// Before you start and Let your apps ask Agent Tooling draw at the stage's
/// size in light and dark, still and at the sample world's clock, in every
/// state they have. Before you start's four places sit exactly where Your
/// apps lights its tiles; drawing it moves, opens and reads nothing; and a
/// failure that arrives after it laid out leaves the stage in its window.
@Suite("Launchpad helper renders", .serialized, .timeLimit(.minutes(5)))
@MainActor
struct LaunchpadHelperRenderTests {
    @Test(arguments: [RenderAppearance.light, .dark])
    func beforeYouStartDrawsInEveryState(appearance: RenderAppearance) async throws {
        for state in GalleryMoveState.allCases {
            let stage = try await GalleryMoveStage(state)
            defer { stage.remove() }
            try expectDrawn(stage.view, size: WindowSize.stage, appearance: appearance)
        }
    }

    @Test(arguments: [RenderAppearance.light, .dark])
    func letYourAppsAskDrawsInEveryState(appearance: RenderAppearance) async throws {
        for state in GalleryAskState.allCases {
            let stage = try await GalleryAskStage(state)
            defer { stage.remove() }
            try expectDrawn(stage.view, size: WindowSize.stage, appearance: appearance)
        }
    }

    /// The poster's four places are plates at x 104 / 300 / 496 / 692, y 170,
    /// 64 square: where Your apps lights its tiles, so the next screen lights
    /// them where they wait.
    @Test(arguments: [RenderAppearance.light, .dark])
    func thePlacesSitWhereTheTilesLight(appearance: RenderAppearance) async throws {
        let stage = try await GalleryMoveStage(.diskImage)
        defer { stage.remove() }
        let bitmap = try rasterize(stage.view, size: WindowSize.stage, appearance: appearance)
        let probe = PixelProbe(bitmap)
        let top = StageLayout.Grid.contentTop + StageLayout.Poster.placesTop
        #expect(top == 170)

        for centre in [136, 332, 528, 724] as [CGFloat] {
            let left = centre - Size.stageTile / 2
            let right = centre + Size.stageTile / 2
            let middle = top + Size.stageTile / 2
            let ground = probe.colour(x: centre, y: top - 6)
            #expect(probe.differs(probe.colour(x: centre, y: middle), from: ground), "a plate at x \(centre)")
            // Just inside each edge is the plate; just outside is the ground.
            for (inside, outside) in [
                ((left + 4, middle), (left - 4, middle)), ((right - 4, middle), (right + 4, middle)),
                ((centre, top + 4), (centre, top - 4)), ((centre, top + Size.stageTile - 4), (centre, top + Size.stageTile + 4)),
            ] {
                #expect(
                    probe.differs(probe.colour(x: inside.0, y: inside.1), from: ground),
                    "inside the place at x \(centre): (\(inside.0), \(inside.1))")
                #expect(
                    !probe.differs(probe.colour(x: outside.0, y: outside.1), from: ground),
                    "outside the place at x \(centre): (\(outside.0), \(outside.1))")
            }
        }
    }

    /// Let your apps ask's explainer card is the fragment's y 140–272,
    /// whatever its lists need, and the apps card follows 16 under it, at
    /// y 288. Probed at x 60, inside both cards' left edge, clear of text.
    @Test(arguments: [RenderAppearance.light, .dark])
    func theExplainerCardKeepsItsHeight(appearance: RenderAppearance) async throws {
        let stage = try await GalleryAskStage(.geminiUnticked)
        defer { stage.remove() }
        let probe = PixelProbe(try rasterize(stage.view, size: WindowSize.stage, appearance: appearance))
        let x: CGFloat = 60
        let ground = probe.colour(x: x, y: 280)

        #expect(probe.differs(probe.colour(x: x, y: 268), from: ground), "the explainer card reaches y 272")
        #expect(!probe.differs(probe.colour(x: x, y: 276), from: ground), "and ends there")
        #expect(probe.differs(probe.colour(x: x, y: 292), from: ground), "the apps card starts at y 288")
    }

    /// Drawing Before you start reads where it would go and nothing more: no
    /// copy, no app opened, nothing quit, ejected or sent to the Trash, and no
    /// app read.
    @Test func drawingBeforeYouStartMovesNothing() async throws {
        let stage = try await GalleryMoveStage(.olderCopy)
        defer { stage.remove() }
        let applications = stage.fixture.home.appending(path: "Applications", directoryHint: .isDirectory)
        let before = try FileManager.default.contentsOfDirectory(atPath: applications.path)

        try expectDrawn(stage.view, size: WindowSize.stage)

        #expect(try FileManager.default.contentsOfDirectory(atPath: applications.path) == before)
        #expect(stage.recorder.opened.isEmpty)
        #expect(stage.recorder.terminated == 0)
        #expect(stage.recorder.ejected.isEmpty)
        #expect(stage.recorder.trashed.isEmpty)
        #expect(stage.fixture.firstReads.started.isEmpty)
        #expect(stage.fixture.observer.fullChecks == 0)
        #expect(!stage.fixture.hasWorkspace)
    }

    /// A failed move's banner takes the caption's place after the stage laid
    /// out, and the stage stays exactly in its window.
    @Test func aFailureArrivingLateKeepsTheStageInItsWindow() async throws {
        let stage = try await GalleryMoveStage(.failed, pressesPrimary: false)
        defer { stage.remove() }
        let model = LaunchpadMoveModel.of(stage.flow)

        let layout = try await LateContentHarness.heightAfterChange(
            stage.view, windowSize: WindowSize.stage, styleMask: LateContentHarness.stageWindowStyle
        ) {
            model.primary()
            await waitUntil { model.phase != .moving }
        }

        #expect(model.phase == .failed(LaunchpadCopy.Helper.Failures.notMoved))
        #expect(layout.hostHeight == layout.windowHeight)
    }
}

/// Reads a stage capture's pixels in stage points.
private struct PixelProbe {
    let bitmap: NSBitmapImageRep
    private let scale: CGFloat

    init(_ bitmap: NSBitmapImageRep) {
        self.bitmap = bitmap
        scale = CGFloat(bitmap.pixelsWide) / bitmap.size.width
    }

    func colour(x: CGFloat, y: CGFloat) -> (CGFloat, CGFloat, CGFloat) {
        let pixel = bitmap.colorAt(x: Int(x * scale), y: Int(y * scale))?.usingColorSpace(.sRGB)
        return (pixel?.redComponent ?? 0, pixel?.greenComponent ?? 0, pixel?.blueComponent ?? 0)
    }

    /// Whether two colours are told apart: more than a level of difference in
    /// some channel.
    func differs(_ lhs: (CGFloat, CGFloat, CGFloat), from rhs: (CGFloat, CGFloat, CGFloat)) -> Bool {
        max(abs(lhs.0 - rhs.0), abs(lhs.1 - rhs.1), abs(lhs.2 - rhs.2)) > Self.level
    }

    private static let level: CGFloat = 1.5 / 255
}
