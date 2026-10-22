import Foundation
import Testing

@testable import AgentToolingCore

/// `agent-tooling://setup`: the setup stage again, at Your apps, on a Mac that
/// already has its library. Exactly that link and nothing more, and never a
/// section, because sections are what the MCP server's `open_review_screen`
/// offers and builds links to, from `ExternalAppSection.allCases`.
@Suite("External app routes · setup")
struct ExternalAppRouteSetupTests {
    @Test func theSetupLinkParses() throws {
        #expect(ExternalAppRoute(url: try #require(URL(string: "agent-tooling://setup"))) == .setup)
        // A host is not case-sensitive, as every other route's is not.
        #expect(ExternalAppRoute(url: try #require(URL(string: "agent-tooling://Setup"))) == .setup)
    }

    @Test(
        "Anything more than the bare link is refused",
        arguments: [
            "agent-tooling://setup/x",
            "agent-tooling://setup/apps",
            "agent-tooling://setup?y",
            "agent-tooling://setup?step=apps",
            "agent-tooling://user@setup",
            "agent-tooling://user:password@setup",
            "agent-tooling://setup:8080",
            "agent-tooling://setup#apps",
            "https://setup",
            "agent-tooling://set-up",
        ])
    func anythingMoreIsRefused(rawValue: String) throws {
        #expect(ExternalAppRoute(url: try #require(URL(string: rawValue))) == nil)
    }

    @Test func theSetupLinkIsNoSection() {
        #expect(ExternalAppSection(rawValue: "setup") == nil)
        #expect(!ExternalAppSection.allCases.map(\.rawValue).contains("setup"))
        for section in ExternalAppSection.allCases {
            let url = URL(string: "agent-tooling://\(section.rawValue)")
            #expect(url.flatMap(ExternalAppRoute.init(url:)) != .setup, "\(section.rawValue)")
        }
    }
}
