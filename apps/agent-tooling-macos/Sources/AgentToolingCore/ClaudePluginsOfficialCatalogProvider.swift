import Foundation

/// The official Claude plugins marketplace, read directly from its published
/// catalog file rather than through Claude Code's own CLI.
///
/// Discover's Claude listings normally come from `claude plugin list
/// --available --json`. When that command cannot run — an isolated HOME, a
/// Toolbox shim in place of the real binary, or Claude simply not installed —
/// the CLI catalog is silent and Discover has nothing browsable to show. This
/// provider answers the same catalog from the machine-readable file the
/// marketplace repository publishes, so the browse experience survives the CLI
/// being unavailable.
///
/// It is deliberately shaped so the CLI stays the authority where it can speak:
/// every listing here is emitted with the same `claude:<name>@claude-plugins-official`
/// identifier the CLI parser produces, so `NativeCatalogPackageIdentity.recognize`
/// accepts it, the existing "Add to Library for Claude Code" path installs it
/// through Claude's own plugin command, and the deduplicating merge folds a CLI
/// row and a file row for the same plugin into one. This provider never claims
/// a listing is installed — installation is a fact about this Mac that only the
/// library and a scan can establish — and it reads the catalog over HTTPS with
/// the same byte limits, timeout, and bounded-string validation the MCP
/// registry provider uses. No web page is scraped.
public struct ClaudePluginsOfficialCatalogProvider: MarketplaceProvider {
    public let id = "claude.plugins-official"
    public let displayName = "claude-plugins-official"

    /// The marketplace this provider's listings belong to. It is part of every
    /// listing's identifier, so a person adding one runs
    /// `claude plugin install <name>@claude-plugins-official`.
    public static let marketplaceName = "claude-plugins-official"

    private enum Limit {
        /// The published file is roughly 190 KB today; 4 MiB leaves generous
        /// headroom while still bounding a runaway or malicious response, and
        /// matches the ceiling the MCP registry provider allows.
        static let responseBytes = 4_194_304
        static let plugins = 4_096
        static let nameCharacters = 128
        static let summaryCharacters = 8_192
        static let publisherCharacters = 256
        static let categoryCharacters = 64
        static let revisionCharacters = 256
        static let locationCharacters = 2_048
    }

    private let url: URL
    private let loader: any HTTPDataLoading

    /// The catalog anything outside this package asks for.
    ///
    /// The loader stays internal for the same reason as the other registry
    /// providers': how the catalog is reached is this package's business, and a
    /// caller that could substitute one could point "the official catalog"
    /// anywhere it liked.
    public init(url: URL? = nil) throws {
        try self.init(url: url, loader: URLSessionHTTPDataLoader())
    }

    init(
        url: URL? = nil,
        loader: any HTTPDataLoading = URLSessionHTTPDataLoader()
    ) throws {
        let defaultURL = URL(
            string:
                "https://raw.githubusercontent.com/anthropics/claude-plugins-official/main/.claude-plugin/marketplace.json")
        guard let resolvedURL = url ?? defaultURL,
            resolvedURL.scheme == "https",
            resolvedURL.host != nil
        else {
            throw MarketplaceProviderError.insecureBaseURL
        }
        self.url = resolvedURL
        self.loader = loader
    }

    /// The catalog file lists every plugin at once and takes no query, so the
    /// whole catalog is returned and Discover filters it. The query's page
    /// limit is meant for registries that page through results; applying it
    /// here would cut the alphabet off after the first hundred plugins, so the
    /// bound on this catalog is its own `Limit.plugins` instead. A search term
    /// is honored: only plugins that mention it come back.
    public func search(_ query: MarketplaceQuery) async throws -> MarketplacePage {
        var request = URLRequest(url: url)
        request.timeoutInterval = 15
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try await loader.data(for: request)
        guard (200..<300).contains(response.statusCode) else {
            throw MarketplaceProviderError.httpStatus(response.statusCode)
        }
        guard data.count <= Limit.responseBytes else {
            throw MarketplaceProviderError.responseTooLarge
        }

        let catalog: OfficialCatalog
        do {
            catalog = try AgentToolingCoding.decoder().decode(OfficialCatalog.self, from: data)
        } catch {
            throw MarketplaceProviderError.invalidPayload
        }
        let term = query.search?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
        let packages = catalog.plugins
            .prefix(Limit.plugins)
            .compactMap(Self.marketplacePackage)
            .filter { term.isEmpty || Self.mentions($0, term) }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        return MarketplacePage(packages: packages)
    }

    private static func mentions(_ package: MarketplacePackage, _ term: String) -> Bool {
        [package.name, package.publisher, package.summary, package.category ?? ""]
            .contains { $0.lowercased().contains(term) }
    }

