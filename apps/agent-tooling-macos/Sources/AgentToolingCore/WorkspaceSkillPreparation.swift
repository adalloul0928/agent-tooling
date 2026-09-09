import Foundation

public struct PreparedStandaloneSkill: Sendable, Equatable {
    public let tree: CapturedPackageTree
    public let frontmatter: SkillFrontmatter
    public let review: StandaloneSkillContentReview

    init(tree: CapturedPackageTree, upstream: PreparedSkillUpstream? = nil) throws {
        self.tree = tree
        self.frontmatter = try validatedStandaloneFrontmatter(tree)
        self.review = .init(
            contentDigest: tree.digest,
            excludedRootGitMetadata: tree.excludedRootGitMetadata,
            upstream: upstream
        )
    }
}

public struct StandaloneSkillContentReview: Codable, Sendable, Equatable {
    public let contentDigest: ContentDigest
    public let excludedRootGitMetadata: Bool
    public let upstream: PreparedSkillUpstream?

    init(contentDigest: ContentDigest, excludedRootGitMetadata: Bool, upstream: PreparedSkillUpstream?) {
        self.contentDigest = contentDigest
        self.excludedRootGitMetadata = excludedRootGitMetadata
        self.upstream = upstream
    }
}

public struct PreparedSkillUpstream: Codable, Sendable, Equatable {
    public let repositoryURL: String
    public let requestedRef: String
    public let revision: SourceRevision
    public let packageRelativePath: String
    public let publisherID: String

    init(
        repositoryURL: String,
        requestedRef: String,
        revision: SourceRevision,
        packageRelativePath: String,
        publisherID: String
    ) {
        self.repositoryURL = repositoryURL
        self.requestedRef = requestedRef
        self.revision = revision
        self.packageRelativePath = packageRelativePath
        self.publisherID = publisherID
    }
}

public enum WorkspaceSkillPreparationError: Error, Equatable, Sendable {
    case missingSkillDefinition
    case invalidSkillDefinition
    case pluginPackageRoot
    case invalidUpstream
}

/// Produces immutable, reviewable standalone-skill content. It never writes a
/// client destination or changes workspace authority.
public enum WorkspaceSkillPreparation {
    public static func personal(tree: CapturedPackageTree) throws -> PreparedStandaloneSkill {
        try PreparedStandaloneSkill(tree: tree)
    }

    public static func capturePersonal(directory: URL) async throws -> PreparedStandaloneSkill {
        let tree = try await PackageTreeCapture().capture(directory: directory)
        try Task.checkCancellation()
        return try personal(tree: tree)
    }

    public static func fetchUpstream(
        binding: SkillRepositoryBinding,
        cacheURL: URL
    ) async throws -> PreparedStandaloneSkill {
        try await fetchUpstream(binding: binding, cacheURL: cacheURL, runner: ProcessCommandRunner())
    }

    static func fetchUpstream(
        binding: SkillRepositoryBinding,
        cacheURL: URL,
        runner: any CommandRunning
    ) async throws -> PreparedStandaloneSkill {
        try Task.checkCancellation()
        do {
            try binding.validate()
            let service = SkillRepositoryService(cacheURL: cacheURL, runner: runner)
            let checkout = try await service.fetch(binding)
            defer { service.discard(checkout) }
            let tree = try await PackageTreeCapture().capture(directory: checkout.skillURL)
            try Task.checkCancellation()
            guard let source = canonicalUpstream(binding: binding, revision: checkout.revision) else {
                throw WorkspaceSkillPreparationError.invalidUpstream
            }
            return try PreparedStandaloneSkill(tree: tree, upstream: source)
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as WorkspaceSkillPreparationError {
            throw error
        } catch let error as PackageTreeError {
            throw error
        } catch let error as SkillRepositoryError {
            throw error
        } catch {
            throw WorkspaceSkillPreparationError.invalidUpstream
        }
    }

    private static func canonicalUpstream(
        binding: SkillRepositoryBinding,
        revision: String
    ) -> PreparedSkillUpstream? {
        guard let components = URLComponents(string: binding.repositoryURL),
              components.scheme?.lowercased() == "https",
              components.host?.lowercased() == "github.com" else { return nil }
        let parts = components.path.split(separator: "/").map(String.init)
        guard parts.count == 2,
              SkillRepositoryBinding.isHash(revision, lengths: [40, 64]) else { return nil }
        let owner = parts[0].lowercased()
        let repository = parts[1].lowercased()
        return PreparedSkillUpstream(
            repositoryURL: "https://github.com/\(owner)/\(repository)",
            requestedRef: binding.ref,
            revision: .init(kind: revision.count == 40 ? .gitCommitSHA1 : .gitCommitSHA256, value: revision),
            packageRelativePath: binding.subdirectory.isEmpty ? "." : binding.subdirectory,
            publisherID: "github:\(owner)"
        )
    }
}

private func validatedStandaloneFrontmatter(_ tree: CapturedPackageTree) throws -> SkillFrontmatter {
    try Task.checkCancellation()
    let index = Dictionary(uniqueKeysWithValues: tree.entries.map { ($0.relativePath, $0.kind) })
    // Native clients also run on case-insensitive macOS volumes. A differently
    // cased package marker still denotes a package, not a standalone skill.
    let paths = index.keys.map { $0.lowercased() }
    guard !paths.contains("plugin.json"),
          !paths.contains("agent-plugin.json"),
          !paths.contains(".agents/plugin.json"),
          !paths.contains(where: { $0 == ".claude-plugin" || $0.hasPrefix(".claude-plugin/") }),
          !paths.contains(where: { $0 == ".codex-plugin" || $0.hasPrefix(".codex-plugin/") }) else {
        throw WorkspaceSkillPreparationError.pluginPackageRoot
    }
    guard case .file(let bytes, _)? = index["SKILL.md"] else {
        throw WorkspaceSkillPreparationError.missingSkillDefinition
    }
    guard let markdown = String(data: bytes, encoding: .utf8) else {
        throw WorkspaceSkillPreparationError.invalidSkillDefinition
    }
    do {
        return try SkillFrontmatter.parse(markdown)
    } catch {
        throw WorkspaceSkillPreparationError.invalidSkillDefinition
    }
}
