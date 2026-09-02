import Foundation
import Testing

@testable import AgentToolingCore

private actor MarketplaceHTTPStub: HTTPDataLoading {
    private let payload: Data
    private let statusCode: Int
    private var requestedURL: URL?

    init(payload: Data, statusCode: Int = 200) {
        self.payload = payload
        self.statusCode = statusCode
    }

    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        guard let url = request.url else { throw MarketplaceProviderError.invalidRequest }
        requestedURL = url
        guard
            let response = HTTPURLResponse(
                url: url,
                statusCode: statusCode,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "application/json"]
            )
        else { throw MarketplaceProviderError.invalidResponse }
        return (payload, response)
    }

    func lastURL() -> URL? { requestedURL }
}

struct MarketplaceProviderTests {
    @Test func officialRegistryMapsProvenanceAndCredentialNamesWithoutValues() async throws {
        let payload = Data(
            #"""
            {
              "servers": [{
                "server": {
                  "name": "io.github.example/filesystem",
                  "description": "A reviewed filesystem server.",
                  "version": "1.2.3",
                  "repository": {"url": "https://github.com/example/server"},
                  "packages": [{
                    "environmentVariables": [
                      {"name": "API_TOKEN", "isSecret": true},
                      {"name": "ROOT_PATH"}
                    ]
                  }]
                }
              }],
              "metadata": {"nextCursor": "next-page", "count": 1}
            }
            """#.utf8
        )
        let stub = MarketplaceHTTPStub(payload: payload)
        let provider = try OfficialMCPRegistryProvider(loader: stub)

        let page = try await provider.search(MarketplaceQuery(search: "file system", limit: 500))

        let package = try #require(page.packages.first)
        #expect(page.nextCursor == "next-page")
        #expect(package.publisher == "example")
        #expect(package.requestedCredentialNames == ["API_TOKEN", "ROOT_PATH"])
        #expect(package.provenance?.lock?.revision == "1.2.3")
        #expect(package.nativeInstalls.isEmpty)
        let url = try #require(await stub.lastURL())
        let components = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
        #expect(components.queryItems?.contains(URLQueryItem(name: "limit", value: "100")) == true)
        #expect(components.queryItems?.contains(URLQueryItem(name: "search", value: "file system")) == true)
    }

    @Test func officialRegistryRejectsInsecureSourcesAndBadResponses() async throws {
        #expect(throws: MarketplaceProviderError.self) {
            _ = try OfficialMCPRegistryProvider(baseURL: URL(string: "http://registry.example")!)
        }

        let stub = MarketplaceHTTPStub(payload: Data("{}".utf8), statusCode: 503)
        let provider = try OfficialMCPRegistryProvider(loader: stub)
        await #expect(throws: MarketplaceProviderError.self) {
            _ = try await provider.search(MarketplaceQuery())
        }
    }

    @Test func officialRegistryCreatesOnlyPinnedCredentialFreeNativeRoutes() async throws {
        let payload = Data(
            #"""
            {
              "servers": [
                {"server": {
                  "name": "com.example/remote-docs",
                  "description": "Remote docs",
                  "version": "2.0.0",
                  "remotes": [{"type": "streamable-http", "url": "https://example.com/mcp"}]
                }},
                {"server": {
                  "name": "com.example/local-search",
                  "description": "Local search",
                  "version": "3.0.0",
                  "packages": [{
                    "registryType": "npm",
                    "identifier": "@example/local-search",
                    "version": "3.0.0",
                    "transport": {"type": "stdio"}
                  }]
                }}
              ],
              "metadata": {"count": 2}
            }
            """#.utf8
        )
        let provider = try OfficialMCPRegistryProvider(loader: MarketplaceHTTPStub(payload: payload))

        let page = try await provider.search(MarketplaceQuery())

        let remote = try #require(page.packages.first(where: { $0.name == "com.example/remote-docs" }))
        #expect(remote.nativeInstalls.count == 3)
        #expect(
            remote.nativeInstalls.first(where: { $0.client == .codex })?.arguments
                == ["mcp", "add", "remote-docs", "--url", "https://example.com/mcp"]
        )
        let local = try #require(page.packages.first(where: { $0.name == "com.example/local-search" }))
        #expect(local.nativeInstalls.count == 3)
        #expect(
            local.nativeInstalls.first(where: { $0.client == .claude })?.arguments
                == [
                    "mcp", "add", "--transport", "stdio", "--scope", "user", "local-search", "--", "npx", "-y",
                    "@example/local-search@3.0.0",
                ]
        )
    }

    @Test func officialRegistryKeepsListingsWhenOneEntryIsIncomplete() async throws {
        let payload = Data(
            #"""
            {
              "servers": [
                {"server": {
                  "name": "ai.example/empty-repository",
                  "description": "Published with an empty repository object.",
                  "version": "0.1.0",
                  "repository": {},
                  "remotes": [{"type": "streamable-http", "url": "https://example.com/mcp"}]
                }},
                {"server": {
                  "description": "Missing the required name field.",
                  "version": "9.9.9"
                }},
                {"server": {
                  "name": "ai.example/healthy",
                  "description": "A complete listing.",
                  "version": "2.0.0",
                  "repository": {"url": "https://github.com/example/healthy"},
                  "remotes": [{"type": "streamable-http", "url": "https://example.com/healthy"}]
                }}
              ],
              "metadata": {"count": 3}
            }
            """#.utf8
        )
        let provider = try OfficialMCPRegistryProvider(loader: MarketplaceHTTPStub(payload: payload))

        let page = try await provider.search(MarketplaceQuery())

        #expect(page.packages.map(\.name) == ["ai.example/empty-repository", "ai.example/healthy"])
        let sparse = try #require(page.packages.first(where: { $0.name == "ai.example/empty-repository" }))
        #expect(sparse.location == "https://registry.modelcontextprotocol.io")
    }
}
