import Foundation

public struct MarketplaceQuery: Codable, Hashable, Sendable {
    public var search: String?
    public var cursor: String?
    public var limit: Int

    public init(search: String? = nil, cursor: String? = nil, limit: Int = 50) {
        self.search = search
        self.cursor = cursor
        self.limit = min(max(limit, 1), 100)
    }
}

public struct MarketplacePage: Codable, Hashable, Sendable {
    public var packages: [MarketplacePackage]
    public var nextCursor: String?

    public init(packages: [MarketplacePackage], nextCursor: String? = nil) {
        self.packages = packages
        self.nextCursor = nextCursor
    }
}

public protocol MarketplaceProvider: Sendable {
    var id: String { get }
    var displayName: String { get }
    func search(_ query: MarketplaceQuery) async throws -> MarketplacePage
}

public protocol HTTPDataLoading: Sendable {
    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

public actor URLSessionHTTPDataLoader: HTTPDataLoading {
    private let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    public func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw MarketplaceProviderError.invalidResponse
        }
        return (data, httpResponse)
    }
}

public struct OfficialMCPRegistryProvider: MarketplaceProvider {
    public let id = "mcp.official-registry"
    public let displayName = "Official MCP Registry"

    private static let maximumResponseBytes = 4_194_304
    private let baseURL: URL
    private let loader: any HTTPDataLoading

    public init(
        baseURL: URL? = nil,
        loader: any HTTPDataLoading = URLSessionHTTPDataLoader()
    ) throws {
        var defaultComponents = URLComponents()
        defaultComponents.scheme = "https"
        defaultComponents.host = "registry.modelcontextprotocol.io"
        guard let resolvedBaseURL = baseURL ?? defaultComponents.url,
            resolvedBaseURL.scheme == "https",
            resolvedBaseURL.host != nil
        else {
            throw MarketplaceProviderError.insecureBaseURL
        }
        self.baseURL = resolvedBaseURL
        self.loader = loader
    }

    public func search(_ query: MarketplaceQuery) async throws -> MarketplacePage {
        let endpoint = baseURL.appending(path: "v0.1/servers")
        guard let urlComponents = URLComponents(url: endpoint, resolvingAgainstBaseURL: false) else {
            throw MarketplaceProviderError.invalidRequest
        }
        var components = urlComponents

        var items = [
            URLQueryItem(name: "limit", value: String(query.limit)),
            URLQueryItem(name: "version", value: "latest"),
        ]
        if let search = query.search?.trimmingCharacters(in: .whitespacesAndNewlines), !search.isEmpty {
            items.append(URLQueryItem(name: "search", value: String(search.prefix(256))))
        }
        if let cursor = query.cursor, !cursor.isEmpty {
            items.append(URLQueryItem(name: "cursor", value: String(cursor.prefix(1_024))))
        }
        components.queryItems = items
        guard let url = components.url else { throw MarketplaceProviderError.invalidRequest }

        var request = URLRequest(url: url)
        request.timeoutInterval = 15
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try await loader.data(for: request)
        guard (200..<300).contains(response.statusCode) else {
            throw MarketplaceProviderError.httpStatus(response.statusCode)
        }
        guard data.count <= Self.maximumResponseBytes else {
            throw MarketplaceProviderError.responseTooLarge
        }

        let payload: RegistryResponse
        do {
            payload = try AgentToolingCoding.decoder().decode(RegistryResponse.self, from: data)
        } catch {
            throw MarketplaceProviderError.invalidPayload
        }
        return MarketplacePage(
            packages: payload.servers.compactMap(Self.marketplacePackage).sorted { $0.name < $1.name },
            nextCursor: payload.metadata.nextCursor
        )
    }

    private static func marketplacePackage(_ entry: RegistryEntry) -> MarketplacePackage? {
        let server = entry.server
        guard let name = bounded(server.name, limit: 256), let version = bounded(server.version, limit: 256) else {
            return nil
        }
        let credentialNames = Set(
            server.packages.flatMap { package in
                package.environmentVariables.compactMap { variable in
                    bounded(variable.name, limit: 128)
                }
            }
                + server.remotes.flatMap { remote in
                    remote.headers.compactMap { header in bounded(header.name, limit: 128) }
                }
        ).sorted()
        let repositoryURL = safeHTTPSURL(server.repository?.url)
        let publisher = publisherName(serverName: name, repositoryURL: repositoryURL)
        let sourceLocation = repositoryURL ?? "https://registry.modelcontextprotocol.io"
        let nativeInstalls = reviewedNativeInstalls(server: server, credentialNames: credentialNames)
        return MarketplacePackage(
            id: "mcp-registry:\(name)@\(version)",
            name: name,
            publisher: publisher,
            summary: bounded(server.description, limit: 8_192) ?? "No description provided.",
            sourceName: "Official MCP Registry",
            revision: version,
            components: [.mcpServer],
            supportedClients: Set(ClientKind.allCases),
            authentication: credentialNames.isEmpty
                ? nil
                : "Requests \(credentialNames.count) named configuration value\(credentialNames.count == 1 ? "" : "s").",
            hasExecutableContent: true,
            trustSummary: "Registry metadata is validated, but package behavior and identity still require review.",
            location: sourceLocation,
            nativeInstalls: nativeInstalls,
            provenance: PackageProvenance(
                source: PackageSource(kind: .mcpRegistry, location: sourceLocation),
                lock: SourceLock(revision: version),
                publisher: publisher
            ),
            requestedCredentialNames: credentialNames,
            ownership: .managed,
            updateStatus: .unknown
        )
    }

