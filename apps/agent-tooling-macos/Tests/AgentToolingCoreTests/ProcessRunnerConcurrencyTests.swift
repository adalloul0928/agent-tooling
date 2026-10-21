import Foundation
import Testing

@testable import AgentToolingCore

struct ProcessRunnerConcurrencyTests {
    @Test func concurrentInputAndOutputDoNotBlockConcurrencyWorkers() async throws {
        let input = Data(repeating: 0x61, count: 131_072)
        try await withThrowingTaskGroup(of: Void.self) { group in
            for _ in 0..<32 {
                group.addTask {
                    // Only a hang should run out of this time: at the start of
                    // a parallel run, a command that ends at once can wait
                    // seconds for its task to resume.
                    let output = try await ProcessCommandRunner(timeout: .seconds(30)).run(
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
        // A stream left undrained hangs the command; only that should run out
        // of this time, not a parallel run's slow start.
        let output = try await ProcessCommandRunner(timeout: .seconds(30)).run(
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
