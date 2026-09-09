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
        let gitRoot = taskRoot.appending(path: "repository.git")
        let export = taskRoot.appending(path: "files")
        do {
            try Self.createPrivateDirectory(export)
            _ = try await git(["init", "--bare", "--template=", gitRoot.path], root: taskRoot)
            try Self.createPrivateDirectory(gitRoot.appending(path: "info"))
            try "* -filter -text -ident -working-tree-encoding\n".write(
                to: gitRoot.appending(path: "info/attributes"), atomically: true, encoding: .utf8)
            _ = try await git(
                [
                    "--git-dir=\(gitRoot.path)", "fetch", "--depth=1", "--no-tags", "--no-recurse-submodules",
                    "--", binding.repositoryURL, binding.ref,
                ], root: taskRoot)
            let revision = try await git(["--git-dir=\(gitRoot.path)", "rev-parse", "--verify", "FETCH_HEAD^{commit}"], root: taskRoot)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard SkillRepositoryBinding.isHash(revision, lengths: [40, 64]) else { throw SkillRepositoryError.invalidRevision }
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
