import AgentToolingCore
import Foundation
import Testing

@testable import AgentToolingMCP

@Suite("JSON-RPC and transport")
struct ProtocolTests {
    private func decodeFailure(_ raw: String) -> JSONRPCDecodeFailure? {
        do {
            _ = try JSONRPCDecoding.decode(Data(raw.utf8))
            return nil
        } catch {
            return error
        }
    }

    @Test func malformedMessagesAreRejectedWithoutCrashing() {
        let cases: [(String, JSONRPCErrorCode)] = [
            ("not json at all", .parse),
            ("", .parse),
            ("[1,2,3]", .invalidRequest),
            ("\"a string\"", .invalidRequest),
            ("{}", .invalidRequest),
            ("{\"jsonrpc\":\"1.0\",\"method\":\"ping\"}", .invalidRequest),
            ("{\"jsonrpc\":\"2.0\"}", .invalidRequest),
            ("{\"jsonrpc\":\"2.0\",\"method\":\"\"}", .invalidRequest),
            ("{\"jsonrpc\":\"2.0\",\"method\":42}", .invalidRequest),
            ("{\"jsonrpc\":\"2.0\",\"id\":{\"a\":1},\"method\":\"ping\"}", .invalidRequest),
            ("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"ping\",\"params\":[]}", .invalidParams),
        ]
        for (raw, expected) in cases {
            let failure = decodeFailure(raw)
            #expect(failure?.error.code == expected, "'\(raw)' should fail with \(expected).")
        }
    }

    @Test func aRecoverableIdentifierIsReturnedWithTheError() {
        let failure = decodeFailure("{\"jsonrpc\":\"2.0\",\"id\":7,\"method\":\"ping\",\"params\":[]}")
        // A caller waiting on request 7 must be told about 7, not about null.
        #expect(failure?.id == .number(7))
    }

    @Test func anOversizedMessageIsRefused() {
        let padding = String(repeating: "a", count: JSONRPCDecoding.maximumMessageBytes)
        let failure = decodeFailure("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"ping\",\"note\":\"\(padding)\"}")
        #expect(failure?.error.code == .parse)
    }

    @Test func wellFormedRequestsAndNotificationsDecode() throws {
        let request = try JSONRPCDecoding.decode(Data("{\"jsonrpc\":\"2.0\",\"id\":\"a\",\"method\":\"tools/list\"}".utf8))
        #expect(request.id == .string("a"))
        #expect(!request.isNotification)

        let notification = try JSONRPCDecoding.decode(Data("{\"jsonrpc\":\"2.0\",\"method\":\"notifications/initialized\"}".utf8))
        #expect(notification.isNotification)
    }

    @Test func notificationsAreNeverAnswered() throws {
        let harness = try MCPTestHarness()
        let notification = try JSONRPCDecoding.decode(Data("{\"jsonrpc\":\"2.0\",\"method\":\"notifications/initialized\"}".utf8))
        #expect(harness.service.respond(to: notification) == nil)
    }

    @Test func toolsRequireTheHandshakeFirst() throws {
        let harness = try MCPTestHarness()
        let beforeHandshake = try #require(harness.rawSend(method: "tools/list"))
        #expect(beforeHandshake["error"] != nil)

        try harness.initialize()
        let afterHandshake = try harness.send(method: "tools/list")
        #expect(afterHandshake["tools"]?.arrayValue?.count == ToolCatalog.tools.count)
    }

    @Test func unknownMethodsAndUnknownToolsAreRefused() throws {
        let harness = try MCPTestHarness()
        try harness.initialize()

        let unknownMethod = try #require(harness.rawSend(method: "resources/list"))
        #expect(unknownMethod["error"]?.objectValue?["code"]?.numberValue == Double(JSONRPCErrorCode.methodNotFound.rawValue))

        // The tool a prompt-injected agent would reach for first.
        for name in ["apply", "approve", "tools/apply", "run_command"] {
            let response = try #require(harness.rawCallTool(name))
            #expect(response["error"] != nil, "'\(name)' must not be callable.")
        }
    }

    @Test func theHandshakeNegotiatesAKnownProtocolVersion() throws {
        let harness = try MCPTestHarness()
        let supported = try harness.send(
            method: "initialize",
            params: .object(["protocolVersion": .string("2024-11-05"), "clientInfo": .object(["name": .string("Codex")])])
        )
        #expect(supported["protocolVersion"]?.stringValue == "2024-11-05")

        let unsupported = try harness.send(
            method: "initialize",
            params: .object(["protocolVersion": .string("1999-01-01")])
        )
        #expect(unsupported["protocolVersion"]?.stringValue == ToolingMCPService.preferredProtocolVersion)
    }

