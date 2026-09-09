import Foundation
import Testing

@testable import AgentToolingCore

private struct NativeCatalogFixtureRunner: CommandRunning {
    let responses: [String: CommandOutput]

    func run(executable: String, arguments: [String], currentDirectory _: URL?) async throws -> CommandOutput {
        responses[([executable] + arguments).joined(separator: " ")]
            ?? .init(status: 127, standardOutput: "", standardError: "unavailable")
    }
}

struct NativeCatalogCachePreservationTests {
    @Test func failedAndExcludedClientsRetainExactAndMalformedCachedRows() async {
        let cached = [
            Self.package("codex:old@market", client: .codex),
            Self.package("codex:contains/path", client: .codex),
            Self.package("claude:old@market", client: .claude),
            Self.package("claude:", client: .claude),
        ]
        let discovery = await MarketplaceService.discoverNativeCatalogs(
            runner: NativeCatalogFixtureRunner(responses: [:]), clients: [.codex])

        #expect(discovery.outcomes[.codex] == .incomplete)
        #expect(discovery.outcomes[.claude] == .excluded)
        #expect(Set(discovery.retainedCachedPackages(from: cached).map(\.id)) == Set(cached.map(\.id)))
    }

    @Test func successfulKnownEmptyResponseAuthoritativelyClearsOnlyThatClient() async {
        let cached = [
            Self.package("codex:old@market", client: .codex),
            Self.package("claude:old@market", client: .claude),
        ]
        let discovery = await MarketplaceService.discoverNativeCatalogs(
            runner: NativeCatalogFixtureRunner(responses: [
                "codex plugin list --available --json": .init(
                    status: 0,
                    standardOutput: "{\"installed\":[],\"available\":[]}",
                    standardError: ""
                ),
            ]),
            clients: [.codex]
        )

        #expect(discovery.outcomes[.codex] == .complete)
        #expect(discovery.packages.isEmpty)
        #expect(discovery.retainedCachedPackages(from: cached).map(\.id) == ["claude:old@market"])
    }

    @Test func successfulDiscoveryOverlaysTheSameExactCachedIdentity() async throws {
        var old = Self.package("codex:reviewer@market", client: .codex)
        old.name = "Old cached name"
        let discovery = await MarketplaceService.discoverNativeCatalogs(
            runner: NativeCatalogFixtureRunner(responses: [
                "codex plugin list --available --json": .init(
                    status: 0,
                    standardOutput: """
                    {"installed":[],"available":[{"pluginId":"reviewer@market","name":"Current name"}]}
                    """,
                    standardError: ""
                ),
            ]),
            clients: [.codex]
        )

        let current = try #require(discovery.packages.first)
        #expect(current.id == old.id)
        #expect(current.name == "Current name")
        #expect(discovery.retainedCachedPackages(from: [old]).isEmpty)
    }

    @Test func malformedAndPartiallyFailedResponsesRemainIncompleteAndPreserveCache() async {
        let old = Self.package("codex:old@market", client: .codex)
        let malformed = await MarketplaceService.discoverNativeCatalogs(
            runner: NativeCatalogFixtureRunner(responses: [
                "codex plugin list --available --json": .init(
                    status: 0, standardOutput: "{}", standardError: ""),
            ]),
            clients: [.codex]
        )
        #expect(malformed.outcomes[.codex] == .incomplete)
        #expect(malformed.retainedCachedPackages(from: [old]) == [old])

        let partial = await MarketplaceService.discoverNativeCatalogs(
            runner: NativeCatalogFixtureRunner(responses: [
                "codex plugin list --available --json": .init(
                    status: 0, standardOutput: "[output truncated", standardError: ""),
                "codex plugin list --json": .init(
                    status: 0,
                    standardOutput: "{\"installed\":[{\"pluginId\":\"old@market\"}]}",
                    standardError: ""
                ),
                "codex plugin list --marketplace market --available --json": .init(
                    status: 1, standardOutput: "", standardError: "page failed"),
            ]),
            clients: [.codex]
        )
        #expect(partial.outcomes[.codex] == .incomplete)
        #expect(partial.retainedCachedPackages(from: [old]) == [old])
    }

