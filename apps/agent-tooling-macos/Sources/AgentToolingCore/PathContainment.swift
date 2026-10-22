import Foundation

/// Path containment with explicit normalization and conservative comparison.
/// Choose the lexical or symlink-resolving variant to match the call site.
/// Allow checks compare case exactly and treat `/` as containing only itself.
/// Deny checks fold case and Unicode composition, with `/` containing all paths.
/// This can reject distinct names on case-sensitive volumes, but prevents
/// alternate spellings bypassing exclusions. Mixed-volume paths make a single
/// volume's case-sensitivity insufficient. Lexical checks do not detect aliases;
/// callers requiring that guarantee must resolve or refuse symlinks first.
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

    /// Only for children returned by a directory walk. Enumeration may use
    /// resolved spelling, disk case or /private, so accept containment under
    /// either the supplied root or its pre-resolved equivalent. This changes
    /// path spelling only; the child must remain inside one of those roots.
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

    /// Standardizes and removes one trailing separator without explicitly
    /// resolving symlinks. Foundation resolves `..` against existing paths but
    /// removes it lexically for missing paths; it may also drop `/private`.
    /// A symlink without a following `..` stays unresolved.
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
