import Foundation
import Testing

@testable import AgentToolingCore

/// A loader that records whether it was asked anything, for proving the
/// provider's deliberate silences never open a socket.
private actor SkillsShHTTPStub: HTTPDataLoading {
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

struct SkillsShProviderTests {
    @Test func searchListingsBecomeSkillPackagesWithPublishedInstallCounts() async throws {
        let payload = Data(
            #"""
            {
              "query": "react performance",
              "skills": [
                {
                  "id": "vercel-labs/agent-skills/react-best-practices",
                  "skillId": "react-best-practices",
                  "name": "react-best-practices",
                  "installs": 217637,
                  "source": "vercel-labs/agent-skills"
                },
                {
                  "id": "../escape/attempt",
                  "skillId": "escape",
                  "name": "escape",
                  "installs": 5,
                  "source": "owner/repo"
                }
              ]
            }
            """#.utf8
        )
        let stub = SkillsShHTTPStub(payload: payload)
        let provider = try SkillsShRegistryProvider(loader: stub)

        let page = try await provider.search(MarketplaceQuery(search: "react performance"))

        #expect(page.packages.count == 1)
        let package = try #require(page.packages.first)
        #expect(package.id == "skills-sh:vercel-labs/agent-skills/react-best-practices")
        #expect(package.name == "react-best-practices")
        #expect(package.publisher == "vercel-labs")
        #expect(package.components == [.skill])
        #expect(package.installCount == 217_637)
        #expect(package.location == "https://skills.sh/vercel-labs/agent-skills/react-best-practices")
        #expect(package.provenance?.source.kind == .skillsShRegistry)
        #expect(package.provenance?.source.location == "https://github.com/vercel-labs/agent-skills")
        #expect(package.catalogKind == .skillsShRegistry)
        #expect(package.nativeInstalls.isEmpty)
        let url = try #require(await stub.lastURL())
        let components = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
        #expect(components.path == "/api/search")
        #expect(components.queryItems?.contains(URLQueryItem(name: "q", value: "react performance")) == true)
    }

    /// The registry answers search terms only, and refuses anything under two
    /// characters. Both silences are answered locally: no request is made.
    @Test func unqueriedAndTooShortSearchesAreAnsweredWithSilenceNotARequest() async throws {
        let stub = SkillsShHTTPStub(payload: Data("{}".utf8))
        let provider = try SkillsShRegistryProvider(loader: stub)

        let unqueried = try await provider.search(MarketplaceQuery())
        let tooShort = try await provider.search(MarketplaceQuery(search: " a "))

        #expect(unqueried.packages.isEmpty)
        #expect(tooShort.packages.isEmpty)
        #expect(await stub.lastURL() == nil)
    }

    @Test func theRegistryIsOnlyReachedOverHTTPSAndBadAnswersAreRefusals() async throws {
        #expect(throws: MarketplaceProviderError.self) {
            _ = try SkillsShRegistryProvider(baseURL: URL(string: "http://skills.example")!)
        }

        let failing = SkillsShHTTPStub(payload: Data("{}".utf8), statusCode: 503)
        let provider = try SkillsShRegistryProvider(loader: failing)
        await #expect(throws: MarketplaceProviderError.self) {
            _ = try await provider.search(MarketplaceQuery(search: "react"))
        }

        let malformed = SkillsShHTTPStub(payload: Data("not json".utf8))
        let broken = try SkillsShRegistryProvider(loader: malformed)
        await #expect(throws: MarketplaceProviderError.self) {
            _ = try await broken.search(MarketplaceQuery(search: "react"))
        }
    }

    @Test func theInstallCommandIsTheSkillsCLIDocumentedForm() {
        #expect(
            SkillsShRegistryProvider.installCommand(
                source: "vercel-labs/agent-skills", skillID: "react-best-practices")
                == "npx skills add vercel-labs/agent-skills@react-best-practices")
    }

    /// "Most installed" sorts by the catalog's published count, keeps ties and
    /// uncounted listings in stable name order, and puts uncounted rows last.
    @Test func installSortOrdersByPublishedCountAndUncountedListingsSortLast() {
        func listing(_ name: String, installs: Int?) -> MarketplacePackage {
            MarketplacePackage(
                id: "skills-sh:owner/repo/\(name)", name: name, publisher: "owner", summary: "s",
                sourceName: "skills.sh", components: [.skill], supportedClients: [.claude],
                location: "https://skills.sh/owner/repo/\(name)", installCount: installs)
        }
        let packages = [
            listing("beta", installs: 10), listing("alpha", installs: 10),
            listing("uncounted", installs: nil), listing("popular", installs: 5_000),
        ]

        let sorted = MarketplaceSorting.sorted(packages, by: .installs)

        #expect(sorted.map(\.name) == ["popular", "alpha", "beta", "uncounted"])
    }
}
