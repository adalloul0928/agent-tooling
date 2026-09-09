import Foundation
import Testing

@testable import AgentToolingCore

struct PackageTreeModelTests {
    @Test func mixedTreeMatchesIndependentSHA256Golden() throws {
        let tree = try CapturedPackageTree(entries: [
            directory("assets"), file("assets/a.txt", "A"), file("run.sh", "#!/bin/sh\n", executable: true), link("latest", "assets/a.txt"),
        ])
        #expect(tree.digest == .init(value: "e6505517f35988dd1bd550acf7b6f4ae38617f00a38b59d891012defcdb99dc1"))
        #expect(tree.totalFileBytes == 11)
    }

    @Test func canonicalOrderAndExcludedGitObservationDoNotChangeDigest() throws {
        let entries = [directory("a"), file("a/x", "x"), link("current", "a/x")]
        let first = try CapturedPackageTree(entries: entries)
        let second = try CapturedPackageTree(entries: entries.reversed(), excludedRootGitMetadata: true)
        #expect(first.digest == second.digest)
        #expect(second.excludedRootGitMetadata)
    }

    @Test func digestChangesForContentPathExecutableTypeAndEmptyDirectory() throws {
        let base = try CapturedPackageTree(entries: [directory("empty"), file("a", "x")])
        let content = try CapturedPackageTree(entries: [directory("empty"), file("a", "y")])
        let path = try CapturedPackageTree(entries: [directory("empty"), file("b", "x")])
        let executable = try CapturedPackageTree(entries: [directory("empty"), file("a", "x", executable: true)])
        let type = try CapturedPackageTree(entries: [directory("empty"), link("a", "empty")])
        let noEmpty = try CapturedPackageTree(entries: [file("a", "x")])
        #expect(Set([base.digest, content.digest, path.digest, executable.digest, type.digest, noEmpty.digest]).count == 6)
    }

    @Test func unicodeCanonicalizationSharesDigestButRejectsDualNFCEntries() throws {
        let composed = try CapturedPackageTree(entries: [file("café", "x")])
        let decomposed = try CapturedPackageTree(entries: [file("cafe\u{301}", "x")])
        #expect(composed.digest == decomposed.digest)
        #expect(throws: PackageTreeError.self) { _ = try CapturedPackageTree(entries: [file("café", "x"), file("cafe\u{301}", "x")]) }
    }

    @Test func rejectsCaseAndMalformedPaths() {
        #expect(throws: PackageTreeError.self) { _ = try CapturedPackageTree(entries: [file("Readme", "x"), file("README", "x")]) }
        for path in ["", ".", "../x", "/x", "a//b", "a\\b", ".git/x", "a/\u{0}/b"] {
            #expect(throws: PackageTreeError.self) { _ = try CapturedPackageTree(entries: [file(path, "x")]) }
        }
    }

    @Test func requiresExplicitDirectoryParents() {
        #expect(throws: PackageTreeError.self) { _ = try CapturedPackageTree(entries: [file("a/b", "x")]) }
        #expect(throws: PackageTreeError.self) { _ = try CapturedPackageTree(entries: [file("a", "x"), file("a/b", "x")]) }
    }

    @Test func validatesInternalEscapingDanglingAndCyclicLinks() throws {
        _ = try CapturedPackageTree(entries: [directory("d"), file("d/x", "x"), link("ok", "d/x")])
        for entries in [[link("bad", "../x")], [link("bad", "missing")], [link("one", "two"), link("two", "one")]] {
            #expect(throws: PackageTreeError.self) { _ = try CapturedPackageTree(entries: entries) }
        }
    }

    @Test func resolvesRelativeLinksAgainstTheirContainingDirectory() throws {
        _ = try CapturedPackageTree(entries: [directory("dir"), directory("dir/linkdir"), file("dir/x", "x"), link("dir/linkdir/up", "../x")])
        _ = try CapturedPackageTree(entries: [directory("real"), directory("real/nested"), file("real/x", "x"),
                                             link("linkdir", "real/nested"), link("through-link", "linkdir/../x"), link("root", ".")])
        // A lexical `..` collapse would incorrectly accept root `x`; POSIX
        // resolution expands linkdir first, then applies `..` inside real.
        #expect(throws: PackageTreeError.self) { _ = try CapturedPackageTree(entries: [
            directory("real"), directory("real/nested"), file("x", "root"), link("linkdir", "real/nested"), link("wrong", "linkdir/../x"),
        ]) }
    }

    @Test func enforcesEntryFileTotalDepthAndPathLimits() {
        let one = PackageTreeLimits(maxEntries: 1, maxFileBytes: 1, maxTotalBytes: 1, maxDepth: 1, maxPathBytes: 1)
        #expect(throws: PackageTreeError.self) { _ = try CapturedPackageTree(entries: [file("a", "xx")], limits: one) }
        #expect(throws: PackageTreeError.self) { _ = try CapturedPackageTree(entries: [file("a", "x"), file("b", "x")], limits: one) }
        #expect(throws: PackageTreeError.self) { _ = try CapturedPackageTree(entries: [directory("a"), directory("a/b")], limits: one) }
    }

    @Test func enforcesIndependentTotalPathAndDepthLimits() {
        let total = PackageTreeLimits(maxEntries: 10, maxFileBytes: 10, maxTotalBytes: 3, maxDepth: 10, maxPathBytes: 10)
        #expect(throws: PackageTreeError.self) { _ = try CapturedPackageTree(entries: [file("a", "xx"), file("b", "xx")], limits: total) }
        let path = PackageTreeLimits(maxEntries: 10, maxFileBytes: 10, maxTotalBytes: 10, maxDepth: 10, maxPathBytes: 1)
        #expect(throws: PackageTreeError.self) { _ = try CapturedPackageTree(entries: [file("ab", "x")], limits: path) }
        let depth = PackageTreeLimits(maxEntries: 10, maxFileBytes: 10, maxTotalBytes: 10, maxDepth: 1, maxPathBytes: 100)
        #expect(throws: PackageTreeError.self) { _ = try CapturedPackageTree(entries: [directory("a"), file("a/b", "x")], limits: depth) }
    }

    @Test func acceptsExactLimitBoundaries() throws {
        let limits = PackageTreeLimits(maxEntries: 2, maxFileBytes: 1, maxTotalBytes: 2, maxDepth: 1, maxPathBytes: 1)
        let tree = try CapturedPackageTree(entries: [file("a", "x"), file("b", "y")], limits: limits)
        #expect(tree.totalFileBytes == 2)
    }

    private func directory(_ path: String) -> PackageTreeEntry { .init(relativePath: path, kind: .directory) }
    private func file(_ path: String, _ text: String, executable: Bool = false) -> PackageTreeEntry { .init(relativePath: path, kind: .file(bytes: Data(text.utf8), executable: executable)) }
    private func link(_ path: String, _ target: String) -> PackageTreeEntry { .init(relativePath: path, kind: .symbolicLink(target: target)) }
}
