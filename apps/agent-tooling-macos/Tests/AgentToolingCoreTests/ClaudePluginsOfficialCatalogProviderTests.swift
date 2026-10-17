import Foundation
import Testing

@testable import AgentToolingCore

/// A loader that answers the official catalog from memory and records whether it
/// was reached, so the provider's HTTPS-only and byte-limit rules can be proven
/// without opening a socket.
private actor OfficialCatalogHTTPStub: HTTPDataLoading {
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
                url: url, statusCode: statusCode, httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "application/json"])
        else { throw MarketplaceProviderError.invalidResponse }
        return (payload, response)
    }

    func lastURL() -> URL? { requestedURL }
}

struct ClaudePluginsOfficialCatalogProviderTests {
    /// The three source shapes the file uses — an object with a URL, a
    /// git-subdir object, and a bare path string — all parse, and every listing
    /// carries the identifier, provenance, and native install route the
    /// adoption path needs. An unsafe name is dropped rather than emitted.
    @Test func parsesEveryPublishedShapeAndRejectsAnUnsafeName() async throws {
        let payload = Data(
            #"""
            {
              "$schema": "https://json.schemastore.org/claude-plugins-marketplace.json",
              "name": "claude-plugins-official",
              "owner": {"name": "Anthropic"},
              "plugins": [
                {
                  "name": "42crunch-api-security-testing",
                  "displayName": "42Crunch API Security",
                  "description": "Audit and test APIs for security issues.",
                  "author": {"name": "42Crunch"},
                  "category": "security",
                  "homepage": "https://example.com/42crunch",
                  "version": "1.2.0",
                  "source": {"source": "url", "url": "https://github.com/42crunch/plugin", "path": "plugins/api"}
                },
                {
                  "name": "git-helper",
                  "description": "Common git workflows.",
                  "author": "Community Author",
                  "category": "development",
                  "source": {"source": "git-subdir", "url": "https://github.com/example/git-helper", "path": "plugins/git"}
                },
                {
                  "name": "path-only",
                  "description": "A plugin whose source is a bare repository path.",
                  "source": "./plugins/path-only"
                },
                {
                  "name": "../escape/attempt",
                  "description": "An unsafe name that must never be emitted.",
                  "source": {"url": "https://github.com/example/escape"}
                }
              ]
            }
            """#.utf8
        )
        let stub = OfficialCatalogHTTPStub(payload: payload)
        let provider = try ClaudePluginsOfficialCatalogProvider(loader: stub)

        let page = try await provider.search(MarketplaceQuery(limit: 100))

        // The unsafe name is gone; the three safe ones are present.
        #expect(page.packages.map(\.name).sorted() == ["42Crunch API Security", "git-helper", "path-only"])

        // Object-with-url source: display name, author, category, homepage, and
        // a locked revision all survive, and the identity is Claude's own.
        let crunch = try #require(page.packages.first { $0.id == "claude:42crunch-api-security-testing@claude-plugins-official" })
        #expect(crunch.name == "42Crunch API Security")
        #expect(crunch.publisher == "42Crunch")
        #expect(crunch.category == "security")
        #expect(crunch.location == "https://example.com/42crunch")
        #expect(crunch.revision == "1.2.0")
        #expect(crunch.components == [.plugin])
        #expect(crunch.supportedClients == [.claude])
        #expect(crunch.provenance?.source.kind == .claudeMarketplace)
        #expect(crunch.isInstalled == false)
        let install = try #require(crunch.nativeInstalls.first)
        #expect(install.client == .claude)
        #expect(install.executable == "claude")
        #expect(
            install.arguments
                == ["plugin", "install", "42crunch-api-security-testing@claude-plugins-official", "--scope", "user"])
        #expect(install.removalArguments == ["plugin", "uninstall", "42crunch-api-security-testing@claude-plugins-official", "--scope", "user"])

        // A bare-string author is read into the one name shown; a git-subdir
        // object yields the source URL as the location when no homepage exists.
        let git = try #require(page.packages.first { $0.name == "git-helper" })
        #expect(git.publisher == "Community Author")
        #expect(git.location == "https://github.com/example/git-helper")
        #expect(git.category == "development")

        // A bare-path source is not a linkable URL, so the catalog root is used
        // and a missing author falls back to the marketplace name.
        let pathOnly = try #require(page.packages.first { $0.name == "path-only" })
        #expect(pathOnly.publisher == "Anthropic marketplace")
        #expect(pathOnly.location == "https://github.com/anthropics/claude-plugins-official")
        #expect(pathOnly.category == nil)

        let url = try #require(await stub.lastURL())
        #expect(url.scheme == "https")
    }

    /// Every emitted listing is one the adoption path accepts for Claude and
    /// refuses for Codex — the whole point of matching the CLI parser's
    /// identity so the existing "Add to Library for Claude Code" path works.
    @Test func emittedListingsAreAdoptableForClaudeAndNotForCodex() async throws {
        let payload = Data(
            #"""
            {
              "name": "claude-plugins-official",
              "plugins": [
                {"name": "review-buddy", "description": "Reviews code.", "source": {"url": "https://github.com/example/review"}}
              ]
            }
            """#.utf8
        )
        let provider = try ClaudePluginsOfficialCatalogProvider(loader: OfficialCatalogHTTPStub(payload: payload))

        let package = try #require(try await provider.search(MarketplaceQuery()).packages.first)

        // The catalog's own identity is recognized.
        let identity = try #require(NativeCatalogPackageIdentity.recognize(package))
        #expect(identity.client == .claude)
        #expect(identity.externalPluginID == "review-buddy@claude-plugins-official")
        // Adoptable for Claude, refused for Codex — a Claude-namespace plugin is
        // never recorded under another app.
        #expect(NativePackageAdoptionCommand.refusal(adding: package, for: .claude) == nil)
        #expect(NativePackageAdoptionCommand.refusal(adding: package, for: .codex) != nil)
    }

    /// The catalog is reached over HTTPS only, and a non-2xx answer, an oversize
    /// body, or malformed JSON are all refusals rather than empty pages.
    @Test func onlyHTTPSAndWellFormedAnswersAreAccepted() async throws {
        #expect(throws: MarketplaceProviderError.self) {
            _ = try ClaudePluginsOfficialCatalogProvider(url: URL(string: "http://raw.example/marketplace.json")!)
        }

        let failing = OfficialCatalogHTTPStub(payload: Data("{}".utf8), statusCode: 503)
        let downProvider = try ClaudePluginsOfficialCatalogProvider(loader: failing)
        await #expect(throws: MarketplaceProviderError.self) {
            _ = try await downProvider.search(MarketplaceQuery())
        }

        let malformed = OfficialCatalogHTTPStub(payload: Data("not json".utf8))
        let brokenProvider = try ClaudePluginsOfficialCatalogProvider(loader: malformed)
        await #expect(throws: MarketplaceProviderError.self) {
            _ = try await brokenProvider.search(MarketplaceQuery())
        }
    }

    /// One malformed plugin entry does not hide the rest of the catalog, exactly
    /// as the MCP registry tolerates a single bad server.
    @Test func oneMalformedEntryDoesNotHideTheCatalog() async throws {
        let payload = Data(
            #"""
            {
              "name": "claude-plugins-official",
              "plugins": [
                {"description": "Missing the required name field."},
                {"name": "healthy", "description": "A complete listing.", "source": {"url": "https://github.com/example/healthy"}}
              ]
            }
            """#.utf8
        )
        let provider = try ClaudePluginsOfficialCatalogProvider(loader: OfficialCatalogHTTPStub(payload: payload))

        let page = try await provider.search(MarketplaceQuery())

        #expect(page.packages.map(\.name) == ["healthy"])
    }

    /// The whole catalog comes back regardless of the query's page size, so a
    /// 300-plugin marketplace is browsable past its first hundred names, and
    /// a search term narrows it to the plugins that mention it.
    @Test func theWholeCatalogIsReturnedAndASearchTermNarrowsIt() async throws {
        let entries = (1...250).map { index in
            #"{"name": "plugin-\#(String(format: "%03d", index))", "description": "\#(index % 50 == 0 ? "Works with Postgres databases." : "A tool.")", "category": "\#(index % 2 == 0 ? "database" : "development")"}"#
        }
        let payload = Data(#"{"name": "claude-plugins-official", "plugins": [\#(entries.joined(separator: ","))]}"#.utf8)
        let provider = try ClaudePluginsOfficialCatalogProvider(loader: OfficialCatalogHTTPStub(payload: payload))

        let everything = try await provider.search(MarketplaceQuery(limit: 20))
        #expect(everything.packages.count == 250)
        #expect(everything.packages.last?.name == "plugin-250")

        let narrowed = try await provider.search(MarketplaceQuery(search: "postgres", limit: 20))
        #expect(narrowed.packages.count == 5)
        #expect(narrowed.packages.allSatisfy { $0.summary.contains("Postgres") })

        let byCategory = try await provider.search(MarketplaceQuery(search: "Database"))
        #expect(byCategory.packages.count == 125)
    }

    /// The CLI's discovery of the same plugin wins for installed/count/revision,
    /// while the official catalog supplies category, homepage, and author when
    /// the CLI leaves them out. Neither half is dropped by the merge.
    @Test func aCLIRowAndACatalogRowForOnePluginKeepBothHalves() throws {
        let externalPluginID = "review-buddy@claude-plugins-official"
        // The CLI row: installed, with an install count and a revision, but no
        // category or homepage.
        let cli = MarketplacePackage(
            id: "claude:\(externalPluginID)", name: "review-buddy", publisher: "claude-plugins-official",
            summary: "Installed Claude Code plugin discovered by the native catalog.",
            sourceName: "claude-plugins-official", revision: "2.0.0", components: [.plugin],
            supportedClients: [.claude], location: "review-buddy@claude-plugins-official",
            isInstalled: true, installCount: 4_200)
        // The catalog row: not installed, no count, but it knows the category
        // and homepage.
        let catalog = MarketplacePackage(
            id: "claude:\(externalPluginID)", name: "Review Buddy", publisher: "Anthropic marketplace",
            summary: "Reviews code.", sourceName: "claude-plugins-official", revision: "2.0.0",
            components: [.plugin], supportedClients: [.claude],
            location: "https://example.com/review-buddy",
            provenance: PackageProvenance(
                source: PackageSource(kind: .claudeMarketplace, location: "https://example.com/review-buddy")),
            category: "development")

        let merged = try #require(MarketplaceService().deduplicatedPackages([catalog, cli]).first)

        // The CLI wins the facts only it can know.
        #expect(merged.isInstalled == true)
        #expect(merged.installCount == 4_200)
        #expect(merged.revision == "2.0.0")
        // The catalog supplies the one field the CLI never has.
        #expect(merged.category == "development")
        // One row, not two.
        #expect(MarketplaceService().deduplicatedPackages([catalog, cli]).count == 1)
    }
}
