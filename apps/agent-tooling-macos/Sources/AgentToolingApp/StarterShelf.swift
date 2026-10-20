import AgentToolingCore
import Foundation

/// Public starter listings bundled in `Resources/StarterShelf.json`; loading them
/// makes no catalog request before setup consent. Entries use the same native
/// package and skills.sh parsers as Discover. Cached catalog facts may enrich a
/// listing, while the bundled descriptions remain authoritative.
@MainActor
enum StarterShelf {
    /// One listing on the shelf, as the bundle records it.
    struct Entry: Decodable, Equatable, Sendable {
        enum Kind: String, Decodable, Sendable {
            case plugin
            case skill
        }

        /// The listing's catalog identity: `claude:` or `codex:` and the
        /// plugin's identifier, or `skills-sh:` and the skill's path.
        let packageID: String
        /// The app whose catalog lists a plugin. A skill from skills.sh is
        /// for any app.
        let client: ClientKind?
        let kind: Kind
        let name: String
        let publisher: String
        /// The listing's one-line summary, as the card shows it.
        let summary: String
        /// Where it comes from, as the card's last line says it.
        let source: String
        /// `owner/repo`, for a skill from skills.sh.
        let skillsRepository: String?
    }

    private struct Shelf: Decodable {
        let entries: [Entry]
    }

    /// The bundled entries, in the order the shelf shows them.
    static func entries() throws -> [Entry] {
        guard let url = AppResources.bundle.url(forResource: "StarterShelf", withExtension: "json") else {
            throw CocoaError(.fileNoSuchFile)
        }
        return try JSONDecoder().decode(Shelf.self, from: Data(contentsOf: url)).entries
    }

    /// The shelf's listings, in its order, each filled in from `retained`
    /// when a catalog listed the same identity there.
    static func packages(retained: [MarketplacePackage]) -> [MarketplacePackage] {
        let known = Dictionary(retained.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return ((try? entries()) ?? []).compactMap { package(for: $0, retained: known[$0.packageID]) }
    }

    /// The listing for `entry`, or nil when the entry names no listing its
    /// catalog could have published.
    static func package(for entry: Entry, retained: MarketplacePackage?) -> MarketplacePackage? {
        var package: MarketplacePackage
        switch entry.kind {
        case .plugin:
            guard let client = entry.client, let pluginID = pluginID(of: entry.packageID, for: client),
                let install = NativePluginInstallRegister.reviewedInstall(for: client, externalPluginID: pluginID)
            else { return nil }
            package = MarketplacePackage(
                id: entry.packageID, name: entry.name, publisher: entry.publisher, summary: entry.summary,
                sourceName: "\(client.rawValue)’s catalog", components: [.plugin], supportedClients: [client],
                trustSummary: "Listed in \(client.rawValue)’s catalog. Review the source and permissions before installing.",
                location: pluginID, nativeInstalls: [install])
        case .skill:
            guard let repository = entry.skillsRepository, entry.packageID.hasPrefix(skillsShPrefix) else { return nil }
            let identifier = String(entry.packageID.dropFirst(skillsShPrefix.count))
            package = MarketplacePackage(
                id: entry.packageID, name: entry.name, publisher: entry.publisher, summary: entry.summary,
                sourceName: "skills.sh", components: [.skill], supportedClients: Set(ClientKind.allCases),
                trustSummary:
                    "skills.sh indexes public GitHub repositories; it does not verify publishers or review skill content.",
                location: "https://skills.sh/\(identifier)",
                provenance: PackageProvenance(
                    source: PackageSource(kind: .skillsShRegistry, location: "https://github.com/\(repository)"),
                    publisher: entry.publisher))
        }
        guard let retained else { return package }
        // What only a catalog that was read can say: how many installs it
        // reports, the routes and revision it published, and where it came
        // from.
        package.installCount = retained.installCount
        package.revision = retained.revision ?? package.revision
        package.lastUpdate = retained.lastUpdate
        if !retained.nativeInstalls.isEmpty { package.nativeInstalls = retained.nativeInstalls }
        if retained.provenance?.source.kind == package.catalogKind { package.provenance = retained.provenance }
        return package
    }

    /// The plugin identifier in `packageID`, when it is in `client`'s
    /// namespace.
    private static func pluginID(of packageID: String, for client: ClientKind) -> String? {
        let prefix: String
        switch client {
        case .claude: prefix = "claude:"
        case .codex: prefix = "codex:"
        case .gemini, .kiro: return nil
        }
        guard packageID.hasPrefix(prefix) else { return nil }
        return String(packageID.dropFirst(prefix.count))
    }

    private static let skillsShPrefix = "skills-sh:"
}
