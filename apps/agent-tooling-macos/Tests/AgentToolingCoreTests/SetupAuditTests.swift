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
            pluginCache = root.appending(path: ".claude/plugins/cache/example/Example-all", directoryHint: .isDirectory)
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
            let missingPlugin = root.appending(path: ".claude/plugins/cache/example/Vanished-all/1.0.1").path(percentEncoded: false)
            let claude = TargetObservation(
                surface: .claudeCode, installed: true, commandAvailable: true, version: "2.1.285",
                configurationPaths: [root.appending(path: ".claude.json").path(percentEncoded: false)],
                discoveredSkills: ["docx", "Example-all:docx"],
                discoveredPlugins: ["Example-all@example", "Vanished-all@example"],
                discoveredMCPServers: ["present", "vanished"],
                skillMetadata: [
                    "docx": .init(
                        path: claudeSkills.appending(path: "docx").path(percentEncoded: false), source: "Standalone Claude Code skill"),
                    "Example-all:docx": .init(
                        path: pluginCache.appending(path: "1.0.200/skills/docx").path(percentEncoded: false), source: "Example-all@example",
                        providerPluginID: "Example-all@example"),
                ],
                pluginMetadata: [
                    "Example-all@example": .init(
                        name: "Example All", source: currentPlugin, scope: "User", enabled: true, skillIDs: ["Example-all:docx"]),
                    "Vanished-all@example": .init(name: "Vanished All", source: missingPlugin, scope: "User", enabled: true),
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
                capabilities: Self.capabilities,
                notes: ["The codex CLI was not available in any known install location; configuration was scanned from disk only."])
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

        let missing = try one(.missingPluginInstall, "Vanished-all@example")
        #expect(missing.severity == .high)
        #expect(missing.actions == [.reinstallPlugin(pluginID: "Vanished-all@example", client: .claude)])

        let stale = try one(.stalePluginCache, "Example-all@example")
        #expect(
            stale.evidence == [
                "~/.claude/plugins/cache/example/Example-all/1.0.100", "~/.claude/plugins/cache/example/Example-all/1.0.150",
            ])
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

    /// Example Manager keeps Codex's plugins flat by name; their siblings are other
    /// plugins, not old versions, and must not be offered for removal.
    @Test func aPluginKeptFlatByNameHasNoStaleVersions() throws {
        let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
            .appending(path: "SetupAuditTests-flat-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        let plugins = root.appending(path: ".config/example-manager/plugins/codex", directoryHint: .isDirectory)
        for name in ["Core", "Pipeline", "Additional"] {
            try FileManager.default.createDirectory(at: plugins.appending(path: name), withIntermediateDirectories: true)
        }
        let observation = TargetObservation(
            surface: .codexCLI, installed: true, commandAvailable: true, version: "0.159",
            configurationPaths: [], discoveredSkills: [], discoveredPlugins: ["Core@example"], discoveredMCPServers: [],
            skillMetadata: [:],
            pluginMetadata: [
                "Core@example": .init(
                    name: "Core", source: plugins.appending(path: "Core").path(percentEncoded: false), scope: "User", enabled: true)
            ],
            mcpMetadata: [:], capabilities: Home.capabilities, notes: [])
        let report = SetupAuditor(homeURL: root).audit(
            observations: [observation], managed: [.codex], library: .init(managedSkillNames: []))
        #expect(!report.findings.contains { $0.kind == .stalePluginCache })
        #expect(
            SetupAuditor.looksLikeVersion("1.0.6484223236") && SetupAuditor.looksLikeVersion("fa59bc903774")
                && SetupAuditor.looksLikeVersion("unknown"))
        #expect(!SetupAuditor.looksLikeVersion("Pipeline") && !SetupAuditor.looksLikeVersion("Core"))
    }

    /// A plugin from a directory marketplace loads from that folder even
    /// when its install record names a cache path that is gone.
    @Test func aPluginFromADirectoryMarketplaceIsNotMissingWhenItsFolderIsThere() throws {
        let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
            .appending(path: "SetupAuditTests-mkt-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        let marketplace = root.appending(path: ".config/example-manager/catalog", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(
            at: marketplace.appending(path: "Example-all/.claude-plugin"), withIntermediateDirectories: true)
        try "{}".write(to: marketplace.appending(path: "Example-all/.claude-plugin/plugin.json"), atomically: true, encoding: .utf8)
        try FileManager.default.createDirectory(at: root.appending(path: ".claude"), withIntermediateDirectories: true)
        let settings = root.appending(path: ".claude/settings.json")
        try
            #"{"extraKnownMarketplaces":{"example":{"source":{"source":"directory","path":"\#(marketplace.path(percentEncoded: false))"}}}}"#
            .write(to: settings, atomically: true, encoding: .utf8)
        let observation = TargetObservation(
            surface: .claudeCode, installed: true, commandAvailable: true, version: "2",
            configurationPaths: [settings.path(percentEncoded: false)], discoveredSkills: [],
            discoveredPlugins: ["Example-all@example", "Gone-all@example"],
            discoveredMCPServers: [], skillMetadata: [:],
            pluginMetadata: [
                "Example-all@example": .init(
                    name: "Example",
                    source: root.appending(path: ".claude/plugins/cache/example/Example-all/1.0.1").path(percentEncoded: false),
                    scope: "User", enabled: true),
                "Gone-all@example": .init(
                    name: "Gone", source: root.appending(path: ".claude/plugins/cache/example/Gone-all/1.0.1").path(percentEncoded: false),
                    scope: "User", enabled: true),
            ],
            mcpMetadata: [:], capabilities: Home.capabilities, notes: [])
        let report = SetupAuditor(homeURL: root).audit(
            observations: [observation], managed: [.claude], library: .init(managedSkillNames: []))
        let missing = report.findings.filter { $0.kind == .missingPluginInstall }.map(\.subject)
        #expect(missing == ["Gone-all@example"], "the one whose folder is in the marketplace directory is not missing")
    }

    @Test func aManagedSkillIsNotReportedAsUnmanaged() throws {
        let home = try Home()
        defer { home.remove() }
        let report = audit(home, managed: ["docx"])
        #expect(!report.findings.contains { $0.kind == .unmanagedSkill })
        // The duplicate is still a duplicate whoever manages it.
        #expect(report.findings.contains { $0.kind == .duplicateSkillInClient })
    }

    /// Recorded external ownership prevents adoption or removal of the copy.
    @Test func aCopyAnotherToolPlacedIsNeitherUnmanagedNorRemovable() throws {
        let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
            .appending(path: "SetupAuditTests-manager-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        let manager = ObservedExternalManager(tool: "Example Manager", package: "core-skills")
        let digest = String(repeating: "a", count: 64)
        let observation = TargetObservation(
            surface: .claudeCode, installed: true, commandAvailable: true, version: "2",
            configurationPaths: [], discoveredSkills: ["build", "Core:build"], discoveredPlugins: [], discoveredMCPServers: [],
            skillMetadata: [
                "build": .init(
                    path: root.appending(path: ".claude/skills/build").path(percentEncoded: false), source: "s",
                    definitionDigest: digest, externalManager: manager),
                "Core:build": .init(
                    path: root.appending(path: "plugins/Core/skills/build").path(percentEncoded: false), source: "Core@example",
                    providerPluginID: "Core@example", definitionDigest: digest),
            ],
            pluginMetadata: [:], mcpMetadata: [:], capabilities: Home.capabilities, notes: [])
        let report = SetupAuditor(homeURL: root).audit(
            observations: [observation], managed: [.claude], library: .init(managedSkillNames: []))
        #expect(!report.findings.contains { $0.kind == .unmanagedSkill })
        let duplicate = try #require(report.findings.first { $0.kind == .duplicateSkillInClient })
        #expect(duplicate.actions.isEmpty, "removing Example Manager's copy would be undone at its next sync")
        #expect(duplicate.severity == .low, "identical copies cannot behave differently")
        #expect(duplicate.detail.contains("identical"))
        #expect(duplicate.detail.contains("Example Manager · core-skills"))
    }

    @Test func copiesWithDifferentContentAreSaidToDiffer() throws {
        let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
            .appending(path: "SetupAuditTests-variants-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        let observation = TargetObservation(
            surface: .claudeCode, installed: true, commandAvailable: true, version: "2",
            configurationPaths: [], discoveredSkills: ["A:sop", "B:sop"], discoveredPlugins: [], discoveredMCPServers: [],
            skillMetadata: [
                "A:sop": .init(
                    path: "/p/A/sop", source: "A@example", providerPluginID: "A@example",
                    definitionDigest: String(repeating: "a", count: 64)),
                "B:sop": .init(
                    path: "/p/B/sop", source: "B@example", providerPluginID: "B@example",
                    definitionDigest: String(repeating: "b", count: 64)),
            ],
            pluginMetadata: [:], mcpMetadata: [:], capabilities: Home.capabilities, notes: [])
        let report = SetupAuditor(homeURL: root).audit(
            observations: [observation], managed: [.claude], library: .init(managedSkillNames: []))
        let duplicate = try #require(report.findings.first { $0.kind == .duplicateSkillInClient })
        #expect(duplicate.severity == .medium)
        #expect(duplicate.detail.contains("A@example, B@example"))
        #expect(duplicate.detail.contains("differ"))
    }

    /// Claude Code keeps a plugin's server apart from one configured by hand
    /// unless the two are identical, so one name from several places is
    /// reported, with a way in only where a person's own copy is one of them.
    @Test func aServerDefinedInSeveralPlacesIsReported() throws {
        let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
            .appending(path: "SetupAuditTests-mcp-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        let observation = TargetObservation(
            surface: .claudeCode, installed: true, commandAvailable: true, version: "2",
            configurationPaths: [], discoveredSkills: [], discoveredPlugins: [], discoveredMCPServers: ["builder", "jira"],
            skillMetadata: [:], pluginMetadata: [:],
            mcpMetadata: [
                "builder": .init(
                    transport: "stdio", authentication: "", source: "Example-all@example",
                    additionalSources: ["Additional-all@example", "Claude Code configuration"]),
                "jira": .init(
                    transport: "stdio", authentication: "", source: "Example-all@example", additionalSources: ["Additional-all@example"]),
            ],
            capabilities: Home.capabilities, notes: [])
        let codex = TargetObservation(
            surface: .codexCLI, installed: true, commandAvailable: true, version: "1",
            configurationPaths: [], discoveredSkills: [], discoveredPlugins: [], discoveredMCPServers: ["builder"],
            skillMetadata: [:], pluginMetadata: [:],
            mcpMetadata: ["builder": .init(transport: "stdio", authentication: "", source: "Codex CLI configuration")],
            capabilities: Home.capabilities, notes: [])
        let report = SetupAuditor(homeURL: root, searchPath: [])
            .audit(observations: [observation, codex], managed: [.claude, .codex], library: .init(managedSkillNames: []))
        let several = report.findings.filter { $0.kind == .mcpServerDefinedSeveralTimes }
        let builder = try #require(several.first { $0.subject == "builder" })
        #expect(builder.title == "Claude Code gets builder from 3 places")
        #expect(builder.actions == [.inspectMCPServer(name: "builder", client: .claude)])
        let jira = try #require(several.first { $0.subject == "jira" })
        #expect(jira.actions.isEmpty, "only plugins bring it: nothing here is a person's to remove")
        // The hand-configured copy behind a plugin's still counts as one.
        #expect(report.findings.contains { $0.kind == .mcpServerRepeatedAcrossClients && $0.subject == "builder" })
    }

    @Test func pluginsThatCarryTheSameSkillsAreNamed() throws {
        let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
            .appending(path: "SetupAuditTests-overlap-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        let shared = ["build", "crux", "wiki-edit"]
        let observation = TargetObservation(
            surface: .claudeCode, installed: true, commandAvailable: true, version: "2",
            configurationPaths: [], discoveredSkills: [], discoveredPlugins: ["Core@example", "Example@example", "Other@example"],
            discoveredMCPServers: [],
            skillMetadata: [:],
            pluginMetadata: [
                "Core@example": .init(name: "Core", source: "Core", scope: "User", enabled: true, skillIDs: shared.map { "Core:\($0)" }),
                "Example@example": .init(
                    name: "Example", source: "Example", scope: "User", enabled: true,
                    skillIDs: (shared + ["mcm", "oncall"]).map { "Example:\($0)" }),
                "Other@example": .init(
                    name: "Other", source: "Other", scope: "User", enabled: true, skillIDs: ["Other:build", "Other:x", "Other:y"]),
            ],
            mcpMetadata: [:], capabilities: Home.capabilities, notes: [])
        let report = SetupAuditor(homeURL: root).audit(
            observations: [observation], managed: [.claude], library: .init(managedSkillNames: []))
        let overlaps = report.findings.filter { $0.kind == .pluginSkillsOverlap }
        #expect(overlaps.map(\.subject) == ["Core@example|Example@example"], "one shared skill is not an overlap")
        #expect(overlaps.first?.title == "Every skill in Core also comes with Example")
        #expect(overlaps.first?.evidence == shared)
        #expect(overlaps.first?.actions.isEmpty == true)
    }

    @Test func findingIdentifiersAreStableAcrossRuns() throws {
        let home = try Home()
        defer { home.remove() }
        let first = audit(home).findings.map(\.id)
        let second = audit(home).findings.map(\.id)
        #expect(first == second)
        #expect(Set(first).count == first.count, "no two findings share an id")
        #expect(
            SetupFinding.identifier(kind: .unmanagedSkill, client: .claude, subject: "docx")
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
        let report = SetupAuditor(homeURL: root).audit(
            observations: [observation], managed: [.claude], library: .init(managedSkillNames: ["tidy"]))
        #expect(report.findings.isEmpty)
        #expect(report.highestSeverity == nil)
    }

    @Test func theCommandCheckUnderstandsBothConfigurationFormatsAndTildePaths() throws {
        let home = try Home()
        defer { home.remove() }
        let auditor = SetupAuditor(homeURL: home.root, searchPath: [home.root.appending(path: ".local/bin")])
        let json = auditor.configuredCommands(configurationPaths: [home.root.appending(path: ".claude.json").path(percentEncoded: false)])
        #expect(json == ["present": "present-mcp", "vanished": "vanished-mcp"])
        let toml = auditor.configuredCommands(configurationPaths: [
            home.root.appending(path: ".codex/config.toml").path(percentEncoded: false)
        ])
        #expect(toml == ["present": "present-mcp"])
        #expect(auditor.commandIsReachable("present-mcp"))
        #expect(auditor.commandIsReachable("~/.local/bin/present-mcp"))
        #expect(!auditor.commandIsReachable("/nowhere/at/all"))
        #expect(!auditor.commandIsReachable("vanished-mcp"))
    }
}
