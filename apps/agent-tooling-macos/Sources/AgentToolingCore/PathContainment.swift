import Foundation

/// One place that answers "is this path the root, or inside it," so the several
/// call sites that each used to spell out their own `hasPrefix` check cannot
/// drift apart or get the edge cases subtly wrong.
///
/// The sites did not all normalize the same way, and that is deliberate: a path
/// the caller has already resolved must not be resolved again, and a check that
/// must follow symlinks must not be turned into a lexical one. So the shared
/// primitive is the comparison, and each named variant applies exactly the
/// normalization its site always applied. The variants are not interchangeable;
/// pick the one that normalizes the way the site's own paths already are.
///
/// A check must also err in the direction its answer is used, so there are two
/// families, and a site picks by what a wrong answer would cost:
///
/// - An allow check asks whether a path may be read, written or removed. It
///   compares exactly, so on a case-insensitive volume a differently cased
///   spelling of an allowed root is refused, and the filesystem root contains
///   only itself. Either mistake costs a refusal, never access.
/// - A deny or exclusion check asks whether a path must be left alone. It folds
///   case the way a case-insensitive volume compares names, on every volume,
///   and treats the filesystem root as containing everything. Either can refuse
///   a path the disk keeps apart, such as a folder that differs from a
///   protected one only by case on a case-sensitive volume, but no spelling of
///   a protected path gets through.
///
/// Deny checks fold case everywhere rather than asking a volume, because a path
/// has no single answer: each component is looked up on the volume holding its
/// parent. `/volumes/work/repo` reaches a case-sensitive volume mounted at
/// `/Volumes/work` through the case-insensitive startup volume, and a path that
/// does not exist yet has no volume to ask.
enum PathContainment {
    // MARK: - Allow checks: exact

    /// The component-wise containment test over two normalized paths.
    ///
    /// Both arguments must already be normalized the same way by the caller
    /// (the variants below do this). The comparison is on whole path
    /// components: `/a/bc` is not inside `/a/b`, because each of the root's
    /// components must equal the child's in the same place. The leading and
    /// trailing separators are trimmed, so `"/"` trims to the empty string and
    /// contains only itself. A caller that passes the filesystem root by
    /// mistake is refused, not granted the disk.
    static func isContained(normalizedChild child: String, inNormalizedRoot root: String) -> Bool {
        let rootParts = components(root)
        let childParts = components(child)
        guard !rootParts.isEmpty else { return childParts.isEmpty }
        return childParts.count >= rootParts.count && zip(rootParts, childParts).allSatisfy { $0 == $1 }
    }

    /// Where `child` sits below `root`: the components after the root, with
    /// no separator leading or trailing. Nil when `child` is the root itself
    /// or not inside it, compared the way `isContained` compares, so `/a/bc`
    /// is not below `/a/b` and nothing is below the filesystem root. Also nil
    /// when a remaining component is empty, `.` or `..`, so the answer joined
    /// back onto the root names the place the comparison saw.
    static func relativePath(ofNormalizedChild child: String, inNormalizedRoot root: String) -> String? {
        let rootParts = components(root)
        let childParts = components(child)
        guard !rootParts.isEmpty, childParts.count > rootParts.count,
            zip(rootParts, childParts).allSatisfy({ $0 == $1 })
        else { return nil }
        let below = childParts.dropFirst(rootParts.count)
        guard !below.contains(where: { $0.isEmpty || $0 == "." || $0 == ".." }) else { return nil }
        return below.joined(separator: "/")
    }

    /// The relative path of an item found under a root the caller has already
    /// normalized, such as an item a directory enumerator returned: the item
    /// is standardized here, and the root is compared as given.
    static func relativePath(of child: URL, under root: URL) -> String? {
        relativePath(
            ofNormalizedChild: child.standardizedFileURL.path(percentEncoded: false),
            inNormalizedRoot: root.path(percentEncoded: false)
        )
    }

    /// The relative path of an item a directory walk of `root` returned, and
    /// only for such an item. A walk names what it finds under the folder's
    /// real path: links above the folder resolved, letter case as the disk
    /// stores it, `/private` put back. So the item is matched against `root`
    /// as given and then against `resolvedRoot`, the same folder with its
    /// links resolved, which the caller works out once per walk. A walk never
    /// returns anything outside the folder it opened, so the second spelling
    /// changes how an item is named, never which items are let in: each must
    /// still be inside one spelling of the root.
    static func relativePath(ofEnumerated child: URL, under root: URL, resolvedRoot: URL) -> String? {
        relativePath(of: child, under: root) ?? relativePath(of: child, under: resolvedRoot)
    }

    /// Containment with no normalization: the caller has already resolved both
    /// URLs and the bytes it passes are the bytes compared.
    static func containsAsGiven(_ child: URL, in root: URL) -> Bool {
        isContained(
            normalizedChild: child.path(percentEncoded: false),
            inNormalizedRoot: root.path(percentEncoded: false)
        )
    }

