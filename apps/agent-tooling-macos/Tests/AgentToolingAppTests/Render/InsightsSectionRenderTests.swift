import Foundation
import SwiftUI
import Testing

@testable import AgentToolingApp
@testable import AgentToolingCore

/// Insights draws before a scan has ever run, and again once one has answered.
///
/// The scan is scripted: a render test that read this Mac's chat history would
/// draw a different screen on every machine, and would be reading something a
/// test has no business reading.
@Suite("Insights renders")
@MainActor
struct InsightsSectionRenderTests {
    @Test func theShellDrawsInsightsBeforeAnyScan() async throws {
        let fixture = try await ShellRenderFixture()
        defer { fixture.remove() }
        let services = StubInsightsServices(answer: ShellRenderFixture.insightsReport())

        try expectDrawn(
            renderShell(.insights, fixture: fixture)
                .environment(\.insightsServices, { _ in services }))

        // Opening the screen is not a scan: nothing reads history until asked.
        #expect(services.scanCount == 0)
    }

    @Test func theShellDrawsAReportThisMacAlreadyKept() async throws {
        let fixture = try await ShellRenderFixture()
        defer { fixture.remove() }
        let report = ShellRenderFixture.insightsReport()
        let kept = StubInsightsServices(answer: report, restored: report)
        let empty = StubInsightsServices(answer: report)

        let withReport = try rasterize(
            renderShell(.insights, fixture: fixture).environment(\.insightsServices, { _ in kept }))
        try expectDrawn(
            renderShell(.insights, fixture: fixture).environment(\.insightsServices, { _ in kept }))

        // The blank-frame check passes on the chrome alone, so the report has
        // to be shown to have changed something: a screen that quietly drops it
        // draws exactly what the screen with no report draws.
        let withoutReport = try rasterize(
            renderShell(.insights, fixture: fixture).environment(\.insightsServices, { _ in empty }))
        #expect(
            withReport.tiffRepresentation != withoutReport.tiffRepresentation,
            "the kept report changed nothing on screen")
    }

    /// The scan options draw whether or not a catalog can be asked, and the
    /// switch that decides it is the only thing that differs between them.
    @Test func theScanOptionsDrawWithAndWithoutACatalogToAsk() async throws {
        let fixture = try await ShellRenderFixture()
        defer { fixture.remove() }
        let report = ShellRenderFixture.insightsReport()

        for reachable in [true, false] {
            let services = StubInsightsServices(answer: report, reachesCatalog: reachable)
            try expectDrawn(
                renderShell(.insights, fixture: fixture)
                    .environment(\.insightsServices, { _ in services }))
            #expect(services.canReachCatalog == reachable)
        }
    }
}
