import AgentToolingCore
import Testing

@testable import AgentToolingApp

/// The line on each Apps tile that says what the last check found in the app.
/// It counted "servers" while the library calls them connections, and never
/// said a count in the singular: "1 skills · 1 servers · 1 plugins". It also
/// put connections before plugins, so one app's counts read in one order on
/// its tile and in another in the setup wizard and on another Mac's sheet.
@Suite("Apps tile holdings")
@MainActor
struct AppTileHeldTests {
    @Test("One of each is singular, and connections are called connections")
    func singularAndConnections() {
        #expect(AppTile.Held(skills: 1, plugins: 1, connections: 1).summary == "1 skill · 1 plugin · 1 connection")
    }

    @Test("Other counts take the plural, zero included")
    func plurals() {
        #expect(AppTile.Held(skills: 3, plugins: 2, connections: 0).summary == "3 skills · 2 plugins · 0 connections")
    }

    /// Skills, plugins, connections: the order of the Library's tabs.
    @Test("The tile counts in the same order as the wizard and another Mac's sheet")
    func oneOrderEverywhere() {
        let tile = AppTile.Held(skills: 17, plugins: 5, connections: 8).summary
        #expect(tile == "17 skills · 5 plugins · 8 connections")
        #expect(tile == CheckupTriage.inventoryLine(.init(skills: 17, plugins: 5, mcpServers: 8)))

        let otherMac = DeviceLabels.appLine(
            .init(
                surface: .claudeCode, installed: true, version: "2.1",
                skillCount: 17, pluginCount: 5, mcpServerCount: 8))
        #expect(otherMac.text == "2.1 · " + tile)
    }
}
