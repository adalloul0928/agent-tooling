import Foundation

public enum WorkspaceProjectDeclarationError: Error, Equatable, Sendable {
    case invalidRoot
    /// A locked entry whose revision is not immutable. A branch or a tag names
    /// something that moves, so it cannot restore the same bytes later.
    case mutableRevision(name: String)
    case duplicateEntry(name: String)
    case invalidEntry(name: String)
    case unsupportedFormat
    case unreadable
    /// Something is already at that path that this app did not write.
    case foreignFile(path: String)
}

/// What a project asks for, and what that resolved to.
///
/// Two files, on purpose. The **declaration** says what this project wants — by
/// name, kind and where it comes from — and is what a person edits. The **lock**
/// pins what those resolved to, by immutable revision and content digest, and is
/// what makes a later checkout reproduce the same bytes.
///
/// A branch or a tag in a lock would defeat it: those name something that moves,
/// so a lock entry without an immutable revision is refused rather than written.
///
/// Both are additive. Agent Tooling writes these two files and nothing else, and
/// refuses to overwrite anything at those paths it did not write itself. Other
/// tools' lock files are read elsewhere and never rewritten here.
///
/// Neither file carries an absolute path, an observation timestamp, a device
/// identity or a credential. They are meant to be committed and to diff cleanly,
/// which is also why every list is sorted and the encoding is deterministic:
/// the same inputs produce byte-identical output.
public struct WorkspaceProjectDeclaration: Codable, Hashable, Sendable {
    public static let formatVersion = 1
    /// Names this app's own file, so a reader can tell it apart from another
    /// tool's file that happens to sit beside it.
    public static let marker = "agent-tooling.project.v1"

    public let formatVersion: Int
    public let marker: String
    public let entries: [Entry]

    /// One thing this project asks for.
    public struct Entry: Codable, Hashable, Sendable {
        /// The name the item goes by, which is how a person recognises it and
        /// how the declaration stays readable across machines.
        public let name: String
        public let kind: ArtifactKind
        /// Credential-free HTTPS identity, when it comes from a publisher.
        /// Absent for something the person authors themselves.
        public let repositoryURL: String?
        /// What was asked for — a branch, a tag, or nothing. This is allowed to
        /// move; that is what the lock is for.
        public let requestedRef: String?
        public let packageRelativePath: String?

        public init(
            name: String, kind: ArtifactKind, repositoryURL: String? = nil,
            requestedRef: String? = nil, packageRelativePath: String? = nil
        ) {
            self.name = name
            self.kind = kind
            self.repositoryURL = repositoryURL
            self.requestedRef = requestedRef
            self.packageRelativePath = packageRelativePath
        }
    }

    public init(entries: [Entry]) throws {
        formatVersion = Self.formatVersion
        marker = Self.marker
        self.entries = try Self.validated(entries)
    }

    static func validated(_ entries: [Entry]) throws -> [Entry] {
        var seen = Set<String>()
        for entry in entries {
            guard !entry.name.isEmpty, entry.name.count <= 200,
                  !entry.name.contains("/"), entry.name != "." , entry.name != "..",
                  entry.repositoryURL.map(isCredentialFreeHTTPS) ?? true,
                  entry.packageRelativePath.map(isRelativeContainedPath) ?? true else {
                throw WorkspaceProjectDeclarationError.invalidEntry(name: entry.name)
            }
            guard seen.insert(entry.name + "\u{0}" + entry.kind.rawValue).inserted else {
                throw WorkspaceProjectDeclarationError.duplicateEntry(name: entry.name)
            }
        }
        return entries.sorted {
            $0.name == $1.name ? $0.kind.rawValue < $1.kind.rawValue : $0.name < $1.name
        }
    }
}

/// What the declaration resolved to, pinned so it can be reproduced.
public struct WorkspaceProjectLock: Codable, Hashable, Sendable {
    public static let formatVersion = 1
    public static let marker = "agent-tooling.project-lock.v1"

    public let formatVersion: Int
    public let marker: String
    public let entries: [Entry]

    public struct Entry: Codable, Hashable, Sendable {
        public let name: String
        public let kind: ArtifactKind
        public let repositoryURL: String?
        /// Kept beside the revision rather than replaced by it: what was asked
        /// for and what it turned out to be are different facts, and losing the
        /// first makes the lock impossible to explain.
        public let requestedRef: String?
        /// Immutable: a commit hash. A version tag or an opaque publisher
        /// revision is refused.
        public let revision: SourceRevision
        public let contentDigest: ContentDigest
        public let packageRelativePath: String?

        public init(
            name: String, kind: ArtifactKind, repositoryURL: String? = nil,
            requestedRef: String? = nil, revision: SourceRevision,
            contentDigest: ContentDigest, packageRelativePath: String? = nil
        ) {
            self.name = name
            self.kind = kind
            self.repositoryURL = repositoryURL
            self.requestedRef = requestedRef
            self.revision = revision
            self.contentDigest = contentDigest
            self.packageRelativePath = packageRelativePath
        }
    }

