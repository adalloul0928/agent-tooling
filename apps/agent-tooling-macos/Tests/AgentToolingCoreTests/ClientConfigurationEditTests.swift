import Foundation
import Testing

@testable import AgentToolingCore

/// Editing one key in a client's own configuration file, leaving everything
/// else in the file as it was, with the original kept first.
@Suite("Client configuration edits")
struct ClientConfigurationEditTests {
    // MARK: JSON

    @Test func aJSONKeyIsSetNestedAndRemovedWithoutDisturbingTheRest() throws {
        let original = """
            {
              "model": "sonnet",
              "permissions": {"allow": ["Read"]},
              "hooks": {"PreToolUse": []}
            }
            """
        let set = try ClientConfigurationEditor.apply(.init(file: .claudeSettings, keyPath: ["toolSearch"], value: .bool(true)), to: original)
        let root = try #require(try JSONSerialization.jsonObject(with: Data(set.utf8)) as? [String: Any])
        #expect(root["toolSearch"] as? Bool == true)
        #expect(root["model"] as? String == "sonnet", "the rest stays")
        #expect((root["hooks"] as? [String: Any])?["PreToolUse"] != nil)

        let nested = try ClientConfigurationEditor.apply(.init(file: .kiroMCP, keyPath: ["mcpServers", "memory", "disabled"], value: .bool(true)), to: #"{"mcpServers":{"memory":{"command":"x"},"other":{"command":"y"}}}"#)
        let servers = try #require((try JSONSerialization.jsonObject(with: Data(nested.utf8)) as? [String: Any])?["mcpServers"] as? [String: Any])
        #expect((servers["memory"] as? [String: Any])?["disabled"] as? Bool == true)
        #expect((servers["memory"] as? [String: Any])?["command"] as? String == "x")
        #expect((servers["other"] as? [String: Any])?["command"] as? String == "y")

        let removed = try ClientConfigurationEditor.apply(.init(file: .claudeSettings, keyPath: ["model"], value: .remove), to: original)
        #expect(!(try #require(try JSONSerialization.jsonObject(with: Data(removed.utf8)) as? [String: Any])).keys.contains("model"))

        let fromEmpty = try ClientConfigurationEditor.apply(.init(file: .geminiSettings, keyPath: ["a", "b"], value: .number(3)), to: "")
        #expect(fromEmpty.contains("\"b\" : 3") || fromEmpty.contains("\"b\": 3"))
    }

    @Test func aJSONListGainsAndLosesOneItemOnce() throws {
        let original = #"{"projects":{"/Users/example/ws":{"disabledMcpServers":["a"]}}}"#
        let path = ["projects", "/Users/example/ws", "disabledMcpServers"]
        let added = try ClientConfigurationEditor.apply(.init(file: .claudeGlobal, keyPath: path, value: .appendToList("slack")), to: original)
        let again = try ClientConfigurationEditor.apply(.init(file: .claudeGlobal, keyPath: path, value: .appendToList("slack")), to: added)
        func list(_ text: String) -> [String]? {
            (((try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])?["projects"] as? [String: Any])?["/Users/example/ws"] as? [String: Any])?["disabledMcpServers"] as? [String]
        }
        #expect(list(added) == ["a", "slack"])
        #expect(list(again) == ["a", "slack"], "adding twice adds once")
        let removed = try ClientConfigurationEditor.apply(.init(file: .claudeGlobal, keyPath: path, value: .removeFromList("a")), to: again)
        #expect(list(removed) == ["slack"])
        // A list where there was none is made; a non-list is refused.
        let made = try ClientConfigurationEditor.apply(.init(file: .claudeGlobal, keyPath: ["projects", "/p", "disabledMcpServers"], value: .appendToList("x")), to: original)
        #expect((((try JSONSerialization.jsonObject(with: Data(made.utf8)) as? [String: Any])?["projects"] as? [String: Any])?["/p"] as? [String: Any])?["disabledMcpServers"] as? [String] == ["x"])
        #expect(throws: ClientConfigurationEditError.notAList("model")) {
            try ClientConfigurationEditor.apply(.init(file: .claudeSettings, keyPath: ["model"], value: .appendToList("x")), to: #"{"model":"sonnet"}"#)
        }
        #expect(throws: ClientConfigurationEditError.notAnObject("model")) {
            try ClientConfigurationEditor.apply(.init(file: .claudeSettings, keyPath: ["model", "x"], value: .bool(true)), to: #"{"model":"sonnet"}"#)
        }
    }

