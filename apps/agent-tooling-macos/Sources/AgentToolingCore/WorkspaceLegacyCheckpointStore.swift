import Darwin
import Foundation

public enum WorkspaceLegacyCheckpointStoreError: Error, Equatable, Sendable {
    case invalidRoot
    case invalidDigest
    case missingCheckpoint
    case corruptCheckpoint
    case changedStore
    case ioFailure
    case busy
}

/// Device-local immutable storage for raw legacy database checkpoints. Saving
/// a checkpoint does not open or mutate the source database and does not
/// initialize a new workspace revision store.
public actor WorkspaceLegacyCheckpointStore {
    private static let marker = Data("agent-tooling-legacy-checkpoints.v1\n".utf8)
    private let handles: LegacyCheckpointStoreHandles

    public init(directory: URL, initializeIfEmpty: Bool = true) throws {
        handles = try LegacyCheckpointStoreHandles(directory: directory, marker: Self.marker, initializeIfEmpty: initializeIfEmpty)
    }

    public func save(_ checkpoint: WorkspaceLegacyCheckpoint) async throws -> String {
        try Task.checkCancellation()
        let verified: WorkspaceLegacyCheckpoint
        do {
            verified = try WorkspaceLegacyCheckpoint.reopen(
                bytes: checkpoint.databaseBytes,
                expectedSHA256: checkpoint.sha256)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw WorkspaceLegacyCheckpointStoreError.corruptCheckpoint
        }
        let digest = verified.sha256
        try validateDigest(digest)
        try handles.validateBindings()
        do {
            _ = try readObject(digest)
            try handles.validateBindings()
            try Task.checkCancellation()
            return digest
        } catch WorkspaceLegacyCheckpointStoreError.missingCheckpoint {
            // Absence alone permits publication. Existing corrupt bytes remain visible.
        }

        let stageName = UUID().uuidString.lowercased()
        let stage = openat(
            handles.staging, stageName,
            O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC,
            0o600)
        guard stage >= 0 else { throw WorkspaceLegacyCheckpointStoreError.ioFailure }
        var stageIdentity = stat()
        guard fstat(stage, &stageIdentity) == 0,
              stageIdentity.st_mode & S_IFMT == S_IFREG,
              stageStillMatches(stageIdentity, name: stageName) else {
            close(stage)
            throw WorkspaceLegacyCheckpointStoreError.changedStore
        }
        var published = false
        defer {
            close(stage)
            if !published, stageStillMatches(stageIdentity, name: stageName) {
                _ = unlinkat(handles.staging, stageName, 0)
            }
        }
        try writeAll(verified.databaseBytes, to: stage)
        guard fchmod(stage, 0o400) == 0, fsync(stage) == 0 else {
            throw WorkspaceLegacyCheckpointStoreError.ioFailure
        }
        try Task.checkCancellation()
        try handles.validateBindings()
        guard regularFile(stage, expectedSize: verified.databaseBytes.count, privateMode: true) else {
            throw WorkspaceLegacyCheckpointStoreError.changedStore
        }
        var stagedFinal = stat()
        guard fstat(stage, &stagedFinal) == 0,
              stagedFinal.st_dev == stageIdentity.st_dev,
              stagedFinal.st_ino == stageIdentity.st_ino,
              stageStillMatches(stagedFinal, name: stageName) else {
            throw WorkspaceLegacyCheckpointStoreError.changedStore
        }
        if renameatx_np(handles.staging, stageName, handles.objects, digest, UInt32(RENAME_EXCL)) != 0 {
            guard errno == EEXIST else { throw WorkspaceLegacyCheckpointStoreError.ioFailure }
            let existing = try readObject(digest)
            try handles.validateBindings()
            try Task.checkCancellation()
            return existing.sha256
        }
        published = true
        guard fsync(handles.objects) == 0, fsync(handles.staging) == 0, fsync(handles.root) == 0 else {
            throw WorkspaceLegacyCheckpointStoreError.ioFailure
        }
        try Task.checkCancellation()
        let stored = try readObject(digest)
        try handles.validateBindings()
        return stored.sha256
    }

    public func read(_ sha256: String) async throws -> WorkspaceLegacyCheckpoint {
        try Task.checkCancellation()
        try validateDigest(sha256)
        try handles.validateBindings()
        let checkpoint = try readObject(sha256)
        try handles.validateBindings()
        try Task.checkCancellation()
        return checkpoint
    }

    private func readObject(_ digest: String) throws -> WorkspaceLegacyCheckpoint {
        let descriptor = openat(handles.objects, digest, O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else {
            throw errno == ENOENT
                ? WorkspaceLegacyCheckpointStoreError.missingCheckpoint
                : WorkspaceLegacyCheckpointStoreError.corruptCheckpoint
        }
        defer { close(descriptor) }
        var initial = stat()
        guard fstat(descriptor, &initial) == 0,
              initial.st_mode & S_IFMT == S_IFREG,
              initial.st_uid == geteuid(),
              initial.st_nlink == 1,
              initial.st_mode & 0o077 == 0,
              initial.st_size > 0,
              initial.st_size <= off_t(WorkspaceLegacyCheckpoint.maximumDatabaseBytes) else {
            throw WorkspaceLegacyCheckpointStoreError.corruptCheckpoint
        }
        let size = Int(initial.st_size)
        var bytes = Data(count: size)
        let count = try bytes.withUnsafeMutableBytes { buffer -> Int in
            guard let base = buffer.baseAddress else { return 0 }
            var offset = 0
            while offset < size {
                try Task.checkCancellation()
                let result = Darwin.read(descriptor, base.advanced(by: offset), size - offset)
                if result < 0, errno == EINTR { continue }
                guard result > 0 else { throw WorkspaceLegacyCheckpointStoreError.corruptCheckpoint }
                offset += result
            }
            return offset
        }
        guard count == size else { throw WorkspaceLegacyCheckpointStoreError.corruptCheckpoint }
        var final = stat()
        guard fstat(descriptor, &final) == 0,
              initial.st_dev == final.st_dev,
              initial.st_ino == final.st_ino,
              initial.st_size == final.st_size,
              initial.st_mtimespec.tv_sec == final.st_mtimespec.tv_sec,
              initial.st_mtimespec.tv_nsec == final.st_mtimespec.tv_nsec,
              initial.st_ctimespec.tv_sec == final.st_ctimespec.tv_sec,
              initial.st_ctimespec.tv_nsec == final.st_ctimespec.tv_nsec,
              regularFile(final, expectedSize: size, privateMode: true),
              objectStillMatches(final, name: digest) else {
            throw WorkspaceLegacyCheckpointStoreError.changedStore
        }
        do {
            return try WorkspaceLegacyCheckpoint.reopen(bytes: bytes, expectedSHA256: digest)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw WorkspaceLegacyCheckpointStoreError.corruptCheckpoint
        }
    }

    private func validateDigest(_ value: String) throws {
        guard value.count == 64,
              value.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else {
            throw WorkspaceLegacyCheckpointStoreError.invalidDigest
        }
    }

    private func writeAll(_ data: Data, to descriptor: Int32) throws {
        try data.withUnsafeBytes { buffer in
            guard let base = buffer.baseAddress, !buffer.isEmpty else {
                throw WorkspaceLegacyCheckpointStoreError.corruptCheckpoint
            }
            var offset = 0
            while offset < buffer.count {
                try Task.checkCancellation()
                let result = Darwin.write(descriptor, base.advanced(by: offset), buffer.count - offset)
                if result < 0, errno == EINTR { continue }
                guard result > 0 else { throw WorkspaceLegacyCheckpointStoreError.ioFailure }
                offset += result
            }
        }
    }

    private func regularFile(_ descriptor: Int32, expectedSize: Int, privateMode: Bool) -> Bool {
        var value = stat()
        return fstat(descriptor, &value) == 0 && regularFile(value, expectedSize: expectedSize, privateMode: privateMode)
    }

    private func regularFile(_ value: stat, expectedSize: Int, privateMode: Bool) -> Bool {
        value.st_mode & S_IFMT == S_IFREG && value.st_uid == geteuid() && value.st_nlink == 1
            && value.st_size == off_t(expectedSize) && (!privateMode || value.st_mode & 0o077 == 0)
    }

    private func objectStillMatches(_ identity: stat, name: String) -> Bool {
        var current = stat()
        return fstatat(handles.objects, name, &current, AT_SYMLINK_NOFOLLOW) == 0
            && current.st_mode & S_IFMT == S_IFREG
            && current.st_dev == identity.st_dev && current.st_ino == identity.st_ino
    }

    private func stageStillMatches(_ identity: stat, name: String) -> Bool {
        var current = stat()
        return fstatat(handles.staging, name, &current, AT_SYMLINK_NOFOLLOW) == 0
            && current.st_mode & S_IFMT == S_IFREG
            && current.st_dev == identity.st_dev && current.st_ino == identity.st_ino
    }
}

private struct LegacyCheckpointStoreIdentity {
    let device: dev_t
    let inode: ino_t

    init(descriptor: Int32) throws {
        var value = stat()
        guard fstat(descriptor, &value) == 0, value.st_mode & S_IFMT == S_IFDIR else {
            throw WorkspaceLegacyCheckpointStoreError.invalidRoot
        }
        device = value.st_dev
        inode = value.st_ino
    }

    func matches(parent: Int32, name: String) -> Bool {
        var value = stat()
        return fstatat(parent, name, &value, AT_SYMLINK_NOFOLLOW) == 0
            && value.st_mode & S_IFMT == S_IFDIR && value.st_dev == device && value.st_ino == inode
    }
}

private final class LegacyCheckpointStoreHandles: @unchecked Sendable {
    let root: Int32
    let objects: Int32
    let staging: Int32
    private let rootPath: String
    private let marker: Data
    private let rootIdentity: LegacyCheckpointStoreIdentity
    private let objectsIdentity: LegacyCheckpointStoreIdentity
    private let stagingIdentity: LegacyCheckpointStoreIdentity

    init(directory: URL, marker: Data, initializeIfEmpty: Bool) throws {
        guard directory.isFileURL, directory.path.hasPrefix("/"),
              !directory.path.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else {
            throw WorkspaceLegacyCheckpointStoreError.invalidRoot
        }
        var original = stat()
        guard lstat(directory.path, &original) == 0,
              original.st_mode & S_IFMT == S_IFDIR,
              original.st_uid == geteuid(),
              original.st_mode & 0o077 == 0,
              let resolved = directory.path.withCString({ realpath($0, nil) }) else {
            throw WorkspaceLegacyCheckpointStoreError.invalidRoot
        }
        defer { free(resolved) }
        let path = String(cString: resolved)
        let root = open(path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard root >= 0 else { throw WorkspaceLegacyCheckpointStoreError.invalidRoot }
        var keepRoot = false
        defer { if !keepRoot { close(root) } }
        var opened = stat()
        guard fstat(root, &opened) == 0,
              opened.st_dev == original.st_dev,
              opened.st_ino == original.st_ino,
              Self.privateDirectory(root) else {
            throw WorkspaceLegacyCheckpointStoreError.invalidRoot
        }
        guard flock(root, LOCK_EX | LOCK_NB) == 0 else {
            throw errno == EWOULDBLOCK
                ? WorkspaceLegacyCheckpointStoreError.busy
                : WorkspaceLegacyCheckpointStoreError.ioFailure
        }
        defer { _ = flock(root, LOCK_UN) }
        let names = try Self.names(root)
        guard initializeIfEmpty || Set(names) == ["format", "objects", "staging"] else {
            throw WorkspaceLegacyCheckpointStoreError.invalidRoot
        }
        if names.isEmpty {
            try Self.writeMarker(marker, parent: root)
            guard fsync(root) == 0 else { throw WorkspaceLegacyCheckpointStoreError.ioFailure }
        }
        guard Set(try Self.names(root)).isSubset(of: ["format", "objects", "staging"]),
              try Self.readMarker(parent: root) == marker else {
            throw WorkspaceLegacyCheckpointStoreError.invalidRoot
        }
        let objects = try Self.ensureDirectory(parent: root, name: "objects", create: initializeIfEmpty)
        var keepObjects = false
        defer { if !keepObjects { close(objects) } }
        let staging = try Self.ensureDirectory(parent: root, name: "staging", create: initializeIfEmpty)
        var keepStaging = false
        defer { if !keepStaging { close(staging) } }
        self.root = root
        self.objects = objects
        self.staging = staging
        rootPath = path
        self.marker = marker
        rootIdentity = try LegacyCheckpointStoreIdentity(descriptor: root)
        objectsIdentity = try LegacyCheckpointStoreIdentity(descriptor: objects)
        stagingIdentity = try LegacyCheckpointStoreIdentity(descriptor: staging)
        keepRoot = true
        keepObjects = true
        keepStaging = true
    }

    deinit {
        close(staging)
        close(objects)
        close(root)
    }

    func validateBindings() throws {
        guard rootIdentity.matches(parent: AT_FDCWD, name: rootPath),
              objectsIdentity.matches(parent: root, name: "objects"),
              stagingIdentity.matches(parent: root, name: "staging"),
              Self.privateDirectory(root), Self.privateDirectory(objects), Self.privateDirectory(staging),
              try Self.readMarker(parent: root) == marker else {
            throw WorkspaceLegacyCheckpointStoreError.changedStore
        }
    }

    private static func privateDirectory(_ descriptor: Int32) -> Bool {
        var value = stat()
        return fstat(descriptor, &value) == 0 && value.st_mode & S_IFMT == S_IFDIR
            && value.st_uid == geteuid() && value.st_mode & 0o077 == 0
    }

    private static func ensureDirectory(parent: Int32, name: String, create: Bool = true) throws -> Int32 {
        if create, mkdirat(parent, name, 0o700) != 0, errno != EEXIST {
            throw WorkspaceLegacyCheckpointStoreError.invalidRoot
        }
        let descriptor = openat(parent, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0, privateDirectory(descriptor) else {
            if descriptor >= 0 { close(descriptor) }
            throw WorkspaceLegacyCheckpointStoreError.invalidRoot
        }
        return descriptor
    }

    private static func writeMarker(_ marker: Data, parent: Int32) throws {
        let descriptor = openat(parent, "format", O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { throw WorkspaceLegacyCheckpointStoreError.ioFailure }
        defer { close(descriptor) }
        let written = marker.withUnsafeBytes { buffer -> Int in
            guard let base = buffer.baseAddress else { return 0 }
            var offset = 0
            while offset < buffer.count {
                let count = Darwin.write(descriptor, base.advanced(by: offset), buffer.count - offset)
                if count < 0, errno == EINTR { continue }
                guard count > 0 else { return -1 }
                offset += count
            }
            return offset
        }
        guard written == marker.count, fchmod(descriptor, 0o400) == 0, fsync(descriptor) == 0 else {
            throw WorkspaceLegacyCheckpointStoreError.ioFailure
        }
    }

    private static func readMarker(parent: Int32) throws -> Data {
        let descriptor = openat(parent, "format", O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { throw WorkspaceLegacyCheckpointStoreError.invalidRoot }
        defer { close(descriptor) }
        var value = stat()
        guard fstat(descriptor, &value) == 0, value.st_mode & S_IFMT == S_IFREG,
              value.st_uid == geteuid(), value.st_nlink == 1, value.st_mode & 0o077 == 0,
              value.st_size > 0, value.st_size <= 128 else {
            throw WorkspaceLegacyCheckpointStoreError.invalidRoot
        }
        var data = Data(count: Int(value.st_size))
        let readCount = data.withUnsafeMutableBytes { buffer -> Int in
            guard let base = buffer.baseAddress else { return 0 }
            var offset = 0
            while offset < buffer.count {
                let count = Darwin.read(descriptor, base.advanced(by: offset), buffer.count - offset)
                if count < 0, errno == EINTR { continue }
                guard count > 0 else { return -1 }
                offset += count
            }
            return offset
        }
        guard readCount == data.count else { throw WorkspaceLegacyCheckpointStoreError.invalidRoot }
        return data
    }

    private static func names(_ descriptor: Int32) throws -> [String] {
        let copy = openat(descriptor, ".", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard copy >= 0, let stream = fdopendir(copy) else {
            if copy >= 0 { close(copy) }
            throw WorkspaceLegacyCheckpointStoreError.ioFailure
        }
        defer { closedir(stream) }
        var result: [String] = []
        while true {
            errno = 0
            guard let entry = readdir(stream) else {
                guard errno == 0 else { throw WorkspaceLegacyCheckpointStoreError.ioFailure }
                break
            }
            let count = Int(entry.pointee.d_namlen) + 1
            let name = withUnsafePointer(to: &entry.pointee.d_name) {
                $0.withMemoryRebound(to: CChar.self, capacity: count) { String(validatingCString: $0) }
            }
            guard let name else { throw WorkspaceLegacyCheckpointStoreError.invalidRoot }
            if name == "." || name == ".." { continue }
            guard result.count < 4 else { throw WorkspaceLegacyCheckpointStoreError.invalidRoot }
            result.append(name)
        }
        return result.sorted()
    }
}
