import Darwin
import Foundation

public enum WorkspaceAuthorityChoice: String, Codable, Equatable, Sendable {
    case versioned
    case legacy
}

public struct WorkspaceAuthorityTarget: Codable, Equatable, Sendable {
    public let containerRootPath: String
    public let workspaceID: WorkspaceObjectID
    public let deviceID: WorkspaceObjectID
    public let attemptID: WorkspaceObjectID

    public init(
        containerRootPath: String,
        workspaceID: WorkspaceObjectID,
        deviceID: WorkspaceObjectID,
        attemptID: WorkspaceObjectID
    ) {
        self.containerRootPath = containerRootPath
        self.workspaceID = workspaceID
        self.deviceID = deviceID
        self.attemptID = attemptID
    }
}

public struct WorkspaceAuthoritySelection: Codable, Equatable, Sendable {
    public let id: WorkspaceObjectID
    public let previousID: WorkspaceObjectID?
    public let choice: WorkspaceAuthorityChoice
    public let target: WorkspaceAuthorityTarget
    public let checkpointSHA256: String
    public let versionedRevisionID: WorkspaceObjectID
    public let selectedAt: Date

    public init(
        id: WorkspaceObjectID = WorkspaceObjectID(),
        previousID: WorkspaceObjectID? = nil,
        choice: WorkspaceAuthorityChoice,
        target: WorkspaceAuthorityTarget,
        checkpointSHA256: String,
        versionedRevisionID: WorkspaceObjectID,
        selectedAt: Date = .now
    ) {
        self.id = id
        self.previousID = previousID
        self.choice = choice
        self.target = target
        self.checkpointSHA256 = checkpointSHA256
        self.versionedRevisionID = versionedRevisionID
        self.selectedAt = WorkspaceDomainValidation.canonicalDate(selectedAt)
    }
}

public enum WorkspaceAuthorityStoreError: Error, Equatable, LocalizedError, Sendable {
    case unavailable
    case unsafePath
    case corruptRegistry
    case unsupportedVersion
    case invalidSelection
    case staleSelection(current: WorkspaceObjectID?)
    case versionedSelected
    case busy
    case historyLimitExceeded
    case ioFailure(code: Int32)

    public var errorDescription: String? {
        switch self {
        case .unavailable: "The workspace authority registry is unavailable."
        case .unsafePath: "The workspace authority registry location is unsafe."
        case .corruptRegistry: "The workspace authority history is incomplete or inconsistent."
        case .unsupportedVersion: "This workspace authority registry requires a different app version."
        case .invalidSelection: "The workspace authority selection is invalid."
        case .staleSelection: "Workspace authority changed before this selection could be saved."
        case .versionedSelected: "The versioned workspace is selected. The retained legacy workspace is read only."
        case .busy: "Another workspace authority operation is in progress. Try again."
        case .historyLimitExceeded: "The workspace authority history reached its supported limit."
        case .ioFailure(let code): "The workspace authority registry could not be accessed (system error \(code))."
        }
    }
}

/// Stores the explicit choice of workspace authority beside the retained legacy
/// database. Selection does not validate migration readiness; the caller must do
/// so while holding `withExclusiveAccess` before it appends the reviewed choice.
public final class WorkspaceAuthorityStore: @unchecked Sendable {
    public static let maximumHistoryCount = 1_024
    public static let maximumRegistryBytes = 4 * 1_024 * 1_024

    public let legacyRoot: URL

    private static let registryName = "workspace-authority-v1.json"
    private static let lockName = ".workspace-authority-v1.lock"
    private let rootPath: String

    public init(legacyRoot: URL) throws {
        rootPath = try Self.validatedRootPath(legacyRoot, missingIsNil: false)!
        self.legacyRoot = URL(fileURLWithPath: rootPath, isDirectory: true)
        let root = try Self.openRoot(rootPath)
        defer { close(root) }
        let hasRegistry = try Self.itemExists(root: root, name: Self.registryName)
        let hasLock = try Self.itemExists(root: root, name: Self.lockName)
        if hasRegistry && !hasLock {
            throw WorkspaceAuthorityStoreError.unsafePath
        }
        let lock = try Self.openLock(root: root, create: true)
        close(lock)
    }

