import AgentToolingCore
import AgentToolingTestSupport
import AppKit
import SwiftUI
import Testing

@testable import AgentToolingApp

/// Verifies strips beside the review panel show only card edges. Smooth ground
/// bands permit the panel shadow; card columns remain constant vertically, so
/// text or horizontal rules behind the panel fail the pixel checks.
@Suite("Launchpad · the screen under the review panel", .serialized, .timeLimit(.minutes(5)))
@MainActor
struct LaunchpadUnderTheReviewPanelTests {
    /// The strips beside the 764 pt panel at (48, 40), from the stage's
    /// edge inset to the panel, a point and more in from either edge.
    private static let leftStrip: ClosedRange<CGFloat> = (Space.xxxl + 1)...(StageLayout.ReviewPanel.origin.x - 2)
    private static let rightStrip: ClosedRange<CGFloat> =
        (StageLayout.ReviewPanel.origin.x + StageLayout.ReviewPanel.size.width + 1)...(WindowSize.stage.width - Space.xxxl - 2)

    @Test(arguments: [RenderAppearance.light, .dark])
    func letYourAppsAskShowsOnlyItsCardsEdges(appearance: RenderAppearance) async throws {
        let fixture = try await LaunchpadFixture()
        defer { fixture.remove() }
        let (flow, sample) = try await fixture.flow(at: .afterAsk)
        // S11's words reach into the left strip while nothing is over it.
        let bare = PanelStrips(try rasterize(fixture.stage(flow), size: WindowSize.stage, appearance: appearance))
        #expect(!bare.isSmooth(x: Self.leftStrip, y: Self.askHeader), "the check would not see S11's header")

        let review = ScopedPlanReview(
            workspace: sample.workspace, scope: .wholePlan, deviceName: "Juniper", libraryDecisions: flow.decisions)
        flow.presentReview(review, returnTo: nil)
        await review.prepare()
        #expect(LaunchpadAskScreen.isUnderPanel(flow))
        let under = PanelStrips(try rasterize(fixture.stage(flow), size: WindowSize.stage, appearance: appearance))

        for strip in [Self.leftStrip, Self.rightStrip] {
            #expect(under.isSmooth(x: strip, y: Self.askHeader), "the header, x \(strip)")
            #expect(
                under.isFlatDownEachColumn(x: strip, y: Self.askExplainer),
                "the explainer card, x \(strip): \(under.firstBreak(x: strip, y: Self.askExplainer) ?? "")")
            #expect(
                under.isFlatDownEachColumn(x: strip, y: Self.askApps),
                "the apps card, x \(strip): \(under.firstBreak(x: strip, y: Self.askApps) ?? "")")
            #expect(under.isSmooth(x: strip, y: Self.askCaption), "the fine print, x \(strip)")
        }
    }

    @Test(arguments: [RenderAppearance.light, .dark])
    func youJoinedShowsOnlyItsCardsEdges(appearance: RenderAppearance) async throws {
        let fixture = try await LaunchpadFixture(.cedar)
        defer { fixture.remove() }
        let (flow, sample) = try await fixture.flow(at: .cedarJoined)
        defer { sample.remove() }
        let arrivals = try #require(LaunchpadArrivalsScreen.arrivals(for: flow))
        await arrivals.load()
        // The arrivals card's rows reach into the left strip while nothing is
        // over them. J02's well and greeting do not reach it either way, so
        // the card is what shows the panel hiding the screen there.
        let bare = PanelStrips(try rasterize(fixture.stage(flow), size: WindowSize.stage, appearance: appearance))
        #expect(!bare.isFlatDownEachColumn(x: Self.leftStrip, y: Self.joinedCard), "the check would not see J02's card")

        let review = ScopedPlanReview(workspace: sample.workspace, scope: .wholePlan, deviceName: "Cedar")
        flow.presentReview(review, returnTo: nil)
        await review.prepare()
        let under = PanelStrips(try rasterize(fixture.stage(flow), size: WindowSize.stage, appearance: appearance))

        for strip in [Self.leftStrip, Self.rightStrip] {
            #expect(
                under.isFlatDownEachColumn(x: strip, y: Self.joinedWell),
                "the well, x \(strip): \(under.firstBreak(x: strip, y: Self.joinedWell) ?? "")")
            #expect(under.isSmooth(x: strip, y: Self.joinedGreeting), "the greeting, x \(strip)")
            #expect(under.isFlatDownEachColumn(x: strip, y: Self.joinedCard), "the arrivals card, x \(strip)")
        }
    }

    // MARK: The bands, in stage points, each over one surface

    // A card's band keeps clear of its rounded corners, whose edge curves
    // across a column.

    /// S11's eyebrow, title and subtitle, over the ground.
    private static let askHeader: ClosedRange<CGFloat> = 50...134
    /// Inside the explainer card.
    private static let askExplainer: ClosedRange<CGFloat> = 160...250
    /// Inside the apps card, its header row's hairline included.
    private static let askApps: ClosedRange<CGFloat> = 312...470
    /// The fine print under the apps card, over the ground.
    private static let askCaption: ClosedRange<CGFloat> = 500...570
    /// J02's well, where the two Macs and the library between them are.
    private static let joinedWell: ClosedRange<CGFloat> = 112...170
    /// "You joined as Cedar" and the lines under it, over the ground.
    private static let joinedGreeting: ClosedRange<CGFloat> = 200...296
    /// Inside the arrivals card.
    private static let joinedCard: ClosedRange<CGFloat> = 320...424
}