    // MARK: TOML

    private let codexConfig = """
        # Codex
        model = "gpt-5"
        model_reasoning_effort = "medium"

        [mcp_servers.slack-mcp]
          command = "slack-mcp"
          # keep
          enabled = true

        [mcp_servers.other]
          command = "other"

        [plugins."WootAICapabilities-all@aim"]
          enabled = true
        """

    @Test func aTOMLKeyIsReplacedInsideItsTableAndAddedWhenMissing() throws {
        let disabled = try ClientConfigurationEditor.apply(.init(file: .codexConfig, keyPath: ["mcp_servers", "slack-mcp", "enabled"], value: .bool(false)), to: codexConfig)
        #expect(disabled.contains("[mcp_servers.slack-mcp]\n  command = \"slack-mcp\"\n  # keep\n  enabled = false\n"), "replaced in place, comment kept, indent kept")
        #expect(disabled.contains("[mcp_servers.other]\n  command = \"other\"\n"), "the other table is untouched")
        #expect(disabled.contains("# Codex\nmodel = \"gpt-5\""))

        let added = try ClientConfigurationEditor.apply(.init(file: .codexConfig, keyPath: ["mcp_servers", "other", "enabled"], value: .bool(false)), to: codexConfig)
        #expect(added.contains("[mcp_servers.other]\n  command = \"other\"\n  enabled = false\n"), "added at the end of its table")

        let quoted = try ClientConfigurationEditor.apply(.init(file: .codexConfig, keyPath: ["plugins", "WootAICapabilities-all@aim", "enabled"], value: .bool(false)), to: codexConfig)
        #expect(quoted.contains("[plugins.\"WootAICapabilities-all@aim\"]\n  enabled = false"), "a quoted table name is found")

        let root = try ClientConfigurationEditor.apply(.init(file: .codexConfig, keyPath: ["model_reasoning_effort"], value: .string("high")), to: codexConfig)
        #expect(root.contains("model_reasoning_effort = \"high\"\n\n[mcp_servers.slack-mcp]"), "a root key is replaced where it is")

        let newRoot = try ClientConfigurationEditor.apply(.init(file: .codexConfig, keyPath: ["instant_interrupt"], value: .bool(true)), to: codexConfig)
        #expect(newRoot.contains("model_reasoning_effort = \"medium\"\ninstant_interrupt = true\n\n[mcp_servers.slack-mcp]"), "a new root key lands before the first table")

        let newTable = try ClientConfigurationEditor.apply(.init(file: .codexConfig, keyPath: ["features", "web_search"], value: .bool(true)), to: codexConfig)
        #expect(newTable.hasSuffix("[features]\n  web_search = true\n"), "a missing table is added at the end")

        let removed = try ClientConfigurationEditor.apply(.init(file: .codexConfig, keyPath: ["mcp_servers", "slack-mcp", "enabled"], value: .remove), to: codexConfig)
        #expect(!removed.contains("enabled = true\n\n[mcp_servers.other]"))
        #expect(removed.contains("[plugins.\"WootAICapabilities-all@aim\"]\n  enabled = true"), "only the one key went")
    }

    // MARK: Safety

