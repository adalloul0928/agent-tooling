import Foundation
import Testing

@testable import AgentToolingCore

/// The deterministic audit: every finding is a fact planted in a fixture home,
/// found the same way every time, with the evidence that proves it.
@Suite("Setup audit")
struct SetupAuditTests {
    /// A home with one of everything wrong in it.
    private struct Home {
        let root: URL
        let claudeSkills: URL
        let pluginCache: URL

        init() throws {
            root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
                .appending(path: "SetupAuditTests-\(UUID().uuidString)", directoryHint: .isDirectory)
            claudeSkills = root.appending(path: ".claude/skills", directoryHint: .isDirectory)
            pluginCache = root.appending(path: ".claude/plugins/cache/aim/Example-all", directoryHint: .isDirectory)
            let fm = FileManager.default
            try fm.createDirectory(at: claudeSkills, withIntermediateDirectories: true)
            // A real skill, a broken link, a folder with no definition, and a
            // second copy of the real skill inside a plugin.
            try Self.skill(named: "docx", in: claudeSkills)
            try fm.createSymbolicLink(
                at: claudeSkills.appending(path: "gone"), withDestinationURL: root.appending(path: "code/removed/skills/gone"))
            try fm.createDirectory(at: claudeSkills.appending(path: "empty-folder"), withIntermediateDirectories: true)
            let current = pluginCache.appending(path: "1.0.200", directoryHint: .isDirectory)
            try Self.skill(named: "docx", in: current.appending(path: "skills", directoryHint: .isDirectory))
            try fm.createDirectory(at: pluginCache.appending(path: "1.0.100"), withIntermediateDirectories: true)
            try fm.createDirectory(at: pluginCache.appending(path: "1.0.150"), withIntermediateDirectories: true)
            // Claude's settings: a server whose command does not exist, one that does.
            let bin = root.appending(path: ".local/bin", directoryHint: .isDirectory)
            try fm.createDirectory(at: bin, withIntermediateDirectories: true)
            let present = bin.appending(path: "present-mcp")
            try "#!/bin/sh\n".write(to: present, atomically: true, encoding: .utf8)
            try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: present.path(percentEncoded: false))
            try #"{"mcpServers":{"present":{"command":"present-mcp"},"vanished":{"command":"vanished-mcp"}}}"#
                .write(to: root.appending(path: ".claude.json"), atomically: true, encoding: .utf8)
            // Codex: the same "present" server configured by hand in TOML.
            try fm.createDirectory(at: root.appending(path: ".codex"), withIntermediateDirectories: true)
            try "[mcp_servers.present]\n  command = \"present-mcp\"\n[model]\nx = 1\n"
                .write(to: root.appending(path: ".codex/config.toml"), atomically: true, encoding: .utf8)
        }

        static let capabilities = TargetCapabilities(
            supportsPluginInstall: true, supportsProjectScope: true, supportsLocalMarketplace: false,
            supportsMCPAuthentication: false, supportsConnectorDiscovery: false, requiresNewSession: false,
            requiresRestart: false, supportsMachineReadableOutput: true)

