import Foundation

/// The repository a project folder is a checkout of, in the one spelling the
/// workspace keeps.
///
/// A folder on this Mac means nothing on another one, but the repository it
/// was cloned from does: the same remote, cloned twice, is the same project.
/// `LogicalProjectRecord.repositoryHints` carries that identity in the shared
/// document, where the validator admits only a credential-free `https://` URL.
/// This turns whatever `git remote get-url` spells — SSH shorthand, `ssh://`,
/// `git://`, `.git` suffix, trailing slash, a token in the URL — into that one
/// form, and drops anything it cannot read as a repository.
public enum RepositoryIdentity {
    /// The hint for a remote, or `nil` when the remote names nothing this can
    /// treat as a repository (a local path, an empty string, a URL with no host).
    public static func hint(fromRemote remote: String) -> String? {
        let trimmed = remote.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= 4_096 else { return nil }

        var host: String
        var path: String
        if let components = URLComponents(string: trimmed), let scheme = components.scheme?.lowercased(),
           ["https", "http", "ssh", "git", "git+ssh", "ssh+git"].contains(scheme), let found = components.host, !found.isEmpty {
            host = found
            path = components.path
        } else if let colon = trimmed.firstIndex(of: ":"), !trimmed.contains("://"),
                  !trimmed[..<colon].contains("/") {
            // scp-like: [user@]host:path
            let authority = trimmed[..<colon]
            host = String(authority.split(separator: "@").last ?? authority)
            path = String(trimmed[trimmed.index(after: colon)...])
            if !path.hasPrefix("/") { path = "/" + path }
        } else {
            return nil
        }

        host = host.lowercased()
        // Hosts may carry a port in the ssh spelling; a hint never does.
        if let colon = host.firstIndex(of: ":") { host = String(host[..<colon]) }
        guard !host.isEmpty, !host.contains("@") else { return nil }

        var segments = path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        guard !segments.isEmpty else { return nil }
        if let last = segments.last, last.lowercased().hasSuffix(".git") {
            segments[segments.count - 1] = String(last.dropLast(4))
        }
        guard segments.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else { return nil }
        let candidate = "https://\(host)/\(segments.joined(separator: "/"))"
        guard (try? WorkspaceDomainValidation.requireCredentialFreeHTTPS(candidate, field: "repository hint")) != nil else {
            return nil
        }
        return candidate
    }

    /// Whether two hints or remotes name the same repository.
    public static func matches(_ left: String, _ right: String) -> Bool {
        guard let a = hint(fromRemote: left), let b = hint(fromRemote: right) else { return false }
        return a.caseInsensitiveCompare(b) == .orderedSame
    }
}
