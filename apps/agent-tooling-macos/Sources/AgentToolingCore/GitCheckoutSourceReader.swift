import Darwin
import Foundation

/// Checkout paths and branch observations are device facts, not portable source ownership.
/// Deliberately not Codable: only reconciled source candidates can enter a portable review.
public struct GitCheckoutObservation: Hashable, Sendable {
    public let checkoutPath: String
    public let gitDirectory: String
    public let commonGitDirectory: String
    public let branch: String?
    public let headCommit: SourceRevision?
    public let remotes: [GitRemoteSourceObservation]
    public let upstream: GitCheckoutUpstream?
    public let diagnostics: [GitCheckoutSourceDiagnostic]

    public var isLinkedWorktree: Bool { gitDirectory != commonGitDirectory }
    // No clean/dirty or publication assertion is made by these metadata-only reads.
}

public struct GitRemoteSourceObservation: Hashable, Sendable {
    public let name: String
    /// Nil means unsupported or unsafe. The original remote URL is never retained.
    public let repositoryURL: String?
}

public struct GitCheckoutUpstream: Hashable, Sendable {
    public let remoteName: String
    public let repositoryURL: String
    /// The configured remote branch, which may differ from the local branch name.
    public let requestedRef: String
}

public enum GitCheckoutSourceDiagnostic: String, Hashable, Sendable {
    case includedConfigurationOmitted, unsupportedRemote, malformedConfiguration
    case missingUpstream, ambiguousUpstream, unsupportedUpstream, detachedHEAD, unbornHEAD
}

public enum GitCheckoutSourceReadError: Error, Equatable, Sendable {
    case invalidDirectory, notWorkingTree, commandFailed, invalidOutput, outputLimitExceeded
    case changedDuringCapture
}

public enum GitCheckoutSourceMatchIssue: String, Hashable, Sendable {
    case noUpstream, noCommit, incompleteConfiguration, excludedPackagePath
}

public struct GitCheckoutSourceRecognition: Hashable, Sendable {
    public let checkout: GitCheckoutObservation
    public let observations: [SourceEvidenceObservation]
    public let issues: [GitCheckoutSourceMatchIssue]
}

/// Reads an explicitly supplied existing checkout using local Git plumbing only.
/// No fetch, status scan, credential helper, hook, checkout, index refresh, or config write.
/// Invoke from the background inventory pipeline, never a view render path.
public struct GitCheckoutSourceReader: Sendable {
    private let runner: any CommandRunning
    private static let outputLimit = 65_536
    private static let configPattern = "^(remote\\..*\\.url|branch\\..*\\.(remote|merge)|include\\.path|includeif\\..*\\.path)$"
    private static let prefix = [
        "--no-optional-locks", "--no-pager", "-c", "core.fsmonitor=false",
        "-c", "core.hooksPath=/dev/null",
    ]

    public init(runner: any CommandRunning = ProcessCommandRunner(timeout: .seconds(5))) {
        self.runner = runner
    }

    public func capture(directory: URL) async throws -> GitCheckoutObservation {
        let directoryPath = try Self.existingDirectory(directory)
        return try await capture(canonicalDirectory: directoryPath)
    }

    /// The caller supplies an inventory artifact's observed folder, not a name match.
    /// Git finds its nearest checkout; realpath containment establishes the package path.
    /// A configured upstream is a review candidate, never an approved revision or fork.
    public func recognize(artifactID: ArtifactID, directory: URL) async throws -> GitCheckoutSourceRecognition {
        let originalPath = try Self.existingDirectory(directory)
        let checkout = try await capture(canonicalDirectory: originalPath)
        guard try Self.existingDirectory(directory) == originalPath else {
            throw GitCheckoutSourceReadError.changedDuringCapture
        }
        var issues: [GitCheckoutSourceMatchIssue] = []
        if checkout.upstream == nil { issues.append(.noUpstream) }
        if checkout.headCommit == nil { issues.append(.noCommit) }
        if checkout.diagnostics.contains(.includedConfigurationOmitted)
            || checkout.diagnostics.contains(.malformedConfiguration) {
            issues.append(.incompleteConfiguration)
        }
        let packagePath = Self.relativePath(originalPath, inside: checkout.checkoutPath)
        if packagePath == nil || !SourceEvidenceResolver.safePath(packagePath ?? "") {
            issues.append(.excludedPackagePath)
        }
        guard issues.isEmpty, let upstream = checkout.upstream, let packagePath else {
            return .init(checkout: checkout, observations: [], issues: issues)
        }
        let repositoryID = String(upstream.repositoryURL.dropFirst("https://github.com/".count))
        let evidence = SourceLockEvidence(
            skillNameHint: "", // A folder basename is not identity evidence.
            locator: .remote(repositoryID: repositoryID, sourceType: "gitCheckout",
                             repositoryURL: upstream.repositoryURL, baseURL: nil),
            revision: .requestedRef(upstream.requestedRef), skillPath: packagePath
        )
        return .init(checkout: checkout, observations: [
            .init(artifactID: artifactID, context: .exactRelativePath, evidence: evidence,
                  observedCommit: checkout.headCommit),
        ], issues: [])
    }

