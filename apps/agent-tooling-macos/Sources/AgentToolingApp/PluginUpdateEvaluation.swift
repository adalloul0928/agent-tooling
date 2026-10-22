import AgentToolingCore
import Foundation

/// Shared update verdicts for Home and the plugin library. Unchecked catalogs
/// produce no update claim. Native routes establish package identity; display
/// names do not. Comparison remains with `UpdateAvailabilityEvaluator`, and
/// absent installed revisions are never inferred from content digests.
struct PluginUpdateEvaluation {
    /// One verdict per plugin row, keyed the way both screens hold their rows.
    let availability: [ArtifactID: UpdateAvailability]
    /// Whether any catalog has been asked at all. False means every verdict
    /// above is "not checked", and a screen should say so rather than implying
    /// a comparison happened.
    let hasCheckedACatalog: Bool

    private static let neverChecked = "No catalog has been checked yet. Refresh Discover to compare revisions."

    /// The evaluation both screens share, from a library read once.
    ///
    /// `packages` and `sources` default to what this Mac kept from the last
    /// refresh, which is the record Discover writes and every other screen
    /// reads. A screen holding a live catalog session passes its fresher lists
    /// instead; the two agree as soon as that session has kept its answer.
    init(
        state: WorkspaceLibraryState?,
        packages: [MarketplacePackage]? = nil,
        sources: [ToolingSource]? = nil
    ) {
        guard let state else {
            self.init(rows: [], plugins: [:], packages: [], sources: [])
            return
        }
        let inventory = VersionedInventoryProjection.inventory(state.library)
        self.init(
            rows: state.library.rows.filter { $0.kind == .nativePlugin || $0.kind == .package },
            plugins: Dictionary(
                inventory.plugins.compactMap { plugin in ArtifactID(plugin.id).map { ($0, plugin) } },
                uniquingKeysWith: { first, _ in first }),
            packages: packages ?? Self.retainedPackages(state.snapshot),
            sources: sources ?? Self.recordedSources(state.snapshot))
    }

    private init(
        rows: [WorkspaceLibraryReadModelRow],
        plugins: [ArtifactID: Plugin],
        packages: [MarketplacePackage],
        sources: [ToolingSource]
    ) {
        let checked = !packages.isEmpty || sources.contains { $0.lastRefreshedAt != nil }
        hasCheckedACatalog = checked
        availability = Dictionary(
            uniqueKeysWithValues: rows.map { row in
                guard checked, let plugin = plugins[row.artifactID] else {
                    return (row.artifactID, .notChecked(reason: Self.neverChecked))
                }
                guard let package = Self.catalogPackage(for: row, plugin: plugin, in: packages) else {
                    let unmatched = UpdateAvailabilityEvaluator.evaluate(
                        plugin: plugin, sources: sources, packages: packages)
                    return (row.artifactID, unmatched)
                }
                let installed = plugin.revision.isEmpty ? nil : plugin.revision
                let compared = UpdateAvailabilityEvaluator.evaluate(installed: installed, against: package)
                return (row.artifactID, compared)
            })
    }

    /// The rows a catalog says have something newer, worst news first and in a
    /// stable order after that, so the same three rows do not shuffle between
    /// two draws of the same screen.
    func rowsWithUpdates(in rows: [WorkspaceLibraryReadModelRow]) -> [WorkspaceLibraryReadModelRow] {
        rows
            .filter { availability[$0.artifactID]?.hasUpdate == true }
            .sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
    }

    /// The listing this row came from, matched on identity the native parsers
    /// preserved rather than on anything a person typed.
    private static func catalogPackage(
        for row: WorkspaceLibraryReadModelRow,
        plugin: Plugin,
        in packages: [MarketplacePackage]
    ) -> MarketplacePackage? {
        let routes = Set(row.nativeRoutes.map { NativePackageRoute(client: $0.client, externalPluginID: $0.externalPluginID) })
        if !routes.isEmpty,
            let matched = packages.first(where: { package in
                guard let identity = NativeCatalogPackageIdentity.recognize(package) else { return false }
                return routes.contains(
                    NativePackageRoute(client: identity.client, externalPluginID: identity.externalPluginID))
            })
        {
            return matched
        }
        return UpdateAvailabilityEvaluator.catalogPackage(for: plugin, in: packages)
    }

    /// What this Mac kept from the last catalog it reached. Discover writes it;
    /// every other screen reads it rather than asking a catalog of its own.
    private static func retainedPackages(_ snapshot: WorkspaceApplicationSnapshot) -> [MarketplacePackage] {
        snapshot.device.applicationState?.marketplacePackages ?? []
    }

    /// The catalogs and folders this workspace records, in two halves: the
    /// portable half names them, and this Mac's half remembers when it last
    /// looked and what it saw.
    private static func recordedSources(_ snapshot: WorkspaceApplicationSnapshot) -> [ToolingSource] {
        let local = Dictionary(
            (snapshot.device.configurationState?.catalogSources ?? []).map { ($0.catalogSourceID, $0) },
            uniquingKeysWith: { first, _ in first })
        return (snapshot.document.configurationState?.catalogSources ?? []).map { record in
            let device = local[record.id]
            return ToolingSource(
                id: record.id.rawValue, name: record.name, kind: record.kind,
                location: device?.localLocation ?? record.remoteLocation ?? "",
                isOptionalBackup: record.isOptionalBackup, lastRefreshedAt: device?.lastRefreshedAt,
                lastRevision: device?.lastRevision, trustSummary: device?.trustSummary ?? "Not reviewed")
        }
    }
}

extension ArtifactID {
    /// The projection writes an artifact identifier back out as a lowercase
    /// UUID string, so reading one back is exact rather than a guess.
    fileprivate init?(_ projected: String) {
        guard let uuid = UUID(uuidString: projected) else { return nil }
        self.init(rawValue: uuid)
    }
}
