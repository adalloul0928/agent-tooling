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
enum PathContainment {
    /// The component-wise containment test over two normalized paths.
    ///
    /// Both arguments must already be normalized the same way by the caller
    /// (the variants below do this). The comparison is on whole path
    /// components: `/a/bc` is not inside `/a/b`, because the match requires
    /// either equality or the root followed by a separator. The leading and
    /// trailing separators are trimmed, so `"/"` trims to the empty string and
    /// contains only itself, as every check this replaced did. A caller that
    /// passes the filesystem root by mistake is refused, not granted the disk.
    static func isContained(normalizedChild child: String, inNormalizedRoot root: String) -> Bool {
        let child = trimmed(child)
        let root = trimmed(root)
        if root.isEmpty { return child.isEmpty }
        return child == root || child.hasPrefix(root + "/")
    }

    /// Containment with no normalization: the caller has already resolved both
    /// URLs and the bytes it passes are the bytes compared. Used where resolved
    /// URLs flow in from the caller (`BoundedFileAccess`, the conversation
    /// scanner and the read-only insights database).
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

    /// Containment where either path containing the other counts as the same
    /// conflict, comparing the strings exactly as given. Matches
    /// `WorkspaceLinkedDestinations`, where a destination inside a source root
    /// and a source root inside a destination are both refused.
    static func overlapsAsGiven(_ left: String, _ right: String) -> Bool {
        isContained(normalizedChild: left, inNormalizedRoot: right)
            || isContained(normalizedChild: right, inNormalizedRoot: left)
    }

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
}
