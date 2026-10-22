import AgentToolingCore
import Foundation
import Testing

@testable import AgentToolingApp

extension CommandPaletteCatalogTests {
    /// Set up this Mac…, named as the app menu, Apps and Settings name it,
    /// once, with the line that says what it does.
    @Test("The palette offers Set up this Mac… and says what it does")
    func thePaletteOffersSetUpThisMac() async throws {
        let fixture = try await ShellRenderFixture()
        defer { fixture.remove() }
        let items = CommandPaletteCatalog.items(for: fixture.workspace)

        let item = try #require(items.first { $0.outcome == .setUpThisMac })
        #expect(item.title == ActionTitles.setUpThisMacCommand(.palette))
        #expect(item.subtitle == LaunchpadCopy.Reentry.paletteSubtitle)
        #expect(item.help == item.subtitle)
        #expect(item.contextLabel == "Action")
        #expect(item.symbol == SetUpThisMacButton.symbol)
        #expect(items.count { $0.outcome == .setUpThisMac } == 1)
    }

    /// Typing setup, or a name setup has gone by, reaches Set up this Mac…
    /// first. Check apps keeps "setup" among its old names, so the tie goes
    /// to the higher priority; its own old name, "check setup", still
    /// reaches it.
    @Test("Setup's words reach Set up this Mac… first; check setup still reaches Check apps")
    func setupsWordsReachSetUpThisMacFirst() async throws {
        let fixture = try await ShellRenderFixture()
        defer { fixture.remove() }
        let items = CommandPaletteCatalog.items(for: fixture.workspace)

        for query in ["setup", "Setup", "set up", "set up this mac", "onboarding", "run setup again", "first run", "agents"] {
            #expect(CommandPaletteCatalog.results(items, query: query).first?.outcome == .setUpThisMac, "\(query)")
        }
        #expect(CommandPaletteCatalog.results(items, query: "check setup").first?.outcome == .checkApps)
        #expect(CommandPaletteCatalog.results(items, query: "check apps").first?.outcome == .checkApps)
    }

    /// The priority that wins "setup" does not reach an empty palette: it
    /// still opens on Check apps, highlighted, so ↩ reads this Mac's apps as
    /// it always has. Set up this Mac… waits after the other actions, and
    /// every other row keeps the matcher's order. A typed query is the
    /// matcher's alone.
    @Test("An empty palette still opens on Check apps, with Set up this Mac… after the other actions")
    func anEmptyPaletteStillOpensOnCheckApps() async throws {
        let fixture = try await ShellRenderFixture()
        defer { fixture.remove() }
        let items = CommandPaletteCatalog.items(for: fixture.workspace)

        for query in ["", "   "] {
            let results = CommandPaletteCatalog.results(items, query: query)
            #expect(results.first?.outcome == .checkApps, "\"\(query)\"")
            let setUp = try #require(results.firstIndex { $0.outcome == .setUpThisMac })
            #expect(results[..<setUp].allSatisfy { $0.contextLabel == "Action" }, "\"\(query)\"")
            #expect(results[setUp...].dropFirst().allSatisfy { $0.contextLabel != "Action" }, "\"\(query)\"")
            let ranked = CommandPaletteMatcher.rank(items, query: query)
            #expect(results.count == ranked.count)
            #expect(
                results.filter { $0.outcome != .setUpThisMac }.map(\.id)
                    == ranked.filter { $0.outcome != .setUpThisMac }.map(\.id))
        }
        for query in ["set", "check", "s"] {
            #expect(
                CommandPaletteCatalog.results(items, query: query).map(\.id)
                    == CommandPaletteMatcher.rank(items, query: query).map(\.id), "\(query)")
        }
    }
}