        static func skill(named name: String, in root: URL) throws {
            let folder = root.appending(path: name, directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try "---\nname: \(name)\ndescription: d\n---\n".write(to: folder.appending(path: "SKILL.md"), atomically: true, encoding: .utf8)
        }

        func remove() { try? FileManager.default.removeItem(at: root) }

        /// A fixture path in the report's normal form.
        func path(_ relative: String) -> String {
            var p = root.appending(path: relative).standardizedFileURL.path(percentEncoded: false)
            if p.hasPrefix("/private/") { p = String(p.dropFirst("/private".count)) }
            if p.hasSuffix("/") { p.removeLast() }
            return p
        }

        /// What the device check would have said about this home.
        func observations() -> [TargetObservation] {
            let currentPlugin = pluginCache.appending(path: "1.0.200").path(percentEncoded: false)
            let missingPlugin = root.appending(path: ".claude/plugins/cache/aim/Vanished-all/1.0.1").path(percentEncoded: false)
            let claude = TargetObservation(
                surface: .claudeCode, installed: true, commandAvailable: true, version: "2.1.285",
                configurationPaths: [root.appending(path: ".claude.json").path(percentEncoded: false)],
                discoveredSkills: ["docx", "Example-all:docx"],
                discoveredPlugins: ["Example-all@aim", "Vanished-all@aim"],
                discoveredMCPServers: ["present", "vanished"],
                skillMetadata: [
                    "docx": .init(path: claudeSkills.appending(path: "docx").path(percentEncoded: false), source: "Standalone Claude Code skill"),
                    "Example-all:docx": .init(
                        path: pluginCache.appending(path: "1.0.200/skills/docx").path(percentEncoded: false), source: "Example-all@aim",
                        providerPluginID: "Example-all@aim"),
                ],
                pluginMetadata: [
                    "Example-all@aim": .init(name: "Example All", source: currentPlugin, scope: "User", enabled: true, skillIDs: ["Example-all:docx"]),
                    "Vanished-all@aim": .init(name: "Vanished All", source: missingPlugin, scope: "User", enabled: true),
                ],
                mcpMetadata: [
                    "present": .init(transport: "stdio", authentication: "Not inferred", source: "Claude Code configuration"),
                    "vanished": .init(transport: "stdio", authentication: "Not inferred", source: "Claude Code configuration"),
                ],
                capabilities: Self.capabilities, notes: [])
            let codex = TargetObservation(
                surface: .codexCLI, installed: true, commandAvailable: false, version: nil,
                configurationPaths: [root.appending(path: ".codex/config.toml").path(percentEncoded: false)],
                discoveredSkills: [], discoveredPlugins: [], discoveredMCPServers: ["present"],
                skillMetadata: [:], pluginMetadata: [:],
                mcpMetadata: ["present": .init(transport: "stdio", authentication: "Not inferred", source: "Codex configuration")],
                capabilities: Self.capabilities, notes: ["The codex CLI was not available in any known install location; configuration was scanned from disk only."])
            return [claude, codex]
        }
    }

    private func audit(_ home: Home, managed: Set<String> = []) -> SetupAuditReport {
        SetupAuditor(homeURL: home.root, searchPath: [home.root.appending(path: ".local/bin")])
            .audit(observations: home.observations(), managed: [.claude, .codex, .kiro], library: .init(managedSkillNames: managed))
    }

    @Test func everyPlantedProblemIsFoundOnceWithItsEvidence() throws {
        let home = try Home()
        defer { home.remove() }
        let report = audit(home)
        func one(_ kind: SetupFinding.Kind, _ subject: String) throws -> SetupFinding {
            let matches = report.findings.filter { $0.kind == kind && $0.subject == subject }
            #expect(matches.count == 1, "\(kind) \(subject): \(matches.count) findings")
            return try #require(matches.first)
        }

        let link = try one(.brokenSkillLink, "gone")
        #expect(link.client == .claude)
        #expect(link.evidence.first == "~/.claude/skills/gone", "paths are shown relative to home")
        #expect(link.actions == [.removeBrokenLink(path: home.path(".claude/skills/gone"), client: .claude)])

        _ = try one(.skillWithoutDefinition, "empty-folder")

        let duplicate = try one(.duplicateSkillInClient, "docx")
        #expect(duplicate.severity == .medium, "two different copies, not one linked twice")
        #expect(duplicate.evidence.count == 2)
        #expect(duplicate.actions.count == 1, "only the standalone copy is offered for removal; the plugin's copy is the plugin's")

        let unmanaged = try one(.unmanagedSkill, "docx")
        #expect(unmanaged.actions.first == .adoptSkill(path: home.path(".claude/skills/docx"), client: .claude))

        let missing = try one(.missingPluginInstall, "Vanished-all@aim")
        #expect(missing.severity == .high)
        #expect(missing.actions == [.reinstallPlugin(pluginID: "Vanished-all@aim", client: .claude)])

        let stale = try one(.stalePluginCache, "Example-all@aim")
        #expect(stale.evidence == ["~/.claude/plugins/cache/aim/Example-all/1.0.100", "~/.claude/plugins/cache/aim/Example-all/1.0.150"])
        #expect(stale.title.contains("2 old versions"))

        let command = try one(.unreachableMCPCommand, "vanished")
        #expect(command.evidence == ["vanished-mcp"])
        #expect(report.findings.filter { $0.kind == .unreachableMCPCommand }.count == 1, "the reachable server is not reported")

        let tool = try one(.toolUnavailable, "Codex")
        #expect(tool.actions.contains(.locateTool(client: .codex)))

        let repeated = try one(.mcpServerRepeatedAcrossClients, "present")
        #expect(repeated.client == nil)
        #expect(repeated.actions == [.manageMCPServer(name: "present", clients: [.claude, .codex])])

        let never = try one(.neverChecked, "Kiro CLI")
        #expect(never.actions == [.checkClient(client: .kiro)])

        #expect(report.counts[.claude]?.skills == 2)
        #expect(report.highestSeverity == .high)
        #expect(report.findings.first?.severity == .high, "worst first")
    }

