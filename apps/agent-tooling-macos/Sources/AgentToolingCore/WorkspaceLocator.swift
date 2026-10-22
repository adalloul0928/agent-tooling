import Foundation

/// Why this Mac's workspace record could not be found, read or written.
public enum WorkspaceLocatorError: Error, Equatable, Sendable, LocalizedError {
    /// The support folder is not an absolute, resolved file path.
    case invalidRoot
    /// The record could not be read from or written to disk.
    case unreadable
    /// The record says a newer Agent Tooling made it.
    case newerFormat
    /// The record is there but is not one any Agent Tooling writes.
    case damaged
    /// A record already exists, so a new workspace was not created.
    case alreadyExists

    public var errorDescription: String? {
        switch self {
        case .invalidRoot:
            "Agent Tooling's support folder could not be used. Nothing was changed."
        case .unreadable:
            "Agent Tooling could not read or write this Mac's library record. Nothing was changed."
        case .newerFormat:
            "This library was made by a newer Agent Tooling. Update Agent Tooling on this Mac, then open it again. Nothing was changed."
        case .damaged:
            "This Mac's library record, workspace.json, is damaged, so it was left as it is. Nothing was changed."
        case .alreadyExists:
            "This Mac already has a library, so a second one was not started. Nothing was changed."
        }
    }
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
            root.standardizedFileURL.path == root.path
        else {
            throw WorkspaceLocatorError.invalidRoot
        }
        self.root = root
    }

    public static func defaultRoot(fileManager: FileManager = .default) throws -> URL {
        guard
            let support = fileManager.urls(
                for: .applicationSupportDirectory,
                in: .userDomainMask
            ).first
        else {
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
    ///
    /// The format version is read on its own first, so a record a newer build
    /// wrote is told apart from one that is damaged: only the first is a
    /// reason to update. A file too large to be a record, one that is not
    /// JSON, or one that names no format this or any earlier build wrote, is
    /// damaged.
    public func read() throws -> Record? {
        guard FileManager.default.fileExists(atPath: recordURL.path) else { return nil }
        let bytes: Data
        do { bytes = try Data(contentsOf: recordURL, options: [.mappedIfSafe]) } catch { throw WorkspaceLocatorError.unreadable }
        guard bytes.count <= 8_192,
            let format = try? AgentToolingCoding.decoder().decode(FormatProbe.self, from: bytes)
        else {
            throw WorkspaceLocatorError.damaged
        }
        guard format.formatVersion <= Self.formatVersion else { throw WorkspaceLocatorError.newerFormat }
        guard format.formatVersion == Self.formatVersion,
            let record = try? AgentToolingCoding.decoder().decode(Record.self, from: bytes)
        else {
            throw WorkspaceLocatorError.damaged
        }
        return record
    }

    /// Only the field a record of any format version carries.
    private struct FormatProbe: Decodable {
        let formatVersion: Int
    }

    /// The folder the store for `record` lives in, where the app keeps the
    /// files that belong to that workspace alone. It is the folder
    /// `WorkspaceRevisionStore` opens — `workspaces-v1/<lowercased id>` —
    /// with symbolic links in the support folder resolved the same way, so it
    /// can be found before the store is opened, or when it cannot be.
    public func containerDirectory(for record: Record) -> URL {
        root.standardizedFileURL
            .appending(path: "workspaces-v1", directoryHint: .isDirectory)
            .appending(path: record.workspaceID.rawValue.uuidString.lowercased(), directoryHint: .isDirectory)
            .resolvingSymlinksInPath().standardizedFileURL
    }

    public func write(_ record: Record) throws {
        do {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            try AgentToolingCoding.encoder().encode(record).write(to: recordURL, options: .atomic)
        } catch { throw WorkspaceLocatorError.unreadable }
        try? FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
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
        return try await createWorkspace(
            homeURL: homeURL, runner: runner, registry: registry, preferences: nil, beforeRecord: nil,
            refusesExisting: false)
    }

    /// Creates a workspace only when no locator exists, including unreadable records.
    /// Rechecks before an exclusive rename so a concurrent creator cannot be replaced;
    /// a late refusal leaves an unreferenced store. Writes revision 1 with preferences,
    /// runs `beforeRecord` for adjacent files, then writes the locator. A hook failure
    /// leaves no locator pointing to the new store.
    public func create(
        homeURL: URL,
        runner: any CommandRunning,
        registry: ClientAdapterRegistry,
        preferences: DeviceWorkspacePreferences?,
        beforeRecord: (@Sendable (URL) throws -> Void)? = nil
    ) async throws -> WorkspaceRevisionStore {
        guard try read() == nil else { throw WorkspaceLocatorError.alreadyExists }
        return try await createWorkspace(
            homeURL: homeURL, runner: runner, registry: registry, preferences: preferences,
            beforeRecord: beforeRecord, refusesExisting: true)
    }

    /// The one body both doors share, so the order — revision 1, then the
    /// files beside it, then the record — cannot differ between them. With
    /// `refusesExisting`, the record is written only where none is.
    private func createWorkspace(
        homeURL: URL,
        runner: any CommandRunning,
        registry: ClientAdapterRegistry,
        preferences: DeviceWorkspacePreferences?,
        beforeRecord: (@Sendable (URL) throws -> Void)?,
        refusesExisting: Bool
    ) async throws -> WorkspaceRevisionStore {
        let created = try await WorkspaceFirstRun.begin(
            containerRoot: containerRoot, homeURL: homeURL, runner: runner, registry: registry,
            preferences: preferences)
        try beforeRecord?(created.store.databaseURL.deletingLastPathComponent())
        let record = Record(workspaceID: created.result.document.workspaceID, deviceID: created.result.device.deviceID)
        if refusesExisting {
            try writeWhereNoneIs(record)
        } else {
            try write(record)
        }
        return created.store
    }

    /// Writes `record` only where there is no record, and never over one that
    /// appears meanwhile. The record is looked for first, as `create` does,
    /// so one that cannot be read refuses with its own reason.
    private func writeWhereNoneIs(_ record: Record) throws {
        guard try read() == nil else { throw WorkspaceLocatorError.alreadyExists }
        let bytes: Data
        do { bytes = try AgentToolingCoding.encoder().encode(record) } catch { throw WorkspaceLocatorError.unreadable }
        try Self.place(bytes, at: recordURL)
    }

    /// Puts `bytes` at `destination`, readable by this Mac's user only, unless
    /// a file is already there. The bytes go to a file of their own beside it
    /// first, which a rename that refuses an existing file then moves into
    /// place, so a file that appears at any moment before is never replaced.
    /// On a file system that cannot refuse in the rename, it is a plain
    /// rename, and only a look beforehand guards it.
    static func place(_ bytes: Data, at destination: URL) throws {
        let fileManager = FileManager.default
        let folder = destination.deletingLastPathComponent()
        let staged = folder.appending(path: ".\(destination.lastPathComponent).\(UUID().uuidString)")
        defer { try? fileManager.removeItem(at: staged) }
        do {
            try fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
            try bytes.write(to: staged, options: .withoutOverwriting)
            try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: staged.path(percentEncoded: false))
        } catch { throw WorkspaceLocatorError.unreadable }
        let from = staged.path(percentEncoded: false)
        let to = destination.path(percentEncoded: false)
        guard renamex_np(from, to, UInt32(RENAME_EXCL)) != 0 else { return }
        switch errno {
        case EEXIST:
            throw WorkspaceLocatorError.alreadyExists
        case ENOTSUP:
            guard rename(from, to) == 0 else { throw WorkspaceLocatorError.unreadable }
        default:
            throw WorkspaceLocatorError.unreadable
        }
    }
}
