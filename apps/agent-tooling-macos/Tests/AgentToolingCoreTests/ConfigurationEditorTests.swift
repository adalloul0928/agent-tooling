import Foundation
import Testing

@testable import AgentToolingCore

/// A narrow writer: one setting, one file, everything else preserved, and the
/// change confirmed by reading the file back.
@Suite("Configuration editor")
struct ConfigurationEditorTests {
    @Test func oneSettingChangesWhileEveryOtherKeyAndUnknownFieldSurvives() throws {
        let fixture = try Fixture(#"""
        {"model":"old-model","permissions":{"allow":["Read"],"vendorOnly":true},\#
        "unknownThing":{"nested":[1,2]},"cleanupPeriodDays":30}
        """#)
        defer { fixture.remove() }
        let editor = ConfigurationEditor()
        let edit = ConfigurationEdit(key: "model", layer: .user, sourcePath: fixture.path,
            newValue: .string("new-model"), expectedFingerprint: try editor.fingerprint(of: fixture.path))

        let receipt = try editor.apply(edit, adapter: ClaudeCodeConfigurationAdapter(),
                                       installedClientVersion: "2.0.0")

        #expect(receipt.effectiveValue == .string("new-model"))
        let object = try fixture.object()
        #expect(object["model"] as? String == "new-model")
        #expect(object["cleanupPeriodDays"] as? Int == 30)
        // Unknown keys and vendor-only nesting are the person's, not ours.
        #expect(object["unknownThing"] != nil)
        let permissions = try #require(object["permissions"] as? [String: Any])
        #expect(permissions["vendorOnly"] as? Bool == true)
        #expect(permissions["allow"] as? [String] == ["Read"])
        // A backup of the original is left behind.
        #expect(FileManager.default.fileExists(atPath: receipt.backupPath))
        #expect(receipt.previousFingerprint != receipt.newFingerprint)
    }

    @Test func aFileChangedSinceReviewIsNeverOverwritten() throws {
        let fixture = try Fixture(#"{"model":"old-model"}"#)
        defer { fixture.remove() }
        let editor = ConfigurationEditor()
        let stale = try editor.fingerprint(of: fixture.path)
        try fixture.rewrite(#"{"model":"changed-by-someone-else"}"#)

        #expect(throws: ConfigurationEditError.self) {
            _ = try editor.apply(.init(key: "model", layer: .user, sourcePath: fixture.path,
                newValue: .string("new-model"), expectedFingerprint: stale),
                adapter: ClaudeCodeConfigurationAdapter(), installedClientVersion: "2.0.0")
        }
        #expect(try fixture.object()["model"] as? String == "changed-by-someone-else")
    }

    @Test func aValueFixedByPolicyOffersNoEdit() throws {
        let fixture = try Fixture(#"{"model":"user-model"}"#)
        defer { fixture.remove() }
        let configuration = EffectiveConfigurationResolver.resolve(
            adapter: ClaudeCodeConfigurationAdapter(), installedClientVersion: "2.0.0",
            layers: [
                .init(kind: .managedPolicy, sourcePath: "/policy", isWritable: false,
                      values: ["model": .string("policy-model")]),
                .init(kind: .user, sourcePath: fixture.path, isWritable: true,
                      values: ["model": .string("user-model")]),
            ])

        #expect(throws: ConfigurationEditError.constrainedByHigherLayer) {
            try ConfigurationEditor().validate(
                .init(key: "model", layer: .user, sourcePath: fixture.path,
                      newValue: .string("mine"), expectedFingerprint: nil),
                against: configuration)
        }
    }

    @Test func aSettingThisBuildDoesNotDefineIsRefused() throws {
        let fixture = try Fixture(#"{"model":"user-model","unknownThing":1}"#)
        defer { fixture.remove() }
        let configuration = EffectiveConfigurationResolver.resolve(
            adapter: ClaudeCodeConfigurationAdapter(), installedClientVersion: "2.0.0",
            layers: [.init(kind: .user, sourcePath: fixture.path, isWritable: true,
                           values: ["model": .string("user-model"), "unknownThing": .number(1)])])

        #expect(throws: ConfigurationEditError.unsupportedSetting) {
            try ConfigurationEditor().validate(
                .init(key: "unknownThing", layer: .user, sourcePath: fixture.path,
                      newValue: .number(2), expectedFingerprint: nil),
                against: configuration)
        }
        // The unknown key is still visible, just not editable here.
        #expect(configuration.unrecognized.map(\.key) == ["unknownThing"])
    }

    @Test func aValueThisBuildNeverUnderstoodIsNotWrittenBack() throws {
        let fixture = try Fixture(#"{"model":"user-model"}"#)
        defer { fixture.remove() }
        let before = try fixture.contents()

        #expect(throws: ConfigurationEditError.valueRejected) {
            _ = try ConfigurationEditor().apply(
                .init(key: "model", layer: .user, sourcePath: fixture.path,
                      newValue: .opaque("Configured"),
                      expectedFingerprint: try ConfigurationEditor().fingerprint(of: fixture.path)),
                adapter: ClaudeCodeConfigurationAdapter(), installedClientVersion: "2.0.0")
        }
        #expect(try fixture.contents() == before)
    }

    @Test func aListSettingIsWrittenIntoItsDocumentedNesting() throws {
        let fixture = try Fixture(#"{"permissions":{"deny":["Bash"]}}"#)
        defer { fixture.remove() }
        let editor = ConfigurationEditor()

        let receipt = try editor.apply(
            .init(key: "permissions.allow", layer: .user, sourcePath: fixture.path,
                  newValue: .list([.string("Read"), .string("Grep")]),
                  expectedFingerprint: try editor.fingerprint(of: fixture.path)),
            adapter: ClaudeCodeConfigurationAdapter(), installedClientVersion: "2.0.0")

        #expect(receipt.effectiveValue == .list([.string("Read"), .string("Grep")]))
        let permissions = try #require(try fixture.object()["permissions"] as? [String: Any])
        #expect(permissions["allow"] as? [String] == ["Read", "Grep"])
        #expect(permissions["deny"] as? [String] == ["Bash"])
    }

    private struct Fixture {
        let root: URL
        let path: String

        init(_ contents: String) throws {
            root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
                .appending(path: "configuration-editor-\(UUID())")
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700])
            path = root.appending(path: "settings.json").path
            try Data(contents.utf8).write(to: URL(fileURLWithPath: path))
        }

        func rewrite(_ contents: String) throws {
            try Data(contents.utf8).write(to: URL(fileURLWithPath: path))
        }

        func contents() throws -> Data { try Data(contentsOf: URL(fileURLWithPath: path)) }

        func object() throws -> [String: Any] {
            try JSONSerialization.jsonObject(with: try contents()) as? [String: Any] ?? [:]
        }

        func remove() { try? FileManager.default.removeItem(at: root) }
    }
}
