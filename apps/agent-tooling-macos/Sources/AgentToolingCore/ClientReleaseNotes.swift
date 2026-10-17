import Foundation

/// What a client publishes about its versions, fetched by the app itself so
/// the model is handed text rather than told to go and find it. Each note is
/// bounded and names its source, and the source travels with it into the
/// review as provenance.
public struct ClientReleaseNote: Codable, Hashable, Sendable {
    public var client: ClientKind
    public var version: String
    public var source: String
    public var body: String
    public init(client: ClientKind, version: String, source: String, body: String) {
        self.client = client
        self.version = version
        self.source = source
        self.body = body
    }

    /// As the prompt shows it.
    public var rendered: String { "## \(client.rawValue) \(version)\nsource: \(source)\n\(body)" }
}

enum ClientReleaseNotesError: LocalizedError, Sendable {
    case unsupportedClient(ClientKind)
    case unreachable(String)
    var errorDescription: String? {
        switch self {
        case .unsupportedClient(let client): "\(client.rawValue) does not publish release notes this app knows how to read."
        case .unreachable(let detail): "The release notes could not be fetched. \(detail)"
        }
    }
}

/// How bytes are fetched. The live one uses URLSession; a test hands in text.
public protocol ReleaseNotesFetching: Sendable {
    func fetch(_ url: URL) async throws -> Data
}

public struct URLSessionReleaseNotesFetcher: ReleaseNotesFetching {
    public init() {}
    public func fetch(_ url: URL) async throws -> Data {
        var request = URLRequest(url: url)
        request.timeoutInterval = 30
        request.setValue("agent-tooling-macos", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw ClientReleaseNotesError.unreachable("\(url.host() ?? "the server") answered \((response as? HTTPURLResponse)?.statusCode ?? 0).")
        }
        return data
    }
}

/// Where each client's notes live and how to read them. Public, fixed
/// addresses only: nothing here is built from anything the person typed.
public struct ClientReleaseNotesService: Sendable {
    public static let maximumNotes = 12
    public static let maximumBodyCharacters = 6_000
    public static let maximumTotalCharacters = 60_000

    private let fetcher: any ReleaseNotesFetching

    public init(fetcher: any ReleaseNotesFetching = URLSessionReleaseNotesFetcher()) {
        self.fetcher = fetcher
    }

    public static func sources(for client: ClientKind, installedVersion: String?) -> [URL] {
        switch client {
        case .claude:
            return [URL(string: "https://raw.githubusercontent.com/anthropics/claude-code/main/CHANGELOG.md")!]
        case .codex:
            return [URL(string: "https://api.github.com/repos/openai/codex/releases?per_page=30")!]
        case .kiro:
            // Kiro publishes one page per minor: the installed minor and the
            // ones after it, up to a few ahead.
            let (major, minor) = Self.majorMinor(installedVersion) ?? (2, 20)
            return (0..<4).compactMap { offset in URL(string: "https://kiro.dev/changelog/cli/\(major)-\(minor + offset)/") }
        case .gemini:
            return []
        }
    }

    /// Notes for versions newer than the installed one, newest first, bounded.
    /// An installed version the notes do not mention is treated as older than
    /// all of them, so nothing is hidden by a version string the app cannot
    /// read (the ASBX Claude build reports its own number, for one).
    public func notes(for client: ClientKind, installedVersion: String?) async throws -> [ClientReleaseNote] {
        let sources = Self.sources(for: client, installedVersion: installedVersion)
        guard !sources.isEmpty else { throw ClientReleaseNotesError.unsupportedClient(client) }
        var notes: [ClientReleaseNote] = []
        var failures: [String] = []
        for source in sources {
            do {
                let data = try await fetcher.fetch(source)
                let text = String(decoding: data.prefix(4 * 1_024 * 1_024), as: UTF8.self)
                switch client {
                case .claude: notes += Self.parseMarkdownChangelog(text, client: client, source: source.absoluteString)
                case .codex: notes += Self.parseGitHubReleases(text, client: client)
                case .kiro: notes += Self.parseKiroPage(text, client: client, source: source.absoluteString)
                case .gemini: break
                }
            } catch {
                failures.append(error.localizedDescription)
            }
        }
        if notes.isEmpty, !failures.isEmpty { throw ClientReleaseNotesError.unreachable(failures.joined(separator: " ")) }
        let newer = notes.filter { note in
            guard let installed = ClientVersion(installedVersion ?? ""), let published = ClientVersion(note.version) else { return true }
            return published > installed
        }
        return Self.bounded(newer.isEmpty ? Array(notes.prefix(3)) : newer)
    }

