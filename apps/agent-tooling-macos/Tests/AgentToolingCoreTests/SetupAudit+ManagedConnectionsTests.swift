import AgentToolingTestSupport
import Foundation
import Testing

@testable import AgentToolingCore

/// Checkup on Agent Tooling's own connection, once it is in two apps: one
/// definition placed in each, never "configured separately in 2 apps", and,
/// with its helper where the apps start it, nothing to look at at all.
@Suite("Setup audit · managed connections")
struct SetupAuditManagedConnectionsTests {
    @Test func aConnectionTheLibraryManagesInTwoAppsIsNotReportedAsSeparate() throws {
        let home = try FixtureHome("audit-managed-connections")
        defer { home.remove() }
        let helper = home.appending("Applications/Agent Tooling.app/Contents/Helpers/agent-tooling-mcp")
        try write(helper, "#!/bin/sh\nexit 0\n")
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: helper.path(percentEncoded: false))
        let path = helper.path(percentEncoded: false)
        try home.plant(".claude.json", #"{"mcpServers":{"agent-tooling":{"type":"stdio","command":"\#(path)","args":[]}}}"#)
        try home.plant(".codex/config.toml", "[mcp_servers.agent-tooling]\ncommand = \"\(path)\"\nargs = []\n")
        let observations = [
            Self.observation(.claudeCode, file: home.appending(".claude.json")),
            Self.observation(.codexCLI, file: home.appending(".codex/config.toml")),
        ]
        let auditor = SetupAuditor(homeURL: home.url, searchPath: [])

        let unmanaged = auditor.audit(observations: observations, managed: [.codex, .claude], library: .init(managedSkillNames: []))
        let managed = auditor.audit(
            observations: observations, managed: [.codex, .claude],
            library: .init(managedSkillNames: [], managedConnectionNames: [AgentToolingConnection.declaredName]))

        #expect(unmanaged.findings.map(\.kind) == [.mcpServerRepeatedAcrossClients])
        #expect(unmanaged.findings.first?.subject == "agent-tooling")
        #expect(managed.findings.isEmpty, "\(managed.findings.map(\.title))")
    }

    /// Each app's count of connections leaves Agent Tooling's own out where
    /// this Mac set it up (D10: how the app reaches the library, not one of
    /// its holdings), and keeps one under that name anywhere else, which is
    /// somebody's own.
    @Test func anAppsConnectionsLeaveOutTheOneThisMacSetUp() throws {
        let home = try FixtureHome("audit-held-connections")
        defer { home.remove() }
        var claude = Self.observation(.claudeCode, file: home.appending(".claude.json"))
        claude.discoveredMCPServers.append("context7")
        let codex = Self.observation(.codexCLI, file: home.appending(".codex/config.toml"))
        let auditor = SetupAuditor(homeURL: home.url, searchPath: [])

        let report = auditor.audit(
            observations: [claude, codex], managed: [.codex, .claude],
            library: .init(
                managedSkillNames: [], managedConnectionNames: [AgentToolingConnection.declaredName], ownConnectionApps: [.claude]))

        #expect(report.counts[.claude]?.mcpServers == 1, "context7 alone")
        #expect(report.counts[.codex]?.mcpServers == 1, "not set up here by this Mac: somebody's own")
    }

    private static func observation(_ surface: TargetSurface, file: URL) -> TargetObservation {
        TargetObservation(
            surface: surface, installed: true, version: "1.0.0", configurationPaths: [file.path(percentEncoded: false)],
            discoveredMCPServers: ["agent-tooling"],
            mcpMetadata: [
                "agent-tooling": .init(transport: "stdio", authentication: "Not inferred", source: "\(surface.displayName) configuration")
            ],
            capabilities: .init(
                supportsPluginInstall: false, supportsProjectScope: false, supportsLocalMarketplace: false,
                supportsMCPAuthentication: false, supportsConnectorDiscovery: false, requiresNewSession: false,
                requiresRestart: false, supportsMachineReadableOutput: false))
    }
}