    private func capture(canonicalDirectory: String) async throws -> GitCheckoutObservation {
        try Task.checkCancellation()
        let first = try await readSnapshot(directory: canonicalDirectory)
        let second = try await readSnapshot(directory: canonicalDirectory)
        // A bounded optimistic observation, not an atomic Git transaction. Apply must recapture.
        guard first == second else { throw GitCheckoutSourceReadError.changedDuringCapture }
        guard Self.relativePath(canonicalDirectory, inside: first.locations.checkout) != nil else {
            throw GitCheckoutSourceReadError.invalidDirectory
        }
        return Self.observation(first)
    }

    private struct Locations: Hashable, Sendable {
        var checkout: String
        var git: String
        var common: String
    }

    private struct Snapshot: Hashable, Sendable {
        var locations: Locations
        var branch: String?
        var commit: SourceRevision?
        var worktreeConfigurationEnabled: Bool
        var localConfig: [ConfigEntry]
        var worktreeConfig: [ConfigEntry]
    }

    private struct ConfigEntry: Hashable, Sendable {
        var key: String
        var value: String
    }

    private func readSnapshot(directory: String) async throws -> Snapshot {
        let rootOutput = try await git([
            "rev-parse", "--path-format=absolute", "--show-toplevel", "--absolute-git-dir", "--git-common-dir",
        ], directory: directory)
        guard rootOutput.status == 0 else { throw GitCheckoutSourceReadError.notWorkingTree }
        let paths = rootOutput.standardOutput.split(separator: "\n", omittingEmptySubsequences: false)
        guard paths.count == 4, paths[3].isEmpty,
              paths.prefix(3).allSatisfy({ $0.hasPrefix("/") && !$0.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) })
        else { throw GitCheckoutSourceReadError.invalidOutput }
        let locations = try Locations(
            checkout: Self.existingDirectory(URL(fileURLWithPath: String(paths[0]))),
            git: Self.existingDirectory(URL(fileURLWithPath: String(paths[1]))),
            common: Self.existingDirectory(URL(fileURLWithPath: String(paths[2])))
        )
        async let commitOutput = git(["rev-parse", "--verify", "--quiet", "--end-of-options", "HEAD^{commit}"], directory: directory)
        async let branchOutput = git(["symbolic-ref", "--quiet", "HEAD"], directory: directory)
        async let localOutput = git(["config", "--local", "--null", "--no-includes", "--get-regexp", Self.configPattern], directory: directory)
        async let extensionOutput = git(["config", "--local", "--no-includes", "--type=bool", "--get", "extensions.worktreeConfig"], directory: directory)
        let (commitResult, branchResult, localResult, extensionResult) = try await (
            commitOutput, branchOutput, localOutput, extensionOutput
        )
        let commit = try Self.readCommit(commitResult)
        let branch = try Self.readBranch(branchResult)
        let worktreeEnabled = try Self.readWorktreeExtension(extensionResult)
        // Git rejects --worktree for a repository with multiple worktrees unless
        // this extension is enabled. An inactive config.worktree is not evidence.
        let worktreeConfig: [ConfigEntry]
        if worktreeEnabled {
            let output = try await git(["config", "--worktree", "--null", "--no-includes", "--get-regexp", Self.configPattern], directory: directory)
            worktreeConfig = try Self.configEntries(output)
        } else {
            worktreeConfig = []
        }
        guard commit != nil || branch != nil else { throw GitCheckoutSourceReadError.invalidOutput }
        return try Snapshot(
            locations: locations, branch: branch, commit: commit,
            worktreeConfigurationEnabled: worktreeEnabled,
            localConfig: Self.configEntries(localResult), worktreeConfig: worktreeConfig
        )
    }

    private func git(_ arguments: [String], directory: String) async throws -> CommandOutput {
        try Task.checkCancellation()
        let output: CommandOutput
        do {
            output = try await runner.run(executable: "/usr/bin/git", arguments: Self.prefix + arguments,
                                          currentDirectory: URL(fileURLWithPath: directory, isDirectory: true))
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            // Runner errors may include absolute paths or Git's unsanitized stderr.
            try Task.checkCancellation()
            throw GitCheckoutSourceReadError.commandFailed
        }
        try Task.checkCancellation()
        guard output.standardOutput.utf8.count <= Self.outputLimit,
              output.standardError.utf8.count <= Self.outputLimit else {
            throw GitCheckoutSourceReadError.outputLimitExceeded
        }
        return output
    }

    private static func readCommit(_ output: CommandOutput) throws -> SourceRevision? {
        if output.status == 1 && output.standardOutput.isEmpty { return nil }
        guard output.status == 0, let value = singleLine(output.standardOutput) else {
            throw GitCheckoutSourceReadError.invalidOutput
        }
        let revision = SourceRevision(kind: value.count == 40 ? .gitCommitSHA1 : .gitCommitSHA256, value: value)
        guard SourceEvidenceResolver.validCommit(revision) else { throw GitCheckoutSourceReadError.invalidOutput }
        return revision
    }

    private static func readBranch(_ output: CommandOutput) throws -> String? {
        if output.status == 1 && output.standardOutput.isEmpty { return nil }
        guard output.status == 0, let value = singleLine(output.standardOutput), value.hasPrefix("refs/heads/") else {
            throw GitCheckoutSourceReadError.invalidOutput
        }
        let branch = String(value.dropFirst("refs/heads/".count))
        guard SourceEvidenceResolver.safeRef(branch) else { throw GitCheckoutSourceReadError.invalidOutput }
        return branch
    }

    private static func readWorktreeExtension(_ output: CommandOutput) throws -> Bool {
        if output.status == 1 && output.standardOutput.isEmpty { return false }
        guard output.status == 0, let value = singleLine(output.standardOutput),
              value == "true" || value == "false" else { throw GitCheckoutSourceReadError.invalidOutput }
        return value == "true"
    }

    private static func singleLine(_ value: String) -> String? {
        guard value.hasSuffix("\n") else { return nil }
        let line = String(value.dropLast())
        guard !line.isEmpty, !line.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else { return nil }
        return line
    }

    private static func configEntries(_ output: CommandOutput) throws -> [ConfigEntry] {
        if output.status == 1 && output.standardOutput.isEmpty { return [] }
        guard output.status == 0 else { throw GitCheckoutSourceReadError.commandFailed }
        if output.standardOutput.isEmpty { return [] }
        let records = output.standardOutput.split(separator: "\0", omittingEmptySubsequences: false)
        guard records.last?.isEmpty == true, records.count <= 1_025 else {
            throw GitCheckoutSourceReadError.invalidOutput
        }
        return try records.dropLast().map { record in
            guard let delimiter = record.firstIndex(of: "\n") else { throw GitCheckoutSourceReadError.invalidOutput }
            return .init(key: String(record[..<delimiter]), value: String(record[record.index(after: delimiter)...]))
        }
    }

    private static func observation(_ snapshot: Snapshot) -> GitCheckoutObservation {
        // Remove exact repeats only; conflicting values remain ambiguous,
        // including local/worktree overrides.
        let config = Set(snapshot.localConfig + snapshot.worktreeConfig)
        var diagnostics = Set<GitCheckoutSourceDiagnostic>()
        var remotes = Set<GitRemoteSourceObservation>()
        for entry in config {
            if entry.key.hasPrefix("include.") || entry.key.hasPrefix("includeif.") {
                diagnostics.insert(.includedConfigurationOmitted)
                continue
            }
            guard entry.key.hasPrefix("remote."), entry.key.hasSuffix(".url") else { continue }
            let name = String(entry.key.dropFirst("remote.".count).dropLast(".url".count))
            guard safeRemoteName(name) else { diagnostics.insert(.malformedConfiguration); continue }
            let url = canonicalRemoteURL(entry.value)
            if url == nil { diagnostics.insert(.unsupportedRemote) }
            remotes.insert(.init(name: name, repositoryURL: url))
        }
        let orderedRemotes = remotes.sorted {
            $0.name == $1.name ? ($0.repositoryURL ?? "") < ($1.repositoryURL ?? "") : $0.name < $1.name
        }
        var upstream: GitCheckoutUpstream?
        if let branch = snapshot.branch {
            let remoteValues = Set(config.filter { $0.key == "branch.\(branch).remote" }.map(\.value))
            let mergeValues = Set(config.filter { $0.key == "branch.\(branch).merge" }.map(\.value))
            if remoteValues.isEmpty || mergeValues.isEmpty {
                diagnostics.insert(.missingUpstream)
            } else if remoteValues.count != 1 || mergeValues.count != 1 {
                diagnostics.insert(.ambiguousUpstream)
            } else if let remote = remoteValues.first, let merge = mergeValues.first,
                      safeRemoteName(remote), merge.hasPrefix("refs/heads/"),
                      SourceEvidenceResolver.safeRef(String(merge.dropFirst("refs/heads/".count))) {
                let matching = orderedRemotes.filter { $0.name == remote }
                if matching.count == 1, let url = matching[0].repositoryURL {
                    upstream = .init(remoteName: remote, repositoryURL: url,
                                     requestedRef: String(merge.dropFirst("refs/heads/".count)))
                } else {
                    diagnostics.insert(matching.count > 1 ? .ambiguousUpstream : .unsupportedUpstream)
                }
            } else {
                diagnostics.insert(.unsupportedUpstream)
            }
            if snapshot.commit == nil { diagnostics.insert(.unbornHEAD) }
        } else {
            diagnostics.insert(.detachedHEAD)
        }
        return .init(checkoutPath: snapshot.locations.checkout, gitDirectory: snapshot.locations.git,
                     commonGitDirectory: snapshot.locations.common, branch: snapshot.branch,
                     headCommit: snapshot.commit, remotes: orderedRemotes, upstream: upstream,
                     diagnostics: diagnostics.sorted { $0.rawValue < $1.rawValue })
    }

    /// Normalize the GitHub SSH transport forms only after requiring GitHub's literal `git` user.
    /// Tokens/userinfo, aliases, ports, URL rewriting, and other hosts remain unsupported evidence.
    static func canonicalRemoteURL(_ value: String) -> String? {
        guard value.utf8.count <= 4_096,
              !value.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else { return nil }
        if value.hasPrefix("git@github.com:") {
            return SourceEvidenceResolver.canonicalGitHubURL("https://github.com/" + value.dropFirst("git@github.com:".count))
        }
        if let components = URLComponents(string: value), components.scheme?.lowercased() == "ssh",
           components.host?.lowercased() == "github.com", components.user == "git",
           components.password == nil, components.port == nil, components.query == nil, components.fragment == nil,
           components.percentEncodedPath == components.path {
            return SourceEvidenceResolver.canonicalGitHubURL("https://github.com" + components.path)
        }
        return SourceEvidenceResolver.canonicalGitHubURL(value)
    }

    private static func safeRemoteName(_ value: String) -> Bool {
        !value.isEmpty && value.count <= 128 && value != "." && value != ".." && !value.hasPrefix("-")
            && value.unicodeScalars.allSatisfy {
                CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_.").contains($0)
            }
    }

    private static func existingDirectory(_ url: URL) throws -> String {
        guard url.isFileURL, url.host == nil || url.host == "localhost", url.path.hasPrefix("/"),
              url.path.utf8.count <= 4_096,
              !url.path.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains),
              let resolved = url.path.withCString({ realpath($0, nil) }) else {
            throw GitCheckoutSourceReadError.invalidDirectory
        }
        defer { free(resolved) }
        let path = String(cString: resolved)
        var directory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &directory), directory.boolValue else {
            throw GitCheckoutSourceReadError.invalidDirectory
        }
        return path
    }

    private static func relativePath(_ path: String, inside root: String) -> String? {
        if path == root { return "." }
        let prefix = root.hasSuffix("/") ? root : root + "/"
        guard path.hasPrefix(prefix) else { return nil }
        return String(path.dropFirst(prefix.count))
    }
}
