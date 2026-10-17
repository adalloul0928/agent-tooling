import Foundation
import SwiftUI
import Testing

@testable import AgentToolingApp
@testable import AgentToolingCore

/// Checkup draws before an audit, with a kept audit, and with a review on top.
@Suite("Apps · Checkup renders")
@MainActor
struct CheckupSectionRenderTests {
    @Test func theShellDrawsCheckupBeforeAnyAudit() async throws {
        let services = StubSetupServices()
        let fixture = try await ShellRenderFixture(setupServices: services)
        defer { fixture.remove() }
        try expectDrawn(renderShell(.checkup, fixture: fixture))
        // Opening the screen is not an audit and not a review.
        #expect(fixture.workspace.setup.checkup == nil)
        #expect(services.reviewCalls.isEmpty)
    }

    @Test func theShellDrawsAKeptCheckupWithFindingsAndAReview() async throws {
        let fixture = try await ShellRenderFixture(
            setupServices: StubSetupServices(restored: ShellRenderFixture.setupCheckup(home: URL(filePath: "/Users/example"))))
        defer { fixture.remove() }
        let plain = try await ShellRenderFixture(setupServices: StubSetupServices())
        defer { plain.remove() }

        try expectDrawn(renderShell(.checkup, fixture: fixture))
        #expect(
            try rasterize(renderShell(.checkup, fixture: fixture)).tiffRepresentation
                != rasterize(renderShell(.checkup, fixture: plain)).tiffRepresentation,
            "the kept checkup changed nothing on screen")
    }

    @Test func aRowDrawsClosedAndOpenAndTheFixAllSheetDraws() throws {
        let checkup = ShellRenderFixture.setupCheckup(home: URL(filePath: "/Users/example"))
        let items = CheckupTriage.items(from: checkup)
        let item = try #require(items.first)
        for expanded in [false, true] {
            try expectDrawn(
                CheckupRow(item: item, isExpanded: expanded, isBusy: false, onToggle: {}, onRun: {}, onRunOne: { _ in }, onDismiss: {}, onOpen: { _ in })
                    .frame(width: 760))
        }
        let plan = CheckupTriage.fixAll(items)
        #expect(!plan.isEmpty)
        try expectDrawn(FixAllSheet(plan: plan, onCancel: {}, onConfirm: {}))
    }
}
