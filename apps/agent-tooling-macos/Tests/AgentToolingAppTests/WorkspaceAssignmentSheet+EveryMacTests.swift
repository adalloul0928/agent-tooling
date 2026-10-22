import AppKit
import SwiftUI
import Testing

@testable import AgentToolingApp
@testable import AgentToolingCore

/// The assignment sheet's Where control on a first Mac: Every Mac is offered
/// beside This Mac only, as setup's placement grid offers it, and says that
/// Macs that join later get it too; and a step left alone names the app.
@Suite("Workspace assignment sheet · Every Mac", .serialized)
@MainActor
struct WorkspaceAssignmentSheetEveryMacTests {
    @Test func aFirstMacIsOfferedEveryMacAndThisMacOnly() {
        #expect(
            WorkspaceAssignmentSheet.placementChoices(hasOtherMacs: false) == [
                .init(placement: .everyMac, title: "Every Mac"), .init(placement: .thisMac, title: "This Mac only"),
                .init(placement: .project, title: "One project"),
            ])
    }

    @Test func otherMacsAddChooseMacs() {
        #expect(
            WorkspaceAssignmentSheet.placementChoices(hasOtherMacs: true).map(\.title) == [
                "Every Mac", "This Mac only", "Choose Macs", "One project",
            ])
    }

    @Test func everyMacSaysWhoGetsIt() {
        #expect(
            WorkspaceAssignmentSheet.whereExplanation(.everyMac, otherMacs: [])
                == "For every project on this Mac. Macs that join later get it too.")
        #expect(
            WorkspaceAssignmentSheet.whereExplanation(.everyMac, otherMacs: ["Cedar"])
                == "For every project, on this Mac and Cedar. A Mac set to take only what names it is left out.")
        #expect(
            WorkspaceAssignmentSheet.whereExplanation(.thisMac, otherMacs: [])
                == "For every project on this Mac. Other Macs are left out.")
    }

    /// The sheet on the fixture's Mac, which no other Mac shares: the system's
    /// segmented control draws Every Mac, This Mac only and One project, and
    /// Every Mac is chosen.
    @Test func theSheetDrawsEveryMacOnAFirstMac() async throws {
        let fixture = try await ShellRenderFixture()
        defer { fixture.remove() }
        let window = NSWindow(
            contentRect: CGRect(origin: .zero, size: SheetSize.large), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let host = NSHostingView(
            rootView: AnyView(
                WorkspaceAssignmentSheet(session: fixture.workspace.library, artifactIDs: [ShellRenderFixture.skill])))
        window.contentView = host
        window.orderFrontRegardless()
        defer { window.orderOut(nil) }
        let control = try segmentedControl(in: host)

        #expect((0..<control.segmentCount).map { control.label(forSegment: $0) } == ["Every Mac", "This Mac only", "One project"])
        #expect(control.selectedSegment == 0)
    }

    @Test func aStepLeftAloneNamesTheApp() {
        let item = WorkspaceDeploymentItem(
            artifactID: ArtifactID(), displayName: "Frontend Design", physicalDestinationID: WorkspaceObjectID(),
            surface: .codexCLI, scope: .user, logicalProjectID: nil,
            action: .updateContent(from: nil, to: ContentDigest(value: String(repeating: "a", count: 64))), desiredEnabled: nil,
            reasons: [.manual])
        #expect(
            WorkspaceAssignmentSheet.leftAloneSentence(for: item)
                == "Codex already has a copy Agent Tooling did not put there. It won’t be overwritten.")
    }

    /// The first segmented control in `host`, once the sheet has read its
    /// library and drawn its chooser.
    private func segmentedControl(in host: NSView) throws -> NSSegmentedControl {
        for _ in 0..<50 {
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
            host.layoutSubtreeIfNeeded()
            if let control = Self.views(in: host).first { return control }
        }
        throw CancellationError()
    }

    private static func views(in root: NSView) -> [NSSegmentedControl] {
        root.subviews.flatMap { subview in ((subview as? NSSegmentedControl).map { [$0] } ?? []) + views(in: subview) }
    }
}
