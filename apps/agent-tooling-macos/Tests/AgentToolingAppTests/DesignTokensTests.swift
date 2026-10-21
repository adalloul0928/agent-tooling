import AgentToolingCore
import AgentToolingTestSupport
import AppKit
import SwiftUI
import Testing

@testable import AgentToolingApp

/// The promises a few tokens make that a value alone cannot show: that the
/// absent-client ring can be seen, that it fills the same slot as the mark it
/// replaces, and that the shared helpers lay out exactly like the literals
/// they stand for.
@Suite("Design tokens")
@MainActor
struct DesignTokensTests {
    @Test(
        "The absent-client ring keeps 3:1 against a card in both appearances",
        arguments: [NSAppearance.Name.aqua, .darkAqua])
    func absentMarkContrast(appearance: NSAppearance.Name) throws {
        let mark = try resolved(AgentTheme.absentMark, in: appearance)
        for ground in [AgentTheme.controlBackground, AgentTheme.contentBackground] {
            let ratio = try contrast(mark, resolved(ground, in: appearance))
            #expect(ratio >= 3, "the absent mark has only \(ratio):1 against a card in \(appearance.rawValue)")
        }
    }

    /// Proves the check above reads each face: if both resolved alike, the
    /// dark case would pass on the light colours.
    @Test("The contrast check resolves the light and the dark face separately")
    func contrastCheckSeesBothFaces() throws {
        let light = try resolved(AgentTheme.controlBackground, in: .aqua)
        let dark = try resolved(AgentTheme.controlBackground, in: .darkAqua)
        #expect(light != dark)
        #expect(try contrast(light, dark) > 3)
    }

    @Test("An absent mark takes exactly the slot of the brand mark it stands in for")
    func absentMarkKeepsTheSlot() throws {
        #expect(try #require(fittingSize(of: AbsentMark())) == CGSize(width: Size.brandMark, height: Size.brandMark))
        #expect(
            try #require(fittingSize(of: AbsentMark(size: Size.tileSmall)))
                == CGSize(width: Size.tileSmall, height: Size.tileSmall))
    }

    @Test("The client marks column holds a mark for every client")
    func clientMarksColumnFits() throws {
        let marks = try #require(fittingSize(of: TableClientMarks(clients: ClientKind.allCases, present: [])))
        #expect(marks.width <= CollectionColumn.clientMarks)
    }

    @Test("A resizable sheet lays out exactly like the frame it replaces")
    func resizableSheetSize() throws {
        let literal = try #require(
            fittingSize(
                of: Color.clear.frame(
                    minWidth: SheetSize.inspectorMinimum.width, idealWidth: SheetSize.inspectorIdeal.width,
                    minHeight: SheetSize.inspectorMinimum.height, idealHeight: SheetSize.inspectorIdeal.height)))
        let helper = try #require(
            fittingSize(of: Color.clear.sheetSize(minimum: SheetSize.inspectorMinimum, ideal: SheetSize.inspectorIdeal)))
        #expect(helper == literal)
        #expect(helper == SheetSize.inspectorIdeal)
    }

    @Test("A split's shares divide its whole width")
    func splitSharesAddUp() {
        #expect(Proportion.listShare + Proportion.detailShare == 1)
        #expect(Proportion.evenShare * 2 == 1)
    }

    /// The type scale is the only one. A text style resolves to its own size,
    /// which the scale does not have, and drifts from the fonts beside it; the
    /// tool run panel's output was set that way until `monoMicro` existed.
    @Test("Every font a view draws comes from AgentFont, never a text style")
    func fontsComeFromTheScale() throws {
        let styles = "largeTitle|title|title2|title3|headline|subheadline|body|callout|footnote|caption|caption2"
        let textStyle = try NSRegularExpression(
            pattern: #"(\.system\(\s*\.|\.font\(\s*\.|(?<![A-Za-z])Font\.)("# + styles + #")\b"#)
        var found: [String] = []
        for file in try PackageSourceFile.all(in: "AgentToolingApp") {
            for (index, line) in file.lines.enumerated()
            where textStyle.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)) != nil {
                found.append("\(file.path):\(index + 1)")
            }
        }
        #expect(found.isEmpty, "a text-style font at \(found.joined(separator: ", "))")
    }

    // MARK: - Helpers

    /// The colour as drawn in `appearance`, fixed in sRGB so it no longer
    /// follows whichever appearance is current when it is compared.
    private func resolved(_ color: Color, in appearance: NSAppearance.Name) throws -> NSColor {
        let face = try #require(NSAppearance(named: appearance))
        var resolved: NSColor?
        face.performAsCurrentDrawingAppearance {
            resolved = NSColor(color).usingColorSpace(.sRGB)
        }
        return try #require(resolved, "the colour has no sRGB form")
    }

    private func contrast(_ first: NSColor, _ second: NSColor) throws -> Double {
        try #require(ContrastRatio.between(first, second), "a colour has no sRGB form")
    }
}
