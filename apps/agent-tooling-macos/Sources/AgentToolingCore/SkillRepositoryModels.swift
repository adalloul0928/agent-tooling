import Foundation

/// An upstream relationship for existing standalone installations, never an authored copy.
public struct SkillRepositoryBinding: Codable, Hashable, Sendable {
    public var repositoryURL: String
    public var ref: String
    public var subdirectory: String
    public var installedRevision: String?
    public var installedFingerprints: [String: String]
    public var lastCheckedRevision: String?
    public var lastCheckedFingerprint: String?
    public var lastCheckedAt: Date?
    public var lastCheckError: String?

    public init(repositoryURL: String, ref: String = "HEAD", subdirectory: String = "", installedFingerprints: [String: String] = [:])
        throws
    {
        self.repositoryURL = repositoryURL.hasSuffix(".git") ? String(repositoryURL.dropLast(4)) : repositoryURL
        self.ref = ref.isEmpty ? "HEAD" : ref
        self.subdirectory = subdirectory == "." ? "" : subdirectory
        self.installedFingerprints = installedFingerprints
        try validate()
    }

    public func validate() throws {
        guard let url = URLComponents(string: repositoryURL), url.scheme == "https", url.host == "github.com",
            url.user == nil, url.password == nil, url.port == nil, url.query == nil, url.fragment == nil,
            url.percentEncodedPath == url.path,
            url.path.split(separator: "/", omittingEmptySubsequences: false).count == 3,
            url.path.dropFirst().split(separator: "/").allSatisfy({ Self.safeRepositoryComponent(String($0)) })
        else { throw SkillRepositoryError.invalidRepository }
        guard ref.count <= 200, !ref.isEmpty, !ref.hasPrefix("-"), !ref.hasPrefix("/"), !ref.hasSuffix("/"),
            !ref.contains(".."), !ref.contains("@{"), !ref.contains("//"), !ref.hasSuffix(".lock"),
            ref.unicodeScalars.allSatisfy({
                CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_/.").contains($0)
            })
        else { throw SkillRepositoryError.invalidRef }
        guard Self.safeRelativePath(subdirectory, allowEmpty: true), subdirectory.count <= 2_048,
            installedFingerprints.count <= 16
        else { throw SkillRepositoryError.invalidPath }
        for (path, fingerprint) in installedFingerprints {
            guard path.hasPrefix("/"), path.count <= 8_192,
                !path.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains),
                URL(fileURLWithPath: path).standardizedFileURL.path == path,
                Self.isHash(fingerprint)
            else { throw SkillRepositoryError.invalidPath }
        }
        for revision in [installedRevision, lastCheckedRevision].compactMap({ $0 }) {
            guard Self.isHash(revision, lengths: [40, 64]) else { throw SkillRepositoryError.invalidRevision }
        }
        if let lastCheckedFingerprint, !Self.isHash(lastCheckedFingerprint) { throw SkillRepositoryError.invalidRevision }
        if let lastCheckError, lastCheckError.count > 2_048 { throw SkillRepositoryError.invalidRepository }
    }

    static func safeRelativePath(_ value: String, allowEmpty: Bool = false) -> Bool {
        if value.isEmpty { return allowEmpty }
        return value.count <= 8_192 && !value.hasPrefix("/") && !value.contains("\\")
            && !value.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
            && value.split(separator: "/", omittingEmptySubsequences: false).allSatisfy {
                !$0.isEmpty && $0 != "." && $0 != ".." && $0.lowercased() != ".git"
            }
    }

    static func isHash(_ value: String, lengths: Set<Int> = [64]) -> Bool {
        lengths.contains(value.count) && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }

    private static func safeRepositoryComponent(_ value: String) -> Bool {
        !value.isEmpty && value != "." && value != ".." && value.count <= 100
            && value.unicodeScalars.allSatisfy {
                CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_.").contains($0)
            }
    }
}

public struct SkillRepositoryUpdate: Sendable {
    public let skillID: String
    public let plan: OperationPlan
    public let stagingURL: URL
    public let revision: String
    public let fingerprint: String
}

public enum SkillRepositoryError: LocalizedError, Equatable {
    case invalidRepository, invalidRef, invalidPath, invalidRevision
    case unavailable, unsupportedInstallation, sourceMissing, changedInstallation, nameMismatch, unsafeTree

    public var errorDescription: String? {
        switch self {
        case .invalidRepository: "Enter a complete HTTPS GitHub repository URL, such as https://github.com/owner/repository."
        case .invalidRef: "Enter a branch, tag, or commit ref without Git expressions or option characters."
        case .invalidPath: "Use a repository-relative skill folder without parent traversal, hidden Git metadata, or symbolic links."
        case .invalidRevision: "The repository returned an invalid revision or fingerprint. Check the source again."
        case .unavailable: "The GitHub repository or ref could not be fetched. Check the URL, ref, and public read access."
        case .unsupportedInstallation:
            "Updates need a directly installed standalone skill folder. Plugin skills, linked folders, and nested references remain managed by their original source."
        case .sourceMissing: "The selected repository folder does not contain a readable SKILL.md. Check the folder and ref."
        case .changedInstallation:
            "An installed copy changed after its source was linked. Review those local changes before linking a new baseline."
        case .nameMismatch: "The repository skill name does not match the installed skill. Choose its original upstream folder."
        case .unsafeTree:
            "The repository skill contains symbolic links, submodules, unsupported paths, or more content than can be reviewed."
        }
    }
}