    private static func marketplacePackage(_ entry: OfficialPlugin) -> MarketplacePackage? {
        // The name is the plugin's identity in the marketplace, so it has to be
        // exactly what the shared install policy will accept: it becomes both
        // the encoded identifier and an argument to `claude plugin install`.
        guard let name = bounded(entry.name, limit: Limit.nameCharacters),
            OperationCommandPolicy.isSafePluginIdentifier(name)
        else { return nil }
        let externalPluginID = "\(name)@\(marketplaceName)"
        // Built from the same register the adoption command checks against, so
        // the install and removal arguments cannot drift from what the "Add to
        // Library for Claude Code" path expects.
        guard let install = NativePluginInstallRegister.reviewedInstall(for: .claude, externalPluginID: externalPluginID)
        else { return nil }

        let displayName = bounded(entry.displayName, limit: Limit.nameCharacters) ?? name
        let publisher = bounded(entry.author?.name, limit: Limit.publisherCharacters) ?? "Anthropic marketplace"
        let summary =
            bounded(entry.description, limit: Limit.summaryCharacters, allowLineBreaks: true)
            ?? MarketplaceCopy.availableClaudePlugin
        let category = bounded(entry.category, limit: Limit.categoryCharacters)
        let revision = bounded(entry.version, limit: Limit.revisionCharacters)
        // The homepage is where a person reads about the plugin; the source URL
        // is where its bytes live. Either is a defensible link, so the homepage
        // is preferred and the source URL is the fallback.
        let location =
            safeHTTPSURL(entry.homepage)
            ?? safeHTTPSURL(entry.source.url)
            ?? "https://github.com/anthropics/claude-plugins-official"

        return MarketplacePackage(
            id: "claude:\(externalPluginID)",
            name: displayName,
            publisher: publisher,
            summary: summary,
            sourceName: marketplaceName,
            revision: revision,
            components: [.plugin],
            supportedClients: [.claude],
            trustSummary:
                "Listed in the official Claude plugins catalog on GitHub — review the source and permissions before installing.",
            location: location,
            nativeInstalls: [install],
            provenance: PackageProvenance(
                source: PackageSource(kind: .claudeMarketplace, location: location),
                lock: revision.map { SourceLock(revision: $0) },
                publisher: publisher),
            category: category)
    }

    private static func bounded(_ value: String?, limit: Int, allowLineBreaks: Bool = false) -> String? {
        guard let raw = value else { return nil }
        let trimmed = SensitiveValueRedactor.redact(raw).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
            trimmed.count <= limit,
            !trimmed.unicodeScalars.contains(where: { scalar in
                allowLineBreaks
                    ? scalar.value < 0x20 && ![0x09, 0x0A, 0x0D].contains(scalar.value)
                    : CharacterSet.controlCharacters.contains(scalar)
            })
        else { return nil }
        return trimmed
    }

    private static func safeHTTPSURL(_ value: String?) -> String? {
        guard let value,
            value.count <= Limit.locationCharacters,
            let url = URL(string: value),
            url.scheme == "https",
            url.host != nil
        else { return nil }
        return url.absoluteString
    }
}

/// The published catalog document. Only the fields Discover shows are read; the
/// file carries more (renames, lspServers, strict), and everything unread stays
/// in the raw bytes rather than becoming a field this app pretends to model.
private struct OfficialCatalog: Decodable {
    var plugins: [OfficialPlugin]

    private enum CodingKeys: String, CodingKey {
        case plugins
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        // One malformed listing must not hide the rest of the catalog, exactly
        // as the MCP registry tolerates a single bad server entry.
        plugins = (try container.decodeIfPresent([FailableOfficialPlugin].self, forKey: .plugins) ?? [])
            .compactMap(\.plugin)
    }
}

private struct FailableOfficialPlugin: Decodable {
    var plugin: OfficialPlugin?

    init(from decoder: any Decoder) throws {
        plugin = try? OfficialPlugin(from: decoder)
    }
}

private struct OfficialPlugin: Decodable {
    var name: String
    var displayName: String?
    var description: String?
    var author: OfficialAuthor?
    var category: String?
    var homepage: String?
    var version: String?
    var source: OfficialSource

    private enum CodingKeys: String, CodingKey {
        case name, displayName, description, author, category, homepage, version, source
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = try container.decode(String.self, forKey: .name)
        displayName = try container.decodeIfPresent(String.self, forKey: .displayName)
        description = try container.decodeIfPresent(String.self, forKey: .description)
        author = try container.decodeIfPresent(OfficialAuthor.self, forKey: .author)
        category = try container.decodeIfPresent(String.self, forKey: .category)
        homepage = try container.decodeIfPresent(String.self, forKey: .homepage)
        version = try container.decodeIfPresent(String.self, forKey: .version)
        source = (try? container.decodeIfPresent(OfficialSource.self, forKey: .source)) ?? OfficialSource(url: nil)
    }
}

private struct OfficialAuthor: Decodable {
    var name: String?

    private enum CodingKeys: String, CodingKey {
        case name
    }

    init(from decoder: any Decoder) throws {
        // The author is sometimes a bare string and sometimes an object with a
        // name field; either is read into the one name this app shows.
        if let single = try? decoder.singleValueContainer(), let text = try? single.decode(String.self) {
            name = text
            return
        }
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = try container.decodeIfPresent(String.self, forKey: .name)
    }
}

/// The plugin's source, which the catalog writes either as a bare path string
/// or as an object carrying a URL. Only a `url` is read here — the string form
/// is a repository-relative path with no host to link to, so it yields no
/// location and the homepage or catalog root is used instead.
private struct OfficialSource: Decodable {
    var url: String?

    init(url: String?) {
        self.url = url
    }

    private enum CodingKeys: String, CodingKey {
        case url
    }

    init(from decoder: any Decoder) throws {
        if let single = try? decoder.singleValueContainer(), let path = try? single.decode(String.self) {
            // A bare string is a path inside the marketplace repository, not a
            // linkable URL, so it is deliberately not treated as a location.
            _ = path
            url = nil
            return
        }
        let container = try decoder.container(keyedBy: CodingKeys.self)
        url = try container.decodeIfPresent(String.self, forKey: .url)
    }
}
