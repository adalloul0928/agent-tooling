import AgentToolingCore
import Foundation
import Observation
import SwiftUI

/// The catalogs this build can ask, handed in rather than reached for.
///
/// Every provider is a network call, so nothing on the Discover screen is
/// allowed to construct one: a render test sets this key to a stub that answers
/// from memory, and never opens a socket.
///
/// The live value is empty. `MarketplaceProvider` is public, but the one
/// concrete provider in this build — the official MCP registry — is internal to
/// `AgentToolingCore`, and the public factory that used to hand it out
/// (`AppModel.builtInMarketplaceProviders()`) went with `AppModel`. Until core
/// exposes one again, this is the honest value: no catalog can be asked, and
/// the screen says so rather than pretending a refresh did something.
extension EnvironmentValues {
    @Entry var marketplaceProviders: [any MarketplaceProvider] = []
}

/// What the catalogs published, what this Mac has kept from them, and where
/// both came from.
///
/// Three rules shape everything here.
///
/// Reading a catalog is not observing this Mac. A listing arrives claiming to
/// know whether it is installed; this build has observed no such thing, so the
/// claim is dropped on the way in and installation is answered from the
/// library, which is a record this app can defend.
///
/// Nothing is written to a client. The session fetches, sorts and keeps; the
/// only write it ever makes is to this Mac's own record of what the catalogs
/// last said, so a launch with no network still has something to show.
///
/// A catalog that fails is named. A refresh that reaches three providers and
/// loses one keeps the two that answered and says which one did not, because
/// silently returning fewer packages reads as a catalog that shrank.
@MainActor @Observable
final class WorkspaceMarketplaceSession {
    /// One entry per package a catalog published, most recent refresh wins.
    private(set) var packages: [MarketplacePackage] = []
    /// The catalogs and folders this workspace records, in the document's own
    /// order. Read-only: adding one is not a command this build has.
    private(set) var sources: [ToolingSource] = []
    private(set) var isRefreshing = false
    private(set) var errorMessage: String?
    /// When the last refresh that reached a catalog finished. A refresh that
    /// only re-read this Mac's own record leaves it alone.
    private(set) var lastRefreshedAt: Date?

    /// Every native package already in the library, by the route that names it.
    /// Discover matches a catalog listing against this rather than against a
    /// name, so a namesake is never mistaken for the package you already have.
    private(set) var installedRoutes: [NativePackageRoute: LibraryMatch] = [:]

    /// One library row a catalog listing turned out to be.
    struct LibraryMatch: Equatable {
        let artifactID: ArtifactID
        let displayName: String
        /// The form `AppNavigationState.openItem` and the palette both use.
        var itemID: String { artifactID.rawValue.uuidString.lowercased() }
    }

    /// Nothing in this build can add a catalog package to the library. Stated
    /// once here so every disabled control on the screen says the same thing.
    static let installUnavailable = "Adding catalog packages to the library is not available in this build."

    /// Said wherever the screen would otherwise imply a catalog could be asked.
    static let noProviderNote =
        "No catalog provider is available in this build, so Discover shows only what this Mac already kept."

    private static let pageLimit = 100

    private let providers: [any MarketplaceProvider]
    private let service: WorkspaceApplicationService
    private let library: WorkspaceLibrarySession
    private let store: WorkspaceRevisionStore

    /// Deliberately does no work. A section rebuilds its view whenever the
    /// shell redraws, so anything read here would be read again every time the
    /// window changed. The first `refresh()` reads the store instead.
    init(
        providers: [any MarketplaceProvider],
        service: WorkspaceApplicationService,
        library: WorkspaceLibrarySession,
        store: WorkspaceRevisionStore
    ) {
        self.providers = providers
        self.service = service
        self.library = library
        self.store = store
    }

    /// True when there is a catalog to ask at all. A screen that cannot reach
    /// one still refreshes — it re-reads this Mac — but must not imply more.
    var canReachCatalog: Bool { !providers.isEmpty }

    /// Whether a catalog listing is already in the library, and which row it is.
    ///
    /// Matched on the exact catalog identity the native parsers preserved, not
    /// on a display name: `NativeCatalogPackageIdentity` refuses anything whose
    /// identifier, components, client and provenance do not all agree.
    func libraryMatch(for package: MarketplacePackage) -> LibraryMatch? {
        guard let identity = NativeCatalogPackageIdentity.recognize(package) else { return nil }
        return installedRoutes[
            NativePackageRoute(client: identity.client, externalPluginID: identity.externalPluginID)]
    }

    /// Re-reads this Mac's record, then asks every catalog it has.
    func refresh() async {
        await fetch(MarketplaceQuery(limit: Self.pageLimit))
    }

    /// Asks the catalogs for one term. Filtering the packages already on screen
    /// is the screen's own job; this is for the words a catalog knows and this
    /// Mac does not.
    func search(_ term: String) async {
        let trimmed = term.trimmingCharacters(in: .whitespacesAndNewlines)
        await fetch(MarketplaceQuery(search: trimmed.isEmpty ? nil : trimmed, limit: Self.pageLimit))
    }

