import AgentToolingCore
import AgentToolingTestSupport
import Foundation
import Testing

@testable import AgentToolingApp

/// Agent Tooling's own connection is no library entry (D10): Library ›
/// Connections does not list it, so the palette offers no entry that would
/// open it there, while the library's other connections keep theirs.
@Suite("Command palette · Agent Tooling's own connection", .serialized, .timeLimit(.minutes(5)))
@MainActor
struct CommandPaletteCatalogOwnConnectionTests {
    @Test func thePaletteOffersNoEntryForTheOwnConnection() async throws {
        let fixture = try await LaunchpadFixture()
        defer { fixture.remove() }
        let sample = try await fixture.sample(.afterAsk)
        let own = try #require(sample.decisions.helperArtifactID)
        let library = try #require(sample.workspace.library.state?.library)
        let others = library.rows.filter { $0.kind == .mcpServer && !$0.isOwnConnection }

        let items = CommandPaletteCatalog.items(for: sample.workspace)

        #expect(!items.contains { $0.id == "mcp.\(own.rawValue.uuidString.lowercased())" })
        for row in others {
            #expect(items.contains { $0.id == "mcp.\(row.artifactID.rawValue.uuidString.lowercased())" }, "\(row.displayName)")
        }
    }
}
