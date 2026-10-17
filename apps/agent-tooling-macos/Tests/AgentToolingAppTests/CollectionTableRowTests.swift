import AgentToolingCore
import AgentToolingTestSupport
import AppKit
import SwiftUI
import Testing

@testable import AgentToolingApp

/// The Plugins and Connections tables lay their columns out by hand: column
/// titles in a header above a native `List`, and each row in the list reading
/// its widths from the same `CollectionColumns`. Both halves have to land on
/// the same lines. A row that is wider than the table pushes its last column
/// past the card, and a row the list pads further in than the header stands
/// to the right of its titles; the narrow Plugins list did both, clipping the
/// fourth app's ring.
@Suite("Collection table rows")
@MainActor
struct CollectionTableRowTests {
    /// A card as wide as the Plugins list beside an open details pane.
    private static let card = CGSize(width: 551, height: 300)

    @Test("A table row's content spans exactly the width its column titles do")
    func rowsStandUnderTheirHeader() throws {
        let log = FrameLog()
        let table = VStack(spacing: 0) {
            CollectionColumnHeader {
                Color.clear.frame(height: Size.glyph).recordingFrame("header", in: log)
            }
            List(0..<2, id: \.self) { index in
                Color.clear.frame(height: Size.glyph).recordingFrame("row \(index)", in: log)
                    .collectionTableRowChrome(selected: index == 1)
            }
            .collectionListChrome()
        }
        .frame(width: Self.card.width, height: Self.card.height)
        _ = try rasterize(table, size: Self.card)

        let header = try #require(log.frames["header"], "the header was never laid out")
        #expect(abs(header.minX - Space.xl) < 0.5, "the column titles start \(header.minX) in, not at the inset")
        for name in ["row 0", "row 1"] {
            let row = try #require(log.frames[name], "\(name) was never laid out")
            #expect(
                abs(row.minX - header.minX) < 0.5,
                "\(name) starts at \(row.minX), the titles at \(header.minX): see ListCellMargin")
            #expect(
                abs(row.maxX - header.maxX) < 0.5,
                "\(name) ends at \(row.maxX), the titles at \(header.maxX): see ListCellMargin")
        }
    }

    @Test("A narrow Plugins row and its titles fill the table's width and no more")
    func narrowPluginRowFitsTheTable() async throws {
        let fixture = try await ShellRenderFixture()
        defer { fixture.remove() }
        try await fixture.addRequestedPackage()
        let plugin = try #require(
            fixture.workspace.library.state?.library.rows.first { $0.kind == .package }, "the fixture holds no package")

        let columns = CollectionColumns(width: 500, layout: .plugins)
        #expect(!columns.expanded)
        let row = try #require(
            fittingSize(
                of: PluginCollectionRow(
                    row: plugin, update: .notChecked(reason: "Not checked yet."), clients: ClientKind.allCases,
                    columns: columns, selected: false)))
        let titles = try #require(fittingSize(of: PluginsView.columnHeader(columns)))
        #expect(row.width == columns.width, "the row is \(row.width) wide in a table of \(columns.width)")
        #expect(titles.width == columns.width + Space.xl * 2, "the titles are \(titles.width) wide")
    }

    @Test("A narrow Connections row and its titles fill the table's width and no more")
    func narrowConnectionRowFitsTheTable() throws {
        let columns = CollectionColumns(width: 500, layout: .connections)
        #expect(!columns.expanded)
        let row = try #require(
            fittingSize(
                of: ConnectionCollectionRow(
                    entry: MCPConnectionFixture.entry(), columns: columns, clients: ClientKind.allCases, tools: nil,
                    selected: false, ownershipFilter: .constant(""), pluginFilter: .constant(""),
                    sourceFilter: .constant(""))))
        let titles = try #require(fittingSize(of: MCPServersView.columnHeader(columns)))
        #expect(row.width == columns.width, "the row is \(row.width) wide in a table of \(columns.width)")
        #expect(titles.width == columns.width + Space.xl * 2, "the titles are \(titles.width) wide")
    }
}

/// Where each named view was laid out, in the window's coordinates.
@MainActor
private final class FrameLog {
    var frames: [String: CGRect] = [:]
}

extension View {
    fileprivate func recordingFrame(_ name: String, in log: FrameLog) -> some View {
        onGeometryChange(
            for: CGRect.self, of: { $0.frame(in: .global) },
            action: { frame in MainActor.assumeIsolated { log.frames[name] = frame } })
    }
}
