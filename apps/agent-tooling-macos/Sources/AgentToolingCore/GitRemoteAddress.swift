import Foundation

/// A repository address as the join and connect forms help with it: whether
/// it can be used at all, the HTTPS form of one that cannot, and the host a
/// message about reaching it names.
///
/// It wraps the transport's own rule, so the form and the transport can never
/// disagree about an address: one this says is fine is one
/// `GitWorkspaceTransport.enroll` takes once the spaces around it are
/// dropped. The preflight and the join drop them too; anything else given the
/// address, such as `enroll`, takes it as it is, so pass it trimmed.
public enum GitRemoteAddress {
    /// Why `remote` cannot be used as a library's repository, or `nil` when it
    /// can. Spaces and line breaks around it are not held against it. A
    /// refused address carries the HTTPS form of it, when one can be worked
    /// out, for a "Use https://…" button, and says whether it was refused for
    /// the user name or password in it.
    public static func problem(_ remote: String) -> GitRemoteProblem? {
        let trimmed = trimmed(remote)
        guard !GitWorkspaceTransport.isValidRemote(trimmed) else { return nil }
        return .invalidAddress(suggestion: httpsSuggestion(for: trimmed), carriesSignIn: carriesSignIn(trimmed))
    }

    /// `remote` without the spaces and line breaks a paste brings with it.
    static func trimmed(_ remote: String) -> String {
        remote.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Whether `remote` names a user or a password: the `git@` of the scp
    /// form, the user or password of a URL, or anything after a URL's path,
    /// where a token hides as easily. Those are why it is refused, because
    /// whatever is in the address is stored where every Mac reads it.
    static func carriesSignIn(_ remote: String) -> Bool {
        if let scp = scpParts(of: remote) { return scp.hasUser }
        guard let components = URLComponents(string: remote) else { return false }
        return components.user != nil || components.password != nil || components.percentEncodedQuery != nil
            || components.percentEncodedFragment != nil
    }

    /// Suggests credential-free HTTPS for SSH, HTTP or schemeless remotes; Git has
    /// no SSH agent and portable addresses must not store credentials. Trims
    /// surrounding whitespace. Returns nil when the address already works or lacks
    /// a usable host.
    static func httpsSuggestion(for remote: String) -> String? {
        let trimmed = trimmed(remote)
        guard !GitWorkspaceTransport.isValidRemote(trimmed) else { return nil }
        let candidate: String?
        if let scp = scpParts(of: trimmed) {
            candidate = httpsAddress(host: scp.host, port: nil, path: scp.path)
        } else if let components = URLComponents(string: trimmed), let scheme = components.scheme?.lowercased() {
            switch scheme {
            case "https", "http":
                candidate = components.host.flatMap { httpsAddress(host: $0, port: components.port, path: components.path) }
            case "ssh", "git+ssh", "ssh+git", "git":
                // A port there is the SSH server's or the Git daemon's, never
                // the web server's, so it does not carry over.
                candidate = components.host.flatMap { httpsAddress(host: $0, port: nil, path: components.path) }
            default:
                candidate = nil
            }
        } else if !trimmed.hasPrefix("/"), !trimmed.hasPrefix("."), let slash = trimmed.firstIndex(of: "/") {
            candidate = httpsAddress(
                host: String(trimmed[..<slash]), port: nil, path: String(trimmed[trimmed.index(after: slash)...]))
        } else {
            candidate = nil
        }
        guard let candidate, GitWorkspaceTransport.isValidRemote(candidate) else { return nil }
        return candidate
    }

    /// The host `remote` names, lowercased, for a message about reaching it:
    /// `github.com` for `https://github.com/you/library.git` and for
    /// `git@github.com:you/library.git`. `nil` for a folder on this Mac, an
    /// absolute path or a `file:` address, which has no host to name.
    public static func host(of remote: String) -> String? {
        let trimmed = trimmed(remote)
        guard !trimmed.isEmpty, !trimmed.hasPrefix("/") else { return nil }
        if let scp = scpParts(of: trimmed) { return scp.host.lowercased() }
        guard let components = URLComponents(string: trimmed),
            let scheme = components.scheme?.lowercased(), scheme != "file",
            let host = components.host, !host.isEmpty
        else { return nil }
        return host.lowercased()
    }

    /// Git's "scp-like" form, `[user@]host:path`: a colon before any slash,
    /// in an address that is not a URL. A one-letter "host", as in `C:`, is
    /// not taken for one. `hasUser` says a user came before the host.
    private static func scpParts(of remote: String) -> (host: String, path: String, hasUser: Bool)? {
        guard !remote.contains("://"), let colon = remote.firstIndex(of: ":") else { return nil }
        let authority = remote[..<colon]
        guard !authority.contains("/") else { return nil }
        let host = authority.split(separator: "@", omittingEmptySubsequences: false).last.map(String.init) ?? ""
        let path = String(remote[remote.index(after: colon)...])
        guard host.count > 1, !path.isEmpty, isHostName(host) else { return nil }
        return (host, path, authority.contains("@"))
    }

    private static func isHostName(_ value: String) -> Bool {
        !value.isEmpty && value.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "." || $0 == "-") }
    }

    /// An HTTPS address for `host` and `path`, only for a host that looks like
    /// one a web server answers at: a dotted name, or `localhost`. An SSH alias
    /// such as `github-work` names nothing HTTPS can reach.
    private static func httpsAddress(host: String, port: Int?, path: String) -> String? {
        let trimmedPath = path.hasPrefix("/") ? String(path.dropFirst()) : path
        guard isHostName(host), host.contains(".") || host.lowercased() == "localhost", !trimmedPath.isEmpty
        else { return nil }
        var components = URLComponents()
        components.scheme = "https"
        components.host = host.lowercased()
        components.port = port
        components.path = "/" + trimmedPath
        return components.string
    }
}
