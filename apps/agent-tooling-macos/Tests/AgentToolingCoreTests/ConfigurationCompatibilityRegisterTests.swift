import Foundation
import Testing

@testable import AgentToolingCore

/// The register is enforced, not decorative: an adapter cannot claim to
/// understand a setting that nobody recorded a source and a version range for.
@Suite("Configuration compatibility register")
struct ConfigurationCompatibilityRegisterTests {
    @Test func everySettingAnAdapterClaimsIsRecordedWithItsSource() {
        let adapters: [(TargetSurface, [ConfigurationSettingDefinition])] = [
            (.claudeCode, ClaudeCodeConfigurationAdapter().settings(installedClientVersion: "2.0.0")),
            (.codexCLI, CodexConfigurationAdapter(installedClientVersion: "0.140.0")
                .settings(installedClientVersion: "0.140.0")),
        ]
        for (surface, settings) in adapters {
            for setting in settings {
                let entry = ConfigurationCompatibilityRegister.entry(surface: surface, key: setting.key)
                #expect(entry != nil, "\(surface.rawValue) claims '\(setting.key)' with no register entry.")
                #expect(entry?.sourceURL.hasPrefix("https://") == true,
                        "\(setting.key) needs the vendor page it was read from.")
                #expect(entry?.versionRange.isEmpty == false,
                        "\(setting.key) needs the releases it was recorded against.")
            }
        }
    }

    @Test func theRegisterNeverRecordsSomethingNoAdapterUnderstands() {
        let claude = Set(ClaudeCodeConfigurationAdapter().settings(installedClientVersion: "2.0.0").map(\.key))
        let codex = Set(CodexConfigurationAdapter(installedClientVersion: "0.140.0")
            .settings(installedClientVersion: "0.140.0").map(\.key))
        for entry in ConfigurationCompatibilityRegister.entries {
            let known = entry.surface == .claudeCode ? claude : codex
            #expect(known.contains(entry.key), "The register lists '\(entry.key)' that no adapter reads.")
        }
    }

    @Test func anythingNotWritableSaysWhy() {
        for entry in ConfigurationCompatibilityRegister.entries where entry.direction == .read {
            #expect(entry.limitation?.isEmpty == false,
                    "\(entry.surface.rawValue) '\(entry.key)' is read-only with no stated reason.")
        }
        // Codex is entirely read-only for now, and says so on every entry.
        #expect(ConfigurationCompatibilityRegister.entries
            .filter { $0.surface == .codexCLI }
            .allSatisfy { $0.direction == .read })
    }

    @Test func theEditorAndTheRegisterAgreeOnWhatCanBeWritten() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let configuration = EffectiveConfigurationResolver.resolve(
            adapter: ClaudeCodeConfigurationAdapter(), installedClientVersion: "2.0.0",
            layers: [.init(kind: .user, sourcePath: fixture.path, isWritable: true,
                           values: ["model": .string("user-model"), "hooks": .list([])])])
        let editor = ConfigurationEditor()

        // Recorded as writable, so validation accepts it.
        #expect(ConfigurationCompatibilityRegister.isWritable(surface: .claudeCode, key: "model"))
        #expect(throws: Never.self) {
            try editor.validate(.init(key: "model", layer: .user, sourcePath: fixture.path,
                                      newValue: .string("new"), expectedFingerprint: nil),
                                against: configuration)
        }
        // Recorded as read-only, and the register says why.
        #expect(!ConfigurationCompatibilityRegister.isWritable(surface: .claudeCode, key: "hooks"))
        #expect(ConfigurationCompatibilityRegister.entry(surface: .claudeCode, key: "hooks")?
            .limitation?.contains("trust") == true)
    }

    private struct Fixture {
        let root: URL
        let path: String

        init() throws {
            root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
                .appending(path: "compatibility-register-\(UUID())")
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700])
            path = root.appending(path: "settings.json").path
            try Data(#"{"model":"user-model"}"#.utf8).write(to: URL(fileURLWithPath: path))
        }

        func remove() { try? FileManager.default.removeItem(at: root) }
    }
}
