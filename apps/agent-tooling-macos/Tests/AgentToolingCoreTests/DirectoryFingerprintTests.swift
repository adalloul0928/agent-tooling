import AgentToolingTestSupport
import Foundation
import Testing

@testable import AgentToolingCore

@Suite("Directory fingerprints")
struct DirectoryFingerprintTests {
    /// The walk names every item under the folder's real path. A folder
    /// reached through a link above it, or spelled in another case, is the
    /// same folder and has the same fingerprint; a root that is itself a link
    /// is still refused, because the folder named is not the one walked.
    @Test func aFolderReachedThroughALinkOrSpelledInAnotherCaseHasItsRealFingerprint() throws {
        let fixture = try TemporaryFolder("directory-fingerprint-spellings").url
        defer { try? FileManager.default.removeItem(at: fixture) }
        let real = fixture.appending(path: "volume/skill", directoryHint: .isDirectory)
        try write(real.appending(path: "SKILL.md"), "reviewed")
        try write(real.appending(path: "folder/notes.md"), "notes")
        try FileManager.default.createDirectory(at: fixture.appending(path: "home"), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(
            at: fixture.appending(path: "home/workplace"), withDestinationURL: fixture.appending(path: "volume"))
        let expected = try DirectoryFingerprint.sha256(of: real)

        #expect(try DirectoryFingerprint.sha256(of: fixture.appending(path: "home/workplace/skill")) == expected)
        let otherCase = real.path(percentEncoded: false).uppercased()
        if FileManager.default.fileExists(atPath: otherCase) {
            #expect(try DirectoryFingerprint.sha256(of: URL(fileURLWithPath: otherCase, isDirectory: true)) == expected)
        }

        try FileManager.default.createSymbolicLink(at: fixture.appending(path: "linked-skill"), withDestinationURL: real)
        let refusal = #expect(throws: DirectoryFingerprintError.self) {
            _ = try DirectoryFingerprint.sha256(of: fixture.appending(path: "linked-skill"))
        }
        guard case .unsafeItem = refusal else {
            Issue.record("A root that is itself a link is an unsafe item, not \(String(describing: refusal)).")
            return
        }
    }

    /// A file rewritten in place while it is hashed, at the same size, must
    /// not pass as unchanged: the check after the read has to look at the
    /// disk again, not at the values the walk fetched.
    @Test func aSameSizeRewriteWhileHashingIsRefused() throws {
        let fixture = try TemporaryFolder("directory-fingerprint-rewrite").url
        defer { try? FileManager.default.removeItem(at: fixture) }
        let file = fixture.appending(path: "SKILL.md")
        try write(file, "reviewed")

        let refusal = #expect(throws: DirectoryFingerprintError.self) {
            _ = try DirectoryFingerprint.sha256(
                of: fixture,
                afterReading: { _ in
                    let handle = try FileHandle(forWritingTo: file)
                    try handle.write(contentsOf: Data("rewrote!".utf8))
                    try handle.close()
                })
        }
        #expect(Self.isChangedWhileReading(refusal), "\(String(describing: refusal))")
    }

    /// A save that swaps in a new file of the same size leaves a different
    /// file at the path, which the check must see.
    @Test func aSameSizeReplacementWhileHashingIsRefused() throws {
        let fixture = try TemporaryFolder("directory-fingerprint-replace").url
        defer { try? FileManager.default.removeItem(at: fixture) }
        let file = fixture.appending(path: "SKILL.md")
        try write(file, "reviewed")

        let refusal = #expect(throws: DirectoryFingerprintError.self) {
            _ = try DirectoryFingerprint.sha256(
                of: fixture,
                afterReading: { _ in try "replaced".write(to: file, atomically: true, encoding: .utf8) })
        }
        #expect(Self.isChangedWhileReading(refusal), "\(String(describing: refusal))")
    }

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
        let document = try WorkspaceDocumentCoding.seal(.init(
            workspaceID: WorkspaceObjectID(), revision: .init(writerID: WorkspaceObjectID())))
        let device = DeviceWorkspaceState(workspaceID: document.workspaceID)
        let workspace = try WorkspaceRevisionStore(
            containerRoot: root.appending(path: "workspace", directoryHint: .isDirectory),
            workspaceID: document.workspaceID, deviceID: device.deviceID)
        try workspace.initialize(document: document, device: device)
        try workspace.prepareManagedDirectories()
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

    private static func isChangedWhileReading(_ error: DirectoryFingerprintError?) -> Bool {
        if case .changedWhileReading = error { return true }
        return false
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