    @Test func anUnsafeEditIsRefusedAndValuesAreParsedNotRun() {
        #expect(!ClientConfigurationEdit(file: .claudeSettings, keyPath: [], value: .bool(true)).isSafe)
        #expect(!ClientConfigurationEdit(file: .claudeSettings, keyPath: ["a\"b"], value: .bool(true)).isSafe)
        #expect(!ClientConfigurationEdit(file: .codexConfig, keyPath: ["[table]"], value: .bool(true)).isSafe)
        #expect(!ClientConfigurationEdit(file: .codexConfig, keyPath: ["a=b"], value: .bool(true)).isSafe)
        #expect(ClientConfigurationEdit(file: .claudeGlobal, keyPath: ["projects", "/Users/x/ws", "disabledMcpServers"], value: .appendToList("s")).isSafe)
        #expect(ClientConfigurationEdit.Value.parsing("true") == .bool(true))
        #expect(ClientConfigurationEdit.Value.parsing("42") == .number(42))
        #expect(ClientConfigurationEdit.Value.parsing("$(rm -rf /)") == .string("$(rm -rf /)"))
        #expect(ClientConfigurationFile.matching("/Users/x/.codex/config.toml", homeURL: URL(filePath: "/Users/x")) == .codexConfig)
        #expect(ClientConfigurationFile.matching("/Users/x/.codex/../.zshrc", homeURL: URL(filePath: "/Users/x")) == nil)
        #expect(ClientConfigurationFile.matching("/Users/y/.codex/config.toml", homeURL: URL(filePath: "/Users/x")) == nil)
    }