    // MARK: - Reading

    /// Everything the workspace itself can answer, with no network and no scan.
    ///
    /// Sources are two halves of one record: the portable half carries the name
    /// and kind that travel between Macs, and this Mac's half carries where the
    /// folder actually is and what the last look at it found.
    private func reload() {
        guard let snapshot = try? store.snapshot() else { return }
        let deviceSources = Dictionary(
            (snapshot.device.configurationState?.catalogSources ?? []).map { ($0.catalogSourceID, $0) },
            uniquingKeysWith: { first, _ in first })
        sources = (snapshot.document.configurationState?.catalogSources ?? []).map { record in
            let local = deviceSources[record.id]
            return ToolingSource(
                id: record.id.rawValue, name: record.name, kind: record.kind,
                location: local?.localLocation ?? record.remoteLocation ?? "",
                isOptionalBackup: record.isOptionalBackup, lastRefreshedAt: local?.lastRefreshedAt,
                lastRevision: local?.lastRevision, trustSummary: local?.trustSummary ?? "Not reviewed")
        }
        installedRoutes = Dictionary(
            snapshot.document.artifacts
                .filter { $0.identity.parentPackageID == nil }
                .flatMap { artifact in
                    artifact.nativeRoutes.map {
                        ($0, LibraryMatch(artifactID: artifact.identity.id, displayName: artifact.identity.displayName))
                    }
                },
            uniquingKeysWith: { first, _ in first })
        // Only on the first read: a refresh that reached a catalog must not be
        // overwritten by what this Mac kept from the one before it.
        if packages.isEmpty {
            packages = Self.ordered(
                (snapshot.device.applicationState?.marketplacePackages ?? []).map(Self.unobserved))
        }
    }

    private func fetch(_ query: MarketplaceQuery) async {
        guard !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }
        errorMessage = nil
        reload()
        guard !providers.isEmpty else { return }

        var collected: [MarketplacePackage] = []
        var failures: [String] = []
        for provider in providers {
            do {
                let page = try await provider.search(query)
                collected.append(contentsOf: page.packages.map(Self.unobserved))
            } catch {
                // The provider's own words, not this app's guess at them: a
                // catalog that refused says why, and a name says which one.
                failures.append("\(provider.displayName): \(error.localizedDescription)")
            }
        }

        // A refresh where every catalog failed keeps what was already on
        // screen. Replacing it with nothing would read as an empty catalog
        // rather than as a refresh that did not happen.
        if !collected.isEmpty || failures.count < providers.count {
            packages = Self.ordered(Self.deduplicated(collected))
            lastRefreshedAt = .now
            await retain(packages)
        }
        errorMessage = failures.isEmpty ? nil : failures.joined(separator: " · ")
    }

    /// Keeps the last page in this Mac's own record, so the next launch has
    /// something to show before any catalog is reachable.
    ///
    /// Best effort on purpose. This is a convenience, not the result the person
    /// asked for: a workspace that moved on underneath, or one that refuses the
    /// listing, leaves the packages on screen and says only that they were not
    /// kept. Nothing is written where there is no record to write into, so a
    /// workspace without one is left without one rather than given one here.
    private func retain(_ packages: [MarketplacePackage]) async {
        do {
            guard let snapshot = try store.snapshot(), snapshot.device.applicationState != nil else { return }
            let retained = packages
            _ = try await service.commitDeviceChange(expectedRevisionID: snapshot.document.revision.id) { device in
                device.applicationState?.marketplacePackages = retained
            }
        } catch {
            errorMessage = "The catalog is shown but could not be kept for next time."
            return
        }
        // Keeping it advanced the workspace, so the library is read again
        // rather than left holding an older head.
        await library.refresh()
    }

    // MARK: - Packages

    /// A catalog listing with every installation claim removed.
    ///
    /// Catalogs report installation, and this build observes none: nothing here
    /// runs a client's plugin list. Keeping the claim would put "Installed" on
    /// a row on the strength of a file written by a version of this app that
    /// could still check. The library answers that question instead.
    private static func unobserved(_ package: MarketplacePackage) -> MarketplacePackage {
        var value = package
        value.isInstalled = false
        value.nativeInstalls = value.nativeInstalls.map { route in
            var route = route
            route.isInstalled = false
            return route
        }
        return value
    }

    /// One row per catalog identity, first occurrence winning, so two providers
    /// publishing the same server do not double it.
    private static func deduplicated(_ packages: [MarketplacePackage]) -> [MarketplacePackage] {
        var seen = Set<String>()
        return packages.filter { seen.insert($0.id).inserted }
    }

    /// A stable order to arrive in, so a list nobody has sorted yet is not in
    /// whatever order the network answered.
    private static func ordered(_ packages: [MarketplacePackage]) -> [MarketplacePackage] {
        MarketplaceSorting.sorted(packages, by: .name)
    }
}
