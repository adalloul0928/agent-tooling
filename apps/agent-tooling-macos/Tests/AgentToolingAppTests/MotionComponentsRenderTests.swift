import SwiftUI
import Testing

@testable import AgentToolingApp

@Suite("Motion component layout")
@MainActor
struct MotionComponentsRenderTests {
    private enum Segment: String, CaseIterable, Hashable {
        case general = "General"
        case library = "Library & Sync"
        case policy = "Policy & Safety"
    }

    @Test("Sliding selection keeps identical geometry for every segment")
    func slidingSelectionKeepsStableGeometry() {
        let sizes = Segment.allCases.compactMap { selection in
            ImageRenderer(
                content: control(selection: selection)
                    .environment(\.colorScheme, .dark)
            ).nsImage?.size
        }

        #expect(sizes.count == Segment.allCases.count)
        #expect(Set(sizes.map(\.width)).count == 1)
        #expect(Set(sizes.map(\.height)).count == 1)
        #expect(sizes.first?.width == 346)
        #expect(sizes.first?.height == 34)
    }

    @Test("Flexible segments render at a constrained marketplace width")
    func flexibleSegmentsRenderAtConstrainedWidth() {
        let renderer = ImageRenderer(
            content: control(selection: .general, segmentWidth: nil)
                .frame(width: 206)
        )

        #expect(renderer.nsImage?.size.width == 206)
        #expect(renderer.nsImage?.size.height == 34)
    }

    @Test("Segment labels can grow beyond their default minimum width")
    func segmentLabelsGrowBeyondDefaultMinimumWidth() {
        let longTitle = "A deliberately long settings category"
        let renderer = ImageRenderer(
            content: SlidingSegmentedControl<String>(
                selection: .constant(longTitle),
                items: ["General", longTitle, "Policy"].map { .init(value: $0, title: $0) },
                accessibilityLabel: "Fixture category"
            )
        )

        #expect((renderer.nsImage?.size.width ?? 0) > 346)
    }

    private func control(selection: Segment, segmentWidth: CGFloat? = 112) -> some View {
        SlidingSegmentedControl<Segment>(
            selection: .constant(selection),
            items: Segment.allCases.map { .init(value: $0, title: $0.rawValue) },
            accessibilityLabel: "Fixture category",
            segmentWidth: segmentWidth
        )
    }
}
