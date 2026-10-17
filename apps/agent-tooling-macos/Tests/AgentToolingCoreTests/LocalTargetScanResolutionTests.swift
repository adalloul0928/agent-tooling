import Foundation
import Testing

@testable import AgentToolingCore

/// The scan probes the tool where the locator found it — never a bare name
/// through the app's inherited PATH — and a located tool keeps its native
/// inventory. Both halves regressed silently once; this pins them.
struct LocalTargetScanResolutionTests {
    /// Records every launch so the test can say exactly what was run.
    private actor RecordingRunner: CommandRunning {
        private(set) var launches: [(executable: String, arguments: [String])] = []

        func run(executable: String, arguments: [String], currentDirectory: URL?) async throws -> CommandOutput {
            launches.append((executable, arguments))
            if arguments == ["--version"] {
                return CommandOutput(status: 0, standardOutput: "9.9.9", standardError: "")
            }
            if arguments == ["plugin", "list", "--json"] || arguments == ["mcp", "list", "--json"] {
                return CommandOutput(status: 0, standardOutput: #"{"installed": [], "available": []}"#, standardError: "")
            }
            return CommandOutput(status: 0, standardOutput: "{}", standardError: "")
        }

        func recorded() -> [(executable: String, arguments: [String])] { launches }
    }

    @Test func theProbeRunsALocatedAbsolutePathAndNativeInventoryStillFires() async throws {
        let home = FileManager.default.temporaryDirectory
            .appending(path: "scan-resolution-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: home) }
        let bin = home.appending(path: ".local/bin", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        let codex = bin.appending(path: "codex")
        try Data("#!/bin/sh\n".utf8).write(to: codex)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: codex.path)

        let runner = RecordingRunner()
        let observation = await CodexAdapter().scan(homeURL: home, runner: runner)

        #expect(observation.commandAvailable)
        #expect(observation.version == "9.9.9")
        let launches = await runner.recorded()
        // Every launch used a located ABSOLUTE path — never the bare name that
        // would fall through to whatever PATH this process inherited. The
        // exact winner can differ per Mac (a fixed global root may also hold a
        // codex), so the assertion is on the property, not the path.
        #expect(!launches.isEmpty)
        #expect(launches.allSatisfy { $0.executable.hasPrefix("/") })
        // The located tool keeps its native inventory: switching inventory on
        // the executable STRING is how it silently vanished once.
        #expect(launches.contains { $0.arguments == ["plugin", "list", "--json"] })
    }

    @Test func configurationFilesWithoutARunnableToolAreNotACommand() async throws {
        let home = FileManager.default.temporaryDirectory
            .appending(path: "scan-files-only-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: home) }
        let skills = home.appending(path: ".claude/skills/leftover", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: skills, withIntermediateDirectories: true)

        // A runner that refuses everything, the way a missing tool would.
        struct RefusingRunner: CommandRunning {
            func run(executable: String, arguments: [String], currentDirectory: URL?) async throws -> CommandOutput {
                CommandOutput(status: 127, standardOutput: "", standardError: "not found")
            }
        }
        let observation = await ClaudeCodeAdapter().scan(homeURL: home, runner: RefusingRunner())

        #expect(observation.installed)
        #expect(!observation.commandAvailable)
    }

    @Test func aToolPresentButNotAnsweringVersionIsAvailableWithAnUnknownVersionNote() async throws {
        let home = FileManager.default.temporaryDirectory
            .appending(path: "scan-unanswered-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: home) }
        let bin = home.appending(path: ".local/bin", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        let codex = bin.appending(path: "codex")
        try Data("#!/bin/sh\n".utf8).write(to: codex)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: codex.path)

        // A shim that runs (so not 126/127) but exits non-zero for --version —
        // e.g. a Toolbox stub under a redirected HOME.
        struct UnansweringRunner: CommandRunning {
            func run(executable: String, arguments: [String], currentDirectory: URL?) async throws -> CommandOutput {
                if arguments == ["--version"] {
                    return CommandOutput(status: 3, standardOutput: "", standardError: "not signed in")
                }
                return CommandOutput(status: 0, standardOutput: "{}", standardError: "")
            }
        }
        let observation = await CodexAdapter().scan(homeURL: home, runner: UnansweringRunner())

        // Present, but the version is unknown — not missing, not unsupported.
        #expect(observation.commandAvailable)
        #expect(observation.version == nil)
        #expect(observation.notes.contains {
            $0.contains("did not answer --version (exit 3)") && $0.contains("version is unknown")
        }, "\(observation.notes)")
    }
}
