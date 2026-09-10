import Foundation

@testable import AgentToolingApp
@testable import AgentToolingCore

/// What Discover needs that no other screen does: a catalog that answers from
/// memory, and the two listing shapes the screen has to tell apart.
///
/// A render test that reached the official registry would draw whatever the
/// network happened to publish that morning, would fail on a train, and would
/// be a live HTTP call inside a unit test suite. This is the catalog instead.

/// A catalog that answers without a socket, and remembers what it was asked.
actor StubMarketplaceProvider: MarketplaceProvider {
    nonisolated let id: String
    nonisolated let displayName: String
    private let packages: [MarketplacePackage]
    private let fails: Bool
    private(set) var lastQuery: MarketplaceQuery?

    init(
        id: String = "stub.catalog",
        displayName: String = "Stub catalog",
        packages: [MarketplacePackage] = ShellRenderFixture.catalogPackages,
        fails: Bool = false
    ) {
        self.id = id
        self.displayName = displayName
        self.packages = packages
        self.fails = fails
    }

    func search(_ query: MarketplaceQuery) async throws -> MarketplacePage {
        lastQuery = query
        if fails { throw StubCatalogError.unreachable }
        return MarketplacePage(packages: packages)
    }
}

enum StubCatalogError: LocalizedError {
    case unreachable

    var errorDescription: String? { "The stub catalog was unreachable." }
}

extension ShellRenderFixture {
    /// Two listings: one the fixture's library already holds through its native
    /// route, and one it has never seen. Discover has to say which is which.
    nonisolated static var catalogPackages: [MarketplacePackage] { [heldPackage, unheldPackage] }

    /// The same identity the fixture's `Example Plugin` carries, so the screen
    /// can be checked for saying "already in your library" on the right row.
    nonisolated static var heldPackage: MarketplacePackage {
        catalogPackage(
            id: "claude:example@vendor", name: "Example Plugin",
            summary: "The plugin this workspace already holds, listed by the catalog it came from.")
    }

    nonisolated static var unheldPackage: MarketplacePackage {
        catalogPackage(
            id: "claude:atlas@vendor", name: "Atlas",
            summary: "A catalog listing this workspace has never held.")
    }

    /// One native-catalog plugin listing, shaped so
    /// `NativeCatalogPackageIdentity` recognizes it: a `claude:` identifier,
    /// exactly one component, and a client that agrees with the route.
    nonisolated static func catalogPackage(id: String, name: String, summary: String) -> MarketplacePackage {
        MarketplacePackage(
            id: id, name: name, publisher: "vendor", summary: summary,
            sourceName: "vendor", revision: "1.4.0", license: "MIT",
            components: [.plugin], supportedClients: [.claude],
            trustSummary: "Listed by a Claude marketplace; review before installing",
            location: "https://example.com/\(name.lowercased())",
            nativeInstalls: [
                NativeInstall(
                    client: .claude, executable: "claude",
                    arguments: ["plugin", "install", id.replacingOccurrences(of: "claude:", with: ""), "--scope", "user"],
                    removalArguments: ["plugin", "uninstall", id.replacingOccurrences(of: "claude:", with: "")],
                    scope: .user, detail: "Installs through Claude Code's own plugin manager.")
            ],
            lastUpdate: PackageUpdateRecord(date: .now, origin: .catalogListing))
    }
}
