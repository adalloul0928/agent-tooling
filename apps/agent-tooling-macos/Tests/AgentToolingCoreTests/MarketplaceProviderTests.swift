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

    @Test func officialRegistryDecodesDeclaredToolsAnnotationsAndUpdateDate() async throws {
        let payload = Data(
            #"""
            {
              "servers": [{
                "server": {
                  "$schema": "https://static.modelcontextprotocol.io/schemas/2025-12-11/server.schema.json",
                  "name": "io.github.example/notes",
                  "description": "A reviewed notes server.",
                  "version": "1.4.0",
                  "repository": {"url": "https://github.com/example/notes", "source": "github"},
                  "remotes": [{"type": "streamable-http", "url": "https://example.com/mcp"}],
                  "_meta": {
                    "io.modelcontextprotocol.registry/publisher-provided": {
                      "com.example.notes": {
                        "tools": [
                          {
                            "name": "search_notes",
                            "description": "Search the notebook.",
                            "annotations": {"readOnlyHint": true, "idempotentHint": true},
                            "inputSchema": {
                              "type": "object",
                              "properties": {
                                "query": {"type": "string"},
                                "api_key": {"type": "string", "default": "default-value-must-never-render"}
                              },
                              "required": ["query"]
                            },
                            "outputSchema": {"type": "object", "properties": {"matches": {"type": "array"}}}
                          },
                          {
                            "name": "delete_note",
                            "description": "Delete a note permanently.",
                            "annotations": {"destructiveHint": true, "readOnlyHint": false, "openWorldHint": false}
                          },
                          {"name": "list_tags"}
                        ]
                      }
                    }
                  }
                },
                "_meta": {
                  "io.modelcontextprotocol.registry/official": {
                    "status": "active",
                    "publishedAt": "2026-01-02T03:04:05.123456Z",
                    "updatedAt": "2026-06-07T08:09:10.987654Z",
                    "isLatest": true
                  }
                }
              }],
              "metadata": {"count": 1}
            }
            """#.utf8
        )
        let provider = try OfficialMCPRegistryProvider(loader: MarketplaceHTTPStub(payload: payload))

        let page = try await provider.search(MarketplaceQuery())

        let package = try #require(page.packages.first)
        let tools = try #require(package.tools)
        #expect(tools.map(\.name) == ["search_notes", "delete_note", "list_tags"])

        let search = try #require(tools.first(where: { $0.name == "search_notes" }))
        #expect(search.annotations.readOnly == true)
        #expect(search.annotations.idempotent == true)
        // Nothing was declared about destruction, so nothing is claimed.
        #expect(search.annotations.destructive == nil)
        #expect(search.annotations.openWorld == nil)
        #expect(search.inputFields.map(\.name) == ["api_key", "query"])
        #expect(search.inputFields.first(where: { $0.name == "api_key" })?.isSecretLike == true)
        #expect(search.inputFields.first(where: { $0.name == "query" })?.isRequired == true)
        #expect(search.declaresInputSchema)
        #expect(search.outputFields.map(\.name) == ["matches"])

        let delete = try #require(tools.first(where: { $0.name == "delete_note" }))
        #expect(delete.annotations.destructive == true)
        #expect(delete.annotations.declaredLabels.first == "Destructive")
        #expect(delete.declaresInputSchema == false)

        let listTags = try #require(tools.first(where: { $0.name == "list_tags" }))
        #expect(listTags.annotations.isEmpty)
        #expect(listTags.inputFields.isEmpty)

        // Schema defaults are dropped at decode time, so no catalog value can
        // reach a display or a plan.
        let encoded = try String(decoding: AgentToolingCoding.encoder().encode(package), as: UTF8.self)
        #expect(!encoded.contains("must-never-render"))

        let update = try #require(package.lastUpdate)
        #expect(update.origin == .catalogListing)
        let expected = try #require(
            try? Date("2026-06-07T08:09:10.987654Z", strategy: Date.ISO8601FormatStyle(includingFractionalSeconds: true)))
        #expect(abs(update.date.timeIntervalSince(expected)) < 1)
    }

    @Test func officialRegistryLeavesToolsAndDatesUnclaimedWhenThePayloadOmitsThem() async throws {
        let payload = Data(
            #"""
            {
              "servers": [
                {"server": {
                  "name": "io.github.example/plain",
                  "description": "A listing with no publisher metadata at all.",
                  "version": "1.0.0",
                  "remotes": [{"type": "streamable-http", "url": "https://example.com/plain"}]
                }},
                {"server": {
                  "name": "io.github.example/unannotated",
                  "description": "A listing whose tools declare no annotations.",
                  "version": "1.0.0",
                  "_meta": {
                    "io.modelcontextprotocol.registry/publisher-provided": {
                      "tools": [{"name": "fetch_page", "description": "Fetch one page."}]
                    }
                  }
                }}
              ],
              "metadata": {"count": 2}
            }
            """#.utf8
        )
        let provider = try OfficialMCPRegistryProvider(loader: MarketplaceHTTPStub(payload: payload))

        let page = try await provider.search(MarketplaceQuery())

        let plain = try #require(page.packages.first(where: { $0.name == "io.github.example/plain" }))
        #expect(plain.tools == nil)
        #expect(plain.lastUpdate == nil)

        let unannotated = try #require(page.packages.first(where: { $0.name == "io.github.example/unannotated" }))
        let tool = try #require(unannotated.tools?.first)
        #expect(tool.name == "fetch_page")
        #expect(tool.annotations.isEmpty)
        #expect(tool.annotations.declaredLabels.isEmpty)
        #expect(tool.declaresInputSchema == false)
        #expect(tool.declaresOutputSchema == false)
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
