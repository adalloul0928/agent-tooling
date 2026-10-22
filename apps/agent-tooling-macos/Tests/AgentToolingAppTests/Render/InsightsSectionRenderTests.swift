import Foundation
import SwiftUI
import Testing

@testable import AgentToolingApp
@testable import AgentToolingCore

/// Insights draws before a scan has ever run, and again once one has answered.
///
/// The scan is scripted: a render test that read this Mac's chat history would
/// draw a different screen on every machine, and would be reading something a
/// test has no business reading. It is handed to the workspace rather than to
/// the screen, because launch is where the app itself settles it.
@Suite("Insights renders")
@MainActor
struct InsightsSectionRenderTests {
    @Test func theShellDrawsInsightsBeforeAnyScan() async throws {
        let services = StubInsightsServices(answer: ShellRenderFixture.insightsReport())
        let fixture = try await ShellRenderFixture(insightsServices: services)
        defer { fixture.remove() }

        try expectDrawn(renderShell(.insights, fixture: fixture))

        // Opening the screen is not a scan: nothing reads history until asked.
        #expect(services.scanCount == 0)
    }

    @Test func theShellDrawsAReportThisMacAlreadyKept() async throws {
        let report = ShellRenderFixture.insightsReport()
        let kept = try await ShellRenderFixture(
            insightsServices: StubInsightsServices(answer: report, restored: report))
        defer { kept.remove() }
        let empty = try await ShellRenderFixture(
            insightsServices: StubInsightsServices(answer: report))
        defer { empty.remove() }

        let withReport = try rasterize(renderShell(.insights, fixture: kept))
        try expectDrawn(renderShell(.insights, fixture: kept))

        // The blank-frame check passes on the chrome alone, so the report has
        // to be shown to have changed something: a screen that quietly drops it
        // draws exactly what the screen with no report draws.
        let withoutReport = try rasterize(renderShell(.insights, fixture: empty))
        #expect(
            withReport.tiffRepresentation != withoutReport.tiffRepresentation,
            "the kept report changed nothing on screen")
    }

    /// A kept deep dive is shown above the keyword pass: the screen with one
    /// draws differently from the screen with the same report and none.
    @Test func theShellDrawsAKeptDeepDive() async throws {
        let report = ShellRenderFixture.insightsReport()
        var withDive = report
        withDive.deepDive = ShellRenderFixture.insightsDeepDive()
        let dived = try await ShellRenderFixture(
            insightsServices: StubInsightsServices(answer: report, restored: withDive))
        defer { dived.remove() }
        let plain = try await ShellRenderFixture(
            insightsServices: StubInsightsServices(answer: report, restored: report))
        defer { plain.remove() }

        try expectDrawn(renderShell(.insights, fixture: dived))
        #expect(
            try rasterize(renderShell(.insights, fixture: dived)).tiffRepresentation
                != rasterize(renderShell(.insights, fixture: plain)).tiffRepresentation,
            "the deep dive changed nothing on screen")
        // Opening the screen still reads nothing: the daily run belongs to the
        // shell's open, not to the screen.
        #expect(dived.workspace.insights.isDeepDiving == false)
    }

    /// The scan options draw whether or not a catalog can be asked, and the
    /// switch that decides it is the only thing that differs between them.
    @Test func theScanOptionsDrawWithAndWithoutACatalogToAsk() async throws {
        let report = ShellRenderFixture.insightsReport()

        for reachable in [true, false] {
            let services = StubInsightsServices(answer: report, reachesCatalog: reachable)
            let fixture = try await ShellRenderFixture(insightsServices: services)
            defer { fixture.remove() }

            try expectDrawn(renderShell(.insights, fixture: fixture))
            #expect(fixture.workspace.insights.canReachCatalog == reachable)
        }
    }
}
