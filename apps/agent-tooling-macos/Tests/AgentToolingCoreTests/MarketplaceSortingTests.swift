import Foundation
import Testing

@testable import AgentToolingCore

/// The default name order sorts by the words a person reads on the card, not by
/// a registry listing's reverse-DNS publisher domain.
@Suite("Marketplace display-name sorting")
struct MarketplaceDisplayNameSortTests {
    private func package(id: String, name: String) -> MarketplacePackage {
        MarketplacePackage(
            id: id, name: name, publisher: "publisher", summary: "A reviewed fixture.",
            sourceName: "Fixture", components: [.mcpServer],
            supportedClients: Set(ClientKind.allCases), location: "https://example.com")
    }

    @Test func reverseDNSListingsSortByTheirShortName() {
        // Reverse-DNS names whose short last segments are, in order, mcp / git
        // / zeta. By full name they would sort ac… , io… , zz… — a different
        // order that follows the publisher's domain rather than the label.
        let listings = [
            package(id: "mcp-registry:zz.publisher/mcp@1", name: "zz.publisher/mcp"),
            package(id: "mcp-registry:io.example/zeta@1", name: "io.example/zeta"),
            package(id: "mcp-registry:ac.inference.sh/git@1", name: "ac.inference.sh/git"),
        ]

        let sorted = MarketplaceSorting.sorted(listings, by: .name)

        #expect(sorted.map { MarketplaceSorting.displayName(for: $0) } == ["git", "mcp", "zeta"])
    }

    @Test func displayNameIsTheLastPathSegmentOrTheWholeNameWhenThereIsNoSlash() {
        #expect(MarketplaceSorting.displayName(for: package(id: "a", name: "ac.inference.sh/mcp")) == "mcp")
        #expect(MarketplaceSorting.displayName(for: package(id: "b", name: "Filesystem")) == "Filesystem")
        // A trailing slash has no segment after it, so the whole name stands in.
        #expect(MarketplaceSorting.displayName(for: package(id: "c", name: "vendor/")) == "vendor/")
    }

    @Test func theSortIsCaseInsensitiveAndTotal() {
        let listings = [
            package(id: "b", name: "vendor/Beta"),
            package(id: "a", name: "vendor/beta"),
            package(id: "c", name: "vendor/alpha"),
        ]

        let forward = MarketplaceSorting.sorted(listings, by: .name)
        let reversed = MarketplaceSorting.sorted(listings.reversed(), by: .name)

        // alpha before the two betas; the beta tie falls through to identifier.
        #expect(forward.map(\.id) == ["c", "a", "b"])
        #expect(forward.map(\.id) == reversed.map(\.id))
    }
}
