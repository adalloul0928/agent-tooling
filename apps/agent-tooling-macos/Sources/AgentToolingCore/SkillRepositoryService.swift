import Foundation

/// Fetches into an isolated bare repository. No user's checkout or Git configuration is used.
struct SkillRepositoryService: Sendable {
    let cacheURL: URL
    let runner: any CommandRunning

    struct Checkout: Sendable {
        let rootURL: URL
        let skillURL: URL
        let revision: String
        let fingerprint: String
        let frontmatter: SkillFrontmatter
    }

    func fetch(_ binding: SkillRepositoryBinding) async throws -> Checkout {
        try binding.validate()
        let manager = FileManager.default
        let taskRoot = cacheURL.appending(path: "skill-repositories/\(UUID().uuidString)")
        try Self.createPrivateDirectory(taskRoot)
        let export = taskRoot.appending(path: "files")
        do {
            try Self.createPrivateDirectory(export)
            let (gitRoot, revision) = try await shallowFetch(binding.repositoryURL, ref: binding.ref, into: taskRoot)
            let selected = binding.subdirectory.isEmpty ? "." : binding.subdirectory
            let listing = try await git(
                [
                    "--git-dir=\(gitRoot.path)", "ls-tree", "-r", "-l", "-z", "--full-tree", revision, "--", selected,
                ], root: taskRoot)
            try Self.validateListing(listing, subdirectory: binding.subdirectory)
            // The clean environment and bare repo have no filter drivers, hooks, credential helpers,
            // inherited templates, or submodule commands. Checkout copies Git blobs only.
            _ = try await git(
                [
                    "--git-dir=\(gitRoot.path)", "--work-tree=\(export.path)", "checkout", revision, "--", selected,
                ], root: taskRoot)
            let skillURL = binding.subdirectory.isEmpty ? export : export.appending(path: binding.subdirectory)
            let content: String
            do { content = try BoundedFileAccess.readUTF8(at: skillURL.appending(path: "SKILL.md"), allowSymbolicLink: false) } catch {
                throw SkillRepositoryError.sourceMissing
            }
            let metadata = try SkillFrontmatter.parse(content)
            let fingerprint = try DirectoryFingerprint.sha256(of: skillURL)
            return Checkout(rootURL: taskRoot, skillURL: skillURL, revision: revision, fingerprint: fingerprint, frontmatter: metadata)
        } catch {
            try? manager.removeItem(at: taskRoot)
            throw error
        }
    }

    func discard(_ checkout: Checkout) { try? FileManager.default.removeItem(at: checkout.rootURL) }

    /// One commit of one ref into a fresh bare repository under `taskRoot`:
    /// no tags, no submodules, no history. Returns where it landed and the
    /// commit it resolved to.
    private func shallowFetch(_ repositoryURL: String, ref: String, into taskRoot: URL) async throws -> (gitRoot: URL, revision: String) {
        let gitRoot = taskRoot.appending(path: "repository.git")
        _ = try await git(["init", "--bare", "--template=", gitRoot.path], root: taskRoot)
        try Self.createPrivateDirectory(gitRoot.appending(path: "info"))
        try "* -filter -text -ident -working-tree-encoding\n".write(
            to: gitRoot.appending(path: "info/attributes"), atomically: true, encoding: .utf8)
        _ = try await git(
            [
                "--git-dir=\(gitRoot.path)", "fetch", "--depth=1", "--no-tags", "--no-recurse-submodules",
                "--", repositoryURL, ref,
            ], root: taskRoot)
        let revision = try await git(["--git-dir=\(gitRoot.path)", "rev-parse", "--verify", "FETCH_HEAD^{commit}"], root: taskRoot)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard SkillRepositoryBinding.isHash(revision, lengths: [40, 64]) else { throw SkillRepositoryError.invalidRevision }
        return (gitRoot, revision)
    }

    // MARK: - Finding a skill the listing only named