    public static func readIfPresent(legacyRoot: URL) throws -> WorkspaceAuthoritySelection? {
        guard let rootPath = try validatedRootPath(legacyRoot, missingIsNil: true, requirePrivate: false) else { return nil }
        let root = try openRoot(rootPath, requirePrivate: false)
        defer { close(root) }
        let hasRegistry = try itemExists(root: root, name: registryName)
        let hasLock = try itemExists(root: root, name: lockName)
        guard hasRegistry || hasLock else { return nil }
        guard rootIsPrivate(root) else { throw WorkspaceAuthorityStoreError.unsafePath }
        guard hasLock else { throw WorkspaceAuthorityStoreError.unsafePath }
        let lock = try openLock(root: root, create: false)
        defer { close(lock) }
        try acquire(lock, operation: LOCK_SH)
        defer { flock(lock, LOCK_UN) }
        return try readDocument(root: root, legacyRootPath: rootPath)?.selections.last
    }

    public func read() throws -> WorkspaceAuthoritySelection? {
        try withSharedAccess { $0.last }
    }

    public func history() throws -> [WorkspaceAuthoritySelection] {
        try withSharedAccess { $0 }
    }

    public func lookup(_ id: WorkspaceObjectID) throws -> WorkspaceAuthoritySelection? {
        try withSharedAccess { $0.first { $0.id == id } }
    }

    func withExclusiveAccess<T>(_ body: (WorkspaceAuthorityTransaction) throws -> T) throws -> T {
        let root = try Self.openRoot(rootPath)
        defer { close(root) }
        let lock = try Self.openLock(root: root, create: false)
        defer { close(lock) }
        try Self.acquire(lock, operation: LOCK_EX)
        defer { flock(lock, LOCK_UN) }
        let transaction = WorkspaceAuthorityTransaction(
            rootDescriptor: root,
            legacyRootPath: rootPath,
            selections: try Self.readDocument(root: root, legacyRootPath: rootPath)?.selections ?? []
        )
        defer { transaction.invalidate() }
        return try body(transaction)
    }

    /// Cooperative legacy writers hold a shared lock. Existing binaries that do
    /// not use this API remain outside this boundary and require freshness checks
    /// before an authority switch.
    static func withLegacyWriteAccess<T>(legacyRoot: URL, body: () throws -> T) throws -> T {
        let store = try WorkspaceAuthorityStore(legacyRoot: legacyRoot)
        let root = try openRoot(store.rootPath)
        defer { close(root) }
        let lock = try openLock(root: root, create: false)
        defer { close(lock) }
        try acquire(lock, operation: LOCK_SH)
        defer { flock(lock, LOCK_UN) }
        let current = try readDocument(root: root, legacyRootPath: store.rootPath)?.selections.last
        guard current?.choice != .versioned else { throw WorkspaceAuthorityStoreError.versionedSelected }
        return try body()
    }

    /// Selected versioned writers hold the same shared lease through their
    /// database transaction. Rollback therefore cannot publish between the
    /// authority check and the commit, including on an already-open connection.
    static func withVersionedWriteAccess<T>(legacyRoot: URL, selection: WorkspaceAuthoritySelection,
                                           body: () throws -> T) throws -> T {
        let store = try WorkspaceAuthorityStore(legacyRoot: legacyRoot)
        return try store.withSharedAccess { history in
            let current = history.last
            guard selection.choice == .versioned, current == selection else {
                throw WorkspaceAuthorityStoreError.staleSelection(current: current?.id)
            }
            return try body()
        }
    }