    private static func reviewedNativeInstalls(server: RegistryServer, credentialNames: [String]) -> [NativeInstall] {
        guard credentialNames.isEmpty, let installName = installIdentifier(server.name) else { return [] }
        if let remote = server.remotes.first(where: { remote in
            remote.type == "streamable-http"
                && remote.headers.isEmpty
                && remote.variables.isEmpty
                && safeHTTPSURL(remote.url) != nil
        }), let url = safeHTTPSURL(remote.url) {
            return nativeRoutes(name: installName, transport: .http(url))
        }
        if let package = server.packages.first(where: { package in
            package.registryType == "npm"
                && package.transport.type == "stdio"
                && package.environmentVariables.isEmpty
                && package.runtimeArguments.isEmpty
                && package.packageArguments.isEmpty
                && bounded(package.identifier, limit: 512) != nil
                && bounded(package.version, limit: 255) != nil
                && package.version != "latest"
        }) {
            return nativeRoutes(name: installName, transport: .stdio(["npx", "-y", "\(package.identifier)@\(package.version)"]))
        }
        return []
    }

    private enum ReviewedTransport {
        case http(String)
        case stdio([String])
    }

    private static func nativeRoutes(name: String, transport: ReviewedTransport) -> [NativeInstall] {
        let route: (ClientKind, [String], [String], String) -> NativeInstall = { client, arguments, removal, detail in
            NativeInstall(
                client: client,
                executable: client == .claude ? "claude" : client == .codex ? "codex" : "gemini",
                arguments: arguments,
                removalArguments: removal,
                scope: .user,
                detail: detail,
                isInstalled: false
            )
        }
        switch transport {
        case .http(let url):
            return [
                route(
                    .claude,
                    ["mcp", "add", "--transport", "http", "--scope", "user", name, url],
                    ["mcp", "remove", "--scope", "user", name],
                    "Add the reviewed HTTPS endpoint with Claude Code's native MCP command."
                ),
                route(
                    .codex,
                    ["mcp", "add", name, "--url", url],
                    ["mcp", "remove", name],
                    "Add the reviewed HTTPS endpoint with Codex's native MCP command."
                ),
                route(
                    .gemini,
                    ["mcp", "add", "--scope", "user", "--transport", "http", name, url],
                    ["mcp", "remove", "--scope", "user", name],
                    "Add the reviewed HTTPS endpoint with Gemini CLI's native MCP command."
                ),
            ]
        case .stdio(let command):
            return [
                route(
                    .claude,
                    ["mcp", "add", "--transport", "stdio", "--scope", "user", name, "--"] + command,
                    ["mcp", "remove", "--scope", "user", name],
                    "Run the exact pinned npm package through Claude Code's native MCP command."
                ),
                route(
                    .codex,
                    ["mcp", "add", name, "--"] + command,
                    ["mcp", "remove", name],
                    "Run the exact pinned npm package through Codex's native MCP command."
                ),
                route(
                    .gemini,
                    ["mcp", "add", "--scope", "user", "--transport", "stdio", name, "--"] + command,
                    ["mcp", "remove", "--scope", "user", name],
                    "Run the exact pinned npm package through Gemini CLI's native MCP command."
                ),
            ]
        }
    }

    private static func installIdentifier(_ serverName: String) -> String? {
        guard let candidate = serverName.split(separator: "/").last.map(String.init),
            !candidate.isEmpty,
            candidate.count <= 256,
            !candidate.hasPrefix("-"),
            candidate.unicodeScalars.allSatisfy({ scalar in
                CharacterSet.alphanumerics.contains(scalar) || "._-".unicodeScalars.contains(scalar)
            })
        else { return nil }
        return candidate
    }

