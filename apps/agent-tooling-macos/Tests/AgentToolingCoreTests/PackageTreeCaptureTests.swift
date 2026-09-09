import Darwin
import Foundation
import Testing

@testable import AgentToolingCore

struct PackageTreeCaptureTests {
    @Test func rejectsRootPathsThatWouldBeTruncatedByPOSIXCalls() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let truncated = URL(fileURLWithPath: root.path + "\u{0}ignored")
        await #expect(throws: PackageTreeError.invalidPath) {
            _ = try await PackageTreeCapture().capture(directory: truncated)
        }
    }

    @Test func rejectsNonFileURLsBeforeStartingCapture() async {
        let remote = URL(string: "https://example.com/package")!
        await #expect(throws: PackageTreeError.invalidPath) {
            _ = try await PackageTreeCapture().capture(directory: remote)
        }
    }

    @Test func capturesCompletePackageBytesEmptyDirectoriesAndExecutableMode() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        try write("# Skill\n", to: root.appending(path: "skills/demo/SKILL.md"))
        try write("{\"name\":\"demo\"}\n", to: root.appending(path: ".codex-plugin/plugin.json"))
        try write("resource", to: root.appending(path: "assets/.hidden"))
        try FileManager.default.createDirectory(at: root.appending(path: "empty"), withIntermediateDirectories: true)
        let script = root.appending(path: "scripts/run.sh")
        try write("#!/bin/sh\n", to: script)
        #expect(chmod(script.path, mode_t(0o755)) == 0)

        let captured = try await PackageTreeCapture().capture(directory: root)
        #expect(captured.totalFileBytes == 42)
        #expect(Set(captured.entries.map(\.relativePath)) == [
            ".codex-plugin", ".codex-plugin/plugin.json", "assets", "assets/.hidden", "empty",
            "scripts", "scripts/run.sh", "skills", "skills/demo", "skills/demo/SKILL.md",
        ])
        #expect(file(captured, "skills/demo/SKILL.md") == Data("# Skill\n".utf8))
        #expect(executable(captured, "scripts/run.sh") == true)
        #expect(captured.entries.contains { $0.relativePath == "empty" && isDirectory($0) })
    }

    @Test func excludesOnlyRootGitMetadataAndReportsIt() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        try write("ignored", to: root.appending(path: ".git/config"))
        try write("kept", to: root.appending(path: ".github/workflows/test.yml"))

        let captured = try await PackageTreeCapture().capture(directory: root)
        #expect(captured.excludedRootGitMetadata)
        #expect(!captured.entries.contains { $0.relativePath == ".git" || $0.relativePath.hasPrefix(".git/") })
        #expect(file(captured, ".github/workflows/test.yml") == Data("kept".utf8))
    }

    @Test func nestedGitMetadataIsRejectedByCanonicalFactory() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        try write("not administrative root metadata", to: root.appending(path: "vendor/.git/config"))
        await #expect(throws: PackageTreeError.self) {
            _ = try await PackageTreeCapture().capture(directory: root)
        }
    }

    @Test func preservesSafeInternalRelativeSymbolicLinkWithoutFollowingIt() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        try write("payload", to: root.appending(path: "data/value.txt"))
        try FileManager.default.createSymbolicLink(
            atPath: root.appending(path: "current").path,
            withDestinationPath: "data/value.txt"
        )

        let captured = try await PackageTreeCapture().capture(directory: root)
        #expect(link(captured, "current") == "data/value.txt")
        #expect(file(captured, "data/value.txt") == Data("payload".utf8))
    }

    @Test func rejectsEscapingDanglingAndCyclicLinks() async throws {
        for links in [
            [("escape", "../outside")],
            [("dangling", "missing")],
            [("one", "two"), ("two", "one")],
        ] {
            let root = try temporaryDirectory()
            defer { try? FileManager.default.removeItem(at: root) }
            for (name, target) in links {
                try FileManager.default.createSymbolicLink(
                    atPath: root.appending(path: name).path,
                    withDestinationPath: target
                )
            }
            await #expect(throws: PackageTreeError.self) {
                _ = try await PackageTreeCapture().capture(directory: root)
            }
        }
    }

    @Test func rejectsRootSymlinkAndSpecialFiles() async throws {
        let target = try temporaryDirectory()
        let container = try temporaryDirectory()
        defer {
            try? FileManager.default.removeItem(at: target)
            try? FileManager.default.removeItem(at: container)
        }
        let linkedRoot = container.appending(path: "linked")
        try FileManager.default.createSymbolicLink(at: linkedRoot, withDestinationURL: target)
        await #expect(throws: PackageTreeError.self) {
            _ = try await PackageTreeCapture().capture(directory: linkedRoot)
        }

        let fifo = target.appending(path: "pipe")
        #expect(mkfifo(fifo.path, mode_t(0o600)) == 0)
        await #expect(throws: PackageTreeError.self) {
            _ = try await PackageTreeCapture().capture(directory: target)
        }
    }

    @Test func enforcesEntryFileTotalDepthAndPathLimits() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        try write("12345", to: root.appending(path: "one"))
        try write("67890", to: root.appending(path: "nested/two"))

        for limits in [
            PackageTreeLimits(maxEntries: 2),
            PackageTreeLimits(maxFileBytes: 4),
            PackageTreeLimits(maxTotalBytes: 9),
            PackageTreeLimits(maxDepth: 1),
            PackageTreeLimits(maxPathBytes: 3),
        ] {
            await #expect(throws: PackageTreeError.self) {
                _ = try await PackageTreeCapture().capture(directory: root, limits: limits)
            }
        }
    }

    @Test func boundsDirectoryEnumerationAndDoesNotCountExcludedRootGit() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        try write("metadata", to: root.appending(path: ".git/config"))

        let metadataOnly = try await PackageTreeCapture().capture(
            directory: root,
            limits: .init(maxEntries: 0)
        )
        #expect(metadataOnly.entries.isEmpty)
        #expect(metadataOnly.excludedRootGitMetadata)

        try write("one", to: root.appending(path: "one"))
        await #expect(throws: PackageTreeError.limitExceeded) {
            _ = try await PackageTreeCapture().capture(
                directory: root,
                limits: .init(maxEntries: 0)
            )
        }
    }

    @Test func secondValidationPassRejectsFileMutationAfterTraversal() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let value = root.appending(path: "value.txt")
        try write("before", to: value)

        await #expect(throws: PackageTreeError.changedDuringCapture) {
            _ = try await PackageTreeCapture().capture(
                directory: root,
                validationHook: {
                    try? Data("after!".utf8).write(to: value)
                }
            )
        }
    }

    @Test func urlCaptureRejectsRootPathReplacementAfterTraversal() async throws {
        let container = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: container) }
        let root = container.appending(path: "root", directoryHint: .isDirectory)
        let moved = container.appending(path: "moved", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try write("original", to: root.appending(path: "value.txt"))

        await #expect(throws: PackageTreeError.changedDuringCapture) {
            _ = try await PackageTreeCapture().capture(
                directory: root,
                validationHook: {
                    try? FileManager.default.moveItem(at: root, to: moved)
                    try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
                    try? Data("replacement".utf8).write(to: root.appending(path: "value.txt"))
                }
            )
        }
    }

    @Test func cancellationIsNotWrappedAsPackageFailure() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        for index in 0..<2_000 {
            try write("content", to: root.appending(path: "files/\(index).txt"))
        }
        let task = Task { try await PackageTreeCapture().capture(directory: root) }
        task.cancel()
        do {
            _ = try await task.value
            Issue.record("Capture unexpectedly completed after immediate cancellation")
        } catch is CancellationError {
            // Expected: cancellation remains distinguishable to the caller.
        } catch {
            Issue.record("Cancellation was wrapped as \(type(of: error))")
        }
    }

    @Test func descriptorCaptureSurvivesAncestorRenameAndDoesNotCloseCallerDescriptor() async throws {
        let container = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: container) }
        let original = container.appending(path: "original", directoryHint: .isDirectory)
        let renamed = container.appending(path: "renamed", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: original, withIntermediateDirectories: true)
        try write("stable", to: original.appending(path: "value.txt"))
        let descriptor = Darwin.open(original.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        #expect(descriptor >= 0)
        defer { if descriptor >= 0 { Darwin.close(descriptor) } }
        try FileManager.default.moveItem(at: original, to: renamed)

        let captured = try await PackageTreeCapture().capture(directoryDescriptor: descriptor)
        #expect(file(captured, "value.txt") == Data("stable".utf8))
        var status = stat()
        #expect(fstat(descriptor, &status) == 0)
    }

    @Test func normalizationAndCaseCollisionsAreRejectedWhereFilesystemSupportsThem() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        try write("one", to: root.appending(path: "Case"))
        try write("two", to: root.appending(path: "case"))
        let names = try FileManager.default.contentsOfDirectory(atPath: root.path)
        if names.contains("Case"), names.contains("case") {
            await #expect(throws: PackageTreeError.self) {
                _ = try await PackageTreeCapture().capture(directory: root)
            }
        }


        let unicodeRoot = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: unicodeRoot) }
        let composed = "\u{00e9}"
        let decomposed = "e\u{0301}"
        try write("one", to: unicodeRoot.appending(path: composed))
        try write("two", to: unicodeRoot.appending(path: decomposed))
        let unicodeNames = try FileManager.default.contentsOfDirectory(atPath: unicodeRoot.path)
        if unicodeNames.count == 2 {
            await #expect(throws: PackageTreeError.self) {
                _ = try await PackageTreeCapture().capture(directory: unicodeRoot)
            }
        }
    }

    private func temporaryDirectory() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "package-tree-capture-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func write(_ value: String, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(value.utf8).write(to: url)
    }

    private func file(_ tree: CapturedPackageTree, _ path: String) -> Data? {
        guard let entry = tree.entries.first(where: { $0.relativePath == path }),
            case .file(let bytes, _) = entry.kind else { return nil }
        return bytes
    }

    private func executable(_ tree: CapturedPackageTree, _ path: String) -> Bool? {
        guard let entry = tree.entries.first(where: { $0.relativePath == path }),
            case .file(_, let executable) = entry.kind else { return nil }
        return executable
    }

    private func link(_ tree: CapturedPackageTree, _ path: String) -> String? {
        guard let entry = tree.entries.first(where: { $0.relativePath == path }),
            case .symbolicLink(let target) = entry.kind else { return nil }
        return target
    }

    private func isDirectory(_ entry: PackageTreeEntry) -> Bool {
        if case .directory = entry.kind { return true }
        return false
    }
}
