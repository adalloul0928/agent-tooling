import Foundation

/// Abbreviates a home-directory prefix to `~` for display. One shared spelling
/// so a path shown in a review, an audit or the sidebar reads the same way.
public enum PathDisplay {
    /// Returns `path` with a leading home directory replaced by `~`. Both the
    /// home and an absolute input are standardized first, and a `/private`
    /// prefix is folded, so the temporary folder resolved either way still
    /// matches a home given the other way. A relative input is left untouched.
    public static func abbreviatingHome(_ path: String, home: URL) -> String {
        var root = normalized(home.path(percentEncoded: false))
        if root.hasSuffix("/") { root.removeLast() }
        let candidate = path.hasPrefix("/") ? normalized(path) : path
        return candidate.hasPrefix(root) ? "~" + candidate.dropFirst(root.count) : candidate
    }

    /// Standardizes a path and folds the `/private` the temporary folder
    /// resolves through, dropping a trailing slash on anything but the root.
    private static func normalized(_ path: String) -> String {
        var standard = URL(filePath: path).standardizedFileURL.path(percentEncoded: false)
        if standard.hasPrefix("/private/") { standard = String(standard.dropFirst("/private".count)) }
        if standard.count > 1, standard.hasSuffix("/") { standard.removeLast() }
        return standard
    }
}
