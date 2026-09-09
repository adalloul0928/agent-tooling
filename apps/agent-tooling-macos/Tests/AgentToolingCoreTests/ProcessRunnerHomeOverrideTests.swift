import Foundation
import Testing

@testable import AgentToolingCore

struct ProcessRunnerHomeOverrideTests {
    @Test func explicitHomeControlsChildHomeAndPathResolution() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "process-runner-home-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let home = root.appending(path: "fixture-home")
        let bin = home.appending(path: ".local/bin")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        let command = bin.appending(path: "fixture-command")
        try Data("#!/bin/sh\nprintf fixture-path\n".utf8).write(to: command)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: command.path)
        let runner = ProcessCommandRunner(homeURL: home)

        let homeResult = try await runner.run(executable: "/usr/bin/printenv", arguments: ["HOME"])
        let pathResult = try await runner.run(executable: "fixture-command", arguments: [])

        #expect(homeResult.status == 0)
        #expect(homeResult.standardOutput.trimmingCharacters(in: .whitespacesAndNewlines) == home.path)
        #expect(pathResult.status == 0)
        #expect(pathResult.standardOutput.trimmingCharacters(in: .whitespacesAndNewlines) == "fixture-path")
    }

    @Test func defaultHomeBehaviorStillUsesCurrentUserHome() async throws {
        let runner = ProcessCommandRunner()
        let result = try await runner.run(executable: "/usr/bin/printenv", arguments: ["HOME"])

        #expect(result.status == 0)
        #expect(result.standardOutput.trimmingCharacters(in: .whitespacesAndNewlines)
            == FileManager.default.homeDirectoryForCurrentUser.path)
    }
}
