import Foundation
import Testing

@testable import AgentToolingCore

@Suite("Directory fingerprints")
struct DirectoryFingerprintTests {
    @Test func executableModeChangesTheFingerprintWithoutChangingFileBytes() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let script = root.appending(path: "helper.sh", directoryHint: .notDirectory)
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: script)
        try setPermissions(0o600, on: script)
        let reviewed = try DirectoryFingerprint.sha256(of: root)

        try setPermissions(0o700, on: script)

        #expect(try DirectoryFingerprint.sha256(of: root) != reviewed)
        #expect(try Data(contentsOf: script) == Data("#!/bin/sh\nexit 0\n".utf8))
    }

    @Test func nonExecutablePrivacyNormalizationDoesNotChangeTheFingerprint() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let definition = root.appending(path: "SKILL.md", directoryHint: .notDirectory)
        try Data("reviewed".utf8).write(to: definition)
        try setPermissions(0o644, on: definition)
        let reviewed = try DirectoryFingerprint.sha256(of: root)

        try setPermissions(0o600, on: definition)

        #expect(try DirectoryFingerprint.sha256(of: root) == reviewed)
    }

    @Test func reviewedCopyRejectsAnExecutableModeChange() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let workspace = try WorkspaceStore(rootURL: root.appending(path: "workspace", directoryHint: .isDirectory))
        let home = root.appending(path: "home", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        let source = workspace.libraryURL.appending(path: "packages/example", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        let script = source.appending(path: "helper.sh", directoryHint: .notDirectory)
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: script)
        try setPermissions(0o600, on: script)
        let reviewed = try DirectoryFingerprint.sha256(of: source)
        try setPermissions(0o700, on: script)
        let destination = home.appending(path: ".agents/skills/example", directoryHint: .isDirectory)
        let engine = OperationEngine(store: workspace, runner: FingerprintTestRunner(), homeURL: home)

        let receipt = await engine.execute(
            OperationPlan(
                kind: .installSkill,
                title: "Executable mode changed",
                summary: "The reviewed source must remain unchanged.",
                steps: [
                    OperationStep(
                        kind: .copyDirectory,
                        title: "Copy",
                        detail: "Must fail",
                        sourcePath: source.path(percentEncoded: false),
                        sourceFingerprint: reviewed,
                        destinationPath: destination.path(percentEncoded: false)
                    )
                ]
            )
        )

        #expect(receipt.results.first?.status == .failed)
        #expect(receipt.results.first?.output.contains("changed after it was reviewed") == true)
        #expect(!FileManager.default.fileExists(atPath: destination.path(percentEncoded: false)))
    }

    private func temporaryDirectory() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appending(
            path: "DirectoryFingerprintTests-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func setPermissions(_ permissions: Int, on url: URL) throws {
        try FileManager.default.setAttributes(
            [.posixPermissions: permissions],
            ofItemAtPath: url.path(percentEncoded: false)
        )
    }
}

private struct FingerprintTestRunner: CommandRunning {
    func run(executable _: String, arguments _: [String], currentDirectory _: URL?) async throws -> CommandOutput {
        CommandOutput(status: 0, standardOutput: "", standardError: "")
    }
}
