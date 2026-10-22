import AgentToolingCore
import AgentToolingTestSupport
import AppKit
import SwiftUI
import Testing

@testable import AgentToolingApp

/// The stage kit's promises that its values alone cannot show: that the
/// grid puts every screen's parts where the mockups do, that each primitive
/// takes exactly its slot, that text keeps its contrast on the translucent
/// ground, the well and the plate it is drawn over, and that the native mark
/// is the app icon's own drawing.
@Suite("Stage primitives")
@MainActor
struct StagePrimitivesTests {
    // MARK: - The grid

    @Test func theContentSlotSitsUnderTheDragBandAboveTheFooter() {
        #expect(WindowSize.stage == CGSize(width: 860, height: 640))
        #expect(StageLayout.Grid.contentTop == 44)
        #expect(StageLayout.Grid.sideInset == 32)
        #expect(StageLayout.Grid.contentWidth == 796)
        #expect(StageLayout.Grid.footerHeight == 44)
        #expect(StageLayout.Grid.lastLine == 572)
        // A sheet opened from the stage is the content column wide.
        #expect(SheetSize.stageSheet.width == StageLayout.Grid.contentWidth)
        #expect(SheetSize.stageSheet.height < WindowSize.stage.height)
    }

    /// The tiles sit at x 136 / 332 / 528 / 724 (their centres), y 170, on
    /// every screen that draws them, and the poster's places wait there.
    @Test func theWellsColumnsPutTheTilesWhereTheMockupsDo() {
        let centres = (0..<ClientKind.allCases.count).map { index in
            StageLayout.Grid.sideInset + StageLayout.Well.columnInset
                + CGFloat(index) * (StageLayout.Well.column + StageLayout.Well.columnGap) + StageLayout.Well.column / 2
        }
        #expect(centres == [136, 332, 528, 724])
        #expect(StageLayout.Well.columnInset == 14)
        #expect(StageLayout.Grid.contentTop + StageLayout.Header.heroHeight + StageLayout.Well.tileTop == 170)
        #expect(StageLayout.Grid.contentTop + StageLayout.Poster.placesTop == 170)
        #expect(StageLayout.Grid.contentTop + StageLayout.Poster.markTop == 40)
        #expect(Size.heroMark == Size.stageTile * 1.75)
    }

    @Test func eachHeadersPartsFitItsFixedHeight() {
        let header = StageLayout.Header.self
        let hero = header.eyebrowLine + header.heroTitleGap + header.heroTitleLine + header.heroSubtitleGap + header.subtitleBox
        let page = header.eyebrowLine + header.pageTitleGap + header.pageTitleLine + header.pageSubtitleGap + header.subtitleBox
        #expect(hero <= header.heroHeight)
        #expect(page <= header.pageHeight)
        #expect(header.subtitleMeasure <= StageLayout.Grid.contentWidth)
    }

    /// The review panel sits 16 in from the content column, centred, clear of
    /// the traffic lights and above the footer's line.
    @Test func theReviewPanelSitsInsideTheStage() {
        let panel = StageLayout.ReviewPanel.self
        #expect(panel.origin.x == StageLayout.Grid.sideInset + Space.xl)
        #expect(panel.origin.x * 2 + panel.size.width == WindowSize.stage.width)
        #expect(panel.origin.y >= StageLayout.Grid.dragBand)
        #expect(panel.origin.y + panel.size.height <= WindowSize.stage.height - Space.lg)
    }

    @Test func theFinishSettingUpRowsIndentLikeEveryRowAfterAGlyph() {
        #expect(StageLayout.FinishSetup.rowIndent == Hairline.afterLeading(Size.glyphSlot))
    }

    // MARK: - Each primitive takes its slot