    @Test func validJSONWithUnknownClaudeShapeCannotClearCache() async {
        let old = Self.package("claude:old@market", client: .claude)
        for body in ["[1]", "[{\"error\":\"offline\"}]", "{\"plugins\":null}", "{}",
                     "[{\"name\":\"unparsed\"}]", "{\"plugins\":[],\"error\":\"offline\"}"] {
            let discovery = await MarketplaceService.discoverNativeCatalogs(
                runner: NativeCatalogFixtureRunner(responses: [
                    "claude plugin list --available --json": .init(
                        status: 0, standardOutput: body, standardError: ""),
                ]),
                clients: [.claude]
            )
            #expect(discovery.outcomes[.claude] == .incomplete)
            #expect(discovery.retainedCachedPackages(from: [old]) == [old])
        }
    }

    @Test func completeClaudeEmptyAndKnownEntriesRefreshTheCache() async throws {
        let old = Self.package("claude:old@market", client: .claude)
        for body in ["[]", "{\"plugins\":[]}"] {
            let discovery = await MarketplaceService.discoverNativeCatalogs(
                runner: NativeCatalogFixtureRunner(responses: [
                    "claude plugin list --available --json": .init(status: 0, standardOutput: body, standardError: ""),
                ]), clients: [.claude])
            #expect(discovery.outcomes[.claude] == .complete)
            #expect(discovery.retainedCachedPackages(from: [old]).isEmpty)
        }
        let discovery = await MarketplaceService.discoverNativeCatalogs(
            runner: NativeCatalogFixtureRunner(responses: [
                "claude plugin list --available --json": .init(status: 0,
                    standardOutput: "[{\"name\":\"browser\",\"installed\":true}]", standardError: ""),
            ]), clients: [.claude])
        #expect(discovery.outcomes[.claude] == .complete)
        #expect(discovery.packages.map(\.id) == ["claude:browser"])
        #expect(discovery.retainedCachedPackages(from: [old]).isEmpty)
    }

    @Test func installedOnlyAndSuccessfulFallbackPagesCannotClearTheGlobalCodexCache() async throws {
        let old = Self.package("codex:uninstalled-marketplace", client: .codex)
        for installed in ["[]", "[{\"pluginId\":\"new@market\"}]"] {
            let discovery = await MarketplaceService.discoverNativeCatalogs(
                runner: NativeCatalogFixtureRunner(responses: [
                    "codex plugin list --available --json": .init(status: 0,
                        standardOutput: "[output truncated", standardError: ""),
                    "codex plugin list --json": .init(status: 0,
                        standardOutput: "{\"installed\":\(installed)}", standardError: ""),
                    "codex plugin list --marketplace market --available --json": .init(status: 0,
                        standardOutput: "{\"installed\":[],\"available\":[{\"pluginId\":\"new@market\"}]}", standardError: ""),
                ]), clients: [.codex])
            #expect(discovery.outcomes[.codex] == .incomplete)
            #expect(discovery.retainedCachedPackages(from: [old]) == [old])
            #expect(discovery.packages.map(\.id) == (installed == "[]" ? [] : ["codex:new@market"]))
        }
        let installedOnly = await MarketplaceService.discoverNativeCatalogs(
            runner: NativeCatalogFixtureRunner(responses: [
                "codex plugin list --available --json": .init(status: 0,
                    standardOutput: "{\"installed\":[{\"pluginId\":\"new@market\"}]}", standardError: ""),
            ]), clients: [.codex])
        #expect(installedOnly.outcomes[.codex] == .incomplete)
        #expect(installedOnly.packages.map(\.id) == ["codex:new@market"])
        #expect(installedOnly.retainedCachedPackages(from: [old]) == [old])
    }

    @Test func boundedClaudeTraversalCannotTurnSkippedRowsIntoAuthoritativeDeletion() async throws {
        let old = Self.package("claude:old@market", client: .claude)
        var nested: Any = "metadata"
        for _ in 0..<40 { nested = [nested] }
        let bytes = try JSONSerialization.data(withJSONObject: [["name": "browser", "installed": true, "extra": nested]])
        let discovery = await MarketplaceService.discoverNativeCatalogs(
            runner: NativeCatalogFixtureRunner(responses: [
                "claude plugin list --available --json": .init(status: 0,
                    standardOutput: String(decoding: bytes, as: UTF8.self), standardError: ""),
            ]), clients: [.claude])
        #expect(discovery.outcomes[.claude] == .incomplete)
        #expect(discovery.retainedCachedPackages(from: [old]) == [old])
    }

    private static func package(_ id: String, client: ClientKind) -> MarketplacePackage {
        .init(
            id: id,
            name: "Cached",
            publisher: "Cached publisher",
            summary: "Cached native row",
            sourceName: "Cached catalog",
            components: [.plugin],
            supportedClients: [client],
            location: "cached",
            isInstalled: true,
            ownership: .nativeClient
        )
    }
}
