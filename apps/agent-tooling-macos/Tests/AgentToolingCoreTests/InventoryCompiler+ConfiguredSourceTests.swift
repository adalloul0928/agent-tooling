import AgentToolingTestSupport
import Foundation
import Testing

@testable import AgentToolingCore

/// Where a connection set up by hand comes from, once its app's own tool
/// also lists it. The listing is the same definition, so it keeps one
/// source, and that source stays the configuration that defines it, with the
/// listing's details; a plugin's server beside one set up by hand is two
/// definitions, and keeps both sources. Checkup counts a server set up by
/// hand in two apps from the configuration source, so a listing that
/// replaced it would hide that.
@Suite("Inventory · a configured server's source")
struct InventoryCompilerConfiguredSourceTests {
    /// Codex lists Playwright, which its config.toml defines: one definition,
    /// still from its configuration, with what the listing knows of it.
    @Test func codexsOwnListingKeepsTheConfigurationAsTheSource() async throws {
        let home = try FixtureHome("configured-source-codex")
        defer { home.remove() }
        try Self.setUpPlaywrightByHand(in: home)

        let codex = try await Self.scanCodex(in: home)

        let playwright = try #require(codex.mcpMetadata["playwright"])
        #expect(playwright.allSources == ["Codex CLI configuration"])
        #expect(playwright.transport == "stdio")
        #expect(playwright.authentication == "Unsupported", "the listing's details are kept")
        #expect(codex.discoveredMCPServers.contains("playwright"))
    }

    /// A plugin brings a server by the name one was set up with by hand in
    /// Claude Code: both definitions stay, the plugin's first.
    @Test func aPluginsServerBesideOneSetUpByHandKeepsBothSources() async throws {
        let home = try FixtureHome("configured-source-plugin")
        defer { home.remove() }
        try home.plant(".claude.json", #"{"mcpServers":{"x":{"type":"http","url":"https://x.example/mcp"}}}"# + "\n")

        let claude = try await Self.scanClaude(
            in: home,
            plugins:
                #"[{"id":"x@market","version":"1.0.0","scope":"user","enabled":true,"mcpServers":{"x":{"type":"http","url":"https://x.example/mcp"}}}]"#
        )

        let server = try #require(claude.mcpMetadata["x"])
        #expect(server.allSources == ["x@market", "Claude Code configuration"])
    }

    /// Playwright set up by hand in Codex, which also lists it, and in Claude
    /// Code: Checkup says it is configured separately in two apps.
    @Test func checkupCountsAServerSetUpByHandInCodexAndClaudeCode() async throws {
        let home = try FixtureHome("configured-source-audit")
        defer { home.remove() }
        try Self.setUpPlaywrightByHand(in: home)
        try home.plant(
            ".claude.json", #"{"mcpServers":{"playwright":{"type":"stdio","command":"npx","args":["@playwright/mcp@latest"]}}}"# + "\n")

        let observations = [try await Self.scanCodex(in: home), try await Self.scanClaude(in: home)]
        let report = SetupAuditor(homeURL: home.url, searchPath: [])
            .audit(observations: observations, managed: [.codex, .claude], library: .init(managedSkillNames: []))

        let repeated = report.findings.filter { $0.kind == .mcpServerRepeatedAcrossClients }
        #expect(repeated.map(\.subject) == ["playwright"])
        #expect(Set(repeated.flatMap(\.evidence)) == [ClientKind.codex.rawValue, ClientKind.claude.rawValue])
    }

    // MARK: - The fixture

    /// Playwright in Codex's config.toml, as a person adds it.
    private static func setUpPlaywrightByHand(in home: FixtureHome) throws {
        try home.plant(".codex/config.toml", "[mcp_servers.playwright]\ncommand = \"npx\"\nargs = [\"@playwright/mcp@latest\"]\n")
    }

    /// Codex's read of `home`, its tool found only in the fixture and
    /// listing Playwright among its servers, as the sample world's does.
    private static func scanCodex(in home: FixtureHome) async throws -> TargetObservation {
        try home.installTool(.codex)
        let replies: [[String]: ScriptedCommandRunner.Reply] = [
            ["--version"]: .standardOutput("codex-cli 0.164.0\n"),
            ["plugin", "list", "--json"]: .standardOutput(#"{"installed":[],"available":[]}"# + "\n"),
            ["mcp", "list", "--json"]: .standardOutput(
                #"[{"name":"playwright","enabled":true,"transport":{"type":"stdio","command":"npx","args":["@playwright/mcp@latest"]},"auth_status":"unsupported"}]"#
                    + "\n"),
        ]
        return await CodexAdapter(locate: { client, _ in home.locate(client) })
            .scan(homeURL: home.url, runner: ScriptedCommandRunner(byTool: [ClientExecutableLocator.executableName(for: .codex): replies]))
    }

    /// Claude Code's read of `home`, its tool found only in the fixture and
    /// listing `plugins` as its plugins.
    private static func scanClaude(in home: FixtureHome, plugins: String = "[]") async throws -> TargetObservation {
        try home.installTool(.claude)
        let replies: [[String]: ScriptedCommandRunner.Reply] = [
            ["--version"]: .standardOutput("2.1.304 (Claude Code)\n"),
            ["plugin", "list", "--json"]: .standardOutput(plugins + "\n"),
        ]
        return await ClaudeCodeAdapter(locate: { client, _ in home.locate(client) })
            .scan(homeURL: home.url, runner: ScriptedCommandRunner(byTool: [ClientExecutableLocator.executableName(for: .claude): replies]))
    }
}
