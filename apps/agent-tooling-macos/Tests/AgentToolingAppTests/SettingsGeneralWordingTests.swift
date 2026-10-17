import Testing

@testable import AgentToolingApp

/// Settings › General's words for configured entries. The Updates card calls
/// them connections, while the connection modes card two cards above said
/// "Servers stay configured directly in each client".
@Suite("Settings general wording")
@MainActor
struct SettingsGeneralWordingTests {
    /// A configured entry is a connection; an MCP server is only what ToolHive
    /// runs.
    @Test func connectionModesCallConfiguredEntriesConnections() {
        let text = SettingsGeneralView.connectionModesExplanation
        #expect(text.hasPrefix("Connections stay configured directly in each client"))
        #expect(text.contains("never moves a connection into it"))
        #expect(!text.contains("Servers stay"))
        #expect(!text.contains("moves servers"))
        #expect(text.components(separatedBy: "MCP servers").count == 2, "\(text) names MCP servers twice")
        #expect(text.contains("runs MCP servers as isolated workloads"))
    }
}
