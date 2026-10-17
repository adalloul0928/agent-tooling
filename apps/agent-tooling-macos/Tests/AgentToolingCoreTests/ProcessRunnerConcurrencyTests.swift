import Foundation
import Testing

@testable import AgentToolingCore

struct ProcessRunnerConcurrencyTests {
    @Test func concurrentInputAndOutputDoNotBlockConcurrencyWorkers() async throws {
        let input = Data(repeating: 0x61, count: 131_072)
        try await withThrowingTaskGroup(of: Void.self) { group in
            for _ in 0..<32 {
                group.addTask {
                    let output = try await ProcessCommandRunner(timeout: .seconds(3)).run(
                        executable: "/bin/cat", arguments: [], standardInput: input)
                    #expect(output.status == 0)
                    #expect(output.standardOutput.utf8.count == input.count)
                    #expect(output.standardOutput.utf8.allSatisfy { $0 == 0x61 })
                    #expect(output.standardError.isEmpty)
                }
            }
            try await group.waitForAll()
        }
    }

    @Test func bothOutputStreamsAreDrainedAfterTheirCaptureLimits() async throws {
        let output = try await ProcessCommandRunner(timeout: .seconds(3)).run(
            executable: "/bin/sh",
            arguments: ["-c", "/usr/bin/head -c 1114112 /dev/zero; /usr/bin/head -c 1114112 /dev/zero >&2"])
        let marker = "\n[output truncated after 1048576 bytes]"
        #expect(output.status == 0)
        for captured in [output.standardOutput, output.standardError] {
            #expect(captured.hasSuffix(marker))
            #expect(captured.utf8.count == 1_048_576 + marker.utf8.count)
        }
    }
}