    // MARK: Parsers

    /// `## 2.1.286` sections, in file order (newest first).
    static func parseMarkdownChangelog(_ text: String, client: ClientKind, source: String) -> [ClientReleaseNote] {
        var notes: [ClientReleaseNote] = []
        var version: String?
        var body: [String] = []
        func flush() {
            if let version { notes.append(.init(client: client, version: version, source: source, body: body.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines))) }
            body = []
        }
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.hasPrefix("## ") {
                flush()
                version = String(line.dropFirst(3)).trimmingCharacters(in: .whitespaces)
                if notes.count >= 60 { version = nil; break }
            } else if version != nil {
                body.append(String(line))
            }
        }
        flush()
        return notes
    }

    /// GitHub's releases JSON: stable releases only, by tag, newest first.
    static func parseGitHubReleases(_ text: String, client: ClientKind) -> [ClientReleaseNote] {
        guard let data = text.data(using: .utf8), let releases = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return [] }
        return releases.compactMap { release in
            guard (release["prerelease"] as? Bool) != true, (release["draft"] as? Bool) != true,
                let tag = release["tag_name"] as? String, let body = release["body"] as? String, !body.isEmpty
            else { return nil }
            let version = tag.replacingOccurrences(of: "rust-v", with: "").replacingOccurrences(of: "v", with: "")
            let source = (release["html_url"] as? String) ?? "https://github.com/openai/codex/releases/tag/\(tag)"
            return .init(client: client, version: version, source: source, body: body)
        }
    }

    /// Kiro's changelog page: the headings and list items as text, with the
    /// version taken from the address.
    static func parseKiroPage(_ html: String, client: ClientKind, source: String) -> [ClientReleaseNote] {
        guard let range = source.range(of: "/cli/") else { return [] }
        let version = source[range.upperBound...].trimmingCharacters(in: CharacterSet(charactersIn: "/")).replacingOccurrences(of: "-", with: ".")
        // Keep the article's text: strip tags, decode the few entities that
        // matter, collapse whitespace. Good enough for a model to read.
        var text = html
        if let main = text.range(of: "<main"), let end = text.range(of: "</main>", range: main.upperBound..<text.endIndex) {
            text = String(text[main.lowerBound..<end.upperBound])
        }
        text = text.replacingOccurrences(of: "<(script|style)[^>]*>[\\s\\S]*?</\\1>", with: " ", options: .regularExpression)
        text = text.replacingOccurrences(of: "</(h[1-6]|p|li|div|section|article)>", with: "\n", options: .regularExpression)
        text = text.replacingOccurrences(of: "<li[^>]*>", with: "- ", options: .regularExpression)
        text = text.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
        for (entity, character) in [("&amp;", "&"), ("&lt;", "<"), ("&gt;", ">"), ("&quot;", "\""), ("&#39;", "'"), ("&nbsp;", " ")] {
            text = text.replacingOccurrences(of: entity, with: character)
        }
        let lines = text.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        guard lines.count > 3 else { return [] }
        return [.init(client: client, version: version, source: source, body: lines.joined(separator: "\n"))]
    }

    static func bounded(_ notes: [ClientReleaseNote]) -> [ClientReleaseNote] {
        var total = 0
        var kept: [ClientReleaseNote] = []
        for var note in notes.prefix(maximumNotes) {
            if note.body.count > maximumBodyCharacters { note.body = String(note.body.prefix(maximumBodyCharacters)) + "\n…" }
            guard total + note.body.count <= maximumTotalCharacters else { break }
            total += note.body.count
            kept.append(note)
        }
        return kept
    }

    static func majorMinor(_ version: String?) -> (Int, Int)? {
        guard let version else { return nil }
        let parts = version.split(whereSeparator: { !$0.isNumber }).prefix(2).compactMap { Int($0) }
        guard parts.count == 2 else { return nil }
        return (parts[0], parts[1])
    }
}