    private func withSharedAccess<T>(_ body: ([WorkspaceAuthoritySelection]) throws -> T) throws -> T {
        let root = try Self.openRoot(rootPath)
        defer { close(root) }
        let lock = try Self.openLock(root: root, create: false)
        defer { close(lock) }
        try Self.acquire(lock, operation: LOCK_SH)
        defer { flock(lock, LOCK_UN) }
        return try body(Self.readDocument(root: root, legacyRootPath: rootPath)?.selections ?? [])
    }

    fileprivate static func commit(
        _ selection: WorkspaceAuthoritySelection,
        expectedSelectionID: WorkspaceObjectID?,
        transaction: WorkspaceAuthorityTransaction,
        beforeRename: (() throws -> Void)?
    ) throws -> WorkspaceAuthoritySelection {
        guard transaction.isActive else { throw WorkspaceAuthorityStoreError.unavailable }
        guard isEncodableDate(selection.selectedAt) else {
            throw WorkspaceAuthorityStoreError.invalidSelection
        }
        let candidate = canonical(selection)
        try validate(candidate, legacyRootPath: transaction.legacyRootPath)
        if let prior = transaction.selections.first(where: { $0.id == candidate.id }) {
            guard prior == candidate else { throw WorkspaceAuthorityStoreError.invalidSelection }
            return prior
        }
        let current = transaction.selections.last
        guard current?.id == expectedSelectionID else {
            throw WorkspaceAuthorityStoreError.staleSelection(current: current?.id)
        }
        if let current {
            guard current.choice == .versioned, candidate.choice == .legacy,
                  candidate.previousID == current.id,
                  candidate.target == current.target else {
                throw WorkspaceAuthorityStoreError.invalidSelection
            }
        } else {
            guard candidate.choice == .versioned, candidate.previousID == nil else {
                throw WorkspaceAuthorityStoreError.invalidSelection
            }
        }
        guard transaction.selections.count < maximumHistoryCount else {
            throw WorkspaceAuthorityStoreError.historyLimitExceeded
        }
        let updated = transaction.selections + [candidate]
        try validateHistory(updated, legacyRootPath: transaction.legacyRootPath)
        try publish(updated, root: transaction.rootDescriptor, beforeRename: beforeRename)
        transaction.selections = updated
        return candidate
    }