    /// The most SKILL.md files this will look inside when no folder carries the
    /// skill's name. A registry listing names the skill, not the folder.
    static let frontmatterProbeLimit = 64

    /// Where one skill lives in a repository, when all that is known is the
    /// repository and the skill's name (what a registry such as skills.sh
    /// publishes). Resolves the repository's default branch, reads the tree at
    /// its tip, and takes the SKILL.md whose folder is named for the skill;
    /// failing that, the one whose frontmatter names it. Returns a binding to
    /// that folder on that branch, ready to fetch and to follow.
    func locate(skillID: String, repositoryURL: String) async throws -> SkillRepositoryBinding {
        let probe = try SkillRepositoryBinding(repositoryURL: repositoryURL)
        let wanted = Self.comparableName(skillID)
        guard !wanted.isEmpty else { throw SkillRepositoryError.sourceMissing }
        let manager = FileManager.default
        let taskRoot = cacheURL.appending(path: "skill-repositories/\(UUID().uuidString)")
        try Self.createPrivateDirectory(taskRoot)
        defer { try? manager.removeItem(at: taskRoot) }

        let ref = try await defaultBranch(of: probe.repositoryURL, root: taskRoot) ?? probe.ref
        let (gitRoot, revision) = try await shallowFetch(probe.repositoryURL, ref: ref, into: taskRoot)
        let listing = try await git(
            ["--git-dir=\(gitRoot.path)", "ls-tree", "-r", "-z", "--name-only", "--full-tree", revision], root: taskRoot)
        let folders = try Self.skillFolders(in: listing)

        // The folder named for the skill, shallowest first.
        let named = folders.filter { Self.comparableName($0.split(separator: "/").last.map(String.init) ?? "") == wanted }
        if let folder = Self.shallowest(named) {
            return try SkillRepositoryBinding(repositoryURL: probe.repositoryURL, ref: ref, subdirectory: folder)
        }
        // Otherwise the skill that says it is this one, in its own frontmatter.
        var declared: [String] = []
        for folder in folders.sorted(by: Self.shallowerFirst).prefix(Self.frontmatterProbeLimit) {
            let path = folder.isEmpty ? "SKILL.md" : folder + "/SKILL.md"
            guard let content = try? await git(["--git-dir=\(gitRoot.path)", "show", "\(revision):\(path)"], root: taskRoot),
                  content.utf8.count <= BoundedFileAccess.maximumConfigurationBytes,
                  let frontmatter = try? SkillFrontmatter.parse(content),
                  Self.comparableName(frontmatter.name) == wanted
            else { continue }
            declared.append(folder)
        }
        guard let folder = Self.shallowest(declared) else { throw SkillRepositoryError.sourceMissing }
        return try SkillRepositoryBinding(repositoryURL: probe.repositoryURL, ref: ref, subdirectory: folder)
    }

    /// The branch the repository's HEAD points at, from `ls-remote --symref`,
    /// or nil when the remote does not say. Only a name the binding would
    /// accept is returned; anything else is treated as not said.
    private func defaultBranch(of repositoryURL: String, root: URL) async throws -> String? {
        let output = try await git(["ls-remote", "--symref", "--", repositoryURL, "HEAD"], root: root)
        for line in output.split(separator: "\n") where line.hasPrefix("ref: refs/heads/") {
            let name = String(line.dropFirst("ref: refs/heads/".count).split(separator: "\t").first ?? "")
            if (try? SkillRepositoryBinding(repositoryURL: repositoryURL, ref: name)) != nil { return name }
        }
        return nil
    }

