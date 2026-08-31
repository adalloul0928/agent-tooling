import Foundation
import Testing

@testable import AgentToolingCore

@Suite("External app routes")
struct ExternalAppRouteTests {
    @Test("Parses navigation-only sections")
    func parsesSections() throws {
        #expect(ExternalAppRoute(url: try #require(URL(string: "agent-tooling://overview"))) == .section(.overview))
        #expect(ExternalAppRoute(url: try #require(URL(string: "agent-tooling://insights"))) == .section(.insights))
        #expect(ExternalAppRoute(url: try #require(URL(string: "agent-tooling://mcp-servers"))) == .section(.mcpServers))
        #expect(ExternalAppRoute(url: try #require(URL(string: "agent-tooling://sync"))) == .section(.sync))
    }

    @Test("Parses opaque skill creation request identifiers")
    func parsesRequest() throws {
        let id = UUID()
        #expect(
            ExternalAppRoute(url: try #require(URL(string: "agent-tooling://requests/\(id.uuidString)")))
                == .skillCreationRequest(id)
        )
    }

    @Test("Parses normalized skill identifiers")
    func parsesSkill() throws {
        #expect(
            ExternalAppRoute(url: try #require(URL(string: "agent-tooling://skills/release-readiness")))
                == .skill("release-readiness")
        )
    }

    @Test(
        "Rejects malformed or mutation-shaped routes",
        arguments: [
            "https://example.com/skills/demo",
            "agent-tooling://requests/not-a-uuid",
            "agent-tooling://skills/Not%20Normalized",
            "agent-tooling://skills/demo/delete",
            "agent-tooling://sync?apply=true",
            "agent-tooling://user:password@overview",
            "agent-tooling://unknown",
        ])
    func rejectsUnsafeRoutes(rawValue: String) throws {
        #expect(ExternalAppRoute(url: try #require(URL(string: rawValue))) == nil)
    }
}