/// A capture's pixels, read at the capture's own resolution over rectangles
/// given in stage points.
private struct PanelStrips {
    let bitmap: NSBitmapImageRep
    private let scale: CGFloat

    init(_ bitmap: NSBitmapImageRep) {
        self.bitmap = bitmap
        scale = CGFloat(bitmap.pixelsWide) / bitmap.size.width
    }

    /// No pixel differs from the one beside it or the one below it by more
    /// than a few levels.
    func isSmooth(x: ClosedRange<CGFloat>, y: ClosedRange<CGFloat>) -> Bool {
        let columns = pixels(x)
        let rows = pixels(y)
        for row in rows {
            for column in columns {
                let here = colour(column, row)
                if column < columns.upperBound, differs(here, colour(column + 1, row)) { return false }
                if row < rows.upperBound, differs(here, colour(column, row + 1)) { return false }
            }
        }
        return true
    }

    /// Each pixel column is one colour from the band's top to its bottom.
    func isFlatDownEachColumn(x: ClosedRange<CGFloat>, y: ClosedRange<CGFloat>) -> Bool {
        firstBreak(x: x, y: y) == nil
    }

    /// Where a column first changes colour, in pixels, and by how many
    /// levels: for a failure's message.
    func firstBreak(x: ClosedRange<CGFloat>, y: ClosedRange<CGFloat>) -> String? {
        let rows = pixels(y)
        for column in pixels(x) {
            let top = colour(column, rows.lowerBound)
            for row in rows where differs(top, colour(column, row)) {
                let here = colour(column, row)
                let levels = max(abs(here.0 - top.0), abs(here.1 - top.1), abs(here.2 - top.2), abs(here.3 - top.3)) * 255
                return "pixel (\(column), \(row)) is \(Int(levels.rounded())) levels from the top of its column"
            }
        }
        return nil
    }

    private func pixels(_ points: ClosedRange<CGFloat>) -> ClosedRange<Int> {
        Int((points.lowerBound * scale).rounded(.up))...Int((points.upperBound * scale).rounded(.down))
    }

    private func colour(_ x: Int, _ y: Int) -> (CGFloat, CGFloat, CGFloat, CGFloat) {
        let pixel = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB)
        return (pixel?.redComponent ?? 0, pixel?.greenComponent ?? 0, pixel?.blueComponent ?? 0, pixel?.alphaComponent ?? 0)
    }

    private func differs(_ lhs: (CGFloat, CGFloat, CGFloat, CGFloat), _ rhs: (CGFloat, CGFloat, CGFloat, CGFloat)) -> Bool {
        max(abs(lhs.0 - rhs.0), abs(lhs.1 - rhs.1), abs(lhs.2 - rhs.2), abs(lhs.3 - rhs.3)) > Self.tolerance
    }

    /// A few levels: the shadow's wash moves a level or less a pixel, and a
    /// glyph's antialiased edge far more.
    private static let tolerance: CGFloat = 3.5 / 255
}
