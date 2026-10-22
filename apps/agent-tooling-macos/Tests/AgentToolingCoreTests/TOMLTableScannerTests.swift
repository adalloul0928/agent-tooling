import Foundation
import Testing

@testable import AgentToolingCore

@Suite("Conservative TOML fallback")
struct TOMLTableScannerTests {
    @Test func scansVersionedCodexFixtureWithoutReadingValues() throws {
        let testsRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let fixture = testsRoot.appending(path: "Fixtures/ClientConfigs/codex-config-v1.toml")
        let document = try String(contentsOf: fixture, encoding: .utf8)

        #expect(
            TOMLTableScanner.tablePaths(in: document) == [
                ["mcp_servers", "company.docs"],
                ["mcp_servers", "company.docs", "headers"],
                ["plugins", "vendor.tool"],
            ]
        )
    }

    @Test func scansQuotedTablesAndIgnoresValuesArraysAndComments() {
        let paths = TOMLTableScanner.tablePaths(
            in: """
                title = "[mcp_servers.not-a-table]"
                [mcp_servers."company.docs"] # reviewed endpoint
                [[plugins.array-is-not-a-plugin]]
                [mcp_servers."company.docs".headers]
                [plugins.'vendor.tool']
                [unterminated
                """
        )

        #expect(
            paths == [
                ["mcp_servers", "company.docs"],
                ["mcp_servers", "company.docs", "headers"],
                ["plugins", "vendor.tool"],
            ]
        )
    }

    @Test func rejectsEmptyComponentsAndUnclosedQuotes() {
        let paths = TOMLTableScanner.tablePaths(
            in: """
                [mcp_servers..bad]
                [mcp_servers."unfinished]
                [mcp_servers.good]
                """
        )

        #expect(paths == [["mcp_servers", "good"]])
    }
}
