import Foundation
import Testing

@testable import AgentToolingCore

/// These tests pin the behavior of each containment variant with real folders
/// and real symbolic links on disk, so a later change that alters where a path
/// boundary falls fails here first.
@Suite("Path containment")
struct PathContainmentTests {
    // MARK: Primitive: component-wise, not textual prefix

    @Test func rootContainsItself() {
        #expect(PathContainment.isContained(normalizedChild: "/a/b", inNormalizedRoot: "/a/b"))
    }

    @Test func rootContainsAChild() {
        #expect(PathContainment.isContained(normalizedChild: "/a/b/c", inNormalizedRoot: "/a/b"))
    }

    @Test func aSiblingWithASharedPrefixIsNotContained() {
        // The whole point of a component-wise test: /a/bc is not inside /a/b.
        #expect(!PathContainment.isContained(normalizedChild: "/a/bc", inNormalizedRoot: "/a/b"))
    }

    @Test func aSiblingIsNotContained() {
        #expect(!PathContainment.isContained(normalizedChild: "/a/c", inNormalizedRoot: "/a/b"))
    }

    @Test func trailingSlashesAreTrimmedBeforeComparing() {
        #expect(PathContainment.isContained(normalizedChild: "/a/b/", inNormalizedRoot: "/a/b"))
        #expect(PathContainment.isContained(normalizedChild: "/a/b/c/", inNormalizedRoot: "/a/b/"))
    }

    @Test func theFilesystemRootContainsEverything() {
        // "/" trims to the empty string, which contains every path, matching
        // the behavior the string checks had before.
        #expect(PathContainment.isContained(normalizedChild: "/a", inNormalizedRoot: "/"))
        #expect(PathContainment.isContained(normalizedChild: "/", inNormalizedRoot: "/"))
    }

    // MARK: as-given variant (no normalization)

    @Test func asGivenTakesTheBytesItIsGiven() {
        let root = URL(fileURLWithPath: "/a/b")
        #expect(PathContainment.containsAsGiven(URL(fileURLWithPath: "/a/b/c"), in: root))
        #expect(!PathContainment.containsAsGiven(URL(fileURLWithPath: "/a/bc"), in: root))
    }

    @Test func asGivenEqualPaths() {
        let url = URL(fileURLWithPath: "/a/b")
        #expect(PathContainment.containsAsGiven(url, in: url))
    }

    @Test func asGivenDoesNotCollapseDotDot() throws {
        // No normalization: "/a/b/.." is a textual child of "/a/b" because the
        // caller is contracted to pass already-resolved URLs. This pins that
        // the variant does not quietly standardize.
        let root = URL(fileURLWithPath: "/a/b")
        let child = URL(fileURLWithPath: "/a/b/..")
        #expect(PathContainment.containsAsGiven(child, in: root))
    }

    // MARK: lexical variant (standardize, no symlink resolution)

    @Test func lexicalCollapsesDotAndDotDotWithoutTouchingDisk() {
        let root = URL(fileURLWithPath: "/a/b")
        #expect(PathContainment.containsLexically(URL(fileURLWithPath: "/a/b/./c"), in: root))
        #expect(!PathContainment.containsLexically(URL(fileURLWithPath: "/a/b/.."), in: root))
        #expect(PathContainment.containsLexically(URL(fileURLWithPath: "/a/x/../b/c"), in: root))
    }