    @Test func aManagedSkillIsNotReportedAsUnmanaged() throws {
        let home = try Home()
        defer { home.remove() }
        let report = audit(home, managed: ["docx"])
        #expect(!report.findings.contains { $0.kind == .unmanagedSkill })
        // The duplicate is still a duplicate whoever manages it.
        #expect(report.findings.contains { $0.kind == .duplicateSkillInClient })
    }

    @Test func findingIdentifiersAreStableAcrossRuns() throws {
        let home = try Home()
        defer { home.remove() }
        let first = audit(home).findings.map(\.id)
        let second = audit(home).findings.map(\.id)
        #expect(first == second)
        #expect(Set(first).count == first.count, "no two findings share an id")
        #expect(SetupFinding.identifier(kind: .unmanagedSkill, client: .claude, subject: "docx")
            != SetupFinding.identifier(kind: .unmanagedSkill, client: .codex, subject: "docx"))
    }

    @Test func aCleanHomeHasNoFindings() throws {
        let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
            .appending(path: "SetupAuditTests-clean-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        try Home.skill(named: "tidy", in: root.appending(path: ".claude/skills", directoryHint: .isDirectory))
        let observation = TargetObservation(
            surface: .claudeCode, installed: true, commandAvailable: true, version: "1",
            configurationPaths: [], discoveredSkills: ["tidy"], discoveredPlugins: [], discoveredMCPServers: [],
            skillMetadata: ["tidy": .init(path: root.appending(path: ".claude/skills/tidy").path(percentEncoded: false), source: "s")],
            pluginMetadata: [:], mcpMetadata: [:], capabilities: Home.capabilities, notes: [])
        let report = SetupAuditor(homeURL: root).audit(observations: [observation], managed: [.claude], library: .init(managedSkillNames: ["tidy"]))
        #expect(report.findings.isEmpty)
        #expect(report.highestSeverity == nil)
    }

    @Test func theCommandCheckUnderstandsBothConfigurationFormatsAndTildePaths() throws {
        let home = try Home()
        defer { home.remove() }
        let auditor = SetupAuditor(homeURL: home.root, searchPath: [home.root.appending(path: ".local/bin")])
        let json = auditor.configuredCommands(client: .claude, configurationPaths: [home.root.appending(path: ".claude.json").path(percentEncoded: false)])
        #expect(json == ["present": "present-mcp", "vanished": "vanished-mcp"])
        let toml = auditor.configuredCommands(client: .codex, configurationPaths: [home.root.appending(path: ".codex/config.toml").path(percentEncoded: false)])
        #expect(toml == ["present": "present-mcp"])
        #expect(auditor.commandIsReachable("present-mcp"))
        #expect(auditor.commandIsReachable("~/.local/bin/present-mcp"))
        #expect(!auditor.commandIsReachable("/nowhere/at/all"))
        #expect(!auditor.commandIsReachable("vanished-mcp"))
    }
}
