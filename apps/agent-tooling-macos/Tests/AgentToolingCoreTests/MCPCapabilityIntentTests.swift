import Foundation
import Testing

@testable import AgentToolingCore

private struct TemporaryWorkspace {
    let root: URL

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appending(path: "mcp-capability-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    func remove() {
        try? FileManager.default.removeItem(at: root)
    }
}

struct MCPCapabilityIntentTests {
    // MARK: Counting

    @Test func theRowSummaryOnlyExistsOnceALiveTestHasNamedTheTools() {
        var intent = MCPCapabilityIntent(serverID: "sentry")

        #expect(intent.summary == nil)

        intent.observe(toolNames: ["issues", "events", "projects", "releases"])
        #expect(intent.summary == "4/4 enabled")

        intent.setEnabled(false, tool: "releases")
        #expect(intent.summary == "3/4 enabled")
        #expect(intent.enabledCount == 3)
        #expect(intent.isEnabled("releases") == false)
        #expect(intent.isEnabled("issues"))
    }

    @Test func aToolWithNoRecordedDecisionCountsAsWanted() {
        var intent = MCPCapabilityIntent(serverID: "sentry")
        intent.observe(toolNames: ["a", "b"])

        #expect(intent.hasDecisions == false)
        #expect(intent.enabledCount == 2)

        intent.setEnabled(false, tool: "a")
        intent.setEnabled(true, tool: "a")
        #expect(intent.hasDecisions == false)
        #expect(intent.summary == "2/2 enabled")
    }

    @Test func aDecisionAboutAToolTheServerNoLongerOffersIsForgotten() {
        var intent = MCPCapabilityIntent(serverID: "sentry")
        intent.observe(toolNames: ["a", "b", "c"])
        intent.setEnabled(false, tool: "c")
        #expect(intent.summary == "2/3 enabled")

        intent.observe(toolNames: ["a", "b"])

        #expect(intent.disabledToolNames.isEmpty)
        #expect(intent.summary == "2/2 enabled")
    }

    @Test func toolNamesAreBoundedAndDeduplicated() {
        var intent = MCPCapabilityIntent(serverID: "sentry")
        let oversized = String(repeating: "x", count: MCPCapabilityIntent.maximumToolNameCharacters + 40)
        intent.observe(toolNames: ["b", "a", "a", "  spaced  ", "", oversized])

        #expect(
            intent.knownToolNames == ["a", "b", "spaced", String(repeating: "x", count: MCPCapabilityIntent.maximumToolNameCharacters)])
        intent.setEnabled(false, tool: "")
        #expect(intent.disabledToolNames.isEmpty)
    }

    // MARK: Persistence

    @Test func intentRoundTripsThroughTheWorkspaceFile() throws {
        let workspace = try TemporaryWorkspace()
        defer { workspace.remove() }
        let store = MCPCapabilityIntentStore(workspaceRootURL: workspace.root)

        #expect(try store.load().servers.isEmpty)

        var record = try store.load()
        var sentry = MCPCapabilityIntent(serverID: "sentry")
        sentry.observe(toolNames: ["issues", "events", "projects", "releases"])
        sentry.setEnabled(false, tool: "releases")
        record.update(sentry)
        var linear = MCPCapabilityIntent(serverID: "linear")
        linear.observe(toolNames: ["search"])
        record.update(linear)
        try store.save(record)

        let reloaded = try store.load()

        #expect(reloaded.version == MCPCapabilityIntentRecord.currentVersion)
        #expect(reloaded.servers.map(\.serverID) == ["linear", "sentry"])
        #expect(reloaded.intent(for: "sentry")?.summary == "3/4 enabled")
        #expect(reloaded.intent(for: "sentry")?.disabledToolNames == ["releases"])
        #expect(reloaded.intent(for: "linear")?.summary == "1/1 enabled")
        #expect(reloaded.intent(for: "missing") == nil)
    }

    @Test func aServerWithNothingRecordedIsDroppedRatherThanStoredEmpty() throws {
        let workspace = try TemporaryWorkspace()
        defer { workspace.remove() }
        let store = MCPCapabilityIntentStore(workspaceRootURL: workspace.root)
        var record = MCPCapabilityIntentRecord()
        record.update(MCPCapabilityIntent(serverID: "empty"))
        try store.save(record)

        #expect(try store.load().servers.isEmpty)
    }

    @Test func removingAServerClearsItsRecordedChoices() throws {
        let workspace = try TemporaryWorkspace()
        defer { workspace.remove() }
        let store = MCPCapabilityIntentStore(workspaceRootURL: workspace.root)
        var record = MCPCapabilityIntentRecord()
        var intent = MCPCapabilityIntent(serverID: "sentry")
        intent.observe(toolNames: ["issues"])
        record.update(intent)
        try store.save(record)

        record.remove(serverID: "sentry")
        try store.save(record)

        #expect(try store.load().servers.isEmpty)
    }

    @Test func theRecordFileIsPrivateToThisAccount() throws {
        let workspace = try TemporaryWorkspace()
        defer { workspace.remove() }
        let store = MCPCapabilityIntentStore(workspaceRootURL: workspace.root)
        var record = MCPCapabilityIntentRecord()
        var intent = MCPCapabilityIntent(serverID: "sentry")
        intent.observe(toolNames: ["issues"])
        record.update(intent)
        try store.save(record)

        let attributes = try FileManager.default.attributesOfItem(atPath: store.fileURL.path(percentEncoded: false))
        let permissions = attributes[.posixPermissions] as? NSNumber

        #expect(permissions?.uint16Value == 0o600)
    }

    @Test func corruptAndUnsupportedRecordsFailWithoutCrashing() throws {
        let workspace = try TemporaryWorkspace()
        defer { workspace.remove() }
        let store = MCPCapabilityIntentStore(workspaceRootURL: workspace.root)

        try Data("this is not json".utf8).write(to: store.fileURL)
        #expect(throws: MCPCapabilityIntentError.unreadable) { try store.load() }

        try Data(#"{"version":99,"servers":[]}"#.utf8).write(to: store.fileURL)
        #expect(throws: MCPCapabilityIntentError.unsupportedVersion(99)) { try store.load() }

        let oversized = Data(repeating: 0x20, count: MCPCapabilityIntentStore.maximumFileBytes + 1)
        try oversized.write(to: store.fileURL)
        #expect(throws: MCPCapabilityIntentError.recordTooLarge) { try store.load() }
    }

    @Test func theEnforcementNoticeSaysExactlyWhatTheSettingDoes() {
        let notice = MCPCapabilityIntent.enforcementNotice

        #expect(notice.contains("not an enforced restriction"))
        #expect(notice.contains("does not write a per-tool rule into any client"))
    }
}
