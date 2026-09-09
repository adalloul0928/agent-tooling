import AppKit
import SwiftUI
import Testing

@testable import AgentToolingApp

@Suite("Native selector layout")
@MainActor
struct MotionComponentsRenderTests {
    private enum Segment: String, CaseIterable, Hashable {
        case general = "General"
        case library = "Library & Sync"
        case policy = "Policy & Safety"
    }

    @Test("Changing the selected segment does not resize the control")
    func selectionKeepsStableGeometry() {
        let sizes = Segment.allCases.map { selection in
            measuredSize(control(selection: selection).environment(\.colorScheme, .dark))
        }

        #expect(Set(sizes.map(\.width)).count == 1)
        #expect(Set(sizes.map(\.height)).count == 1)
        #expect(sizes.allSatisfy { $0.width > 0 && $0.height > 0 })
    }

    @Test("Package labels fit the narrow inspector browser")
    func packageSegmentsFitNarrowBrowser() {
        let selector = WorkspaceSegmentedPicker("Package component", selection: .constant("All")) {
            ForEach(["All", "Skills", "Plugins", "MCP"], id: \.self) { Text($0).tag($0) }
        }
        // The 340-point browser reserves 24 points of padding on each side.
        let availableWidth: CGFloat = 292
        let naturalSize = measuredSize(selector.fixedSize())
        let constrainedSize = measuredSize(selector.frame(width: availableWidth))

        #expect(naturalSize.width <= availableWidth)
        #expect(constrainedSize.width == availableWidth)
        #expect(constrainedSize.height > 0)
    }

    @Test("Long labels retain their intrinsic width")
    func longLabelsCanGrow() {
        let longTitle = "A deliberately long settings category"
        let longSelector = WorkspaceSegmentedPicker("Fixture category", selection: .constant(longTitle)) {
            ForEach(["General", longTitle, "Policy"], id: \.self) { Text($0).tag($0) }
        }

        #expect(measuredSize(longSelector.fixedSize()).width > measuredSize(control(selection: .general)).width)
    }

    private func control(selection: Segment) -> some View {
        WorkspaceSegmentedPicker("Fixture category", selection: .constant(selection)) {
            ForEach(Segment.allCases, id: \.self) { Text($0.rawValue).tag($0) }
        }
        .fixedSize()
    }

    private func measuredSize(_ content: some View) -> NSSize {
        let host = NSHostingView(rootView: content)
        host.layoutSubtreeIfNeeded()
        return host.fittingSize
    }
}
