import Testing

@testable import AgentToolingApp

/// The line on each Apps tile that says what the last check found in the app.
/// It counted "servers" while the library calls them connections, and never
/// said a count in the singular: "1 skills · 1 servers · 1 plugins".
@Suite("Apps tile holdings")
@MainActor
struct AppTileHeldTests {
    @Test("One of each is singular, and connections are called connections")
    func singularAndConnections() {
        #expect(AppTile.Held(skills: 1, connections: 1, plugins: 1).summary == "1 skill · 1 connection · 1 plugin")
    }

    @Test("Other counts take the plural, zero included")
    func plurals() {
        #expect(AppTile.Held(skills: 3, connections: 0, plugins: 2).summary == "3 skills · 0 connections · 2 plugins")
    }
}