    @Test func lexicalTrailingSlash() {
        #expect(
            PathContainment.containsLexically(
                URL(fileURLWithPath: "/a/b/", isDirectory: true),
                in: URL(fileURLWithPath: "/a/b", isDirectory: true)
            )
        )
    }

    @Test func lexicalDoesNotFollowALinkInsidePointingOut() throws {
        let fixture = try PathContainmentFixture()
        defer { fixture.cleanUp() }
        // root/inside -> /tmp/<outside>. Lexically, root/inside/x is still a
        // child of root because the link is a plain component, not followed.
        try fixture.makeDirectory("root")
        try fixture.makeDirectory("outside")
        try fixture.makeSymlink(at: "root/inside", to: fixture.path("outside"))

        #expect(
            PathContainment.containsLexically(
                fixture.url("root/inside/x"),
                in: fixture.url("root")
            )
        )
    }

    // MARK: resolved variant (standardize then resolve symlinks)

    @Test func resolvedEqualAndChildAndSibling() {
        let root = URL(fileURLWithPath: "/a/b")
        #expect(PathContainment.containsResolved(root, in: root))
        #expect(PathContainment.containsResolved(URL(fileURLWithPath: "/a/b/c"), in: root))
        #expect(!PathContainment.containsResolved(URL(fileURLWithPath: "/a/c"), in: root))
        #expect(!PathContainment.containsResolved(URL(fileURLWithPath: "/a/bc"), in: root))
    }

    @Test func resolvedFollowsALinkInsidePointingOutAndRefusesIt() throws {
        let fixture = try PathContainmentFixture()
        defer { fixture.cleanUp() }
        // root/inside -> outside (a sibling of root). A path under the link
        // resolves out of root, so the resolved check refuses it.
        try fixture.makeDirectory("root")
        try fixture.makeDirectory("outside")
        try fixture.makeDirectory("outside/x")
        try fixture.makeSymlink(at: "root/inside", to: fixture.path("outside"))

        #expect(!PathContainment.containsResolved(fixture.url("root/inside/x"), in: fixture.url("root")))
    }

    @Test func resolvedFollowsALinkOutsidePointingInAndAcceptsIt() throws {
        let fixture = try PathContainmentFixture()
        defer { fixture.cleanUp() }
        // outside/link -> root/real. Checked against root, the link resolves
        // back inside root, so the resolved check accepts it.
        try fixture.makeDirectory("root")
        try fixture.makeDirectory("root/real")
        try fixture.makeSymlink(at: "outside-link", to: fixture.path("root/real"))

        #expect(PathContainment.containsResolved(fixture.url("outside-link"), in: fixture.url("root")))
    }

    /// A real symlink `link -> target`, checked as `link/..`. The kernel
    /// follows `link` first and then applies `..`, so `link/..` is the parent
    /// of `target`, not the parent of the link. This pins which normalization
    /// order the resolved variant uses, the point the task flags between
    /// Marketplace (resolve then standardize) and OperationEngine (standardize
    /// then resolve).
    @Test func resolvedHandlesLinkDotDotTheWayTheFilesystemDoes() throws {
        let fixture = try PathContainmentFixture()
        defer { fixture.cleanUp() }
        try fixture.makeDirectory("rootA")
        try fixture.makeDirectory("rootA/real")
        try fixture.makeDirectory("rootB")
        // link lives in rootB but points at rootA/real. link/.. is rootA.
        try fixture.makeSymlink(at: "rootB/link", to: fixture.path("rootA/real"))

        let linkDotDot = fixture.url("rootB/link/..")
        // Filesystem truth: link/.. == rootA, which is inside rootA.
        #expect(PathContainment.containsResolved(linkDotDot, in: fixture.url("rootA")))
        // And it is NOT inside rootB, even though the link lives in rootB.
        #expect(!PathContainment.containsResolved(linkDotDot, in: fixture.url("rootB")))
    }

    // MARK: overlap variant (either contains the other, strings as given)

    @Test func overlapIsSymmetric() {
        #expect(PathContainment.overlapsAsGiven("/a/b", "/a/b/c"))
        #expect(PathContainment.overlapsAsGiven("/a/b/c", "/a/b"))
        #expect(PathContainment.overlapsAsGiven("/a/b", "/a/b"))
    }

    @Test func overlapRejectsASharedPrefixSibling() {
        #expect(!PathContainment.overlapsAsGiven("/a/b", "/a/bc"))
        #expect(!PathContainment.overlapsAsGiven("/a/bc", "/a/b"))
    }
}

/// A self-cleaning fixture of real directories and symlinks under a resolved
/// temporary root, so a resolved-containment check sees the same bytes the test
/// builds rather than `/private` aliasing on macOS.
private struct PathContainmentFixture {
    let root: URL

    init() throws {
        root = FileManager.default.temporaryDirectory
            .resolvingSymlinksInPath()
            .appending(path: "PathContainmentTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    func path(_ relative: String) -> String { url(relative).path(percentEncoded: false) }

    func url(_ relative: String) -> URL { root.appending(path: relative) }

    func makeDirectory(_ relative: String) throws {
        try FileManager.default.createDirectory(at: url(relative), withIntermediateDirectories: true)
    }

    func makeSymlink(at relative: String, to destination: String) throws {
        try FileManager.default.createSymbolicLink(atPath: path(relative), withDestinationPath: destination)
    }

    func cleanUp() { try? FileManager.default.removeItem(at: root) }
}
