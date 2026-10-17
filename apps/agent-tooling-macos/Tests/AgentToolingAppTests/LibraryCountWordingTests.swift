import Testing

@testable import AgentToolingApp

/// Counts on the Library and Discover screens agree with their number: one
/// thing is singular, and so is the verb that goes with it.
@Suite("Library and Discover count wording")
@MainActor
struct LibraryCountWordingTests {
    @Test("A tool list cut short names what it left out in the singular when it is one")
    func unlistedTools() {
        #expect(MCPToolInventoryList.unlistedNote(1) == "1 more tool is not listed here.")
        #expect(MCPToolInventoryList.unlistedNote(4) == "4 more tools are not listed here.")
    }

    @Test("A stack says how many of it stay out of the review, agreeing with the count")
    func unassignableConnections() {
        #expect(
            MCPStackPane.unassignableNote(1, of: 3)
                == "1 of 3 is owned by an app or a plugin, so this workspace has no say in where it is used. "
                + "It stays out of the review.")
        #expect(
            MCPStackPane.unassignableNote(2, of: 3)
                == "2 of 3 are owned by an app or a plugin, so this workspace has no say in where they are used. "
                + "They stay out of the review.")
    }

    @Test("An install count is singular for one install")
    func installCounts() {
        #expect(CompactCountFormatter.installs(1) == "1 install")
        #expect(CompactCountFormatter.installs(2) == "2 installs")
    }

    @Test("A component filter reads in a sentence with MCP still in capitals")
    func componentFilterNouns() {
        #expect(MarketplaceComponentFilter.skills.listingNoun == "skills")
        #expect(MarketplaceComponentFilter.plugins.listingNoun == "plugins")
        #expect(MarketplaceComponentFilter.mcpServers.listingNoun == "MCP servers")
        #expect(MarketplaceComponentFilter.all.listingNoun == "packages")
    }
}
