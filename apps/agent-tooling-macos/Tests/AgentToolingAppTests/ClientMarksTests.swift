import AgentToolingCore
import AgentToolingTestSupport
import AppKit
import SwiftUI
import Testing

@testable import AgentToolingApp

/// The client marks on a library row say which apps have the item. An app that
/// does not have it has to be seen not to: by the empty place it leaves, which
/// a person can make out on a card, rather than by its mark faded nearly to
/// nothing.
@Suite("Client marks")
@MainActor
struct ClientMarksTests {
    /// A card just big enough for a row of marks and a little ground around it.
    private static let card = CGSize(
        width: CollectionColumn.clientMarks + Space.md * 2, height: Size.brandMark + Space.md * 2)

    @Test("An app without the item leaves a mark that stands off the card in both appearances")
    func absentMarksCanBeSeen() throws {
        try expectAbsentMarksStandOff(AgentTheme.controlBackground, "the card", selected: false)
    }

    /// A selected row draws the accent fill behind its marks, where the grey
    /// that stands off a card reaches under 2:1.
    @Test("On a selected row the empty rings stand off the selection fill in both appearances")
    func absentMarksCanBeSeenOnASelectedRow() throws {
        try expectAbsentMarksStandOff(AgentTheme.selection, "the selection fill", selected: true)
    }

    private func expectAbsentMarksStandOff(
        _ ground: Color, _ groundName: String, selected: Bool, sourceLocation: SourceLocation = #_sourceLocation
    ) throws {
        let rows: [(String, AnyView)] = [
            (
                "TableClientMarks",
                AnyView(TableClientMarks(clients: ClientKind.allCases, present: [], selected: selected))
            ),
            (
                "ClientMarks",
                AnyView(
                    ClientMarks(present: [], selected: selected).environment(\.availableClients, ClientKind.allCases))
            ),
        ]
        for appearance in [RenderAppearance.light, .dark] {
            for (name, marks) in rows {
                let bitmap = try rasterize(
                    marks.frame(maxWidth: .infinity, maxHeight: .infinity).background(ground),
                    size: Self.card, appearance: appearance)
                let ratio = try strongestContrast(in: bitmap)
                #expect(
                    ratio >= 3, "\(name), \(appearance): the absent marks reach only \(ratio):1 against \(groundName)",
                    sourceLocation: sourceLocation)
            }
        }
    }

    /// The most any pixel stands off the card, which is the corner pixel: the
    /// marks sit inset from every edge.
    private func strongestContrast(in bitmap: NSBitmapImageRep) throws -> Double {
        let ground = try #require(bitmap.colorAt(x: 0, y: 0), "the card has no corner pixel")
        var strongest = 1.0
        for y in 0..<bitmap.pixelsHigh {
            for x in 0..<bitmap.pixelsWide {
                guard let pixel = bitmap.colorAt(x: x, y: y),
                    let ratio = ContrastRatio.between(pixel, ground)
                else { continue }
                strongest = max(strongest, ratio)
            }
        }
        return strongest
    }
}