    private static func readDocument(root: Int32, legacyRootPath: String) throws -> RegistryDocument? {
        let descriptor = openat(root, registryName, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        if descriptor < 0 {
            if errno == ENOENT { return nil }
            throw WorkspaceAuthorityStoreError.ioFailure(code: errno)
        }
        defer { close(descriptor) }
        try validateFile(descriptor, root: root, name: registryName)
        var info = stat()
        guard fstat(descriptor, &info) == 0 else { throw WorkspaceAuthorityStoreError.ioFailure(code: errno) }
        guard info.st_size > 0, info.st_size <= off_t(maximumRegistryBytes) else {
            throw WorkspaceAuthorityStoreError.corruptRegistry
        }
        var data = Data()
        data.reserveCapacity(Int(info.st_size))
        var buffer = [UInt8](repeating: 0, count: 64 * 1_024)
        while true {
            let count = buffer.withUnsafeMutableBytes {
                Darwin.read(descriptor, $0.baseAddress, $0.count)
            }
            if count == 0 { break }
            if count < 0 {
                if errno == EINTR { continue }
                throw WorkspaceAuthorityStoreError.ioFailure(code: errno)
            }
            guard data.count + count <= maximumRegistryBytes else {
                throw WorkspaceAuthorityStoreError.corruptRegistry
            }
            data.append(contentsOf: buffer.prefix(count))
        }
        let document: RegistryDocument
        do { document = try decoder().decode(RegistryDocument.self, from: data) }
        catch { throw WorkspaceAuthorityStoreError.corruptRegistry }
        guard document.schemaVersion == 1 else { throw WorkspaceAuthorityStoreError.unsupportedVersion }
        guard !document.selections.isEmpty else { throw WorkspaceAuthorityStoreError.corruptRegistry }
        try validateHistory(document.selections, legacyRootPath: legacyRootPath)
        guard try encoder().encode(document) == data else { throw WorkspaceAuthorityStoreError.corruptRegistry }
        return document
    }

    private static func publish(
        _ selections: [WorkspaceAuthoritySelection], root: Int32, beforeRename: (() throws -> Void)?
    ) throws {
        let data = try encoder().encode(RegistryDocument(schemaVersion: 1, selections: selections))
        guard data.count <= maximumRegistryBytes else { throw WorkspaceAuthorityStoreError.historyLimitExceeded }
        let stage = ".workspace-authority-\(UUID().uuidString.lowercased()).tmp"
        let descriptor = openat(root, stage, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW, 0o600)
        guard descriptor >= 0 else { throw WorkspaceAuthorityStoreError.ioFailure(code: errno) }
        var renamed = false
        defer {
            close(descriptor)
            if !renamed { unlinkat(root, stage, 0) }
        }
        try data.withUnsafeBytes { raw in
            var offset = 0
            while offset < raw.count {
                let count = Darwin.write(descriptor, raw.baseAddress!.advanced(by: offset), raw.count - offset)
                if count < 0 {
                    if errno == EINTR { continue }
                    throw WorkspaceAuthorityStoreError.ioFailure(code: errno)
                }
                offset += count
            }
        }
        guard fsync(descriptor) == 0 else { throw WorkspaceAuthorityStoreError.ioFailure(code: errno) }
        try validateFile(descriptor, root: root, name: stage)
        try beforeRename?()
        guard renameat(root, stage, root, registryName) == 0 else {
            throw WorkspaceAuthorityStoreError.ioFailure(code: errno)
        }
        renamed = true
        try validateFile(descriptor, root: root, name: registryName)
        guard fsync(root) == 0 else { throw WorkspaceAuthorityStoreError.ioFailure(code: errno) }
    }

    private static func validateHistory(
        _ selections: [WorkspaceAuthoritySelection], legacyRootPath: String?
    ) throws {
        guard selections.count <= maximumHistoryCount else { throw WorkspaceAuthorityStoreError.historyLimitExceeded }
        guard Set(selections.map(\.id)).count == selections.count else { throw WorkspaceAuthorityStoreError.corruptRegistry }
        for (index, selection) in selections.enumerated() {
            try validate(selection, legacyRootPath: legacyRootPath)
            if index == 0 {
                guard selection.previousID == nil, selection.choice == .versioned else {
                    throw WorkspaceAuthorityStoreError.corruptRegistry
                }
            } else {
                let previous = selections[index - 1]
                guard selection.previousID == previous.id,
                      previous.choice == .versioned, selection.choice == .legacy,
                      selection.target == previous.target else {
                    throw WorkspaceAuthorityStoreError.corruptRegistry
                }
            }
        }
    }

    private static func validate(_ selection: WorkspaceAuthoritySelection, legacyRootPath: String?) throws {
        guard selection.id != selection.previousID,
              Set([
                selection.id, selection.target.workspaceID, selection.target.deviceID,
                selection.target.attemptID, selection.versionedRevisionID
              ]).count == 5,
              isCanonicalAbsoluteDirectory(selection.target.containerRootPath),
              isLowercaseSHA256(selection.checkpointSHA256),
              isEncodableDate(selection.selectedAt),
              selection.selectedAt == canonical(selection).selectedAt else {
            throw WorkspaceAuthorityStoreError.invalidSelection
        }
        if let legacyRootPath {
            let legacyDatabase = URL(fileURLWithPath: legacyRootPath).appending(path: "agent-tooling.sqlite").standardizedFileURL.path
            let targetDatabase = URL(fileURLWithPath: selection.target.containerRootPath)
                .appending(path: "workspaces-v1")
                .appending(path: selection.target.workspaceID.rawValue.uuidString.lowercased())
                .appending(path: "revisions.sqlite").standardizedFileURL.path
            guard legacyDatabase != targetDatabase else { throw WorkspaceAuthorityStoreError.invalidSelection }
        }
    }

    private static func canonical(_ selection: WorkspaceAuthoritySelection) -> WorkspaceAuthoritySelection {
        WorkspaceAuthoritySelection(
            id: selection.id, previousID: selection.previousID, choice: selection.choice,
            target: selection.target, checkpointSHA256: selection.checkpointSHA256,
            versionedRevisionID: selection.versionedRevisionID,
            selectedAt: WorkspaceDomainValidation.canonicalDate(selection.selectedAt)
        )
    }

    private static func isCanonicalAbsoluteDirectory(_ path: String) -> Bool {
        guard !path.isEmpty, path.utf8.count <= 4_096, path.hasPrefix("/"), path != "/",
              path.precomposedStringWithCanonicalMapping == path,
              !path.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7f }) else { return false }
        return URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL.path == path
    }

    private static func isLowercaseSHA256(_ value: String) -> Bool {
        value.utf8.count == 64 && value.utf8.allSatisfy { ($0 >= 48 && $0 <= 57) || ($0 >= 97 && $0 <= 102) }
    }

    private static func isEncodableDate(_ date: Date) -> Bool {
        let milliseconds = (date.timeIntervalSince1970 * 1_000).rounded()
        return milliseconds.isFinite && milliseconds > Double(Int64.min) && milliseconds < Double(Int64.max)
    }

    private static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(Int64((date.timeIntervalSince1970 * 1_000).rounded()))
        }
        return encoder
    }

    private static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let milliseconds = try decoder.singleValueContainer().decode(Int64.self)
            return Date(timeIntervalSince1970: Double(milliseconds) / 1_000)
        }
        return decoder
    }

    private static func validatedRootPath(
        _ url: URL, missingIsNil: Bool, requirePrivate: Bool = true
    ) throws -> String? {
        guard url.isFileURL, url.path.hasPrefix("/"), url.standardizedFileURL.path != "/" else {
            throw WorkspaceAuthorityStoreError.unsafePath
        }
        var info = stat()
        if lstat(url.path, &info) != 0 {
            if missingIsNil, errno == ENOENT { return nil }
            throw WorkspaceAuthorityStoreError.unavailable
        }
        let permissions = info.st_mode & 0o777
        guard (info.st_mode & S_IFMT) == S_IFDIR, info.st_uid == getuid(),
              (requirePrivate ? permissions == 0o700 : (permissions & 0o022) == 0) else {
            throw WorkspaceAuthorityStoreError.unsafePath
        }
        guard let resolved = realpath(url.path, nil) else { throw WorkspaceAuthorityStoreError.unsafePath }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    private static func openRoot(_ path: String, requirePrivate: Bool = true) throws -> Int32 {
        let descriptor = open(path, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
        guard descriptor >= 0 else { throw WorkspaceAuthorityStoreError.ioFailure(code: errno) }
        var info = stat()
        guard fstat(descriptor, &info) == 0 else {
            let code = errno
            close(descriptor)
            throw WorkspaceAuthorityStoreError.ioFailure(code: code)
        }
        let permissions = info.st_mode & 0o777
        guard (info.st_mode & S_IFMT) == S_IFDIR, info.st_uid == getuid(),
              (requirePrivate ? permissions == 0o700 : (permissions & 0o022) == 0) else {
            close(descriptor)
            throw WorkspaceAuthorityStoreError.unsafePath
        }
        return descriptor
    }

    private static func rootIsPrivate(_ descriptor: Int32) -> Bool {
        var info = stat()
        return fstat(descriptor, &info) == 0 && (info.st_mode & S_IFMT) == S_IFDIR
            && info.st_uid == getuid() && (info.st_mode & 0o777) == 0o700
    }

    private static func openLock(root: Int32, create: Bool) throws -> Int32 {
        var descriptor = openat(root, lockName, O_RDWR | O_CLOEXEC | O_NOFOLLOW, 0)
        if descriptor < 0, create, errno == ENOENT {
            descriptor = openat(root, lockName, O_RDWR | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW, 0o600)
            if descriptor >= 0, fchmod(descriptor, 0o600) != 0 {
                let code = errno
                close(descriptor)
                unlinkat(root, lockName, 0)
                throw WorkspaceAuthorityStoreError.ioFailure(code: code)
            }
            if descriptor < 0, errno == EEXIST {
                descriptor = openat(root, lockName, O_RDWR | O_CLOEXEC | O_NOFOLLOW, 0)
            }
        }
        guard descriptor >= 0 else {
            if !create, errno == ENOENT { throw WorkspaceAuthorityStoreError.unavailable }
            throw WorkspaceAuthorityStoreError.ioFailure(code: errno)
        }
        do { try validateFile(descriptor, root: root, name: lockName) }
        catch { close(descriptor); throw error }
        return descriptor
    }

    private static func validateFile(_ descriptor: Int32, root: Int32, name: String) throws {
        var opened = stat(), named = stat()
        guard fstat(descriptor, &opened) == 0,
              fstatat(root, name, &named, AT_SYMLINK_NOFOLLOW) == 0 else {
            throw WorkspaceAuthorityStoreError.ioFailure(code: errno)
        }
        guard (opened.st_mode & S_IFMT) == S_IFREG, opened.st_uid == getuid(),
              opened.st_nlink == 1, (opened.st_mode & 0o777) == 0o600,
              opened.st_dev == named.st_dev, opened.st_ino == named.st_ino else {
            throw WorkspaceAuthorityStoreError.unsafePath
        }
    }

    private static func itemExists(root: Int32, name: String) throws -> Bool {
        var info = stat()
        if fstatat(root, name, &info, AT_SYMLINK_NOFOLLOW) == 0 { return true }
        if errno == ENOENT { return false }
        throw WorkspaceAuthorityStoreError.ioFailure(code: errno)
    }

    private static func acquire(_ descriptor: Int32, operation: Int32) throws {
        while flock(descriptor, operation | LOCK_NB) != 0 {
            if errno == EINTR { continue }
            if errno == EWOULDBLOCK || errno == EAGAIN { throw WorkspaceAuthorityStoreError.busy }
            throw WorkspaceAuthorityStoreError.ioFailure(code: errno)
        }
    }

    private struct RegistryDocument: Codable {
        let schemaVersion: UInt
        let selections: [WorkspaceAuthoritySelection]
    }
}

final class WorkspaceAuthorityTransaction {
    fileprivate let rootDescriptor: Int32
    fileprivate let legacyRootPath: String
    fileprivate var selections: [WorkspaceAuthoritySelection]
    fileprivate var isActive = true

    fileprivate init(rootDescriptor: Int32, legacyRootPath: String, selections: [WorkspaceAuthoritySelection]) {
        self.rootDescriptor = rootDescriptor
        self.legacyRootPath = legacyRootPath
        self.selections = selections
    }

    func read() -> WorkspaceAuthoritySelection? { selections.last }
    func history() -> [WorkspaceAuthoritySelection] { selections }
    func lookup(_ id: WorkspaceObjectID) -> WorkspaceAuthoritySelection? { selections.first { $0.id == id } }

    fileprivate func invalidate() { isActive = false }

    @discardableResult
    func commit(
        _ selection: WorkspaceAuthoritySelection,
        expectedSelectionID: WorkspaceObjectID?
    ) throws -> WorkspaceAuthoritySelection {
        try WorkspaceAuthorityStore.commit(selection, expectedSelectionID: expectedSelectionID,
            transaction: self, beforeRename: nil)
    }

    @discardableResult
    func commit(
        _ selection: WorkspaceAuthoritySelection,
        expectedSelectionID: WorkspaceObjectID?,
        beforeRename: @escaping () throws -> Void
    ) throws -> WorkspaceAuthoritySelection {
        try WorkspaceAuthorityStore.commit(selection, expectedSelectionID: expectedSelectionID,
            transaction: self, beforeRename: beforeRename)
    }
}