    @Test func theHeadersKeepTheirHeightsWithOrWithoutASubtitle() throws {
        for subtitle in [nil, "Agent Tooling looks after the apps you choose, here and on your other Macs."] {
            let hero = try #require(
                fittingSize(of: StageHeader(.hero, eyebrow: "Your coding agents", title: "Your apps", subtitle: subtitle)))
            #expect(hero.height == StageLayout.Header.heroHeight)
            let page = try #require(
                fittingSize(of: StageHeader(.page, eyebrow: "Your library", title: "Make skills yours", subtitle: subtitle)))
            #expect(page.height == StageLayout.Header.pageHeight)
        }
    }

    @Test func theWellIsTheContentColumnWideAtEachHeight() throws {
        for height in [StageLayout.Well.agentsHeight, StageLayout.Well.readsHeight, StageLayout.Well.foundHeight] {
            let well = try #require(fittingSize(of: HeroWell(height: height) { _ in Color.clear.frame(height: Size.stageTile) }))
            #expect(well == CGSize(width: StageLayout.Grid.contentWidth, height: height))
        }
    }

    @Test func aTileTakesItsSlotInEveryState() throws {
        let states: [StageAgentTile.State] = [.place, .managed, .read, .reading, .ghost, .absent, .absentManaged]
        for state in states {
            let tile = try #require(fittingSize(of: StageAgentTile(client: .codex, state: state)))
            #expect(tile == CGSize(width: Size.stageTile, height: Size.stageTile), "\(state)")
            let compact = try #require(fittingSize(of: StageAgentTile(client: .codex, state: state, compact: true)))
            #expect(compact == CGSize(width: Size.stageTileCompact, height: Size.stageTileCompact), "\(state)")
        }
    }

    @Test func theMarkTakesExactlyItsSize() throws {
        #expect(try #require(fittingSize(of: AgentToolingMark())) == CGSize(width: Size.heroMark, height: Size.heroMark))
        #expect(try #require(fittingSize(of: AgentToolingAppMark())) == CGSize(width: Size.tile, height: Size.tile))
        #expect(
            try #require(fittingSize(of: AgentToolingAppMark(size: Size.tileSmall)))
                == CGSize(width: Size.tileSmall, height: Size.tileSmall))
    }

    @Test func thePosterIsTheStagesWidthAndItsOwnHeight() throws {
        let poster = try #require(fittingSize(of: StagePoster()))
        #expect(poster.height == StageLayout.Poster.height)
        #expect(poster.width >= StageLayout.Grid.contentWidth)
    }

    @Test func theFooterBarIsTheFootersHeight() throws {
        let info = LaunchpadStepInfo.of(.library, path: .startHere, entry: .firstRun)
        let spec = StageFooterSpec(primary: .init(title: LaunchpadCopy.Footer.continue) {})
        let bar = try #require(fittingSize(of: StageFooterBar(info: info, spec: spec).frame(width: WindowSize.stage.width)))
        #expect(bar.height == StageLayout.Grid.footerHeight)
        let confirm = try #require(
            fittingSize(
                of: StageFooterBar(info: info, spec: spec, isConfirmingLeave: true, leaveMoment: .afterCommit)
                    .frame(width: WindowSize.stage.width)))
        #expect(confirm.height == StageLayout.Grid.footerHeight)
    }

    @Test func theStageIsItsFixedWindow() throws {
        let stage = try #require(
            fittingSize(
                of: SetupStage {
                    Color.clear
                } footer: {
                    Color.clear
                } overlay: {
                    EmptyView()
                }))
        #expect(stage == WindowSize.stage)
    }

    @Test func stepCapsulesAndKeycapsAreTheirTokens() throws {
        let capsules = try #require(fittingSize(of: StepCapsules(reached: 2, total: 5)))
        #expect(capsules == CGSize(width: Size.stepCapsuleWidth * 5 + Space.xs * 4, height: Size.stepCapsuleHeight))
        let combo = try #require(fittingSize(of: KeyCombo([.command, .returnKey])))
        #expect(combo.height == Size.chipHeight)
        #expect(combo.width >= Size.chipHeight * 2 + Space.xxs)
    }

    @Test func aManifestColumnReservesItsReadLinesWhateverItLists() throws {
        let short = try #require(
            fittingSize(of: ManifestColumn(reads: [.init(id: "a", text: "~/.codex/config.toml")], runs: [])))
        let full = try #require(
            fittingSize(
                of: ManifestColumn(
                    reads: (0..<StageLayout.Reads.readLinesReserved).map { .init(id: "\($0)", text: "~/.codex/skills") },
                    runs: [])))
        #expect(short == full)
        #expect(short.width == StageLayout.Well.column)
    }

    // MARK: - Contrast

    /// Requires 4.5:1 text contrast on the composited stage surfaces. Where native
    /// macOS text itself falls short, stage contrast must stay within 5% of the
    /// native result, including light-mode secondary text.
    @Test(arguments: [NSAppearance.Name.aqua, .darkAqua])
    func textOnTheStageIsAsLegibleAsOnTheWindow(appearance: NSAppearance.Name) throws {
        let window = try resolved(Color(nsColor: .windowBackgroundColor), in: appearance)
        let ground = try stageGround(in: appearance)
        let surfaces: [(String, NSColor)] = [
            ("the ground", ground),
            ("the well", try #require(ContrastRatio.composited(try resolved(AgentTheme.wellFloor, in: appearance), over: ground))),
            ("a plate", try resolved(AgentTheme.plateOnCard, in: appearance)),
            ("the footer", try #require(ContrastRatio.composited(try resolved(AgentTheme.fillSubtle, in: appearance), over: ground))),
        ]
        for text in [NSColor.labelColor, .secondaryLabelColor] {
            let colour = try resolved(Color(nsColor: text), in: appearance)
            let onWindow = try #require(ContrastRatio.between(colour, window, over: window))
            let required = onWindow >= 4.5 ? 4.5 : onWindow * 0.95
            for (name, surface) in surfaces {
                let ratio = try #require(ContrastRatio.between(colour, surface, over: surface))
                #expect(ratio >= required, "\(text) has \(ratio):1 on \(name) in \(appearance.rawValue), under \(required):1")
            }
        }
    }

    /// A keycap is a mark naming a key, so its label keeps the 3:1 a mark
    /// needs on the cap.
    @Test(arguments: [NSAppearance.Name.aqua, .darkAqua])
    func aKeycapStillReadsAsAKey(appearance: NSAppearance.Name) throws {
        let ground = try stageGround(in: appearance)
        let strip = try #require(ContrastRatio.composited(try resolved(AgentTheme.fillSubtle, in: appearance), over: ground))
        let cap = try #require(ContrastRatio.composited(try resolved(AgentTheme.fillStrong, in: appearance), over: strip))
        let label = try resolved(Color(nsColor: .secondaryLabelColor), in: appearance)
        let ratio = try #require(ContrastRatio.between(label, cap, over: cap))
        #expect(ratio >= 3, "a keycap's label has \(ratio):1 in \(appearance.rawValue)")
    }

    /// Inside the accent-filled primary a keycap's glyph is a symbol, so it
    /// keeps the 3:1 a mark needs on the cap's wash.
    @Test(arguments: [NSAppearance.Name.aqua, .darkAqua])
    func aKeycapOnThePrimaryKeepsItsGlyph(appearance: NSAppearance.Name) throws {
        let accent = try resolved(AgentTheme.selection, in: appearance)
        let wash = try resolved(AgentTheme.onSelection.opacity(Opacity.keycapWash), in: appearance)
        let glyph = try resolved(AgentTheme.onSelection.opacity(Opacity.keycapLabel), in: appearance)
        let ratio = try #require(ContrastRatio.between(glyph, wash, over: accent))
        #expect(ratio >= 3, "a keycap's glyph has \(ratio):1 on the primary in \(appearance.rawValue)")
    }

    /// The symbol tiles' graphite keeps a white symbol at 4.5:1.
    @Test(arguments: [NSAppearance.Name.aqua, .darkAqua])
    func aWhiteSymbolKeepsItsContrastOnGraphite(appearance: NSAppearance.Name) throws {
        let ratio = try #require(ContrastRatio.between(.white, try resolved(AgentTheme.graphiteDeep, in: appearance)))
        #expect(ratio >= 4.5, "white has \(ratio):1 on graphite in \(appearance.rawValue)")
    }

    /// Proves the checks above read each face, and that compositing sees the
    /// ground: a wash over black is darker than the same wash over white.
    @Test func theChecksSeeEachFaceAndTheGroundUnderAWash() throws {
        #expect(try resolved(AgentTheme.stageGround, in: .aqua) != (try resolved(AgentTheme.stageGround, in: .darkAqua)))
        let wash = NSColor(white: 1, alpha: 0.5)
        let overBlack = try #require(ContrastRatio.composited(wash, over: .black))
        let overWhite = try #require(ContrastRatio.composited(wash, over: .white))
        #expect(try #require(ContrastRatio.luminance(of: overBlack)) < (try #require(ContrastRatio.luminance(of: overWhite))))
    }

    // MARK: - The mark is the icon's drawing

    /// The stage draws Agent Tooling's mark natively from numbers; these are
    /// the numbers `Resources/AppIcon.svg` draws the app icon with.
    @Test func theNativeMarkIsTheAppIconsDrawing() throws {
        let svg = try PackageSourceFile.text(at: "Resources/AppIcon.svg")
        typealias Art = AgentToolingMarkArtwork

        let rects = try Self.elements("rect", in: svg)
        try #require(rects.count == 3)
        #expect(Self.rect(rects[0]) == Art.plate)
        #expect(rects[0]["rx"].flatMap(Double.init) == Double(Art.plateRadius))
        #expect(rects[0]["fill"] == Self.hex(Art.plateColour))
        #expect(Self.rect(rects[1]) == Art.innerPlate)
        #expect(rects[1]["rx"].flatMap(Double.init) == Double(Art.innerPlateRadius))
        #expect(rects[1]["fill"] == Self.hex(Art.innerPlateColour))
        #expect(rects[1]["stroke-width"].flatMap(Double.init) == Double(Art.innerPlateStroke))
        #expect(Self.rect(rects[2]) == Art.face)
        #expect(rects[2]["rx"].flatMap(Double.init) == Double(Art.faceRadius))
        #expect(rects[2]["fill-opacity"].flatMap(Double.init) == Art.faceOpacity)
        #expect(rects[2]["stroke"] == Self.hex(Art.faceStrokeColour))
        #expect(rects[2]["stroke-opacity"].flatMap(Double.init) == Art.faceStrokeOpacity)
        #expect(rects[2]["stroke-width"].flatMap(Double.init) == Double(Art.faceStroke))

        // The icon file lifts its plate and knobs with its own filters; the
        // stage draws the mockups' shadows instead, dropping each knob's as far
        // as the file does.
        let shadows = try Self.elements("feDropShadow", in: svg)
        try #require(shadows.count == 2)
        #expect(shadows[1]["dy"].flatMap(Double.init) == Double(Art.knobShadowY))

        let tracks = try Self.matches(#"M(\d+) (\d+) H(\d+)"#, in: svg)
        #expect(tracks.map { Double($0[1]) } == Art.trackY.map { Double($0) })
        #expect(Set(tracks.map { Double($0[0]) }) == [Double(Art.trackStart)])
        #expect(Set(tracks.map { Double($0[2]) }) == [Double(Art.trackEnd)])
        let trackGroup = try #require(try Self.elements("g", in: svg).first { $0["stroke-linecap"] == "round" })
        #expect(trackGroup["stroke"] == Self.hex(Art.ink))
        #expect(trackGroup["stroke-opacity"].flatMap(Double.init) == Art.trackOpacity)
        #expect(trackGroup["stroke-width"].flatMap(Double.init) == Double(Art.trackWidth))

        let circles = try Self.elements("circle", in: svg)
        let knobs = circles.filter { $0["r"].flatMap(Double.init) == Double(Art.knobRadius) }
        let dots = circles.filter { $0["r"].flatMap(Double.init) == Double(Art.dotRadius) }
        #expect(knobs.compactMap { $0["cx"].flatMap(Double.init) } == Art.knobX.map { Double($0) })
        #expect(knobs.compactMap { $0["cy"].flatMap(Double.init) } == Art.trackY.map { Double($0) })
        #expect(Set(knobs.compactMap { $0["fill"] }) == [Self.hex(Art.knobColour)])
        #expect(Set(knobs.compactMap { $0["stroke-width"].flatMap(Double.init) }) == [Double(Art.knobStroke)])
        #expect(Set(knobs.compactMap { $0["stroke-opacity"].flatMap(Double.init) }) == [Art.knobStrokeOpacity])
        #expect(dots.compactMap { $0["cx"].flatMap(Double.init) } == Art.knobX.map { Double($0) })
        #expect(dots.compactMap { $0["fill"] } == [Self.hex(Art.knobBlue), Self.hex(Art.ink), Self.hex(Art.ink)])

        let highlight = try #require(try Self.matches(#"M(\d+) (\d+) C(\d+) (\d+) (\d+) (\d+) (\d+) (\d+)"#, in: svg).first)
        let points = [Art.highlightStart, Art.highlightControl1, Art.highlightControl2, Art.highlightEnd]
        #expect(highlight.compactMap(Double.init) == points.flatMap { [Double($0.x), Double($0.y)] })
        let path = try #require(try Self.elements("path", in: svg).first { $0["d"]?.contains("C") == true })
        #expect(path["stroke-width"].flatMap(Double.init) == Double(Art.highlightWidth))
        #expect(path["stroke-opacity"].flatMap(Double.init) == Art.highlightOpacity)
        #expect(svg.contains(#"viewBox="0 0 \#(Int(Art.viewBox)) \#(Int(Art.viewBox))""#))
    }

    // MARK: - Helpers

    /// The stage's ground as drawn: its translucent face over the window's
    /// own background, under its shade.
    private func stageGround(in appearance: NSAppearance.Name) throws -> NSColor {
        let window = try resolved(Color(nsColor: .windowBackgroundColor), in: appearance)
        let face = try #require(ContrastRatio.composited(try resolved(AgentTheme.stageGround, in: appearance), over: window))
        return try #require(ContrastRatio.composited(try resolved(AgentTheme.stageGroundShade, in: appearance), over: face))
    }

    /// The colour as drawn in `appearance`, fixed in sRGB.
    private func resolved(_ color: Color, in appearance: NSAppearance.Name) throws -> NSColor {
        let face = try #require(NSAppearance(named: appearance))
        var resolved: NSColor?
        face.performAsCurrentDrawingAppearance {
            resolved = NSColor(color).usingColorSpace(.sRGB)
        }
        return try #require(resolved, "the colour has no sRGB form")
    }

    /// Every `<name …>` element's attributes, in document order.
    private static func elements(_ name: String, in svg: String) throws -> [[String: String]] {
        let element = try NSRegularExpression(pattern: "<\(name)\\s([^>]*)>")
        let attribute = try NSRegularExpression(pattern: #"([A-Za-z-]+)="([^"]*)""#)
        return element.matches(in: svg, range: NSRange(svg.startIndex..., in: svg)).compactMap { match in
            guard let range = Range(match.range(at: 1), in: svg) else { return nil }
            let body = String(svg[range])
            var attributes: [String: String] = [:]
            for pair in attribute.matches(in: body, range: NSRange(body.startIndex..., in: body)) {
                guard let key = Range(pair.range(at: 1), in: body), let value = Range(pair.range(at: 2), in: body) else {
                    continue
                }
                attributes[String(body[key])] = String(body[value])
            }
            return attributes
        }
    }

    /// Each match's capture groups, in order.
    private static func matches(_ pattern: String, in text: String) throws -> [[String]] {
        let expression = try NSRegularExpression(pattern: pattern)
        return expression.matches(in: text, range: NSRange(text.startIndex..., in: text)).map { match in
            (1..<match.numberOfRanges).compactMap { Range(match.range(at: $0), in: text).map { String(text[$0]) } }
        }
    }

    private static func rect(_ attributes: [String: String]) -> CGRect? {
        guard let x = attributes["x"].flatMap(Double.init), let y = attributes["y"].flatMap(Double.init),
            let width = attributes["width"].flatMap(Double.init), let height = attributes["height"].flatMap(Double.init)
        else { return nil }
        return CGRect(x: x, y: y, width: width, height: height)
    }

    private static func hex(_ value: UInt32) -> String {
        "#" + String(format: "%06X", value)
    }
}
