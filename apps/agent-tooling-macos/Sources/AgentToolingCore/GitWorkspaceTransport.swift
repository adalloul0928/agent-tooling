import Foundation

public enum GitWorkspaceTransportError: Error, Equatable, Sendable {
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
}

/// A remote workspace head, as observed. A missing head means an empty
/// repository, not an empty workspace.
public struct GitWorkspaceRemoteState: Hashable, Sendable {
    public let head: String?
    public let document: PortableWorkspaceDocument?

    public init(head: String?, document: PortableWorkspaceDocument?) {
        self.head = head
        self.document = document
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
    private static let outputLimit = 1 << 20
    private static let documentLimit = 32 << 20
    private static let prefix = [
        "--no-optional-locks", "--no-pager", "-c", "core.fsmonitor=false",
        "-c", "core.hooksPath=/dev/null",
    ]

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
              Self.isValidBranch(branch) else {
            throw GitWorkspaceTransportError.invalidCheckout
        }
        self.checkout = checkout
        self.branch = branch
        self.runner = runner
    }

    /// Prepares a dedicated checkout for a workspace repository. The remote is
    /// the person's own private repository; nothing else is touched.
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

    /// The remote's current head and the document it holds, or `nil` head for a
    /// repository with no commits yet.
    public func remoteState() async throws -> GitWorkspaceRemoteState {
        try await git(["fetch", "--quiet", "--no-tags", "origin", branch], allowing: [0, 128])
        let head = try await revision("refs/remotes/origin/\(branch)")
        guard let head else { return .init(head: nil, document: nil) }
        let blob = try await git(["show", "\(head):\(Self.documentFileName)"], allowing: [0, 128])
        guard blob.status == 0 else { return .init(head: head, document: nil) }
        return .init(head: head, document: try Self.decode(blob.standardOutput))
    }

    /// Writes the document, commits only that file and pushes fast-forward.
    /// A rejected push reports the remote head rather than overwriting it.
    public func publish(
        document: PortableWorkspaceDocument,
        expectedRemoteHead: String?
    ) async throws -> GitWorkspacePublishReceipt {
        let bytes = try Self.encode(document)
        let observed = try await remoteState().head
        guard observed == expectedRemoteHead else {
            throw GitWorkspaceTransportError.remoteAdvanced(remoteHead: observed ?? "")
        }
        try await resetToRemote(head: observed)
        // Only this file may be committed. Anything else in the checkout is not
        // ours to publish, and its presence is a reason to stop.
        try await requireOnlyDocumentChanges()
        try bytes.write(to: checkout.appending(path: Self.documentFileName), options: .atomic)
        try await git(["add", "--", Self.documentFileName])
        try await requireOnlyDocumentChanges(staged: true)
        let message = "Workspace revision \(document.revision.id.rawValue.uuidString.lowercased())"
        let commit = try await git(["commit", "--quiet", "--only", "--message", message,
                                    "--", Self.documentFileName], allowing: [0, 1])
        guard commit.status == 0 else { throw GitWorkspaceTransportError.commandFailed }
        guard let created = try await revision("HEAD") else {
            throw GitWorkspaceTransportError.commandFailed
        }
        let push = try await git(["push", "origin", "HEAD:refs/heads/\(branch)"], allowing: [0, 1, 128])
        guard push.status == 0 else {
            let current = try await remoteState().head
            throw GitWorkspaceTransportError.remoteAdvanced(remoteHead: current ?? "")
        }
        return .init(commit: created, previousHead: observed, revisionID: document.revision.id)
    }
}

extension GitWorkspaceTransport {
    func clone(remote: String) async throws {
        try FileManager.default.createDirectory(at: checkout, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        try await git(["init", "--quiet", "--initial-branch", branch])
        let existing = try await git(["remote", "get-url", "origin"], allowing: [0, 2, 128])
        if existing.status == 0 {
            guard Self.singleLine(existing.standardOutput) == remote else {
                throw GitWorkspaceTransportError.invalidRemote
            }
        } else {
            try await git(["remote", "add", "origin", remote])
        }
        try await git(["fetch", "--quiet", "--no-tags", "origin", branch], allowing: [0, 128])
        if let head = try await revision("refs/remotes/origin/\(branch)") {
            try await resetToRemote(head: head)
        }
    }

    func resetToRemote(head: String?) async throws {
        guard let head else { return }
        try await git(["checkout", "--quiet", "-B", branch, head])
    }

    /// Refuses to publish while the checkout holds anything but our document.
    /// A dedicated workspace repository should never carry other edits, and
    /// committing them on someone's behalf is not this transport's business.
    func requireOnlyDocumentChanges(staged: Bool = false) async throws {
        let status = try await git(["status", "--porcelain=v1", "--untracked-files=all"])
        for line in status.standardOutput.split(separator: "\n") {
            let path = line.dropFirst(3)
            guard path == Self.documentFileName else {
                throw GitWorkspaceTransportError.unrelatedWorkingTreeChanges
            }
            _ = staged
        }
    }

    func revision(_ reference: String) async throws -> String? {
        let output = try await git(["rev-parse", "--verify", "--quiet", reference], allowing: [0, 1, 128])
        guard output.status == 0, let value = Self.singleLine(output.standardOutput),
              value.count == 40 || value.count == 64,
              value.allSatisfy({ $0.isHexDigit && ($0.isNumber || $0.isLowercase) }) else { return nil }
        return value
    }

    @discardableResult
    func git(_ arguments: [String], allowing statuses: Set<Int32> = [0]) async throws -> CommandOutput {
        try Task.checkCancellation()
        let output: CommandOutput
        do {
            output = try await runner.run(executable: "/usr/bin/git", arguments: Self.prefix + arguments,
                                          currentDirectory: checkout)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            // Git's stderr can carry absolute paths and remote URLs.
            try Task.checkCancellation()
            throw GitWorkspaceTransportError.commandFailed
        }
        try Task.checkCancellation()
        guard output.standardOutput.utf8.count <= Self.outputLimit,
              output.standardError.utf8.count <= Self.outputLimit else {
            throw GitWorkspaceTransportError.outputLimitExceeded
        }
        guard statuses.contains(output.status) else { throw GitWorkspaceTransportError.commandFailed }
        return output
    }

    static func encode(_ document: PortableWorkspaceDocument) throws -> Data {
        let bytes: Data
        do { bytes = try WorkspaceDocumentCoding.encode(document) }
        catch { throw GitWorkspaceTransportError.invalidDocument }
        guard bytes.count <= documentLimit else { throw GitWorkspaceTransportError.documentTooLarge }
        return bytes
    }

    static func decode(_ text: String) throws -> PortableWorkspaceDocument {
        guard text.utf8.count <= documentLimit else { throw GitWorkspaceTransportError.documentTooLarge }
        do { return try WorkspaceDocumentCoding.decode(Data(text.utf8)) }
        catch { throw GitWorkspaceTransportError.invalidDocument }
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
    /// URL. Portable state never carries a token.
    nonisolated static func isValidRemote(_ remote: String) -> Bool {
        guard !remote.isEmpty, remote.count <= 2_048, !remote.hasPrefix("-"),
              !remote.contains("\0"),
              remote.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) })
        else { return false }
        if remote.hasPrefix("/") { return !remote.contains("..") }
        guard let components = URLComponents(string: remote), let scheme = components.scheme?.lowercased()
        else { return false }
        guard ["https", "ssh", "file"].contains(scheme) else { return false }
        return components.user == nil && components.password == nil
    }
}
