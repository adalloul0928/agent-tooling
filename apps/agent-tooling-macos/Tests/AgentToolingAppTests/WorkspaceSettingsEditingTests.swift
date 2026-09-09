import Foundation
import Testing

@testable import AgentToolingCore
@testable import AgentToolingApp

/// Editing is offered only where it would actually work, and a change that
/// would not take effect is refused rather than written and called done.
@MainActor
struct WorkspaceSettingsEditingTests {
    @Test func onlyARecordedWritableSettingInAFileWeCanRewriteIsOffered() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.writeUserSettings(#"{"model":"opus","hooks":[]}"#)
        let session = fixture.session()
        await session.refresh()
        let surface = try #require(session.surfaces.first { $0.id == .claudeCode })
        let rows = try #require(surface.configuration?.rows)

        let model = try #require(rows.first { $0.key == "model" })
        #expect(session.isEditable(model, surface: .claudeCode))
        // Recorded read-only, with the register saying why.
        let hooks = try #require(rows.first { $0.key == "hooks" })
        #expect(!session.isEditable(hooks, surface: .claudeCode))
    }

    @Test func changingASettingWritesItBacksItUpAndReportsWhatTheAppWillUse() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.writeUserSettings(#"{"model":"opus"}"#)
        let session = fixture.session()
        await session.refresh()
        let surface = try #require(session.surfaces.first { $0.id == .claudeCode })
        let model = try #require(surface.configuration?.rows.first { $0.key == "model" })

        session.beginEdit(model, surface: surface)
        #expect(session.pendingEdit?.sourcePath == fixture.userSettingsPath)
        await session.applyEdit(.string("sonnet"))

        #expect(session.editMessage == nil, "\(session.editMessage ?? "")")
        let receipt = try #require(session.lastReceipt)
        #expect(receipt.effectiveValue == .string("sonnet"))
        // The person's original is beside it, byte for byte.
        #expect(try Data(contentsOf: URL(fileURLWithPath: receipt.backupPath))
            == Data(#"{"model":"opus"}"#.utf8))
        // And the screen now shows what the file actually says.
        let after = try #require(session.surfaces.first { $0.id == .claudeCode })
        #expect(after.configuration?.rows.first { $0.key == "model" }?.value == .string("sonnet"))
        #expect(session.pendingEdit == nil)
    }

    @Test func aFileThatChangedSinceYouOpenedItIsNotOverwritten() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.writeUserSettings(#"{"model":"opus"}"#)
        let session = fixture.session()
        await session.refresh()
        let surface = try #require(session.surfaces.first { $0.id == .claudeCode })
        let model = try #require(surface.configuration?.rows.first { $0.key == "model" })
        session.beginEdit(model, surface: surface)

        // Someone edits it in their editor while the sheet is open.
        try fixture.writeUserSettings(#"{"model":"haiku"}"#)
        await session.applyEdit(.string("sonnet"))

        #expect(session.editMessage?.contains("changed since you opened it") == true,
                "\(session.editMessage ?? "")")
        #expect(try Data(contentsOf: URL(fileURLWithPath: fixture.userSettingsPath))
            == Data(#"{"model":"haiku"}"#.utf8))
        #expect(session.lastReceipt == nil)
    }

    @Test func aSettingSomethingWithMoreSayDecidesIsNotEditableHere() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.writeUserSettings(#"{"model":"opus"}"#)
        try fixture.writeManagedPolicy(#"{"model":"policy-model"}"#)
        let session = fixture.session(withPolicy: true)
        await session.refresh()
        let surface = try #require(session.surfaces.first { $0.id == .claudeCode })
        let model = try #require(surface.configuration?.rows.first { $0.key == "model" })

        #expect(model.isConstrained)
        #expect(!session.isEditable(model, surface: .claudeCode))
        // Asking anyway does nothing rather than writing under the policy.
        session.beginEdit(model, surface: surface)
        #expect(session.pendingEdit == nil)
    }

    @Test func thePolicyLocationIsTheVendorsOwnAndIsNotGuessed() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.writeUserSettings(#"{"model":"opus"}"#)

        // Recorded from the vendor's page, so the screen no longer has to say a
        // policy cannot be ruled out on a Mac where it can be read.
        let recorded = try #require(ConfigurationLayerReader.managedPolicyPath(for: .claudeCode))
        #expect(recorded.path == "/Library/Application Support/ClaudeCode/managed-settings.json")
        #expect(!WorkspaceSettingsSession(homeRoot: fixture.home, library: fixture.library)
            .managedPolicyUnknown)
        // Codex documents no equivalent this build has read, and an invented
        // one would be worse than none.
        #expect(ConfigurationLayerReader.managedPolicyPath(for: .codexCLI) == nil)
        #expect(fixture.session().managedPolicyUnknown)
    }

    @Test func codexIsShownAndExplainedRatherThanMadeEditable() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.writeCodexConfig("model = \"gpt-5\"\n")
        let session = fixture.session()
        await session.refresh()
        let surface = try #require(session.surfaces.first { $0.id == .codexCLI })

        // Its file keeps comments and formatting this build cannot reproduce,
        // so every row is read-only — but the values are still shown.
        #expect(surface.configuration?.rows.isEmpty == false)
        #expect(surface.configuration?.rows.allSatisfy { !session.isEditable($0, surface: .codexCLI) } == true)
    }

    @Test func standingInstructionsAreListedBesideTheSettings() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.writeUserSettings(#"{"model":"opus"}"#)
        try Data("my own instructions\n".utf8)
            .write(to: fixture.home.appending(path: ".claude/CLAUDE.md"))
        let session = fixture.session()

        await session.refresh()

        let inventory = try #require(session.instructions)
        #expect(inventory.entries.contains { $0.surface == .claudeCode && $0.kind == .instructions })
        // Read-only: nothing here reports what the file says.
        #expect(inventory.entries.allSatisfy { $0.byteCount > 0 })
    }

    @MainActor private struct Fixture {
        let root: URL
        let home: URL
        let store: WorkspaceRevisionStore
        let library: WorkspaceLibrarySession
        var userSettingsPath: String { home.appending(path: ".claude/settings.json").path }

        init() throws {
            root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
                .appending(path: "settings-editing-\(UUID())")
            home = root.appending(path: "home")
            for path in [".claude", ".codex"] {
                try FileManager.default.createDirectory(at: home.appending(path: path),
                    withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            }
            let writerID = WorkspaceObjectID()
            let document = try WorkspaceDocumentCoding.seal(.init(
                workspaceID: WorkspaceObjectID(), revision: .init(writerID: writerID)))
            var device = DeviceWorkspaceState(workspaceID: document.workspaceID)
            device.capabilityEvidence = [
                .init(surface: .claudeCode, installedClientVersion: "2.0.0", adapterContractVersion: 1,
                      component: .skill, scopes: [.user], support: .supported,
                      observedAt: Date(timeIntervalSince1970: 1_700_000_000)),
                .init(surface: .codexCLI, installedClientVersion: "0.140.0", adapterContractVersion: 1,
                      component: .skill, scopes: [.user], support: .supported,
                      observedAt: Date(timeIntervalSince1970: 1_700_000_000)),
            ]
            store = try WorkspaceRevisionStore(containerRoot: root.appending(path: "store"),
                workspaceID: document.workspaceID, deviceID: device.deviceID)
            try store.initialize(document: document, device: device)
            library = WorkspaceLibrarySession(
                service: WorkspaceApplicationService(store: store, writerID: writerID),
                workspaceID: document.workspaceID, deviceID: device.deviceID, access: .writable)
        }

        func writeUserSettings(_ json: String) throws {
            try Data(json.utf8).write(to: URL(fileURLWithPath: userSettingsPath), options: .atomic)
        }

        var managedPolicyURL: URL { root.appending(path: "managed-settings.json") }

        func writeManagedPolicy(_ json: String) throws {
            try Data(json.utf8).write(to: managedPolicyURL, options: .atomic)
        }

        func writeCodexConfig(_ toml: String) throws {
            try Data(toml.utf8).write(to: home.appending(path: ".codex/config.toml"), options: .atomic)
        }

        func session(withPolicy: Bool = false) -> WorkspaceSettingsSession {
            WorkspaceSettingsSession(homeRoot: home, library: library,
                                     managedPolicyPath: .some(withPolicy ? managedPolicyURL : nil))
        }

        func remove() { try? FileManager.default.removeItem(at: root) }
    }
}