    /// Folders holding a SKILL.md, as repository-relative paths ("" for the
    /// root), from a NUL-separated name-only tree listing. The listing is
    /// bounded like any other tree this service reads.
    static func skillFolders(in listing: String) throws -> [String] {
        let paths = listing.split(separator: "\0", omittingEmptySubsequences: true).map(String.init)
        guard paths.count <= 10_000, listing.utf8.count < 1_000_000 else { throw SkillRepositoryError.unsafeTree }
        return paths.compactMap { path in
            guard SkillRepositoryBinding.safeRelativePath(path) else { return nil }
            if path == "SKILL.md" { return "" }
            guard path.hasSuffix("/SKILL.md") else { return nil }
            return String(path.dropLast("/SKILL.md".count))
        }
    }

    /// Names compare without case or the hyphen/underscore distinction, which
    /// is how registries and folders usually differ for one skill.
    static func comparableName(_ name: String) -> String { SkillRepositoryBinding.comparableSkillName(name) }

    private static func shallowerFirst(_ lhs: String, _ rhs: String) -> Bool {
        let (l, r) = (lhs.split(separator: "/").count, rhs.split(separator: "/").count)
        return l == r ? lhs < rhs : l < r
    }

    private static func shallowest(_ folders: [String]) -> String? {
        folders.sorted(by: shallowerFirst).first
    }

    private func git(_ arguments: [String], root: URL) async throws -> String {
        let environment = [
            "-i", "PATH=/usr/bin:/bin", "HOME=\(root.path)", "XDG_CONFIG_HOME=\(root.path)",
            "GIT_CONFIG_NOSYSTEM=1", "GIT_CONFIG_GLOBAL=/dev/null", "GIT_TERMINAL_PROMPT=0",
            "GIT_ATTR_NOSYSTEM=1",
            "GIT_ALLOW_PROTOCOL=https", "LC_ALL=C", "/usr/bin/git", "--literal-pathspecs",
            "-c", "core.hooksPath=/dev/null", "-c", "credential.helper=", "-c", "protocol.file.allow=never",
            "-c", "protocol.ext.allow=never", "-c", "http.followRedirects=false",
            "-c", "core.attributesFile=/dev/null", "-c", "core.autocrlf=false",
        ]
        do {
            let output = try await runner.run(executable: "/usr/bin/env", arguments: environment + arguments, currentDirectory: root)
            guard output.status == 0 else { throw SkillRepositoryError.unavailable }
            return output.standardOutput
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw SkillRepositoryError.unavailable
        }
    }

    static func validateListing(_ listing: String, subdirectory: String) throws {
        let entries = listing.split(separator: "\0", omittingEmptySubsequences: true)
        guard !entries.isEmpty, entries.count <= 10_000, listing.utf8.count < 1_000_000 else { throw SkillRepositoryError.unsafeTree }
        var total = 0
        var paths = Set<String>()
        for entry in entries {
            guard let tab = entry.firstIndex(of: "\t") else { throw SkillRepositoryError.unsafeTree }
            let fields = entry[..<tab].split(whereSeparator: \.isWhitespace)
            let path = String(entry[entry.index(after: tab)...])
            guard fields.count == 4, ["100644", "100755"].contains(String(fields[0])), fields[1] == "blob",
                let size = Int(fields[3]), size >= 0, size <= 32 * 1_024 * 1_024,
                SkillRepositoryBinding.safeRelativePath(path),
                paths.insert(path.precomposedStringWithCanonicalMapping.lowercased()).inserted,
                subdirectory.isEmpty || path.hasPrefix(subdirectory + "/")
            else { throw SkillRepositoryError.unsafeTree }
            total += size
            guard total <= 128 * 1_024 * 1_024 else { throw SkillRepositoryError.unsafeTree }
        }
    }

    static func createPrivateDirectory(_ url: URL) throws {
        let manager = FileManager.default
        let normalized = url.standardizedFileURL
        guard normalized.path == normalized.resolvingSymlinksInPath().path else { throw SkillRepositoryError.invalidPath }
        try manager.createDirectory(at: normalized, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        guard normalized.path == normalized.resolvingSymlinksInPath().path else { throw SkillRepositoryError.invalidPath }
    }
}
