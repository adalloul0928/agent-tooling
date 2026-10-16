import AgentToolingCore
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
        let mark = try components(of: AgentTheme.absentMark, in: appearance)
        for ground in [AgentTheme.controlBackground, AgentTheme.contentBackground] {
            let ratio = contrast(mark, try components(of: ground, in: appearance))
            #expect(ratio >= 3, "the absent mark has only \(ratio):1 against a card in \(appearance.rawValue)")
        }
    }

    /// Proves the check above reads each face: if both resolved alike, the
    /// dark case would pass on the light colours.
    @Test("The contrast check resolves the light and the dark face separately")
    func contrastCheckSeesBothFaces() throws {
        let light = try components(of: AgentTheme.controlBackground, in: .aqua)
        let dark = try components(of: AgentTheme.controlBackground, in: .darkAqua)
        #expect(light != dark)
        #expect(contrast(light, dark) > 3)
    }

    @Test("An absent mark takes exactly the slot of the brand mark it stands in for")
    func absentMarkKeepsTheSlot() throws {
        #expect(try measure(AbsentMark()) == CGSize(width: Size.brandMark, height: Size.brandMark))
        #expect(try measure(AbsentMark(size: Size.tileSmall)) == CGSize(width: Size.tileSmall, height: Size.tileSmall))
    }

    @Test("The client marks column holds a mark for every client")
    func clientMarksColumnFits() throws {
        let marks = try measure(TableClientMarks(clients: ClientKind.allCases, present: []))
        #expect(marks.width <= CollectionColumn.clientMarks)
    }

    @Test("A resizable sheet lays out exactly like the frame it replaces")
    func resizableSheetSize() throws {
        let literal = try measure(
            Color.clear.frame(
                minWidth: SheetSize.setupWizardMinimum.width, idealWidth: SheetSize.setupWizardIdeal.width,
                minHeight: SheetSize.setupWizardMinimum.height, idealHeight: SheetSize.setupWizardIdeal.height))
        let helper = try measure(
            Color.clear.sheetSize(minimum: SheetSize.setupWizardMinimum, ideal: SheetSize.setupWizardIdeal))
        #expect(helper == literal)
        #expect(helper == SheetSize.setupWizardIdeal)
    }

    @Test("A split's shares divide its whole width")
    func splitSharesAddUp() {
        #expect(Proportion.listShare + Proportion.detailShare == 1)
        #expect(Proportion.evenShare * 2 == 1)
    }

    // MARK: - Helpers

    private struct RGB: Equatable {
        let red: Double
        let green: Double
        let blue: Double
    }

    /// The colour as drawn in `appearance`, composited over white when it is
    /// translucent so the ratio is the one a person would see.
    private func components(of color: Color, in appearance: NSAppearance.Name) throws -> RGB {
        let face = try #require(NSAppearance(named: appearance))
        var resolved: NSColor?
        face.performAsCurrentDrawingAppearance {
            resolved = NSColor(color).usingColorSpace(.sRGB)
        }
        let colour = try #require(resolved, "the colour has no sRGB form")
        let alpha = Double(colour.alphaComponent)
        func over(_ channel: CGFloat) -> Double { Double(channel) * alpha + (1 - alpha) }
        return RGB(red: over(colour.redComponent), green: over(colour.greenComponent), blue: over(colour.blueComponent))
    }

    /// WCAG relative luminance and contrast ratio.
    private func contrast(_ first: RGB, _ second: RGB) -> Double {
        func linear(_ channel: Double) -> Double {
            channel <= 0.040_45 ? channel / 12.92 : pow((channel + 0.055) / 1.055, 2.4)
        }
        func luminance(_ colour: RGB) -> Double {
            0.212_6 * linear(colour.red) + 0.715_2 * linear(colour.green) + 0.072_2 * linear(colour.blue)
        }
        let lighter = max(luminance(first), luminance(second))
        let darker = min(luminance(first), luminance(second))
        return (lighter + 0.05) / (darker + 0.05)
    }

    private func measure(_ view: some View) throws -> CGSize {
        let host = NSHostingView(rootView: AnyView(view.fixedSize()))
        host.layoutSubtreeIfNeeded()
        let size = host.fittingSize
        try #require(size.width > 0 && size.height > 0, "laid out to nothing")
        return size
    }
}
