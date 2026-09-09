import Darwin
import Foundation

public enum CentralPackageStoreError: Error, Equatable, Sendable {
    case invalidRoot, invalidDigest, missingContent, corruptContent, changedStore, ioFailure, busy
}

public struct StoredPackageContent: Hashable, Sendable {
    public let digest: ContentDigest
    public let entryCount: Int
    public let totalFileBytes: Int
}

/// Explicitly initialized, device-local immutable content objects. Publishing an object
/// does not change workspace authority, source locks, assignments or native installations.
/// The application service may reference it only after its own revision/journal checks.
public actor CentralPackageContentStore {
    private let handles: ContentStoreHandles
    private let limits: PackageTreeLimits
    private static let marker = Data("agent-tooling-content-store.v1\n".utf8)

    /// Requires an existing private directory dedicated to this store. An empty directory
    /// is initialized; a nonempty directory must already carry the exact format marker.
    public init(directory: URL, limits: PackageTreeLimits = .default, initializeIfEmpty: Bool = true) throws {
        try limits.validate()
        self.limits = limits
        handles = try ContentStoreHandles(directory: directory, marker: Self.marker, initializeIfEmpty: initializeIfEmpty)
    }

    public func read(_ digest: ContentDigest) async throws -> CapturedPackageTree {
        try validate(digest)
        try handles.validateBindings()
        let object = openat(handles.objects, digest.value, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard object >= 0 else {
            throw errno == ENOENT ? CentralPackageStoreError.missingContent : .corruptContent
        }
        defer { close(object) }
        let identity = try ContentStoreIdentity(descriptor: object)
        guard try ContentStoreFS.names(object) == ["payload"] else { throw CentralPackageStoreError.corruptContent }
        let payload = openat(object, "payload", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard payload >= 0 else { throw CentralPackageStoreError.corruptContent }
        defer { close(payload) }
        let payloadIdentity = try ContentStoreIdentity(descriptor: payload)
        let tree: CapturedPackageTree
        do {
            tree = try await PackageTreeCapture().capture(directoryDescriptor: payload, limits: limits)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw CentralPackageStoreError.corruptContent
        }
        try handles.validateBindings()
        guard identity.matches(parent: handles.objects, name: digest.value),
              payloadIdentity.matches(parent: object, name: "payload"),
              try ContentStoreFS.names(object) == ["payload"], !tree.excludedRootGitMetadata,
              tree.digest == digest else {
            throw CentralPackageStoreError.corruptContent
        }
        return tree
    }

    /// Content-addressed, no-clobber publish. Existing content is verified, never repaired
    /// silently. Old versions remain available; retention/GC belongs to revision policy.
    public func store(_ input: CapturedPackageTree) async throws -> StoredPackageContent {
        try Task.checkCancellation()
        let tree = try CapturedPackageTree(entries: input.entries, limits: limits,
                                           excludedRootGitMetadata: input.excludedRootGitMetadata)
        try handles.validateBindings()
        do {
            return summary(try await read(tree.digest))
        } catch CentralPackageStoreError.missingContent {
            // Only absence admits a new object; corruption and access failures remain visible.
        }
        let stageName = UUID().uuidString.lowercased()
        guard mkdirat(handles.staging, stageName, 0o700) == 0 else { throw CentralPackageStoreError.ioFailure }
        let stage = openat(handles.staging, stageName, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard stage >= 0 else { throw CentralPackageStoreError.ioFailure }
        defer { close(stage) }
        let stageIdentity = try ContentStoreIdentity(descriptor: stage)
        var published = false
        defer {
            if !published, stageIdentity.matches(parent: handles.staging, name: stageName) {
                try? ContentStoreFS.removeContents(stage)
                if stageIdentity.matches(parent: handles.staging, name: stageName) {
                    _ = unlinkat(handles.staging, stageName, AT_REMOVEDIR)
                }
            }
        }
        let payload = try ContentStoreFS.createDirectory(parent: stage, name: "payload")
        defer { close(payload) }
        for entry in tree.entries {
            try Task.checkCancellation()
            let components = entry.relativePath.split(separator: "/").map(String.init)
            guard let name = components.last else { throw CentralPackageStoreError.ioFailure }
            let parent = try ContentStoreFS.openDirectory(payload, components: Array(components.dropLast()))
            defer { close(parent) }
            switch entry.kind {
            case .directory:
                let directory = try ContentStoreFS.createDirectory(parent: parent, name: name)
                close(directory)
            case .file(let bytes, let executable):
                try ContentStoreFS.writeFile(parent: parent, name: name, bytes: bytes, mode: executable ? 0o500 : 0o400)
            case .symbolicLink(let target):
                guard symlinkat(target, parent, name) == 0 else { throw CentralPackageStoreError.ioFailure }
            }
        }
        // Flush children before parents. Protection bits are device metadata; only file
        // executable intent participates in the portable tree digest.
        for entry in tree.entries.reversed() where entry.kind == .directory {
            let directory = try ContentStoreFS.openDirectory(payload, components: entry.relativePath.split(separator: "/").map(String.init))
            defer { close(directory) }
            guard fchmod(directory, 0o500) == 0, fsync(directory) == 0 else { throw CentralPackageStoreError.ioFailure }
        }
        guard fchmod(payload, 0o500) == 0, fsync(payload) == 0, fsync(stage) == 0 else {
            throw CentralPackageStoreError.ioFailure
        }
        let staged = try await PackageTreeCapture().capture(directoryDescriptor: payload, limits: limits)
        guard !staged.excludedRootGitMetadata, staged.digest == tree.digest else { throw CentralPackageStoreError.corruptContent }
        try Task.checkCancellation()
        try handles.validateBindings()
        guard stageIdentity.matches(parent: handles.staging, name: stageName) else { throw CentralPackageStoreError.changedStore }
        if renameatx_np(handles.staging, stageName, handles.objects, tree.digest.value, UInt32(RENAME_EXCL)) != 0 {
            guard errno == EEXIST else { throw CentralPackageStoreError.ioFailure }
            // Another process may have published this same digest during staging.
            return summary(try await read(tree.digest))
        }
        published = true
        // macOS requires write permission on the directory being renamed. Protect
        // the wrapper immediately afterward; all payload bytes were already protected.
        guard fchmod(stage, 0o500) == 0, fsync(stage) == 0,
              fsync(handles.objects) == 0, fsync(handles.staging) == 0 else {
            throw CentralPackageStoreError.ioFailure
        }
        // Recheck the public object before returning a receipt. A cancelled caller may
        // leave an unreferenced complete object, never a partially published tree.
        return summary(try await read(tree.digest))
    }

    private func validate(_ digest: ContentDigest) throws {
        do { try WorkspaceDomainValidation.requireDigest(digest.value, field: "content digest") }
        catch { throw CentralPackageStoreError.invalidDigest }
    }

    private func summary(_ tree: CapturedPackageTree) -> StoredPackageContent {
        .init(digest: tree.digest, entryCount: tree.entries.count, totalFileBytes: tree.totalFileBytes)
    }
}

private struct ContentStoreIdentity {
    let device: dev_t
    let inode: ino_t

    init(descriptor: Int32) throws {
        var value = stat()
        guard fstat(descriptor, &value) == 0, value.st_mode & S_IFMT == S_IFDIR else {
            throw CentralPackageStoreError.invalidRoot
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

/// Owns descriptors exclusively; no mutable state crosses actors. All operations use
/// openat-relative children, so replacing a pathname cannot redirect writes elsewhere.
private final class ContentStoreHandles: @unchecked Sendable {
    let root: Int32
    let objects: Int32
    let staging: Int32
    let rootPath: String
    private let rootIdentity: ContentStoreIdentity
    private let objectsIdentity: ContentStoreIdentity
    private let stagingIdentity: ContentStoreIdentity
    private let marker: Data

    init(directory: URL, marker: Data, initializeIfEmpty: Bool) throws {
        guard directory.isFileURL, directory.path.hasPrefix("/"),
              !directory.path.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else {
            throw CentralPackageStoreError.invalidRoot
        }
        var original = stat()
        guard lstat(directory.path, &original) == 0, original.st_mode & S_IFMT == S_IFDIR,
              let resolved = directory.path.withCString({ realpath($0, nil) }) else {
            throw CentralPackageStoreError.invalidRoot
        }
        defer { free(resolved) }
        let path = String(cString: resolved)
        let root = open(path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard root >= 0 else { throw CentralPackageStoreError.invalidRoot }
        var keepRoot = false
        defer { if !keepRoot { close(root) } }
        var opened = stat()
        guard fstat(root, &opened) == 0, opened.st_dev == original.st_dev, opened.st_ino == original.st_ino,
              opened.st_uid == geteuid(), opened.st_mode & 0o077 == 0 else {
            throw CentralPackageStoreError.invalidRoot
        }
        // Serialize cooperating initializers without blocking the calling thread. A
        // contending caller can retry after the other initialization has completed.
        guard flock(root, LOCK_EX | LOCK_NB) == 0 else {
            throw errno == EWOULDBLOCK ? CentralPackageStoreError.busy : .ioFailure
        }
        defer { _ = flock(root, LOCK_UN) }
        let names = try ContentStoreFS.names(root)
        guard initializeIfEmpty || Set(names) == ["format", "objects", "staging"] else {
            throw CentralPackageStoreError.invalidRoot
        }
        if names.isEmpty {
            try ContentStoreFS.writeFile(parent: root, name: "format", bytes: marker, mode: 0o400)
            guard fsync(root) == 0 else { throw CentralPackageStoreError.ioFailure }
        }
        guard Set(try ContentStoreFS.names(root)).isSubset(of: ["format", "objects", "staging"]),
              try ContentStoreFS.readSmallFile(parent: root, name: "format", limit: 128) == marker else {
            throw CentralPackageStoreError.invalidRoot
        }
        let objects = try ContentStoreFS.ensurePrivateDirectory(parent: root, name: "objects", create: initializeIfEmpty)
        var keepObjects = false
        defer { if !keepObjects { close(objects) } }
        let staging = try ContentStoreFS.ensurePrivateDirectory(parent: root, name: "staging", create: initializeIfEmpty)
        var keepStaging = false
        defer { if !keepStaging { close(staging) } }
        let rootIdentity = try ContentStoreIdentity(descriptor: root)
        let objectsIdentity = try ContentStoreIdentity(descriptor: objects)
        let stagingIdentity = try ContentStoreIdentity(descriptor: staging)
        guard fsync(root) == 0 else { throw CentralPackageStoreError.ioFailure }
        self.rootIdentity = rootIdentity
        self.objectsIdentity = objectsIdentity
        self.stagingIdentity = stagingIdentity
        self.marker = marker
        self.rootPath = path
        self.root = root
        self.objects = objects
        self.staging = staging
        keepRoot = true
        keepObjects = true
        keepStaging = true
    }

    deinit { close(staging); close(objects); close(root) }

    func validateBindings() throws {
        guard rootIdentity.matches(parent: AT_FDCWD, name: rootPath),
              objectsIdentity.matches(parent: root, name: "objects"),
              stagingIdentity.matches(parent: root, name: "staging"),
              ContentStoreFS.isPrivateDirectory(root),
              ContentStoreFS.isPrivateDirectory(objects),
              ContentStoreFS.isPrivateDirectory(staging) else {
            throw CentralPackageStoreError.changedStore
        }
        do {
            guard try ContentStoreFS.readSmallFile(parent: root, name: "format", limit: 128) == marker else {
                throw CentralPackageStoreError.changedStore
            }
        } catch {
            throw CentralPackageStoreError.changedStore
        }
    }
}

private enum ContentStoreFS {
    static func isPrivateDirectory(_ descriptor: Int32) -> Bool {
        var value = stat()
        return fstat(descriptor, &value) == 0 && value.st_mode & S_IFMT == S_IFDIR
            && value.st_uid == geteuid() && value.st_mode & 0o077 == 0
    }

    static func names(_ descriptor: Int32) throws -> [String] {
        // Opening '.' gets an independent directory stream offset; dup alone shares it.
        let copy = openat(descriptor, ".", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard copy >= 0 else { throw CentralPackageStoreError.ioFailure }
        guard let stream = fdopendir(copy) else { close(copy); throw CentralPackageStoreError.ioFailure }
        defer { closedir(stream) }
        var names: [String] = []
        while true {
            errno = 0
            guard let entry = readdir(stream) else {
                guard errno == 0 else { throw CentralPackageStoreError.ioFailure }
                break
            }
            let capacity = Int(entry.pointee.d_namlen) + 1
            let name = withUnsafePointer(to: &entry.pointee.d_name) {
                $0.withMemoryRebound(to: CChar.self, capacity: capacity) { String(validatingCString: $0) }
            }
            guard let name else { throw CentralPackageStoreError.corruptContent }
            if name == "." || name == ".." { continue }
            guard names.count < 10_002 else { throw CentralPackageStoreError.corruptContent }
            names.append(name)
        }
        return names.sorted()
    }

    static func createDirectory(parent: Int32, name: String) throws -> Int32 {
        guard mkdirat(parent, name, 0o700) == 0 else { throw CentralPackageStoreError.ioFailure }
        let descriptor = openat(parent, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { throw CentralPackageStoreError.ioFailure }
        return descriptor
    }

    static func ensurePrivateDirectory(parent: Int32, name: String, create: Bool = true) throws -> Int32 {
        if create, mkdirat(parent, name, 0o700) != 0, errno != EEXIST { throw CentralPackageStoreError.invalidRoot }
        let descriptor = openat(parent, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { throw CentralPackageStoreError.invalidRoot }
        guard isPrivateDirectory(descriptor) else {
            close(descriptor)
            throw CentralPackageStoreError.invalidRoot
        }
        return descriptor
    }

    static func openDirectory(_ base: Int32, components: [String]) throws -> Int32 {
        var current = openat(base, ".", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard current >= 0 else { throw CentralPackageStoreError.ioFailure }
        for component in components {
            let next = openat(current, component, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            close(current)
            guard next >= 0 else { throw CentralPackageStoreError.ioFailure }
            current = next
        }
        return current
    }

    static func writeFile(parent: Int32, name: String, bytes: Data, mode: mode_t) throws {
        let descriptor = openat(parent, name, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { throw CentralPackageStoreError.ioFailure }
        defer { close(descriptor) }
        try bytes.withUnsafeBytes { buffer in
            if buffer.isEmpty { return }
            guard let baseAddress = buffer.baseAddress else { throw CentralPackageStoreError.ioFailure }
            var offset = 0
            while offset < buffer.count {
                try Task.checkCancellation()
                let written = write(descriptor, baseAddress.advanced(by: offset), buffer.count - offset)
                if written < 0, errno == EINTR { continue }
                guard written > 0 else { throw CentralPackageStoreError.ioFailure }
                offset += written
            }
        }
        guard fchmod(descriptor, mode) == 0, fsync(descriptor) == 0 else { throw CentralPackageStoreError.ioFailure }
    }

    static func readSmallFile(parent: Int32, name: String, limit: Int) throws -> Data {
        let descriptor = openat(parent, name, O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { throw CentralPackageStoreError.invalidRoot }
        defer { close(descriptor) }
        var value = stat()
        guard fstat(descriptor, &value) == 0, value.st_mode & S_IFMT == S_IFREG,
              value.st_uid == geteuid(), value.st_mode & 0o077 == 0,
              value.st_size >= 0, value.st_size <= limit else { throw CentralPackageStoreError.invalidRoot }
        var bytes = [UInt8](repeating: 0, count: limit + 1)
        var count: Int
        repeat { count = read(descriptor, &bytes, bytes.count) } while count < 0 && errno == EINTR
        guard count >= 0, count <= limit, count == value.st_size else { throw CentralPackageStoreError.invalidRoot }
        return Data(bytes.prefix(count))
    }

    static func removeContents(_ descriptor: Int32) throws {
        guard fchmod(descriptor, 0o700) == 0 else { throw CentralPackageStoreError.ioFailure }
        for name in try names(descriptor) {
            var info = stat()
            guard fstatat(descriptor, name, &info, AT_SYMLINK_NOFOLLOW) == 0 else { throw CentralPackageStoreError.ioFailure }
            if info.st_mode & S_IFMT == S_IFDIR {
                let child = openat(descriptor, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                guard child >= 0 else { throw CentralPackageStoreError.ioFailure }
                defer { close(child) }
                let identity = try ContentStoreIdentity(descriptor: child)
                try removeContents(child)
                guard identity.matches(parent: descriptor, name: name), unlinkat(descriptor, name, AT_REMOVEDIR) == 0 else {
                    throw CentralPackageStoreError.ioFailure
                }
            } else {
                guard unlinkat(descriptor, name, 0) == 0 else { throw CentralPackageStoreError.ioFailure }
            }
        }
    }
}
