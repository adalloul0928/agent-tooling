import Foundation

/// Why a step of carrying revisions through Git failed.
///
/// No description closes with "Nothing was changed.": a sync pass adds that
/// itself, once, to whatever it reports.
public enum GitWorkspaceTransportError: Error, Equatable, Sendable, LocalizedError {
    case invalidCheckout
    case invalidRemote
    case commandFailed
    case outputLimitExceeded
    case invalidDocument
    case documentTooLarge
    /// The remote advanced while this device was preparing. Fetch and merge;
    /// this transport never force-pushes.
    case remoteAdvanced(remoteHead: String)
    case unrelatedWorkingTreeChanges
    case notEnrolled
    /// A content tree in the repository does not hash to the digest it is
    /// filed under. It is refused; nothing is imported from it.
    case contentMismatch(ContentDigest)
    /// The checkout folder already holds a clone of a different repository.
    /// It is not replaced here: a folder somebody chose is theirs.
    case checkoutHasAnotherRemote
    /// Talking to the remote failed, for the reason Git's own message gave:
    /// it could not be reached, the sign-in did not open it, it is not there,
    /// it took too long, it refused the push, or it holds a library from a
    /// newer Agent Tooling.
    case remote(GitRemoteProblem)

    public var errorDescription: String? {
        switch self {
        case .invalidCheckout: "The repository’s folder on this Mac could not be used."
        case .invalidRemote: "Enter a repository address without a user name or password in it."
        case .commandFailed: "Git could not finish working with the repository’s folder on this Mac."
        case .outputLimitExceeded: "Git answered with more than Agent Tooling reads at once."
        case .invalidDocument: "The library in the repository could not be read."
        case .documentTooLarge: "The library is larger than one repository file can carry."
        case .remoteAdvanced: "Another Mac published while this one was working. Sync again to finish."
        case .unrelatedWorkingTreeChanges: "The repository’s folder on this Mac holds files Agent Tooling did not write."
        case .notEnrolled: "This Mac is not connected to a repository."
        case .contentMismatch: "A skill’s files in the repository do not match their record, so they were not taken in."
        case .checkoutHasAnotherRemote: "That folder already holds a copy of another repository. Choose an empty folder."
        case .remote(let problem): problem.sentence
        }
    }
}

/// A remote workspace head, as observed. A missing head means an empty
/// repository, not an empty workspace.
public struct GitWorkspaceRemoteState: Hashable, Sendable {
    public let head: String?
    public let document: PortableWorkspaceDocument?
    /// Content trees the remote holds, by digest. Empty for a transport that
    /// does not carry content.
    public let contentDigests: Set<ContentDigest>
    /// Every Mac's published summary the remote holds, newest commit's version.
    public let deviceStatuses: [PublishedDeviceStatus]

    public init(
        head: String?, document: PortableWorkspaceDocument?,
        contentDigests: Set<ContentDigest> = [], deviceStatuses: [PublishedDeviceStatus] = []
    ) {
        self.head = head
        self.document = document
        self.contentDigests = contentDigests
        self.deviceStatuses = deviceStatuses
    }
}

public struct GitWorkspacePublishReceipt: Hashable, Sendable {
    public let commit: String
    public let previousHead: String?
    public let revisionID: WorkspaceObjectID
}