    private static func bounded(_ value: String, limit: Int) -> String? {
        let trimmed = SensitiveValueRedactor.redact(value).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
            trimmed.count <= limit,
            !trimmed.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
        else { return nil }
        return trimmed
    }

    private static func safeHTTPSURL(_ value: String?) -> String? {
        guard let value,
            value.count <= 2_048,
            let url = URL(string: value),
            url.scheme == "https",
            url.host != nil
        else { return nil }
        return url.absoluteString
    }

    private static func publisherName(serverName: String, repositoryURL: String?) -> String {
        if let repositoryURL,
            let url = URL(string: repositoryURL),
            let host = url.host,
            host == "github.com" || host.hasSuffix(".github.com"),
            let owner = url.pathComponents.dropFirst().first,
            !owner.isEmpty
        {
            return owner
        }
        return serverName.split(separator: "/").first.map(String.init) ?? serverName
    }
}

public enum MarketplaceProviderError: LocalizedError, Sendable {
    case insecureBaseURL
    case invalidRequest
    case invalidResponse
    case httpStatus(Int)
    case responseTooLarge
    case invalidPayload

    public var errorDescription: String? {
        switch self {
        case .insecureBaseURL: "Marketplace providers require an HTTPS base URL."
        case .invalidRequest: "The marketplace request could not be created."
        case .invalidResponse: "The marketplace returned a non-HTTP response."
        case .httpStatus(let status): "The marketplace returned HTTP status \(status)."
        case .responseTooLarge: "The marketplace response exceeded the review limit."
        case .invalidPayload: "The marketplace returned an unsupported payload."
        }
    }
}

private struct RegistryResponse: Decodable {
    var servers: [RegistryEntry]
    var metadata: RegistryMetadata
}

private struct RegistryMetadata: Decodable {
    var nextCursor: String?
}

private struct RegistryEntry: Decodable {
    var server: RegistryServer
}

private struct RegistryServer: Decodable {
    var name: String
    var description: String
    var version: String
    var repository: RegistryRepository?
    var packages: [RegistryPackage]
    var remotes: [RegistryRemote]

    private enum CodingKeys: String, CodingKey {
        case name, description, version, repository, packages, remotes
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = try container.decode(String.self, forKey: .name)
        description = try container.decodeIfPresent(String.self, forKey: .description) ?? "No description provided."
        version = try container.decode(String.self, forKey: .version)
        repository = try container.decodeIfPresent(RegistryRepository.self, forKey: .repository)
        packages = try container.decodeIfPresent([RegistryPackage].self, forKey: .packages) ?? []
        remotes = try container.decodeIfPresent([RegistryRemote].self, forKey: .remotes) ?? []
    }
}

private struct RegistryRepository: Decodable {
    var url: String
}

private struct RegistryPackage: Decodable {
    var registryType: String
    var identifier: String
    var version: String
    var transport: RegistryTransport
    var environmentVariables: [RegistryEnvironmentVariable]
    var runtimeArguments: [JSONValue]
    var packageArguments: [JSONValue]

    private enum CodingKeys: String, CodingKey {
        case registryType, identifier, version, transport, environmentVariables, runtimeArguments, packageArguments
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        registryType = try container.decodeIfPresent(String.self, forKey: .registryType) ?? ""
        identifier = try container.decodeIfPresent(String.self, forKey: .identifier) ?? ""
        version = try container.decodeIfPresent(String.self, forKey: .version) ?? ""
        transport = try container.decodeIfPresent(RegistryTransport.self, forKey: .transport) ?? RegistryTransport(type: "")
        environmentVariables =
            try container.decodeIfPresent([RegistryEnvironmentVariable].self, forKey: .environmentVariables) ?? []
        runtimeArguments = try container.decodeIfPresent([JSONValue].self, forKey: .runtimeArguments) ?? []
        packageArguments = try container.decodeIfPresent([JSONValue].self, forKey: .packageArguments) ?? []
    }
}

private struct RegistryTransport: Decodable {
    var type: String
}

private struct RegistryRemote: Decodable {
    var type: String
    var url: String
    var headers: [RegistryEnvironmentVariable]
    var variables: [String: JSONValue]

    private enum CodingKeys: String, CodingKey {
        case type, url, headers, variables
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        type = try container.decodeIfPresent(String.self, forKey: .type) ?? ""
        url = try container.decodeIfPresent(String.self, forKey: .url) ?? ""
        headers = try container.decodeIfPresent([RegistryEnvironmentVariable].self, forKey: .headers) ?? []
        variables = try container.decodeIfPresent([String: JSONValue].self, forKey: .variables) ?? [:]
    }
}

private struct RegistryEnvironmentVariable: Decodable {
    var name: String
}
