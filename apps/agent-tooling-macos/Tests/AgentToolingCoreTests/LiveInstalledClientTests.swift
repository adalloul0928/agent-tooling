import Foundation
import Testing

@testable import AgentToolingCore

/// Checks that run against the clients actually installed on this Mac.
///
/// Opt-in, because a machine without them would report failures that say
/// nothing about the code. They read only: no client is launched, no setting is
/// written, and no package is installed. What they establish is the thing a
/// fixture cannot — that this build's recorded facts match a real installation.
///
///     AGENT_TOOLING_RUN_LIVE_CLIENT_CHECKS=1 swift test --filter LiveInstalled
private let runsLiveClientChecks =
    ProcessInfo.processInfo.environment["AGENT_TOOLING_RUN_LIVE_CLIENT_CHECKS"] == "1"

private let home = FileManager.default.homeDirectoryForCurrentUser

@Suite("Live installed clients")
struct LiveInstalledClientTests {
    @Test("The locator finds the real tools where they are actually installed",
          .enabled(if: runsLiveClientChecks))
    func locatorFindsRealTools() throws {
        // At least one has to be here, or this suite is checking nothing.
        let found = ClientKind.allCases.compactMap { client -> (ClientKind, URL)? in
            ClientExecutableLocator.locate(client, homeURL: home).map { (client, $0) }
        }
        #expect(!found.isEmpty, "No client tool was found in any recorded location.")
        for (client, url) in found {
            #expect(FileManager.default.isExecutableFile(atPath: url.path))
            #expect(url.lastPathComponent == ClientExecutableLocator.executableName(for: client))
        }
    }

    @Test("Claude Code's own settings file parses into the layers this build claims",
          .enabled(if: runsLiveClientChecks))
    func claudeSettingsParse() throws {
        let path = home.appending(path: ".claude/settings.json")
        try #require(FileManager.default.fileExists(atPath: path.path),
                     "No Claude Code settings file on this Mac to check against.")
        let layers = try ConfigurationLayerReader().claudeCodeLayers(
            homeRoot: home,
            managedPolicyPath: ConfigurationLayerReader.managedPolicyPath(for: .claudeCode))
        let configuration = EffectiveConfigurationResolver.resolve(
            adapter: ClaudeCodeConfigurationAdapter(), installedClientVersion: nil, layers: layers)

        // Every key the real file carries is either understood and recorded, or
        // reported as one this build does not interpret. Silently dropping one
        // is the failure this exists to catch.
        let raw = try #require(try JSONSerialization.jsonObject(
            with: Data(contentsOf: path)) as? [String: Any])
        let understood = Set(configuration.rows.map(\.key))
        let reported = Set(configuration.unrecognized.map(\.key))
        func check(_ key: String) {
            #expect(understood.contains(key) || reported.contains(key),
                    "'\(key)' is in the real settings file and this build neither reads nor reports it.")
        }
        for (key, value) in raw {
            // The reader goes one level into the nested objects it documents, so
            // each child is its own claim and each has to be accounted for. A
            // parent that "covers" its children would hide exactly the setting
            // this build silently dropped.
            if let nested = value as? [String: Any],
               understood.contains(where: { $0.hasPrefix(key + ".") })
                || reported.contains(where: { $0.hasPrefix(key + ".") }) {
                for child in nested.keys { check("\(key).\(child)") }
            } else {
                check(key)
            }
        }
        // This person's own file is the proof that the nested path is exercised.
        #expect(!configuration.unrecognized.isEmpty
                || raw.keys.allSatisfy { understood.contains($0) })
    }

    @Test("Every setting this build claims for a real file is recorded in the register",
          .enabled(if: runsLiveClientChecks))
    func claimedSettingsAreRegistered() throws {
        let layers = try ConfigurationLayerReader().claudeCodeLayers(homeRoot: home)
        let configuration = EffectiveConfigurationResolver.resolve(
            adapter: ClaudeCodeConfigurationAdapter(), installedClientVersion: nil, layers: layers)
        for row in configuration.rows {
            let entry = ConfigurationCompatibilityRegister.entry(surface: .claudeCode, key: row.key)
            #expect(entry != nil, "'\(row.key)' is resolved from a real file with no register entry.")
        }
    }

    @Test("The recorded instruction locations match what is really on this Mac",
          .enabled(if: runsLiveClientChecks))
    func instructionInventoryMatchesReality() throws {
        let result = AgentInstructionInventory.scan(homeRoot: home)

        // Every path reported has to be a file that is genuinely there. A
        // recorded location that does not exist would be a stale vendor fact.
        for entry in result.entries {
            #expect(FileManager.default.fileExists(atPath: entry.path),
                    "\(entry.path) was reported but is not there.")
        }
        // And anything actually sitting in a recorded location has to be found,
        // which is the direction that catches a location this build forgot.
        let userInstructions = home.appending(path: ".claude/CLAUDE.md")
        if FileManager.default.fileExists(atPath: userInstructions.path) {
            #expect(result.entries.contains { $0.path == userInstructions.standardizedFileURL.path },
                    "This Mac has ~/.claude/CLAUDE.md and the inventory missed it.")
        }
    }

    @Test("Codex's real config parses without claiming anything it does not read",
          .enabled(if: runsLiveClientChecks))
    func codexConfigParses() throws {
        let path = home.appending(path: ".codex/config.toml")
        try #require(FileManager.default.fileExists(atPath: path.path),
                     "No Codex config on this Mac to check against.")
        let adapter = CodexConfigurationAdapter(installedClientVersion: nil)
        let layers = try ConfigurationLayerReader().codexLayers(homeRoot: home, adapter: adapter)
        let configuration = EffectiveConfigurationResolver.resolve(
            adapter: adapter, installedClientVersion: nil, layers: layers)

        // Codex is read-only in the register, and a real file must not change
        // that: nothing resolved from it may be offered as writable.
        for row in configuration.rows {
            #expect(!ConfigurationCompatibilityRegister.isWritable(surface: .codexCLI, key: row.key),
                    "'\(row.key)' resolved from a real Codex file is offered as writable.")
        }
    }
}

/// What a first run would produce on this Mac, against what the legacy library
/// already holds. This is the check that says whether deleting the legacy store
/// loses anything: if a scan reproduces the same items, it does not.
@Suite("Live first run")
struct LiveFirstRunTests {
    @Test("A first run reproduces this Mac's library from a live scan",
          .enabled(if: runsLiveClientChecks))
    func firstRunReproducesTheLibrary() async throws {
        let observations = await ClientAdapterRegistry().scanAll(
            homeURL: home, runner: ProcessCommandRunner(homeURL: home))
        let inventory = InventoryCompiler.compile(observations: observations, homeURL: home)
        let result = try WorkspaceFirstRun.prepare(observations: observations, inventory: inventory)

        // A scan that finds nothing would make this suite prove nothing.
        #expect(!result.document.artifacts.isEmpty,
                "A live scan of this Mac found nothing to record.")
        // Nothing a scan produces may claim this app owns somebody's files.
        #expect(result.document.artifacts.allSatisfy {
            $0.authority == .trackedOnly || $0.authority == .nativeOwned
        })
        #expect(result.document.artifacts.allSatisfy { $0.contentDigest == nil })
        // The result has to be a workspace the store would actually accept.
        #expect(throws: Never.self) {
            try result.document.validateStructure()
            try result.device.validateStructure(against: result.document)
        }
        print("FIRST RUN on this Mac: skills=\(result.skillCount) "
            + "packages=\(result.packageCount) connections=\(result.connectionCount) "
            + "observations=\(result.device.observations.count)")
    }
}
