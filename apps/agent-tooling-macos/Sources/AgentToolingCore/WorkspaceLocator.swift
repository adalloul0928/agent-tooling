import Foundation

public enum WorkspaceLocatorError: Error, Equatable, Sendable {
    case invalidRoot
    case unreadable
    case unsupportedFormat
}

/// Where this Mac's workspace is.
///
/// One small file naming one workspace, replacing the authority registry that
/// existed to choose between two stores. With one store there is no choice to
/// record — only a name to find it by.
///
/// The record holds identifiers and nothing else. The path is derived from the
/// container root the caller passes, so moving the folder moves the workspace
/// with it and no stale absolute path can point somewhere that no longer exists.
public struct WorkspaceLocator: Sendable {
    public static let formatVersion = 1
    public static let recordFileName = "workspace.json"

    public struct Record: Codable, Hashable, Sendable {
        public let formatVersion: Int
        public let workspaceID: WorkspaceObjectID
        public let deviceID: WorkspaceObjectID

        public init(workspaceID: WorkspaceObjectID, deviceID: WorkspaceObjectID) {
            formatVersion = WorkspaceLocator.formatVersion
            self.workspaceID = workspaceID
            self.deviceID = deviceID
        }
    }

    private let root: URL

    /// `root` is this app's own support folder.
    public init(root: URL) throws {
        guard root.isFileURL, root.path.hasPrefix("/"), !root.path.contains("\0"),
              root.standardizedFileURL.path == root.path else {
            throw WorkspaceLocatorError.invalidRoot
        }
        self.root = root
    }

    public static func defaultRoot(fileManager: FileManager = .default) throws -> URL {
        guard let support = fileManager.urls(for: .applicationSupportDirectory,
                                             in: .userDomainMask).first else {
            throw WorkspaceLocatorError.invalidRoot
        }
        return support.appending(path: "Agent Tooling", directoryHint: .isDirectory).standardizedFileURL
    }

    public var recordURL: URL { root.appending(path: Self.recordFileName) }

    /// The root the store is given, not the versioned folder inside it.
    /// `WorkspaceRevisionStore` appends `workspaces-v1/<workspace id>` itself,
    /// so naming it here too would nest one inside another.
    public var containerRoot: URL { root }

    /// `nil` when this Mac has no workspace yet. A record this build cannot read
    /// is an error, not an absence: treating it as absent would start a second
    /// workspace beside one that already exists.
    public func read() throws -> Record? {
        guard FileManager.default.fileExists(atPath: recordURL.path) else { return nil }
        let bytes: Data
        do { bytes = try Data(contentsOf: recordURL, options: [.mappedIfSafe]) }
        catch { throw WorkspaceLocatorError.unreadable }
        guard bytes.count <= 8_192,
              let record = try? AgentToolingCoding.decoder().decode(Record.self, from: bytes),
              record.formatVersion == Self.formatVersion else {
            throw WorkspaceLocatorError.unsupportedFormat
        }
        return record
    }

    public func write(_ record: Record) throws {
        do {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            try AgentToolingCoding.encoder().encode(record).write(to: recordURL, options: .atomic)
        } catch { throw WorkspaceLocatorError.unreadable }
        try? FileManager.default.setAttributes([.posixPermissions: 0o600],
                                               ofItemAtPath: recordURL.path)
    }

    /// Opens the workspace this Mac uses, or `nil` when it has none yet.
    public func open(access: WorkspaceRevisionStoreAccess = .existingReadWrite) throws -> WorkspaceRevisionStore? {
        guard let record = try read() else { return nil }
        return try WorkspaceRevisionStore(
            containerRoot: containerRoot, workspaceID: record.workspaceID,
            deviceID: record.deviceID, access: access)
    }

    /// Opens the workspace, creating one from a live scan when there is none.
    ///
    /// The record is written only after the store is initialized, so an
    /// interrupted first run leaves nothing pointing at a workspace that was
    /// never finished.
    public func openOrCreate(
        homeURL: URL,
        runner: any CommandRunning,
        registry: ClientAdapterRegistry = ClientAdapterRegistry()
    ) async throws -> WorkspaceRevisionStore {
        if let existing = try open() { return existing }
        let created = try await WorkspaceFirstRun.begin(
            containerRoot: containerRoot, homeURL: homeURL, runner: runner, registry: registry)
        try write(.init(workspaceID: created.result.document.workspaceID,
                        deviceID: created.result.device.deviceID))
        return created.store
    }
}
