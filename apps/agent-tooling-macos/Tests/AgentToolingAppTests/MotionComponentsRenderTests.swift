import AgentToolingTestSupport
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
    func selectionKeepsStableGeometry() throws {
        let sizes = try Segment.allCases.map { selection in
            try #require(fittingSize(of: control(selection: selection).environment(\.colorScheme, .dark)))
        }

        #expect(Set(sizes.map(\.width)).count == 1)
        #expect(Set(sizes.map(\.height)).count == 1)
    }

    @Test("Package labels fit the narrow inspector browser")
    func packageSegmentsFitNarrowBrowser() throws {
        let selector = WorkspaceSegmentedPicker("Package component", selection: .constant("All")) {
            ForEach(["All", "Skills", "Plugins", "MCP"], id: \.self) { Text($0).tag($0) }
        }
        // The 340-point browser reserves 24 points of padding on each side.
        let availableWidth: CGFloat = 292
        let naturalSize = try #require(fittingSize(of: selector))
        let constrainedSize = try #require(fittingSize(of: selector.frame(width: availableWidth)))

        #expect(naturalSize.width <= availableWidth)
        #expect(constrainedSize.width == availableWidth)
    }

    @Test("Long labels retain their intrinsic width")
    func longLabelsCanGrow() throws {
        let longTitle = "A deliberately long settings category"
        let longSelector = WorkspaceSegmentedPicker("Fixture category", selection: .constant(longTitle)) {
            ForEach(["General", longTitle, "Policy"], id: \.self) { Text($0).tag($0) }
        }

        let long = try #require(fittingSize(of: longSelector))
        let standard = try #require(fittingSize(of: control(selection: .general)))
        #expect(long.width > standard.width)
    }

    private func control(selection: Segment) -> some View {
        WorkspaceSegmentedPicker("Fixture category", selection: .constant(selection)) {
            ForEach(Segment.allCases, id: \.self) { Text($0.rawValue).tag($0) }
        }
        .fixedSize()
    }
}