    public init(entries: [Entry]) throws {
        formatVersion = Self.formatVersion
        marker = Self.marker
        var seen = Set<String>()
        for entry in entries {
            guard !entry.name.isEmpty, entry.name.count <= 200, !entry.name.contains("/"),
                  entry.repositoryURL.map(isCredentialFreeHTTPS) ?? true,
                  entry.packageRelativePath.map(isRelativeContainedPath) ?? true,
                  !entry.contentDigest.value.isEmpty else {
                throw WorkspaceProjectDeclarationError.invalidEntry(name: entry.name)
            }
            // The whole point of a lock. A commit hash names one set of bytes
            // forever; a version tag can be re-pointed, and an opaque publisher
            // revision makes no promise this build can check. Neither of those
            // restores the same bytes later, so neither is a lock.
            let expected: Int? = switch entry.revision.kind {
            case .gitCommitSHA1: 40
            case .gitCommitSHA256: 64
            case .semanticVersion, .opaquePublisherRevision: nil
            }
            guard let expected, entry.revision.value.count == expected,
                  entry.revision.value.allSatisfy(\.isHexDigit) else {
                throw WorkspaceProjectDeclarationError.mutableRevision(name: entry.name)
            }
            guard seen.insert(entry.name + "\u{0}" + entry.kind.rawValue).inserted else {
                throw WorkspaceProjectDeclarationError.duplicateEntry(name: entry.name)
            }
        }
        self.entries = entries.sorted {
            $0.name == $1.name ? $0.kind.rawValue < $1.kind.rawValue : $0.name < $1.name
        }
    }
}

/// Reads and writes the two files in a project folder.
public struct WorkspaceProjectDeclarationStore: Sendable {
    public static let directoryName = ".agent-tooling"
    public static let declarationFileName = "project.json"
    public static let lockFileName = "project-lock.json"
    static let maximumBytes = 4 << 20

    private let directory: URL

    public init(projectRoot: URL) throws {
        guard projectRoot.isFileURL, projectRoot.path.hasPrefix("/"),
              !projectRoot.path.contains("\0"),
              projectRoot.standardizedFileURL.path == projectRoot.path else {
            throw WorkspaceProjectDeclarationError.invalidRoot
        }
        directory = projectRoot.appending(path: Self.directoryName, directoryHint: .isDirectory)
    }

    public var declarationURL: URL { directory.appending(path: Self.declarationFileName) }
    public var lockURL: URL { directory.appending(path: Self.lockFileName) }

    public func readDeclaration() throws -> WorkspaceProjectDeclaration? {
        try read(declarationURL, as: WorkspaceProjectDeclaration.self,
                 marker: WorkspaceProjectDeclaration.marker,
                 version: WorkspaceProjectDeclaration.formatVersion)
    }

    public func readLock() throws -> WorkspaceProjectLock? {
        try read(lockURL, as: WorkspaceProjectLock.self,
                 marker: WorkspaceProjectLock.marker,
                 version: WorkspaceProjectLock.formatVersion)
    }

    public func write(
        declaration: WorkspaceProjectDeclaration,
        lock: WorkspaceProjectLock?
    ) throws {
        // Refuse before writing anything, so a foreign file next to ours never
        // leaves the pair half-updated.
        try requireOursOrAbsent(declarationURL)
        if lock != nil { try requireOursOrAbsent(lockURL) }
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch { throw WorkspaceProjectDeclarationError.unreadable }
        try write(declaration, to: declarationURL)
        if let lock { try write(lock, to: lockURL) }
    }

    /// Deterministic bytes: sorted keys, no escaping, a trailing newline so the
    /// file is a well-behaved text file in a diff.
    static func encode(_ value: some Encodable) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted, .withoutEscapingSlashes]
        var bytes = try encoder.encode(value)
        bytes.append(0x0A)
        return bytes
    }

    private func write(_ value: some Encodable, to url: URL) throws {
        let bytes = try Self.encode(value)
        do { try bytes.write(to: url, options: .atomic) }
        catch { throw WorkspaceProjectDeclarationError.unreadable }
    }

    /// A file without this app's marker belongs to someone else. Overwriting it
    /// would be the opposite of additive.
    private func requireOursOrAbsent(_ url: URL) throws {
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        let bytes: Data
        do { bytes = try Data(contentsOf: url, options: [.mappedIfSafe]) }
        catch { throw WorkspaceProjectDeclarationError.unreadable }
        guard bytes.count <= Self.maximumBytes,
              let object = try? JSONSerialization.jsonObject(with: bytes) as? [String: Any],
              let marker = object["marker"] as? String,
              marker == WorkspaceProjectDeclaration.marker || marker == WorkspaceProjectLock.marker else {
            throw WorkspaceProjectDeclarationError.foreignFile(path: url.path)
        }
    }

    private func read<Value: Decodable>(
        _ url: URL, as type: Value.Type, marker: String, version: Int
    ) throws -> Value? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let bytes: Data
        do { bytes = try Data(contentsOf: url, options: [.mappedIfSafe]) }
        catch { throw WorkspaceProjectDeclarationError.unreadable }
        guard bytes.count <= Self.maximumBytes,
              let object = try? JSONSerialization.jsonObject(with: bytes) as? [String: Any],
              object["marker"] as? String == marker,
              object["formatVersion"] as? Int == version,
              let value = try? JSONDecoder().decode(Value.self, from: bytes) else {
            throw WorkspaceProjectDeclarationError.unsupportedFormat
        }
        return value
    }
}

/// No user name, no password, no query that could carry a token.
private func isCredentialFreeHTTPS(_ value: String) -> Bool {
    guard value.count <= 2_048, let components = URLComponents(string: value),
          components.scheme?.lowercased() == "https",
          components.user == nil, components.password == nil,
          components.query == nil, components.fragment == nil,
          let host = components.host, !host.isEmpty else { return false }
    return true
}

/// Relative, contained, and never a machine's own path.
private func isRelativeContainedPath(_ value: String) -> Bool {
    guard !value.isEmpty, value.count <= 1_024, !value.hasPrefix("/"),
          !value.contains("\0"), !value.contains("\\") else { return false }
    let parts = value.split(separator: "/", omittingEmptySubsequences: false)
    return !parts.isEmpty && parts.allSatisfy { !$0.isEmpty && $0 != "." && $0 != ".." }
}
