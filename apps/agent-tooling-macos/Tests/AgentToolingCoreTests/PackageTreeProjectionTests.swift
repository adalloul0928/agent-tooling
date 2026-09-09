import Foundation
import Testing

@testable import AgentToolingCore

struct PackageTreeProjectionTests {
    @Test func rootProjectionReturnsTheOriginalTreeAndReviewFact() throws {
        let tree = try CapturedPackageTree(entries: [
            .init(relativePath: "SKILL.md", kind: .file(bytes: Data("skill".utf8), executable: false)),
        ], excludedRootGitMetadata: true)

        #expect(try tree.subtree(at: ".") == tree)
    }

    @Test func directoryProjectionRebasesEveryEntryAndPreservesBytesModesAndLinks() throws {
        let executable = Data("#!/bin/sh\n".utf8)
        let tree = try CapturedPackageTree(entries: [
            .init(relativePath: "packages", kind: .directory),
            .init(relativePath: "packages/review", kind: .directory),
            .init(relativePath: "packages/review/empty", kind: .directory),
            .init(relativePath: "packages/review/scripts", kind: .directory),
            .init(relativePath: "packages/review/scripts/run", kind: .file(bytes: executable, executable: true)),
            .init(relativePath: "packages/review/current", kind: .symbolicLink(target: "scripts/run")),
            .init(relativePath: "unrelated", kind: .directory),
            .init(relativePath: "unrelated/value", kind: .file(bytes: Data([0, 255]), executable: false)),
        ], excludedRootGitMetadata: true)

        let projected = try tree.subtree(at: "packages/review")
        let independentlyBuilt = try CapturedPackageTree(entries: [
            .init(relativePath: "empty", kind: .directory),
            .init(relativePath: "scripts", kind: .directory),
            .init(relativePath: "scripts/run", kind: .file(bytes: executable, executable: true)),
            .init(relativePath: "current", kind: .symbolicLink(target: "scripts/run")),
        ])

        #expect(projected == independentlyBuilt)
        #expect(!projected.excludedRootGitMetadata)
        #expect(projected.entries.allSatisfy { !$0.relativePath.contains("unrelated") })
    }

    @Test func emptyDirectoryProjectsToAValidEmptyTree() throws {
        let tree = try CapturedPackageTree(entries: [
            .init(relativePath: "empty", kind: .directory),
            .init(relativePath: "other", kind: .file(bytes: Data("other".utf8), executable: false)),
        ])

        let projected = try tree.subtree(at: "empty")

        #expect(projected.entries.isEmpty)
        #expect(projected.totalFileBytes == 0)
        #expect(projected == (try CapturedPackageTree(entries: [])))
    }

    @Test func fileAndSymbolicLinkCannotBecomeTreeRoots() throws {
        let tree = try CapturedPackageTree(entries: [
            .init(relativePath: "folder", kind: .directory),
            .init(relativePath: "folder/value", kind: .file(bytes: Data("value".utf8), executable: false)),
            .init(relativePath: "alias", kind: .symbolicLink(target: "folder")),
        ])

        #expect(throws: PackageTreeError.unsupportedItem) {
            try tree.subtree(at: "folder/value")
        }
        #expect(throws: PackageTreeError.unsupportedItem) {
            try tree.subtree(at: "alias")
        }
    }

    @Test func invalidMissingAndNoncanonicalSelectorsAreRejected() throws {
        let composed = "caf\u{00e9}"
        let decomposed = "cafe\u{0301}"
        let tree = try CapturedPackageTree(entries: [
            .init(relativePath: composed, kind: .directory),
        ])

        for path in ["", "/tmp", "../outside", "folder/../outside", ".git", "folder/.GIT/value", "folder/", "folder\\child", decomposed] {
            #expect(throws: PackageTreeError.invalidPath) {
                try tree.subtree(at: path)
            }
        }
        #expect(throws: PackageTreeError.invalidStructure) {
            try tree.subtree(at: "missing")
        }
        #expect(try tree.subtree(at: composed).entries.isEmpty)
    }

    @Test func linkOutsideSelectedDirectoryRejectsTheWholeProjection() throws {
        let tree = try CapturedPackageTree(entries: [
            .init(relativePath: "packages", kind: .directory),
            .init(relativePath: "packages/review", kind: .directory),
            .init(relativePath: "packages/review/SKILL.md", kind: .file(bytes: Data("skill".utf8), executable: false)),
            .init(relativePath: "packages/review/shared", kind: .symbolicLink(target: "../../shared/value")),
            .init(relativePath: "shared", kind: .directory),
            .init(relativePath: "shared/value", kind: .file(bytes: Data("shared".utf8), executable: false)),
        ])

        #expect(throws: PackageTreeError.unsafeSymbolicLink) {
            try tree.subtree(at: "packages/review")
        }
    }
}