    @Test func theEngineBacksUpTheFileThenWritesAndRefusesAnyOtherFile() async throws {
        let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
            .appending(path: "ClientConfigurationEditTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        let home = root.appending(path: "home", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: home.appending(path: ".kiro/settings"), withIntermediateDirectories: true)
        let file = home.appending(path: ".kiro/settings/mcp.json")
        try #"{"mcpServers":{"memory":{"command":"gone.sh"}}}"#.write(to: file, atomically: true, encoding: .utf8)
        let document = try WorkspaceDocumentCoding.seal(.init(workspaceID: WorkspaceObjectID(), revision: .init(writerID: WorkspaceObjectID())))
        let device = DeviceWorkspaceState(workspaceID: document.workspaceID)
        let store = try WorkspaceRevisionStore(containerRoot: root.appending(path: "workspace"), workspaceID: document.workspaceID, deviceID: device.deviceID)
        try store.initialize(document: document, device: device)
        let engine = OperationEngine(store: store, homeURL: home)
        let edit = ClientConfigurationEdit(file: .kiroMCP, keyPath: ["mcpServers", "memory", "disabled"], value: .bool(true))
        func plan(_ path: String, _ edit: ClientConfigurationEdit) throws -> OperationPlan {
            OperationPlan(kind: .configureMCP, title: "t", summary: "s", steps: [.init(kind: .editClientConfiguration, title: "e", detail: edit.summary, destinationPath: path, contents: try edit.encoded())])
        }

        let receipt = await engine.execute(try plan(file.path(percentEncoded: false), edit))

        #expect(receipt.results.first?.status == .succeeded, Comment(rawValue: receipt.results.first?.output ?? ""))
        let written = try #require((try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])?["mcpServers"] as? [String: Any])
        #expect((written["memory"] as? [String: Any])?["disabled"] as? Bool == true)
        let backups = try FileManager.default.subpathsOfDirectory(atPath: store.rootURL.appending(path: "trash").path(percentEncoded: false)).filter { $0.hasSuffix("mcp.json") }
        #expect(backups.count == 1, "the original was kept")
        // Saying it again changes nothing and says so.
        let again = await engine.execute(try plan(file.path(percentEncoded: false), edit))
        #expect(again.results.first?.status == .skipped)
        // Another file, or an edit naming a different file than the path: refused.
        let other = home.appending(path: ".zshrc").path(percentEncoded: false)
        #expect((await engine.execute(try plan(other, edit))).results.first?.status == .failed)
        let mismatched = ClientConfigurationEdit(file: .claudeSettings, keyPath: ["x"], value: .bool(true))
        #expect((await engine.execute(try plan(file.path(percentEncoded: false), mismatched))).results.first?.status == .failed)
    }

    @Test func aConfigurationPathThatIsALinkIsRefusedAndTheTargetIsLeftAlone() async throws {
        // The edit is computed from what the path reads as; the write must not
        // follow a link that points the path somewhere else.
        let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
            .appending(path: "ClientConfigurationEditTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        let home = root.appending(path: "home", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: home.appending(path: ".kiro/settings"), withIntermediateDirectories: true)
        let elsewhere = root.appending(path: "elsewhere.json")
        try #"{"mcpServers":{"memory":{"command":"gone.sh"}}}"#.write(to: elsewhere, atomically: true, encoding: .utf8)
        let file = home.appending(path: ".kiro/settings/mcp.json")
        try FileManager.default.createSymbolicLink(at: file, withDestinationURL: elsewhere)

        let document = try WorkspaceDocumentCoding.seal(.init(workspaceID: WorkspaceObjectID(), revision: .init(writerID: WorkspaceObjectID())))
        let device = DeviceWorkspaceState(workspaceID: document.workspaceID)
        let store = try WorkspaceRevisionStore(containerRoot: root.appending(path: "workspace"), workspaceID: document.workspaceID, deviceID: device.deviceID)
        try store.initialize(document: document, device: device)
        let engine = OperationEngine(store: store, homeURL: home)
        let edit = ClientConfigurationEdit(file: .kiroMCP, keyPath: ["mcpServers", "memory", "disabled"], value: .bool(true))
        let plan = OperationPlan(kind: .configureMCP, title: "t", summary: "s", steps: [
            .init(kind: .editClientConfiguration, title: "e", detail: edit.summary,
                  destinationPath: file.path(percentEncoded: false), contents: try edit.encoded()),
        ])

        let receipt = await engine.execute(plan)

        #expect(receipt.results.first?.status == .failed)
        #expect(try String(contentsOf: elsewhere, encoding: .utf8) == #"{"mcpServers":{"memory":{"command":"gone.sh"}}}"#)
        #expect((try? FileManager.default.destinationOfSymbolicLink(atPath: file.path(percentEncoded: false))) != nil)
    }

    @Test func anOversizedConfigurationIsRefusedBeforeItIsLoaded() async throws {
        // The existing file is read bounded, so a file past the configuration
        // size limit is refused rather than read whole and measured after.
        let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
            .appending(path: "ClientConfigurationEditTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        let home = root.appending(path: "home", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: home.appending(path: ".kiro/settings"), withIntermediateDirectories: true)
        let file = home.appending(path: ".kiro/settings/mcp.json")
        // One byte past the limit is enough to trip the bounded read.
        let oversized = Data(repeating: UInt8(ascii: " "), count: BoundedFileAccess.maximumConfigurationBytes + 1)
        try oversized.write(to: file, options: .atomic)

        let document = try WorkspaceDocumentCoding.seal(.init(workspaceID: WorkspaceObjectID(), revision: .init(writerID: WorkspaceObjectID())))
        let device = DeviceWorkspaceState(workspaceID: document.workspaceID)
        let store = try WorkspaceRevisionStore(containerRoot: root.appending(path: "workspace"), workspaceID: document.workspaceID, deviceID: device.deviceID)
        try store.initialize(document: document, device: device)
        let engine = OperationEngine(store: store, homeURL: home)
        let edit = ClientConfigurationEdit(file: .kiroMCP, keyPath: ["mcpServers", "memory", "disabled"], value: .bool(true))
        let plan = OperationPlan(kind: .configureMCP, title: "t", summary: "s", steps: [
            .init(kind: .editClientConfiguration, title: "e", detail: edit.summary,
                  destinationPath: file.path(percentEncoded: false), contents: try edit.encoded()),
        ])

        let receipt = await engine.execute(plan)

        #expect(receipt.results.first?.status == .failed)
        // The file is left exactly as it was: nothing was rewritten.
        #expect(try Data(contentsOf: file).count == BoundedFileAccess.maximumConfigurationBytes + 1)
    }
}
