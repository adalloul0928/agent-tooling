import Foundation
import Testing

@testable import AgentToolingCore

/// Framing and lifecycle for the stdio transport, exercised without starting a
/// process. The reader is the piece a hostile or broken server touches first.
struct MCPStdioFramingTests {
    @Test func newlineFramingSurvivesChunkBoundaries() async throws {
        let reader = MCPLineReader(maximumMessageBytes: 4_096)
        reader.append(Data(#"{"jsonrpc":"2.0","id":1,"#.utf8))
        reader.append(Data("\"result\":{}}\r\n{\"jsonrpc\":\"2.0\",\"id\":2,\"result\":{}}\n".utf8))
        reader.finish()

        let first = try await reader.next()
        let second = try await reader.next()
        let end = try await reader.next()

        #expect(first.map { MCPJSONRPC.responseIdentifier(in: $0) } == 1)
        #expect(second.map { MCPJSONRPC.responseIdentifier(in: $0) } == 2)
        #expect(end == nil)
    }

    @Test func blankLinesAreSkippedRatherThanDeliveredAsMessages() async throws {
        let reader = MCPLineReader(maximumMessageBytes: 4_096)
        reader.append(Data("\n\n\n".utf8))
        reader.append(Data("{}\n".utf8))
        reader.finish()

        #expect(try await reader.next() == Data("{}".utf8))
        #expect(try await reader.next() == nil)
    }

    @Test func aWaiterIsResumedWhenTheLineArrivesLater() async throws {
        let reader = MCPLineReader(maximumMessageBytes: 4_096)
        let pending = Task { try await reader.next() }
        try await Task.sleep(for: .milliseconds(10))
        reader.append(Data("{\"late\":true}\n".utf8))

        #expect(try await pending.value == Data("{\"late\":true}".utf8))
    }

    @Test func aServerThatNeverSendsANewlineIsCutOffAtTheSizeLimit() async throws {
        let reader = MCPLineReader(maximumMessageBytes: 64)
        reader.append(Data(String(repeating: "a", count: 200).utf8))

        await #expect(throws: MCPLiveTestError.responseTooLarge) { try await reader.next() }
    }

    @Test func cancellingAReadStopsWaitingWithACancelledError() async throws {
        let reader = MCPLineReader(maximumMessageBytes: 4_096)
        let pending = Task { try await reader.next() }
        try await Task.sleep(for: .milliseconds(10))
        pending.cancel()

        await #expect(throws: MCPLiveTestError.cancelled) { try await pending.value }
    }

    @Test func aFailedReaderStaysFailedForEveryLaterRead() async throws {
        let reader = MCPLineReader(maximumMessageBytes: 4_096)
        reader.append(Data("{}\n".utf8))
        reader.fail(.cancelled)

        await #expect(throws: MCPLiveTestError.cancelled) { try await reader.next() }
        await #expect(throws: MCPLiveTestError.cancelled) { try await reader.next() }
    }

    @Test func aStdioChannelThatWasStoppedNeverStartsAProcess() async throws {
        let channel = MCPStdioTestChannel(
            executableURL: URL(fileURLWithPath: "/nonexistent/should-never-run"),
            arguments: [],
            environment: [:]
        )
        await channel.shutdown()

        await #expect(throws: MCPLiveTestError.cancelled) {
            _ = try await channel.send(request: Data("{}".utf8), id: 1)
        }
    }

    @Test func aStdioChannelRefusesATargetThatIsNotAProcess() async throws {
        let httpTarget = try MCPTestConnectionPolicy.resolveHTTP("https://mcp.example.com/rpc")

        #expect(throws: MCPLiveTestError.self) { try MCPStdioTestChannel(target: httpTarget) }
        #expect(throws: MCPLiveTestError.self) {
            try MCPHTTPTestChannel(target: .stdio(executableURL: URL(fileURLWithPath: "/bin/true"), arguments: []))
        }
    }

    @Test func boundedDiagnosticsNeverGrowPastTheirLimit() {
        let buffer = MCPBoundedTextBuffer(limit: 16)
        buffer.append(String(repeating: "x", count: 100))
        buffer.note("more")

        #expect(buffer.text().count == 16)
    }
}
