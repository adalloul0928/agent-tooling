import Foundation

public enum WorkspaceSyncEnrollmentError: Error, Equatable, Sendable {
    case invalidRoot
    case invalidRemote
    case invalidCheckout
    case unsupportedFormat
    case unreadable
    case missingKey
}

/// How this Mac carries revisions to its others.
public enum WorkspaceSyncTransportKind: String, Codable, Hashable, Sendable, CaseIterable {
    /// A private Git repository. Its history is the record; whoever can read
    /// the repository can read what is published there.
    case git
    /// A folder a file-sync service already keeps in step, holding only sealed
    /// bytes. The service cannot read what is in it.
    case encryptedFolder
}

/// This device's connection to a shared workspace repository.
///
/// It is deliberately device-local and never part of portable bytes: a remote
/// locator and a checkout path belong to one Mac. No credential is stored here;
/// authorization stays with Git's own helpers on each machine.
public struct WorkspaceSyncEnrollment: Codable, Hashable, Sendable {
    public static let formatVersion = 1

    public let formatVersion: Int
    public let workspaceID: WorkspaceObjectID
    public let remote: String
    public let checkoutPath: String
    public let branch: String
    /// Which transport this connection uses. Enrollments written before this
    /// field existed are Git, which is the only kind that existed then.
    public let kind: WorkspaceSyncTransportKind
    /// Whether this Mac runs sync passes on its own while the app is open.
    /// Enrollments written before this field existed read as on, which is what
    /// connecting a repository already meant.
    public let isAutomatic: Bool

    public init(
        workspaceID: WorkspaceObjectID,
        remote: String,
        checkoutPath: String,
        branch: String = "main",
        kind: WorkspaceSyncTransportKind = .git,
        isAutomatic: Bool = true
    ) throws {
        // A folder connection has no remote address: the folder itself is the
        // whole locator, and demanding a Git URL for one would be nonsense.
        if kind == .git {
            guard GitWorkspaceTransport.isValidRemote(remote) else {
                throw WorkspaceSyncEnrollmentError.invalidRemote
            }
        } else if !remote.isEmpty {
            throw WorkspaceSyncEnrollmentError.invalidRemote
        }
        guard checkoutPath.hasPrefix("/"), !checkoutPath.contains("\0"),
              checkoutPath.count <= 4_096,
              URL(fileURLWithPath: checkoutPath).standardizedFileURL.path == checkoutPath,
              GitWorkspaceTransport.isValidBranch(branch) else {
            throw WorkspaceSyncEnrollmentError.invalidCheckout
        }
        formatVersion = Self.formatVersion
        self.workspaceID = workspaceID
        self.remote = remote
        self.checkoutPath = checkoutPath
        self.branch = branch
        self.kind = kind
        self.isAutomatic = isAutomatic
    }

    private enum CodingKeys: String, CodingKey {
        case formatVersion, workspaceID, remote, checkoutPath, branch, kind, isAutomatic
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        formatVersion = try container.decode(Int.self, forKey: .formatVersion)
        workspaceID = try container.decode(WorkspaceObjectID.self, forKey: .workspaceID)
        remote = try container.decode(String.self, forKey: .remote)
        checkoutPath = try container.decode(String.self, forKey: .checkoutPath)
        branch = try container.decode(String.self, forKey: .branch)
        kind = try container.decodeIfPresent(WorkspaceSyncTransportKind.self, forKey: .kind) ?? .git
        isAutomatic = try container.decodeIfPresent(Bool.self, forKey: .isAutomatic) ?? true
    }

    /// The same connection with automatic passes turned on or off.
    public func settingAutomatic(_ value: Bool) throws -> Self {
        try .init(workspaceID: workspaceID, remote: remote, checkoutPath: checkoutPath,
                  branch: branch, kind: kind, isAutomatic: value)
    }
}

/// Stores one enrollment beside the workspace's own revision store.
public struct WorkspaceSyncEnrollmentStore: Sendable {
    private let file: URL

    public init(containerRoot: URL) throws {
        guard containerRoot.isFileURL, containerRoot.path.hasPrefix("/"),
              !containerRoot.path.contains("\0"),
              containerRoot.standardizedFileURL.path == containerRoot.path else {
            throw WorkspaceSyncEnrollmentError.invalidRoot
        }
        file = containerRoot.appending(path: "sync-enrollment.json")
    }

    /// The saved enrollment, or `nil` when this device has not connected a
    /// repository. A file this build cannot read is an error, never silently
    /// treated as "not connected".
    public func read() throws -> WorkspaceSyncEnrollment? {
        guard FileManager.default.fileExists(atPath: file.path) else { return nil }
        let bytes: Data
        do { bytes = try Data(contentsOf: file, options: [.mappedIfSafe]) }
        catch { throw WorkspaceSyncEnrollmentError.unreadable }
        guard bytes.count <= 64_000 else { throw WorkspaceSyncEnrollmentError.unsupportedFormat }
        let value: WorkspaceSyncEnrollment
        do { value = try AgentToolingCoding.decoder().decode(WorkspaceSyncEnrollment.self, from: bytes) }
        catch { throw WorkspaceSyncEnrollmentError.unsupportedFormat }
        // A folder connection has no remote address, and a Git one must not
        // pick up a folder's empty locator by decoding an older or edited file.
        guard value.formatVersion == WorkspaceSyncEnrollment.formatVersion,
              value.kind == .encryptedFolder || GitWorkspaceTransport.isValidRemote(value.remote),
              value.kind == .git || value.remote.isEmpty,
              GitWorkspaceTransport.isValidBranch(value.branch) else {
            throw WorkspaceSyncEnrollmentError.unsupportedFormat
        }
        return value
    }

    public func write(_ enrollment: WorkspaceSyncEnrollment) throws {
        let bytes = try AgentToolingCoding.encoder().encode(enrollment)
        do { try bytes.write(to: file, options: .atomic) }
        catch { throw WorkspaceSyncEnrollmentError.unreadable }
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    }

    /// Disconnects this device. The repository and its history are untouched;
    /// only this Mac stops using it.
    public func remove() throws {
        guard FileManager.default.fileExists(atPath: file.path) else { return }
        do { try FileManager.default.removeItem(at: file) }
        catch { throw WorkspaceSyncEnrollmentError.unreadable }
    }
}
