import AgentToolingCore
import AppKit
import SwiftUI
import Testing

@testable import AgentToolingApp

/// The promises a few tokens make that a value alone cannot show: that a
/// column is wide enough for what it holds, and that the shared helpers lay
/// out exactly like the literals they stand for.
@Suite("Design tokens")
@MainActor
struct DesignTokensTests {
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

    private func measure(_ view: some View) throws -> CGSize {
        let host = NSHostingView(rootView: AnyView(view.fixedSize()))
        host.layoutSubtreeIfNeeded()
        let size = host.fittingSize
        try #require(size.width > 0 && size.height > 0, "laid out to nothing")
        return size
    }
}