    /// Containment over `lexicalPath`: both paths standardized, with one
    /// trailing separator dropped. Symlinks are not followed, except that a
    /// `..` after a link is resolved when the whole path exists, as
    /// `lexicalPath` describes. This is the check `OperationEngine` applies
    /// before its stricter validation, which refuses any symlink component
    /// and then repeats the check on resolved paths.
    static func containsLexically(_ child: URL, in root: URL) -> Bool {
        isContained(
            normalizedChild: lexicalPath(child),
            inNormalizedRoot: lexicalPath(root)
        )
    }

    /// Containment after standardizing and then resolving symlinks on both
    /// sides. Matches `OperationEngine.isContained` and
    /// `OperationCommandPolicy.contains`, which both standardize before
    /// resolving.
    static func containsResolved(_ child: URL, in root: URL) -> Bool {
        isContained(
            normalizedChild: resolvedPath(child),
            inNormalizedRoot: resolvedPath(root)
        )
    }

    // MARK: - Deny and exclusion checks: case folded, "/" holds everything

    /// The deny counterpart of `isContained`: whether `child` may be `root` or
    /// inside it under any spelling a case-insensitive volume accepts, and
    /// always when `root` is the filesystem root.
    ///
    /// Both paths are compared in Unicode's canonical caseless form, which is
    /// how such a volume compares names (`straße` is `STRASSE`, `σ` is `ς`),
    /// and as scalars rather than characters, so a component that begins with
    /// a combining mark still starts after the separator before it.
    static func mightBeContained(normalizedChild child: String, inNormalizedRoot root: String) -> Bool {
        let root = caselessScalars(root)
        guard !root.isEmpty else { return true }
        let child = caselessScalars(child)
        return child == root || child.starts(with: root + ["/"])
    }

    /// The deny counterpart of comparing two normalized paths for equality:
    /// whether they may name the same place.
    static func mightBeSamePath(_ left: String, _ right: String) -> Bool {
        caselessScalars(left) == caselessScalars(right)
    }

    /// The deny counterpart of `containsLexically`.
    static func mightContainLexically(_ child: URL, in root: URL) -> Bool {
        mightBeContained(normalizedChild: lexicalPath(child), inNormalizedRoot: lexicalPath(root))
    }

    /// Either path containing the other counts as the same conflict, comparing
    /// the strings as given. A deny check: `WorkspaceLinkedDestinations` refuses
    /// a destination inside a source root and a source root inside a
    /// destination, so either side being `/` overlaps everything.
    static func overlapsAsGiven(_ left: String, _ right: String) -> Bool {
        mightBeContained(normalizedChild: left, inNormalizedRoot: right)
            || mightBeContained(normalizedChild: right, inNormalizedRoot: left)
    }

    // MARK: - Normalization

    /// Standardize and drop one trailing separator, without resolving the
    /// path's symlinks. This is the normalization `OperationEngine.normalizedPath`
    /// performed, kept here so the lexical variant and the engine's own policy
    /// share one spelling.
    ///
    /// Standardizing is not purely textual. When the whole path exists,
    /// Foundation resolves its `..` on disk, so a `..` after a symbolic link
    /// names the parent of the link's target, the folder the kernel would
    /// reach. When the path does not exist, `..` is removed as text, even
    /// right after a link. A link with no `..` after it stays a plain
    /// component either way, and a leading `/private` is dropped when the
    /// path without it exists.
    static func lexicalPath(_ url: URL) -> String {
        let path = url.standardizedFileURL.path(percentEncoded: false)
        guard path.count > 1 else { return path }
        return path.hasSuffix("/") ? String(path.dropLast()) : path
    }

    private static func resolvedPath(_ url: URL) -> String {
        url.standardizedFileURL.resolvingSymlinksInPath().path(percentEncoded: false)
    }

    private static func trimmed(_ path: String) -> String {
        path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }

    /// The trimmed path's components, split at every separator scalar, as the
    /// deny checks compare. Split as characters, a separator and the mark
    /// after it are one character, so a name that begins with a combining
    /// mark would not start a component, and a name that ends in a prepended
    /// mark would swallow the separator after it. Each component stays a
    /// string, so precomposed and decomposed spellings of a name still match.
    /// Empty for the filesystem root.
    private static func components(_ path: String) -> [String] {
        let path = trimmed(path)
        guard !path.isEmpty else { return [] }
        return path.unicodeScalars.split(separator: "/", omittingEmptySubsequences: false).map { String($0) }
    }

    /// The trimmed path in Unicode's canonical caseless form: decomposed, case
    /// folded, decomposed again.
    private static func caselessScalars(_ path: String) -> [Unicode.Scalar] {
        let folded = trimmed(path).decomposedStringWithCanonicalMapping
            .folding(options: [.caseInsensitive], locale: Locale(identifier: "en_US_POSIX"))
        return Array(folded.decomposedStringWithCanonicalMapping.unicodeScalars)
    }
}
