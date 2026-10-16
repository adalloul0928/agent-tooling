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
/// pick the one whose column in the task table matches the site.
enum PathContainment {
    /// The component-wise containment test over two normalized paths.
    ///
    /// Both arguments must already be normalized the same way by the caller
    /// (the variants below do this). The comparison is on whole path
    /// components: `/a/bc` is not inside `/a/b`, because the match requires
    /// either equality or the root followed by a separator. The leading and
    /// trailing separators are trimmed so `"/"` (the filesystem root, which
    /// trims to the empty string) contains everything, matching the behavior
    /// the string checks had before.
    static func isContained(normalizedChild child: String, inNormalizedRoot root: String) -> Bool {
        let child = trimmed(child)
        let root = trimmed(root)
        if root.isEmpty { return true }
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

    /// Lexical containment: standardize both paths and drop one trailing
    /// separator, but do not follow symlinks. Matches the "same as the
    /// filesystem would read the characters" check `OperationEngine` applies
    /// before its stricter symlink-walking validation.
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

    /// Standardize, drop one trailing separator, do not resolve. This is the
    /// normalization `OperationEngine.normalizedPath` performed, kept here so
    /// the lexical variant and the engine's own policy share one spelling.
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
