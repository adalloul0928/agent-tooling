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

struct OfficialMCPRegistryProvider: MarketplaceProvider {
    public let id = "mcp.official-registry"
    let displayName = "Official MCP Registry"

    private enum Limit {
        static let responseBytes = 4_194_304
        static let tools = 200
        static let schemaFields = 60
    }

    /// The registry's own `_meta` namespaces, spelled once.
    private static let registryOfficialMetaKey = "io.modelcontextprotocol.registry/official"
    private static let registryPublisherMetaKey = "io.modelcontextprotocol.registry/publisher-provided"

    private let baseURL: URL
    private let loader: any HTTPDataLoading

    init(
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

    func search(_ query: MarketplaceQuery) async throws -> MarketplacePage {
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
        guard data.count <= Limit.responseBytes else {
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
        let declaredTools = declaredTools(in: server)
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
            summary: bounded(server.description, limit: 8_192) ?? MarketplaceCopy.missingRegistryDescription,
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
            updateStatus: .unknown,
            lastUpdate: lastUpdate(entry),
            tools: declaredTools
        )
    }

    /// The registry records when it last accepted a change to a listing. That
    /// is the only update date this app can defend, so it is the only one it
    /// keeps — publish dates are used only when no update date exists.
    private static func lastUpdate(_ entry: RegistryEntry) -> PackageUpdateRecord? {
        guard case .object(let official)? = entry.meta[registryOfficialMetaKey] else { return nil }
        let candidates = [official["updatedAt"], official["publishedAt"]]
        for candidate in candidates {
            guard case .string(let text)? = candidate, let date = timestamp(text) else { continue }
            return PackageUpdateRecord(date: date, origin: .catalogListing)
        }
        return nil
    }

    private static func timestamp(_ value: String) -> Date? {
        guard value.count <= 64 else { return nil }
        if let date = try? Date(value, strategy: Date.ISO8601FormatStyle(includingFractionalSeconds: true)) { return date }
        return try? Date(value, strategy: Date.ISO8601FormatStyle())
    }

    /// Tool lists are publisher metadata, not an observation: the registry
    /// schema has no tools field, and a handful of publishers put one in their
    /// own `_meta` block. Where nobody published one the package carries `nil`
    /// so the UI can say so instead of drawing an empty table.
    private static func declaredTools(in server: RegistryServer) -> [MCPToolDescriptor]? {
        var candidates: [JSONValue] = []
        if let tools = server.tools { candidates.append(.array(tools)) }
        if case .object(let published)? = server.meta[registryPublisherMetaKey] {
            if let tools = published["tools"] { candidates.append(tools) }
            // Publishers namespace their own metadata, so a tool list is often
            // one level down under a reverse-DNS key of their choosing.
            for value in published.values {
                guard case .object(let nested) = value, let tools = nested["tools"] else { continue }
                candidates.append(tools)
            }
        }
        for candidate in candidates {
            guard case .array(let entries) = candidate, !entries.isEmpty else { continue }
            var seen: Set<String> = []
            let tools = entries.prefix(Limit.tools).compactMap { entry -> MCPToolDescriptor? in
                guard let tool = toolDescriptor(entry), seen.insert(tool.name).inserted else { return nil }
                return tool
            }
            if !tools.isEmpty { return tools }
        }
        return nil
    }

    private static func toolDescriptor(_ value: JSONValue) -> MCPToolDescriptor? {
        guard case .object(let fields) = value,
            case .string(let rawName)? = fields["name"],
            let name = bounded(rawName, limit: 128)
        else { return nil }
        let input = schemaFields(fields["inputSchema"])
        let output = schemaFields(fields["outputSchema"])
        return MCPToolDescriptor(
            name: name,
            title: string(fields["title"], limit: 128),
            summary: string(fields["description"], limit: 1_024),
            annotations: annotations(fields["annotations"]),
            inputFields: input.fields,
            outputFields: output.fields,
            declaresInputSchema: input.declared,
            declaresOutputSchema: output.declared
        )
    }

    /// MCP's hints are read exactly as declared. An absent hint stays absent:
    /// the specification's defaults are a client's own risk posture, not a
    /// statement the publisher made, and the app does not put words in their
    /// mouth.
    private static func annotations(_ value: JSONValue?) -> MCPToolAnnotations {
        guard case .object(let fields)? = value else { return MCPToolAnnotations() }
        return MCPToolAnnotations(
            readOnly: flag(fields["readOnlyHint"] ?? fields["readOnly"]),
            destructive: flag(fields["destructiveHint"] ?? fields["destructive"]),
            idempotent: flag(fields["idempotentHint"] ?? fields["idempotent"]),
            openWorld: flag(fields["openWorldHint"] ?? fields["openWorld"])
        )
    }

    /// Only property names, declared types, and the required list are read.
    /// Defaults and examples are dropped here so a value from a catalog can
    /// never reach a display or a plan.
    private static func schemaFields(_ value: JSONValue?) -> (fields: [MCPSchemaField], declared: Bool) {
        guard case .object(let schema)? = value else { return ([], false) }
        guard case .object(let properties)? = schema["properties"] else { return ([], true) }
        var required: Set<String> = []
        if case .array(let names)? = schema["required"] {
            for case .string(let name) in names.prefix(Limit.schemaFields) { required.insert(name) }
        }
        let fields = properties.keys.sorted().prefix(Limit.schemaFields).compactMap { key -> MCPSchemaField? in
            guard let name = bounded(key, limit: 128) else { return nil }
            var type: String?
            if case .object(let property)? = properties[key] { type = string(property["type"], limit: 32) }
            return MCPSchemaField(name: name, type: type, isRequired: required.contains(key))
        }
        return (fields, true)
    }

    private static func flag(_ value: JSONValue?) -> Bool? {
        guard case .bool(let flag)? = value else { return nil }
        return flag
    }

    private static func string(_ value: JSONValue?, limit: Int) -> String? {
        guard case .string(let text)? = value else { return nil }
        return bounded(text, limit: limit)
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
                executable: MCPClientCommand.executable(for: client),
                arguments: arguments,
                removalArguments: removal,
                scope: .user,
                detail: detail,
                isInstalled: false
            )
        }
        switch transport {
        case .http(let url):
            let httpDestination = ValidatedMCPDestination(endpoint: url, command: [])
            return [
                route(
                    .claude,
                    MCPClientCommand.addArguments(
                        serverID: name, transport: .http, destination: httpDestination, client: .claude, scope: .user),
                    MCPClientCommand.removeArguments(serverID: name, client: .claude, scope: .user),
                    "Add the reviewed HTTPS endpoint with Claude Code's native MCP command."
                ),
                route(
                    .codex,
                    MCPClientCommand.addArguments(
                        serverID: name, transport: .http, destination: httpDestination, client: .codex, scope: .user),
                    MCPClientCommand.removeArguments(serverID: name, client: .codex, scope: .user),
                    "Add the reviewed HTTPS endpoint with Codex's native MCP command."
                ),
                route(
                    .gemini,
                    MCPClientCommand.addArguments(
                        serverID: name, transport: .http, destination: httpDestination, client: .gemini, scope: .user),
                    MCPClientCommand.removeArguments(serverID: name, client: .gemini, scope: .user),
                    "Add the reviewed HTTPS endpoint with Gemini CLI's native MCP command."
                ),
            ]
        case .stdio(let command):
            let stdioDestination = ValidatedMCPDestination(endpoint: "", command: command)
            return [
                route(
                    .claude,
                    MCPClientCommand.addArguments(
                        serverID: name, transport: .stdio, destination: stdioDestination, client: .claude, scope: .user),
                    MCPClientCommand.removeArguments(serverID: name, client: .claude, scope: .user),
                    "Run the exact pinned npm package through Claude Code's native MCP command."
                ),
                route(
                    .codex,
                    MCPClientCommand.addArguments(
                        serverID: name, transport: .stdio, destination: stdioDestination, client: .codex, scope: .user),
                    MCPClientCommand.removeArguments(serverID: name, client: .codex, scope: .user),
                    "Run the exact pinned npm package through Codex's native MCP command."
                ),
                route(
                    .gemini,
                    MCPClientCommand.addArguments(
                        serverID: name, transport: .stdio, destination: stdioDestination, client: .gemini, scope: .user),
                    MCPClientCommand.removeArguments(serverID: name, client: .gemini, scope: .user),
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

enum MarketplaceProviderError: LocalizedError, Sendable {
    case insecureBaseURL
    case invalidRequest
    case invalidResponse
    case httpStatus(Int)
    case responseTooLarge
    case invalidPayload

    var errorDescription: String? {
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

    private enum CodingKeys: String, CodingKey {
        case servers, metadata
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        // One malformed listing must not hide the rest of the registry. Entries
        // that do not match the documented shape are skipped instead of failing
        // the whole page.
        servers = (try container.decodeIfPresent([FailableRegistryEntry].self, forKey: .servers) ?? [])
            .compactMap(\.entry)
        metadata = try container.decodeIfPresent(RegistryMetadata.self, forKey: .metadata) ?? RegistryMetadata()
    }
}

private struct FailableRegistryEntry: Decodable {
    var entry: RegistryEntry?

    init(from decoder: any Decoder) throws {
        entry = try? RegistryEntry(from: decoder)
    }
}

private struct RegistryMetadata: Decodable {
    var nextCursor: String?

    init(nextCursor: String? = nil) {
        self.nextCursor = nextCursor
    }
}

private struct RegistryEntry: Decodable {
    var server: RegistryServer
    /// The registry's own record for the listing, including the dates it keeps.
    var meta: [String: JSONValue]

    private enum CodingKeys: String, CodingKey {
        case server
        case meta = "_meta"
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        server = try container.decode(RegistryServer.self, forKey: .server)
        meta = (try? container.decodeIfPresent([String: JSONValue].self, forKey: .meta)).flatMap { $0 } ?? [:]
    }
}

private struct RegistryServer: Decodable {
    var name: String
    var description: String
    var version: String
    var repository: RegistryRepository?
    var packages: [RegistryPackage]
    var remotes: [RegistryRemote]
    /// Publisher-supplied metadata. The registry does not validate its shape,
    /// so everything read from it is bounded and optional.
    var meta: [String: JSONValue]
    /// Not part of the published schema today; read anyway so the listing wins
    /// if the registry ever adopts a first-class tools field.
    var tools: [JSONValue]?

    private enum CodingKeys: String, CodingKey {
        case name, description, version, repository, packages, remotes, tools
        case meta = "_meta"
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = try container.decode(String.self, forKey: .name)
        description = try container.decodeIfPresent(String.self, forKey: .description) ?? MarketplaceCopy.missingRegistryDescription
        version = try container.decode(String.self, forKey: .version)
        repository = try container.decodeIfPresent(RegistryRepository.self, forKey: .repository)
        packages = try container.decodeIfPresent([RegistryPackage].self, forKey: .packages) ?? []
        remotes = try container.decodeIfPresent([RegistryRemote].self, forKey: .remotes) ?? []
        meta = (try? container.decodeIfPresent([String: JSONValue].self, forKey: .meta)).flatMap { $0 } ?? [:]
        tools = (try? container.decodeIfPresent([JSONValue].self, forKey: .tools)).flatMap { $0 }
    }
}

private struct RegistryRepository: Decodable {
    var url: String

    private enum CodingKeys: String, CodingKey {
        case url
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        // Published listings sometimes carry an empty repository object. The
        // package stays reviewable; it simply has no source link.
        url = try container.decodeIfPresent(String.self, forKey: .url) ?? ""
    }
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