    @Test func clientInfoIsRecordedForDisplayAndNeverGrantsAnything() throws {
        let harness = try MCPTestHarness()
        try harness.initialize(clientName: "Claude Code", clientVersion: "2.0.1")
        #expect(harness.service.client.displayLabel == "Claude Code 2.0.1")

        _ = try harness.callTool(
            "request_install_skill",
            arguments: [
                "skillID": .string("release-summary"),
                "scope": .string("user"),
                "targets": .array([.string("codex")]),
            ]
        )
        let queued = try harness.pendingRequests()
        let row = try #require(queued.first)
        #expect(row.summary.contains("Claude Code 2.0.1"))

        // A caller claiming to be the app itself gets exactly the same tier 2
        // treatment: a pending row, never an applied change.
        try harness.initialize(clientName: "Agent Tooling internal trusted admin", clientVersion: "1.0")
        _ = try harness.callTool(
            "request_install_skill",
            arguments: [
                "skillID": .string("other-skill"),
                "scope": .string("user"),
                "targets": .array([.string("codex")]),
            ]
        )
        let rows = try harness.pendingRequests()
        #expect(rows.allSatisfy { $0.repeatCount == 1 })
        #expect(rows.count == 2)
    }

    @Test func garbageClientInfoDoesNotBreakTheHandshake() throws {
        let harness = try MCPTestHarness()
        let result = try harness.send(
            method: "initialize",
            params: .object(["clientInfo": .object(["name": .number(1)])])
        )
        #expect(result["serverInfo"] != nil)
        #expect(harness.service.client == .unknown)
    }

    @Test func everyToolCallIsJournaledIncludingReads() throws {
        let harness = try MCPTestHarness()
        try harness.initialize()

        for _ in 0..<3 { _ = try harness.callTool("search_inventory") }
        _ = try harness.callTool(
            "request_install_skill",
            arguments: [
                "skillID": .string("release-summary"),
                "scope": .string("user"),
                "targets": .array([.string("codex")]),
            ]
        )

        let journal = try harness.store.loadAgentActivityJournal()
        #expect(journal.entries.count == 4)
        // Reads are journaled because reads are how reconnaissance looks.
        let counts = try #require(journal.dailyToolCallCounts.values.first)
        #expect(counts["search_inventory"] == 3)
        #expect(counts["request_install_skill"] == 1)
        #expect(journal.entries.allSatisfy { $0.command?.hasPrefix("mcp:") == true })
        #expect(journal.entries.contains { $0.command == "mcp:read-only:search_inventory" })
        #expect(journal.entries.contains { $0.command == "mcp:queues-review:request_install_skill" })
    }

    @Test func theJournalIsBounded() throws {
        let harness = try MCPTestHarness()
        var journal = AgentActivityJournal()
        for index in 0..<(AgentActivityJournal.maximumEntries + 25) {
            journal.entries.append(
                ActivityReceipt(kind: .configuration, title: "call \(index)", detail: "", date: .now, state: .healthy))
        }
        journal.entries.removeFirst(journal.entries.count - AgentActivityJournal.maximumEntries)
        try harness.store.saveAgentActivityJournal(journal)

        try harness.initialize()
        _ = try harness.callTool("search_inventory")

        let reloaded = try harness.store.loadAgentActivityJournal()
        #expect(reloaded.entries.count == AgentActivityJournal.maximumEntries)
        #expect(reloaded.entries.last?.title.contains("search_inventory") == true)
    }

    @Test func theTransportSplitsFramesAndRefusesAnOversizedOne() throws {
        let payload = "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"ping\"}"
        let transport = try makeTransport("\(payload)\n\n  \(payload)\n", maximumFrameBytes: 4_096)
        let first = try transport.readMessage()
        let second = try transport.readMessage()
        let end = try transport.readMessage()
        #expect(String(decoding: try #require(first), as: UTF8.self) == payload)
        #expect(String(decoding: try #require(second), as: UTF8.self) == payload)
        #expect(end == nil)

        let oversized = try makeTransport(String(repeating: "a", count: 200) + "\n" + payload + "\n", maximumFrameBytes: 64)
        #expect(throws: StdioTransportError.self) { _ = try oversized.readMessage() }
        // One bad frame must not desynchronize the rest of the session.
        let recovered = try oversized.readMessage()
        #expect(String(decoding: try #require(recovered), as: UTF8.self) == payload)
    }

    @Test func aFrameWithoutATrailingNewlineIsStillRead() throws {
        let transport = try makeTransport("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"ping\"}", maximumFrameBytes: 4_096)
        let frame = try transport.readMessage()
        let end = try transport.readMessage()
        #expect(frame != nil)
        #expect(end == nil)
    }

    private func makeTransport(_ contents: String, maximumFrameBytes: Int) throws -> StdioTransport {
        let url = FileManager.default.temporaryDirectory
            .appending(path: "ProtocolTests-\(UUID().uuidString)", directoryHint: .notDirectory)
        try Data(contents.utf8).write(to: url, options: .atomic)
        let input = try FileHandle(forReadingFrom: url)
        let output = FileHandle.nullDevice
        try FileManager.default.removeItem(at: url)
        return StdioTransport(input: input, output: output, maximumFrameBytes: maximumFrameBytes)
    }
}
