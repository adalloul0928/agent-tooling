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

    @Test func theFilesystemRootContainsOnlyItself() {
        // The checks this replaced trimmed "/" to the empty string and then
        // required the child to equal it or start with "/", so the root
        // contained only itself. A caller that passes "/" by mistake is
        // therefore refused rather than granted the whole disk.
        #expect(PathContainment.isContained(normalizedChild: "/", inNormalizedRoot: "/"))
        #expect(!PathContainment.isContained(normalizedChild: "/a", inNormalizedRoot: "/"))
        #expect(!PathContainment.containsAsGiven(URL(fileURLWithPath: "/Users"), in: URL(fileURLWithPath: "/")))
        #expect(!PathContainment.containsLexically(URL(fileURLWithPath: "/Users"), in: URL(fileURLWithPath: "/")))
        #expect(!PathContainment.containsResolved(URL(fileURLWithPath: "/Users"), in: URL(fileURLWithPath: "/")))
    }

    // MARK: Relative path below a root

    @Test func aChildsRelativePathIsWhatFollowsTheRoot() {
        #expect(PathContainment.relativePath(ofNormalizedChild: "/a/b/c/d", inNormalizedRoot: "/a/b") == "c/d")
        #expect(PathContainment.relativePath(ofNormalizedChild: "/a/b/c/", inNormalizedRoot: "/a/b/") == "c")
    }

    @Test func theRootItselfHasNoRelativePath() {
        #expect(PathContainment.relativePath(ofNormalizedChild: "/a/b", inNormalizedRoot: "/a/b") == nil)
        #expect(PathContainment.relativePath(ofNormalizedChild: "/a/b/", inNormalizedRoot: "/a/b") == nil)
    }

    @Test func aSharedPrefixSiblingHasNoRelativePath() {
        #expect(PathContainment.relativePath(ofNormalizedChild: "/a/bc/d", inNormalizedRoot: "/a/b") == nil)
        #expect(PathContainment.relativePath(ofNormalizedChild: "/a/c", inNormalizedRoot: "/a/b") == nil)
    }

    @Test func nothingHasARelativePathBelowTheFilesystemRoot() {
        // The same answer the containment test gives: "/" contains only itself.
        #expect(PathContainment.relativePath(ofNormalizedChild: "/a", inNormalizedRoot: "/") == nil)
        #expect(PathContainment.relativePath(ofNormalizedChild: "/", inNormalizedRoot: "/") == nil)
    }

    @Test func aRelativePathThatWouldNotLandWhereItWasCheckedIsRefused() {
        // Joined back onto the root, each of these names some other place.
        for child in ["/a/b/../c", "/a/b/./c", "/a/b//c", "/a/b/c/.."] {
            #expect(PathContainment.relativePath(ofNormalizedChild: child, inNormalizedRoot: "/a/b") == nil, "\(child)")
        }
    }

    @Test func anEnumeratedItemIsStandardizedAndItsRootTakenAsGiven() {
        let root = URL(fileURLWithPath: "/a/b", isDirectory: true)
        #expect(PathContainment.relativePath(of: URL(fileURLWithPath: "/a/b/./c/d"), under: root) == "c/d")
        #expect(PathContainment.relativePath(of: URL(fileURLWithPath: "/a/x/../b/c"), under: root) == "c")
        // The root is the caller's to normalize: it is not standardized here.
        #expect(PathContainment.relativePath(of: URL(fileURLWithPath: "/a/b/c"), under: URL(fileURLWithPath: "/a/x/../b")) == nil)
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

    /// Standardizing is not purely textual: when the whole path exists,
    /// Foundation resolves its `..` on disk, so `link/..` is the parent of the
    /// link's target, the folder the kernel would reach. When the path does
    /// not exist, `..` is removed as text, even right after a link.
    @Test func lexicalResolvesDotDotAfterALinkOnlyWhenThePathExists() throws {
        let fixture = try PathContainmentFixture()
        defer { fixture.cleanUp() }
        try fixture.makeDirectory("rootA/real")
        try fixture.makeDirectory("rootA/present")
        try fixture.makeDirectory("rootB")
        try fixture.makeSymlink(at: "rootB/link", to: fixture.path("rootA/real"))

        // The whole path exists, so the link is followed before the `..`.
        let linkDotDot = fixture.url("rootB/link/..")
        #expect(PathContainment.lexicalPath(linkDotDot) == fixture.path("rootA"))
        #expect(PathContainment.containsLexically(linkDotDot, in: fixture.url("rootA")))
        #expect(!PathContainment.containsLexically(linkDotDot, in: fixture.url("rootB")))
        #expect(PathContainment.lexicalPath(fixture.url("rootB/link/../present")) == fixture.path("rootA/present"))
        // Nothing is there, so the same `..` is removed as text.
        #expect(PathContainment.lexicalPath(fixture.url("rootB/link/../missing")) == fixture.path("rootB/missing"))
        // Without the `..`, the link is a plain component and is not followed.
        #expect(PathContainment.containsLexically(fixture.url("rootB/link/x"), in: fixture.url("rootB")))
        // A `..` after a name that is not a link is removed as text too.
        #expect(PathContainment.lexicalPath(fixture.url("rootB/missing/..")) == fixture.path("rootB"))
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
    /// of `target`, not the parent of the link. This pins that the resolved
    /// variant's order, standardize then resolve, reaches the same folder as
    /// Marketplace's former resolve then standardize: standardizing already
    /// resolves a `..` that follows an existing link.
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
