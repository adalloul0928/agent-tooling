import Foundation
import SwiftUI
import Testing

@testable import AgentToolingApp
@testable import AgentToolingCore

extension HomeSectionRenderTests {
    /// Home's setup card reads the kept checkup: a Mac that has one says what
    /// it found, and a Mac that has none offers one, so the two Homes differ.
    @Test func homeShowsTheLastCheckupAndOffersOneWhenThereIsNone() async throws {
        let checked = try await ShellRenderFixture(
            setupServices: StubSetupServices(restored: ShellRenderFixture.setupCheckup(home: URL(filePath: "/Users/example"))))
        defer { checked.remove() }
        let unchecked = try await ShellRenderFixture(setupServices: StubSetupServices())
        defer { unchecked.remove() }

        try expectDrawn(renderShell(.overview, fixture: checked))
        #expect(
            try rasterize(renderShell(.overview, fixture: checked)).tiffRepresentation
                != rasterize(renderShell(.overview, fixture: unchecked)).tiffRepresentation,
            "the checkup changed nothing on Home")
    }
}