/// Carries portable workspace revisions through a dedicated Git repository.
///
/// It moves one file — the portable document — inside a repository the person
/// connected for this purpose. It never synchronizes the live database, never
/// commits unrelated working-tree changes, and never force-pushes: a rejected
/// push is reported as `remoteAdvanced` so the caller fetches, merges through
/// `WorkspaceMergeEngine`, and publishes the merged revision instead.
///
/// Repository access is not end-to-end encryption. Anything published here is
/// readable by anyone with access to that repository.
public actor GitWorkspaceTransport {
    public static let documentFileName = "workspace.json"
    public static let contentDirectoryName = "content"
    public static let statusDirectoryName = "status"
    /// The one Git this app runs: the Command Line Tools' shim, which runs
    /// the selected developer folder's Git.
    static let gitExecutable = "/usr/bin/git"
    public nonisolated var carriesContent: Bool { true }
    private static let outputLimit = 1 << 20
    private static let documentLimit = 32 << 20
    private static let statusLimit = 256 << 10
    private static let maximumDeviceStatuses = 256
    /// Every Git command starts with these: no locks taken for reads, no
    /// pager, no file-system monitor, no hooks.
    static let prefix = [
        "--no-optional-locks", "--no-pager", "-c", "core.fsmonitor=false",
        "-c", "core.hooksPath=/dev/null",
        // Paths come back as written, so a non-ASCII or space-bearing name is
        // compared as itself rather than as a quoted escape.
        "-c", "core.quotePath=false",
    ]
    /// Used only when the person has no Git identity of their own; see
    /// `commitIdentityArguments`.
    private static let identityFallback = ["user.name=Agent Tooling", "user.email=agent-tooling@localhost"]

    private let checkout: URL
    private let branch: String
    private let runner: any CommandRunning

    public init(
        checkout: URL,
        branch: String = "main",
        runner: any CommandRunning = ProcessCommandRunner(timeout: .seconds(30))
    ) throws {
        guard checkout.isFileURL, checkout.path.hasPrefix("/"),
            !checkout.path.contains("\0"),
            checkout.standardizedFileURL.path == checkout.path,
            Self.isValidBranch(branch)
        else {
            throw GitWorkspaceTransportError.invalidCheckout
        }
        self.checkout = checkout
        self.branch = branch
        self.runner = runner
    }

    /// Prepares a dedicated checkout for a workspace repository. The remote is
    /// the person's own private repository; nothing else is touched.
    ///
    /// A folder that already holds a clone of another repository is refused
    /// with `checkoutHasAnotherRemote`. Agent Tooling's own checkout is
    /// emptied first with `prepareFreshCheckout(at:discard:)` instead, when no
    /// enrollment uses it.
    public static func enroll(
        remote: String,
        checkout: URL,
        branch: String = "main",
        runner: any CommandRunning = ProcessCommandRunner(timeout: .seconds(120))
    ) async throws -> GitWorkspaceTransport {
        guard isValidRemote(remote) else { throw GitWorkspaceTransportError.invalidRemote }
        let transport = try GitWorkspaceTransport(checkout: checkout, branch: branch, runner: runner)
        try await transport.clone(remote: remote)
        return transport
    }

    /// Prepares an unenrolled application-owned checkout for a fresh clone. Moves
    /// stale contents aside through `discard` (Trash by default), moving symlinks
    /// themselves without touching their targets. Empty or absent folders stay.
    /// Never call for an enrolled checkout or a user-selected Settings folder.
    public static func prepareFreshCheckout(
        at checkout: URL,
        discard: @Sendable (URL) throws -> Void = moveToTrash
    ) throws {
        guard checkout.isFileURL, checkout.path.hasPrefix("/"), !checkout.path.contains("\0"),
            checkout.standardizedFileURL.path == checkout.path
        else {
            throw GitWorkspaceTransportError.invalidCheckout
        }
        let manager = FileManager.default
        let path = checkout.path(percentEncoded: false)
        if (try? manager.destinationOfSymbolicLink(atPath: path)) == nil {
            var isDirectory: ObjCBool = false
            guard manager.fileExists(atPath: path, isDirectory: &isDirectory) else { return }
            if isDirectory.boolValue, (try? manager.contentsOfDirectory(atPath: path))?.isEmpty == true { return }
        }
        do { try discard(checkout) } catch { throw GitWorkspaceTransportError.invalidCheckout }
    }

    /// Moves `item` to the Trash, or, on a volume that has none, beside
    /// itself under a dated hidden name. Nothing is deleted either way.
    public static func moveToTrash(_ item: URL) throws {
        let manager = FileManager.default
        do {
            try manager.trashItem(at: item, resultingItemURL: nil)
        } catch {
            let stamp = ISO8601DateFormatter().string(from: .now).replacingOccurrences(of: ":", with: "")
            let aside = item.deletingLastPathComponent()
                .appending(path: ".\(item.lastPathComponent)-replaced-\(stamp)-\(UUID().uuidString.prefix(8).lowercased())")
            try manager.moveItem(at: item, to: aside)
        }
    }

    /// The remote's current head and the document it holds, or `nil` head for a
    /// repository with no commits yet.
    ///
    /// A repository that cannot be read is reported as itself, not as an empty
    /// one: only a branch the remote does not have reads as no head.
    public func remoteState() async throws -> GitWorkspaceRemoteState {
        try await fetchBranch()
        let head = try await revision("refs/remotes/origin/\(branch)")
        guard let head else { return .init(head: nil, document: nil) }
        let blob = try await git(["show", "\(head):\(Self.documentFileName)"], allowing: [0, 128])
        guard blob.status == 0 else { return .init(head: head, document: nil) }
        return .init(
            head: head, document: try Self.decode(blob.standardOutput),
            contentDigests: try await contentDigests(at: head),
            deviceStatuses: try await deviceStatuses(at: head))
    }

    /// Which content trees the head commit holds: the digest directories under
    /// `content/<algorithm>/`. Listed from the commit, not the working tree,
    /// so a half-written checkout cannot claim content it does not have.
    func contentDigests(at head: String) async throws -> Set<ContentDigest> {
        let listing = try await git(["ls-tree", "--name-only", "-r", "-d", head, "--", Self.contentDirectoryName], allowing: [0, 128])
        guard listing.status == 0 else { return [] }
        var digests = Set<ContentDigest>()
        for line in listing.standardOutput.split(separator: "\n") {
            let parts = line.split(separator: "/").map(String.init)
            guard parts.count == 3, parts[0] == Self.contentDirectoryName,
                let algorithm = ContentDigestAlgorithm(rawValue: parts[1]),
                Self.isDigestPathComponent(parts[2])
            else { continue }
            digests.insert(.init(algorithm: algorithm, value: parts[2]))
        }
        return digests
    }

    func deviceStatuses(at head: String) async throws -> [PublishedDeviceStatus] {
        let listing = try await git(["ls-tree", "--name-only", head, "--", Self.statusDirectoryName + "/"], allowing: [0, 128])
        guard listing.status == 0 else { return [] }
        var statuses: [PublishedDeviceStatus] = []
        let paths = listing.standardOutput.split(separator: "\n").map(String.init)
            .filter { $0.hasSuffix(".json") && $0.hasPrefix(Self.statusDirectoryName + "/") }
        for path in paths.prefix(Self.maximumDeviceStatuses) {
            let blob = try await git(["show", "\(head):\(path)"], allowing: [0, 128])
            guard blob.status == 0, blob.standardOutput.utf8.count <= Self.statusLimit,
                let status = try? AgentToolingCoding.decoder().decode(PublishedDeviceStatus.self, from: Data(blob.standardOutput.utf8)),
                status.formatVersion == PublishedDeviceStatus.formatVersion,
                path == Self.statusPath(for: status.deviceID)
            else { continue }
            statuses.append(status)
        }
        return statuses.sorted { $0.deviceID < $1.deviceID }
    }

    /// One content tree from the head commit, re-captured from a private
    /// extraction and verified against the digest it is filed under. A tree
    /// that does not hash to its own name is refused, never trusted.
    public func content(for digest: ContentDigest) async throws -> CapturedPackageTree? {
        guard Self.isDigestPathComponent(digest.value) else { return nil }
        try await fetchBranch()
        guard let head = try await revision("refs/remotes/origin/\(branch)") else { return nil }
        let relative = Self.contentPath(for: digest)
        let probe = try await git(["ls-tree", "--name-only", head, "--", relative], allowing: [0, 128])
        guard probe.status == 0, !probe.standardOutput.isEmpty else { return nil }
        // Extract the subtree into a scratch folder inside the checkout's own
        // private area; `git archive` writes exactly what the commit holds.
        let scratch = checkout.appending(path: ".git/agent-tooling-extract-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: scratch) }
        let archive = scratch.appending(path: "tree.tar")
        // Through the same hardened invocation every other Git call uses.
        try await git(["archive", "--format=tar", "-o", archive.path, head, "--", relative])
        let extracted = scratch.appending(path: "extracted", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: extracted, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let untar = try await runner.run(
            executable: "/usr/bin/tar", arguments: ["-xf", archive.path, "-C", extracted.path], currentDirectory: checkout)
        guard untar.status == 0 else { throw GitWorkspaceTransportError.commandFailed }
        let tree = try await PackageTreeCapture().capture(directory: extracted.appending(path: relative, directoryHint: .isDirectory))
        guard tree.digest == digest else { throw GitWorkspaceTransportError.contentMismatch(digest) }
        return tree
    }

    static func contentPath(for digest: ContentDigest) -> String {
        "\(contentDirectoryName)/\(digest.algorithm.rawValue)/\(digest.value)"
    }

    static func statusPath(for deviceID: WorkspaceObjectID) -> String {
        "\(statusDirectoryName)/\(deviceID.rawValue.uuidString.lowercased()).json"
    }

    nonisolated static func isDigestPathComponent(_ value: String) -> Bool {
        value.count == 64 && value.allSatisfy { ($0.isNumber || ("a"..."f").contains($0)) }
    }

    /// Writes the document, commits only that file and pushes fast-forward.
    /// A rejected push reports the remote head rather than overwriting it.
    public func publish(
        document: PortableWorkspaceDocument,
        content: [CapturedPackageTree],
        status: PublishedDeviceStatus?,
        expectedRemoteHead: String?
    ) async throws -> GitWorkspacePublishReceipt {
        let bytes = try Self.encode(document)
        let observed = try await remoteState().head
        guard observed == expectedRemoteHead else {
            throw GitWorkspaceTransportError.remoteAdvanced(remoteHead: observed ?? "")
        }
        try await resetToRemote(head: observed)
        // Only our files may be committed. Anything else in the checkout is not
        // ours to publish, and its presence is a reason to stop.
        try await requireOnlyDocumentChanges()
        try bytes.write(to: checkout.appending(path: Self.documentFileName), options: .atomic)
        var paths = [Self.documentFileName]
        for tree in content {
            let relative = Self.contentPath(for: tree.digest)
            let destination = checkout.appending(path: relative, directoryHint: .isDirectory)
            // Immutable by digest: a tree already there is the same bytes.
            if !FileManager.default.fileExists(atPath: destination.path) {
                try WorkspacePackageExporter.write(tree: tree, to: destination)
                // An empty directory in the tree would not be committed by Git;
                // the capture tolerates its absence on the way back, and the
                // digest is over file content, so the round trip holds.
            }
            paths.append(relative)
        }
        if let status {
            let statusURL = checkout.appending(path: Self.statusPath(for: status.deviceID))
            try FileManager.default.createDirectory(
                at: statusURL.deletingLastPathComponent(), withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700])
            let encoder = AgentToolingCoding.encoder()
            try encoder.encode(status).write(to: statusURL, options: .atomic)
            paths.append(Self.statusPath(for: status.deviceID))
        }
        try await git(["add", "--"] + paths)
        try await requireOnlyDocumentChanges(staged: true)
        let message = "Workspace revision \(document.revision.id.rawValue.uuidString.lowercased())"
        let identity = try await commitIdentityArguments()
        let commit = try await git(identity + ["commit", "--quiet", "--only", "--message", message, "--"] + paths, allowing: [0, 1])
        if commit.status != 0 {
            // Nothing to commit: an earlier attempt already committed exactly
            // these files and its push did not go through. That commit is the
            // one to push, so a retry after a refused push reaches the remote
            // again instead of failing here.
            let unchanged = try await git(["diff", "--quiet", "HEAD", "--"] + paths, allowing: [0, 1, 128])
            guard unchanged.status == 0 else { throw GitWorkspaceTransportError.commandFailed }
        }
        guard let created = try await revision("HEAD") else {
            throw GitWorkspaceTransportError.commandFailed
        }
        let push = try await remoteGit(["push", "origin", "HEAD:refs/heads/\(branch)"])
        guard push.status == 0 else {
            // A push the remote refused for moving on is a merge to make; one
            // it refused outright, or could not take at all, is said as such.
            if !GitRemoteFailure.isRejectedBecauseRemoteMoved(push.standardError),
                let problem = GitRemoteFailure.problem(
                    standardError: push.standardError, host: await originHost(), pushing: true)
            {
                throw GitWorkspaceTransportError.remote(problem)
            }
            let current = try await remoteState().head
            guard current != observed else {
                // Rejected, yet the remote is where it was: it refused this push.
                throw GitWorkspaceTransportError.remote(.pushRefused(host: await originHost()))
            }
            throw GitWorkspaceTransportError.remoteAdvanced(remoteHead: current ?? "")
        }
        return .init(commit: created, previousHead: observed, revisionID: document.revision.id)
    }
}

extension GitWorkspaceTransport {
    func clone(remote: String) async throws {
        try FileManager.default.createDirectory(
            at: checkout, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        try await git(["init", "--quiet", "--initial-branch", branch])
        let existing = try await git(["remote", "get-url", "origin"], allowing: [0, 2, 128])
        if existing.status == 0 {
            guard Self.singleLine(existing.standardOutput) == remote else {
                throw GitWorkspaceTransportError.checkoutHasAnotherRemote
            }
        } else {
            try await git(["remote", "add", "origin", remote])
        }
        try await fetchBranch()
        if let head = try await revision("refs/remotes/origin/\(branch)") {
            try await resetToRemote(head: head)
        }
    }

    /// Fetches the branch from `origin`. A branch the remote does not have is
    /// not a failure, because an empty repository answers that way; every
    /// other failure is classified from what Git said, so a typo, a sign-in
    /// that does not open the repository and no network are told apart rather
    /// than all reading as empty.
    func fetchBranch() async throws {
        let fetch = try await remoteGit(["fetch", "--quiet", "--no-tags", "origin", branch])
        guard fetch.status != 0, !GitRemoteFailure.isMissingRemoteBranch(fetch.standardError) else { return }
        let host = await originHost()
        throw GitWorkspaceTransportError.remote(
            GitRemoteFailure.problem(standardError: fetch.standardError, host: host) ?? .notFound(host: host))
    }

    /// The host `origin` names, for a message. Read from the checkout's own
    /// configuration, and only once something went wrong.
    func originHost() async -> String? {
        guard let output = try? await git(["remote", "get-url", "origin"], allowing: [0, 2, 128]), output.status == 0,
            let address = Self.singleLine(output.standardOutput)
        else { return nil }
        return GitRemoteAddress.host(of: address)
    }

    /// The head `remote` advertises for this branch, or `nil` when it has no
    /// such branch: the one answer that tells an empty repository from one
    /// that cannot be reached, because `ls-remote` succeeds on the first and
    /// fails on the second. `host` names the remote in a failure.
    func advertisedHead(of remote: String, host: String?) async throws -> String? {
        let reference = "refs/heads/\(branch)"
        let listing = try await remoteGit(["ls-remote", "--heads", "--", remote, reference], host: host)
        guard listing.status == 0 else {
            throw GitWorkspaceTransportError.remote(
                GitRemoteFailure.problem(standardError: listing.standardError, host: host) ?? .notFound(host: host))
        }
        for line in listing.standardOutput.split(separator: "\n") {
            let fields = line.split(separator: "\t")
            guard fields.count == 2, fields[1] == reference else { continue }
            let head = String(fields[0])
            guard Self.isObjectName(head) else { continue }
            return head
        }
        return nil
    }

    /// Whether `remote` has any branch at all, which tells a repository with
    /// nothing in it from one where the branch asked for is a typo. `remote`
    /// is an address, or `origin` for this checkout's own; `host` names it in
    /// a failure. So many branches that the listing outgrows what is read at
    /// once is still an answer: it has some.
    func listsAnyBranch(on remote: String, host: String?) async throws -> Bool {
        let listing: CommandOutput
        do {
            listing = try await remoteGit(["ls-remote", "--heads", "--", remote], host: host)
        } catch GitWorkspaceTransportError.outputLimitExceeded {
            return true
        }
        guard listing.status == 0 else {
            throw GitWorkspaceTransportError.remote(
                GitRemoteFailure.problem(standardError: listing.standardError, host: host) ?? .notFound(host: host))
        }
        return listing.standardOutput.split(separator: "\n").contains { line in
            let fields = line.split(separator: "\t")
            return fields.count == 2 && fields[1].hasPrefix("refs/heads/") && Self.isObjectName(String(fields[0]))
        }
    }

    /// Fetches only the branch's newest commit from `remote` into this
    /// checkout, which has no `origin`: enough to read the library at its
    /// head without its history. `nil` when the remote has no such branch.
    func shallowFetch(from remote: String, host: String?) async throws -> String? {
        let fetch = try await remoteGit(
            ["fetch", "--quiet", "--no-tags", "--depth", "1", "--", remote, "refs/heads/\(branch)"], host: host)
        guard fetch.status == 0 else {
            guard !GitRemoteFailure.isMissingRemoteBranch(fetch.standardError) else { return nil }
            throw GitWorkspaceTransportError.remote(
                GitRemoteFailure.problem(standardError: fetch.standardError, host: host) ?? .notFound(host: host))
        }
        return try await revision("FETCH_HEAD")
    }

    /// The text of `workspace.json` at `head`, or `nil` when the commit holds
    /// no such file.
    func documentText(at head: String) async throws -> String? {
        let blob = try await git(["show", "\(head):\(Self.documentFileName)"], allowing: [0, 128])
        return blob.status == 0 ? blob.standardOutput : nil
    }

    func resetToRemote(head: String?) async throws {
        guard let head else { return }
        try await git(["checkout", "--quiet", "-B", branch, head])
    }

    /// Refuses to publish while the checkout holds anything but our document.
    /// A dedicated workspace repository should never carry other edits, and
    /// committing them on someone's behalf is not this transport's business.
    /// With `staged`, the index is checked instead of the working tree: what
    /// `git add` took must be ours and nothing else.
    func requireOnlyDocumentChanges(staged: Bool = false) async throws {
        let output: String
        if staged {
            output = try await git(["diff", "--cached", "--name-only", "-z"]).standardOutput
                .split(separator: "\0").map(String.init).joined(separator: "\n")
        } else {
            // Porcelain v1 with -z: each record is "XY path", NUL-terminated,
            // and a rename carries its source as a second NUL-terminated field.
            let records = try await git(["status", "--porcelain=v1", "-z", "--untracked-files=all"]).standardOutput
                .split(separator: "\0", omittingEmptySubsequences: true).map(String.init)
            var paths: [String] = []
            var index = 0
            while index < records.count {
                let record = records[index]
                paths.append(String(record.dropFirst(3)))
                if record.hasPrefix("R") || record.hasPrefix("C") { index += 1 }  // skip the source path
                index += 1
            }
            output = paths.joined(separator: "\n")
        }
        for path in output.split(separator: "\n").map(String.init) where !path.isEmpty {
            guard Self.isOurs(path) else { throw GitWorkspaceTransportError.unrelatedWorkingTreeChanges }
        }
    }

    nonisolated static func isOurs(_ path: String) -> Bool {
        path == documentFileName
            || path.hasPrefix(contentDirectoryName + "/")
            || path.hasPrefix(statusDirectoryName + "/")
    }

    /// A commit needs an author. A Mac that never set one up still gets to
    /// publish, under a name that says what wrote it.
    func commitIdentityArguments() async throws -> [String] {
        let name = try await git(["config", "--get", "user.name"], allowing: [0, 1])
        let email = try await git(["config", "--get", "user.email"], allowing: [0, 1])
        var arguments: [String] = []
        if name.status != 0 || name.standardOutput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            arguments += ["-c", Self.identityFallback[0]]
        }
        if email.status != 0 || email.standardOutput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            arguments += ["-c", Self.identityFallback[1]]
        }
        return arguments
    }

    func revision(_ reference: String) async throws -> String? {
        let output = try await git(["rev-parse", "--verify", "--quiet", reference], allowing: [0, 1, 128])
        guard output.status == 0, let value = Self.singleLine(output.standardOutput), Self.isObjectName(value)
        else { return nil }
        return value
    }

    /// A full commit name, SHA-1 or SHA-256, in Git's lowercase hex.
    nonisolated static func isObjectName(_ value: String) -> Bool {
        (value.count == 40 || value.count == 64) && value.allSatisfy { $0.isHexDigit && ($0.isNumber || $0.isLowercase) }
    }

    /// A local Git command: one that does not talk to the remote. Any status
    /// it was not allowed to end with, and a runner that gave up waiting, is
    /// `commandFailed`.
    @discardableResult
    func git(_ arguments: [String], allowing statuses: Set<Int32> = [0]) async throws -> CommandOutput {
        let output: CommandOutput
        do { output = try await runGit(arguments) } catch ProcessCommandRunnerError.timedOut {
            throw GitWorkspaceTransportError.commandFailed
        }
        guard statuses.contains(output.status) else { throw GitWorkspaceTransportError.commandFailed }
        return output
    }

    /// A Git command that talks to `origin`, with whatever status it ended
    /// with, so the caller can read what went wrong. A runner that gave up
    /// waiting is reported as the remote's slowness.
    func remoteGit(_ arguments: [String]) async throws -> CommandOutput {
        do {
            return try await runGit(arguments)
        } catch ProcessCommandRunnerError.timedOut {
            throw GitWorkspaceTransportError.remote(.timedOut(host: await originHost()))
        }
    }

    /// The same, for a command that names the remote itself; `host` is the
    /// one a report of its slowness names.
    func remoteGit(_ arguments: [String], host: String?) async throws -> CommandOutput {
        do {
            return try await runGit(arguments)
        } catch ProcessCommandRunnerError.timedOut {
            throw GitWorkspaceTransportError.remote(.timedOut(host: host))
        }
    }

    /// One Git command through the hardened invocation, whatever status it
    /// ends with. A runner that gave up waiting is passed on as such, for the
    /// caller to classify; every other runner failure is `commandFailed`,
    /// because Git's own message can carry absolute paths and remote URLs.
    private func runGit(_ arguments: [String]) async throws -> CommandOutput {
        try Task.checkCancellation()
        let output: CommandOutput
        do {
            output = try await runner.run(
                executable: Self.gitExecutable, arguments: Self.prefix + arguments,
                currentDirectory: checkout)
        } catch is CancellationError {
            throw CancellationError()
        } catch ProcessCommandRunnerError.timedOut(let executable) {
            try Task.checkCancellation()
            throw ProcessCommandRunnerError.timedOut(executable)
        } catch {
            try Task.checkCancellation()
            throw GitWorkspaceTransportError.commandFailed
        }
        try Task.checkCancellation()
        guard output.standardOutput.utf8.count <= Self.outputLimit,
            output.standardError.utf8.count <= Self.outputLimit
        else {
            throw GitWorkspaceTransportError.outputLimitExceeded
        }
        return output
    }

    static func encode(_ document: PortableWorkspaceDocument) throws -> Data {
        let bytes: Data
        do { bytes = try WorkspaceDocumentCoding.encode(document) } catch { throw GitWorkspaceTransportError.invalidDocument }
        guard bytes.count <= documentLimit else { throw GitWorkspaceTransportError.documentTooLarge }
        return bytes
    }

    /// Reads a published document. Its format is read on its own first, so a
    /// library from a newer Agent Tooling is reported as that rather than as a
    /// document this build cannot read, and a `workspace.json` that is some
    /// other JSON is no library at all, as the preflight says of it.
    static func decode(_ text: String) throws -> PortableWorkspaceDocument {
        guard text.utf8.count <= documentLimit else { throw GitWorkspaceTransportError.documentTooLarge }
        let bytes = Data(text.utf8)
        switch RemoteDocumentFormat.classify(bytes) {
        case .library(let format) where format.isNewer: throw GitWorkspaceTransportError.remote(.newerFormat)
        case .notALibrary: throw GitWorkspaceTransportError.remote(.notALibrary)
        case .library, .damaged: break
        }
        do { return try WorkspaceDocumentCoding.decode(bytes) } catch { throw GitWorkspaceTransportError.invalidDocument }
    }

    static func singleLine(_ text: String) -> String? {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: true)
        guard lines.count == 1 else { return nil }
        return String(lines[0]).trimmingCharacters(in: .whitespaces)
    }

    nonisolated static func isValidBranch(_ branch: String) -> Bool {
        !branch.isEmpty && branch.count <= 200 && !branch.hasPrefix("-") && !branch.hasPrefix("/")
            && !branch.hasSuffix("/") && !branch.contains("..") && !branch.contains("@{")
            && !branch.hasSuffix(".lock")
            && branch.unicodeScalars.allSatisfy {
                !CharacterSet.whitespacesAndNewlines.contains($0)
                    && !CharacterSet.controlCharacters.contains($0)
                    && !"~^:?*[\\".unicodeScalars.contains($0)
            }
    }

    /// Only an explicit remote the person supplied, with no credentials in the
    /// URL: no user or password, and nothing after the path, where a token
    /// hides as easily (`?access_token=…`, `#…`). Portable state never
    /// carries a token.
    nonisolated static func isValidRemote(_ remote: String) -> Bool {
        guard !remote.isEmpty, remote.count <= 2_048, !remote.hasPrefix("-"),
            !remote.contains("\0"),
            remote.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) })
        else { return false }
        if remote.hasPrefix("/") { return !remote.contains("..") }
        guard let components = URLComponents(string: remote), let scheme = components.scheme?.lowercased()
        else { return false }
        guard ["https", "ssh", "file"].contains(scheme) else { return false }
        return components.user == nil && components.password == nil && components.percentEncodedQuery == nil
            && components.percentEncodedFragment == nil
    }
}
