import Darwin
import Foundation

/// Captures package bytes without following links or executing package content.
public struct PackageTreeCapture: Sendable {
    public init() {}

    public func capture(
        directory: URL,
        limits: PackageTreeLimits = .default
    ) async throws -> CapturedPackageTree {
        try await capture(directory: directory, limits: limits, validationHook: nil)
    }

    /// Internal deterministic seam for mutation-race tests. Production callers use the
    /// public overload, which never runs caller code during capture.
    func capture(
        directory: URL,
        limits: PackageTreeLimits = .default,
        validationHook: (@Sendable () -> Void)?
    ) async throws -> CapturedPackageTree {
        guard directory.isFileURL else { throw PackageTreeError.invalidPath }
        let worker = Task.detached(priority: nil) {
            try Self.captureSynchronously(
                directory: directory,
                limits: limits,
                validationHook: validationHook
            )
        }
        let result = try await withTaskCancellationHandler {
            try await worker.value
        } onCancel: {
            worker.cancel()
        }
        try Task.checkCancellation()
        return result
    }

    /// Captures from an already validated directory capability. The duplicate
    /// is owned by this call; the caller's descriptor is never closed.
    func capture(
        directoryDescriptor: Int32,
        limits: PackageTreeLimits = .default
    ) async throws -> CapturedPackageTree {
        let ownedFD = dup(directoryDescriptor)
        guard ownedFD >= 0 else { throw PackageTreeError.ioFailure }
        guard fcntl(ownedFD, F_SETFD, FD_CLOEXEC) == 0 else {
            Darwin.close(ownedFD)
            throw PackageTreeError.ioFailure
        }
        var status = stat()
        guard fstat(ownedFD, &status) == 0 else {
            Darwin.close(ownedFD)
            throw PackageTreeError.ioFailure
        }
        guard Self.fileType(status) == S_IFDIR else {
            Darwin.close(ownedFD)
            throw PackageTreeError.unsupportedItem
        }
        let expected = FileMetadata(status)
        let worker = Task.detached(priority: nil) {
            try Self.captureOpenedRoot(
                ownedFD,
                expected: expected,
                limits: limits,
                validationHook: nil
            )
        }
        let result = try await withTaskCancellationHandler {
            try await worker.value
        } onCancel: {
            worker.cancel()
        }
        try Task.checkCancellation()
        return result
    }

    private static func captureSynchronously(
        directory: URL,
        limits: PackageTreeLimits,
        validationHook: (@Sendable () -> Void)?
    ) throws -> CapturedPackageTree {
        try Task.checkCancellation()
        guard directory.isFileURL else { throw PackageTreeError.invalidPath }
        guard limits.maxEntries >= 0, limits.maxFileBytes >= 0, limits.maxTotalBytes >= 0,
            limits.maxDepth >= 0, limits.maxPathBytes >= 0, limits.maxPathBytes < Int.max
        else { throw PackageTreeError.limitExceeded }
        let rootPath = directory.path(percentEncoded: false)
        guard rootPath.hasPrefix("/"),
              !rootPath.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else {
            throw PackageTreeError.invalidPath
        }
        var pathStatus = stat()
        guard rootPath.withCString({ lstat($0, &pathStatus) }) == 0 else {
            throw PackageTreeError.ioFailure
        }
        guard fileType(pathStatus) != S_IFLNK else {
            throw PackageTreeError.unsafeSymbolicLink
        }
        guard fileType(pathStatus) == S_IFDIR else {
            throw PackageTreeError.unsupportedItem
        }

        let rootFD = rootPath.withCString {
            Darwin.open($0, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        }
        guard rootFD >= 0 else {
            throw errno == ELOOP ? PackageTreeError.unsafeSymbolicLink : PackageTreeError.ioFailure
        }
        let expected = FileMetadata(pathStatus)
        let result = try captureOpenedRoot(
            rootFD,
            expected: expected,
            limits: limits,
            validationHook: validationHook
        )
        var finalPath = stat()
        let finalStatus = rootPath.withCString { lstat($0, &finalPath) }
        guard finalStatus == 0, expected.matches(finalPath, includeSize: false) else {
            throw PackageTreeError.changedDuringCapture
        }
        try Task.checkCancellation()
        return result
    }

    private static func captureOpenedRoot(
        _ rootFD: Int32,
        expected: FileMetadata,
        limits: PackageTreeLimits,
        validationHook: (@Sendable () -> Void)?
    ) throws -> CapturedPackageTree {
        defer { Darwin.close(rootFD) }
        try Task.checkCancellation()
        try limits.validate()
        var openedRoot = stat()
        guard fstat(rootFD, &openedRoot) == 0 else { throw PackageTreeError.ioFailure }
        guard expected.matches(openedRoot, includeSize: false) else {
            throw PackageTreeError.changedDuringCapture
        }

        var state = CaptureState(limits: limits)
        try walk(
            directoryFD: rootFD,
            relativeParent: nil,
            rawParentComponents: [],
            depth: 0,
            isRoot: true,
            state: &state
        )
        validationHook?()
        try Task.checkCancellation()
        try verifyCapturedEntries(rootFD: rootFD, observations: state.observations)
        var finalRoot = stat()
        guard fstat(rootFD, &finalRoot) == 0 else { throw PackageTreeError.ioFailure }
        guard sameIdentityAndMetadata(openedRoot, finalRoot, includeSize: false) else {
            throw PackageTreeError.changedDuringCapture
        }
        try Task.checkCancellation()
        return try CapturedPackageTree(
            entries: state.entries,
            limits: limits,
            excludedRootGitMetadata: state.excludedRootGitMetadata
        )
    }

    private static func walk(
        directoryFD: Int32,
        relativeParent: String?,
        rawParentComponents: [String],
        depth: Int,
        isRoot: Bool,
        state: inout CaptureState
    ) throws {
        try Task.checkCancellation()
        var initialDirectory = stat()
        guard fstat(directoryFD, &initialDirectory) == 0 else { throw PackageTreeError.ioFailure }
        let initialNames = try directoryNames(
            directoryFD,
            maximumEntries: state.limits.maxEntries,
            excludedName: isRoot ? ".git" : nil
        )

        for rawName in initialNames {
            try Task.checkCancellation()
            if isRoot, rawName == ".git" {
                state.excludedRootGitMetadata = true
                continue
            }
            let canonicalName = rawName.precomposedStringWithCanonicalMapping
            let relativePath = relativeParent.map { "\($0)/\(canonicalName)" } ?? canonicalName
            let entryDepth = depth + 1
            guard entryDepth <= state.limits.maxDepth,
                relativePath.utf8.count <= state.limits.maxPathBytes
            else { throw PackageTreeError.limitExceeded }
            try state.reserveEntry()

            var before = stat()
            let status = rawName.withCString {
                fstatat(directoryFD, $0, &before, AT_SYMLINK_NOFOLLOW)
            }
            guard status == 0 else {
                throw errno == ENOENT ? PackageTreeError.changedDuringCapture : PackageTreeError.ioFailure
            }
            switch fileType(before) {
            case S_IFDIR:
                let childFD = rawName.withCString {
                    openat(directoryFD, $0, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                }
                guard childFD >= 0 else {
                    throw errno == ELOOP || errno == ENOTDIR
                        ? PackageTreeError.changedDuringCapture : PackageTreeError.ioFailure
                }
                do {
                    var opened = stat()
                    guard fstat(childFD, &opened) == 0 else { throw PackageTreeError.ioFailure }
                    guard sameIdentityAndMetadata(before, opened, includeSize: false) else {
                        throw PackageTreeError.changedDuringCapture
                    }
                    state.entries.append(.init(relativePath: relativePath, kind: .directory))
                    try walk(
                        directoryFD: childFD,
                        relativeParent: relativePath,
                        rawParentComponents: rawParentComponents + [rawName],
                        depth: entryDepth,
                        isRoot: false,
                        state: &state
                    )
                    var after = stat()
                    guard fstat(childFD, &after) == 0,
                        sameIdentityAndMetadata(opened, after, includeSize: false)
                    else { throw PackageTreeError.changedDuringCapture }
                    state.observations.append(.init(
                        rawComponents: rawParentComponents + [rawName],
                        metadata: FileMetadata(after),
                        includeSize: false
                    ))
                } catch {
                    Darwin.close(childFD)
                    throw error
                }
                Darwin.close(childFD)

            case S_IFREG:
                let captured = try readFile(
                    parentFD: directoryFD,
                    rawName: rawName,
                    before: before,
                    state: &state
                )
                state.entries.append(.init(
                    relativePath: relativePath,
                    kind: .file(bytes: captured.bytes, executable: captured.executable)
                ))
                state.observations.append(.init(
                    rawComponents: rawParentComponents + [rawName],
                    metadata: captured.metadata,
                    includeSize: true
                ))

            case S_IFLNK:
                let captured = try readSymbolicLink(
                    parentFD: directoryFD,
                    rawName: rawName,
                    before: before,
                    limits: state.limits
                )
                state.entries.append(.init(
                    relativePath: relativePath,
                    kind: .symbolicLink(target: captured.target.precomposedStringWithCanonicalMapping)
                ))
                state.observations.append(.init(
                    rawComponents: rawParentComponents + [rawName],
                    metadata: captured.metadata,
                    includeSize: true
                ))

            default:
                throw PackageTreeError.unsupportedItem
            }
        }

        try Task.checkCancellation()
        let finalNames = try directoryNames(
            directoryFD,
            maximumEntries: state.limits.maxEntries,
            excludedName: isRoot ? ".git" : nil
        )
        guard initialNames == finalNames else { throw PackageTreeError.changedDuringCapture }
        var finalDirectory = stat()
        guard fstat(directoryFD, &finalDirectory) == 0,
            sameIdentityAndMetadata(initialDirectory, finalDirectory, includeSize: false)
        else { throw PackageTreeError.changedDuringCapture }
    }

    private static func readFile(
        parentFD: Int32,
        rawName: String,
        before: stat,
        state: inout CaptureState
    ) throws -> (bytes: Data, executable: Bool, metadata: FileMetadata) {
        let fileFD = rawName.withCString {
            openat(parentFD, $0, O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC)
        }
        guard fileFD >= 0 else {
            throw errno == ELOOP || errno == ENOENT
                ? PackageTreeError.changedDuringCapture : PackageTreeError.ioFailure
        }
        defer { Darwin.close(fileFD) }
        var opened = stat()
        guard fstat(fileFD, &opened) == 0 else { throw PackageTreeError.ioFailure }
        guard fileType(opened) == S_IFREG,
            sameIdentityAndMetadata(before, opened, includeSize: true)
        else { throw PackageTreeError.changedDuringCapture }
        guard opened.st_size >= 0, UInt64(opened.st_size) <= UInt64(Int.max) else {
            throw PackageTreeError.limitExceeded
        }
        let expectedSize = Int(opened.st_size)
        guard expectedSize <= state.limits.maxFileBytes,
            expectedSize <= state.limits.maxTotalBytes,
            state.totalFileBytes <= state.limits.maxTotalBytes - expectedSize
        else { throw PackageTreeError.limitExceeded }

        var data = Data()
        data.reserveCapacity(expectedSize)
        var buffer = [UInt8](repeating: 0, count: 64 * 1_024)
        while true {
            try Task.checkCancellation()
            let count = buffer.withUnsafeMutableBytes { bytes in
                Darwin.read(fileFD, bytes.baseAddress, bytes.count)
            }
            if count == 0 { break }
            if count < 0 {
                if errno == EINTR { continue }
                throw PackageTreeError.ioFailure
            }
            data.append(contentsOf: buffer.prefix(Int(count)))
            guard data.count <= state.limits.maxFileBytes, data.count <= state.limits.maxTotalBytes,
                state.totalFileBytes <= state.limits.maxTotalBytes - data.count
            else { throw PackageTreeError.limitExceeded }
        }
        var after = stat()
        guard fstat(fileFD, &after) == 0,
            sameIdentityAndMetadata(opened, after, includeSize: true),
            data.count == Int(after.st_size)
        else { throw PackageTreeError.changedDuringCapture }
        state.totalFileBytes += data.count
        let executableMask = mode_t(S_IXUSR | S_IXGRP | S_IXOTH)
        return (data, (after.st_mode & executableMask) != 0, FileMetadata(after))
    }

    private static func readSymbolicLink(
        parentFD: Int32,
        rawName: String,
        before: stat,
        limits: PackageTreeLimits
    ) throws -> (target: String, metadata: FileMetadata) {
        var buffer = [CChar](repeating: 0, count: limits.maxPathBytes + 1)
        let count = rawName.withCString { name in
            buffer.withUnsafeMutableBufferPointer { pointer in
                readlinkat(parentFD, name, pointer.baseAddress, pointer.count)
            }
        }
        guard count >= 0 else {
            throw errno == ENOENT ? PackageTreeError.changedDuringCapture : PackageTreeError.ioFailure
        }
        guard count <= limits.maxPathBytes else { throw PackageTreeError.limitExceeded }
        var after = stat()
        let status = rawName.withCString {
            fstatat(parentFD, $0, &after, AT_SYMLINK_NOFOLLOW)
        }
        guard status == 0, sameIdentityAndMetadata(before, after, includeSize: true) else {
            throw PackageTreeError.changedDuringCapture
        }
        let bytes = buffer.prefix(Int(count)).map { UInt8(bitPattern: $0) }
        guard let target = String(bytes: bytes, encoding: .utf8), !target.isEmpty else {
            throw PackageTreeError.unsafeSymbolicLink
        }
        return (target, FileMetadata(after))
    }

    private static func directoryNames(
        _ directoryFD: Int32,
        maximumEntries: Int,
        excludedName: String?
    ) throws -> [String] {
        let enumerationFD = openat(directoryFD, ".", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard enumerationFD >= 0 else { throw PackageTreeError.ioFailure }
        guard let stream = fdopendir(enumerationFD) else {
            Darwin.close(enumerationFD)
            throw PackageTreeError.ioFailure
        }
        defer { closedir(stream) }
        var result: [String] = []
        var countedEntries = 0
        errno = 0
        while let entry = readdir(stream) {
            let name: String? = withUnsafePointer(to: &entry.pointee.d_name) { pointer in
                pointer.withMemoryRebound(to: CChar.self, capacity: Int(MAXNAMLEN) + 1) {
                    String(validatingCString: $0)
                }
            }
            guard let name else { throw PackageTreeError.unsupportedItem }
            if name != ".", name != ".." {
                guard name == excludedName || countedEntries < maximumEntries else {
                    throw PackageTreeError.limitExceeded
                }
                result.append(name)
                if name != excludedName { countedEntries += 1 }
            }
            errno = 0
        }
        guard errno == 0 else { throw PackageTreeError.ioFailure }
        return result.sorted { Array($0.utf8).lexicographicallyPrecedes(Array($1.utf8)) }
    }

    /// Rechecks every captured directory entry through the still-bound root descriptor.
    /// This catches ordinary edits after an entry's local read. It is deliberately a
    /// bounded validation pass, not a claim of filesystem snapshot isolation.
    private static func verifyCapturedEntries(
        rootFD: Int32,
        observations: [CapturedEntryObservation]
    ) throws {
        for observation in observations {
            try Task.checkCancellation()
            guard let rawName = observation.rawComponents.last else {
                throw PackageTreeError.changedDuringCapture
            }
            let parentFD = try openRawDirectory(
                rootFD,
                components: Array(observation.rawComponents.dropLast())
            )
            defer { Darwin.close(parentFD) }
            var current = stat()
            let status = rawName.withCString {
                fstatat(parentFD, $0, &current, AT_SYMLINK_NOFOLLOW)
            }
            guard status == 0, observation.metadata.matches(current, includeSize: observation.includeSize) else {
                throw PackageTreeError.changedDuringCapture
            }
        }
    }

    private static func openRawDirectory(_ rootFD: Int32, components: [String]) throws -> Int32 {
        var current = openat(rootFD, ".", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard current >= 0 else { throw PackageTreeError.ioFailure }
        for component in components {
            let next = component.withCString {
                openat(current, $0, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            }
            Darwin.close(current)
            guard next >= 0 else { throw PackageTreeError.changedDuringCapture }
            current = next
        }
        return current
    }

    private static func fileType(_ value: stat) -> mode_t {
        value.st_mode & mode_t(S_IFMT)
    }

    private static func sameIdentityAndMetadata(_ lhs: stat, _ rhs: stat, includeSize: Bool) -> Bool {
        lhs.st_dev == rhs.st_dev
            && lhs.st_ino == rhs.st_ino
            && fileType(lhs) == fileType(rhs)
            && (!includeSize || lhs.st_size == rhs.st_size)
            && lhs.st_mtimespec.tv_sec == rhs.st_mtimespec.tv_sec
            && lhs.st_mtimespec.tv_nsec == rhs.st_mtimespec.tv_nsec
            && lhs.st_ctimespec.tv_sec == rhs.st_ctimespec.tv_sec
            && lhs.st_ctimespec.tv_nsec == rhs.st_ctimespec.tv_nsec
            && (lhs.st_mode & mode_t(0o7777)) == (rhs.st_mode & mode_t(0o7777))
    }

    private struct FileMetadata: Sendable {
        var device: UInt64
        var inode: UInt64
        var size: Int64
        var mode: UInt64
        var modifiedSeconds: Int64
        var modifiedNanoseconds: Int64
        var changedSeconds: Int64
        var changedNanoseconds: Int64

        init(_ value: stat) {
            device = UInt64(bitPattern: Int64(value.st_dev))
            inode = UInt64(value.st_ino)
            size = Int64(value.st_size)
            mode = UInt64(value.st_mode)
            modifiedSeconds = Int64(value.st_mtimespec.tv_sec)
            modifiedNanoseconds = Int64(value.st_mtimespec.tv_nsec)
            changedSeconds = Int64(value.st_ctimespec.tv_sec)
            changedNanoseconds = Int64(value.st_ctimespec.tv_nsec)
        }

        func matches(_ value: stat, includeSize: Bool) -> Bool {
            let other = FileMetadata(value)
            return device == other.device && inode == other.inode
                && (mode & UInt64(S_IFMT)) == (other.mode & UInt64(S_IFMT))
                && (!includeSize || size == other.size)
                && modifiedSeconds == other.modifiedSeconds
                && modifiedNanoseconds == other.modifiedNanoseconds
                && changedSeconds == other.changedSeconds
                && changedNanoseconds == other.changedNanoseconds
                && (mode & 0o7777) == (other.mode & 0o7777)
        }
    }

    private struct CaptureState {
        var entries: [PackageTreeEntry] = []
        var observations: [CapturedEntryObservation] = []
        var totalFileBytes = 0
        var excludedRootGitMetadata = false
        let limits: PackageTreeLimits

        mutating func reserveEntry() throws {
            guard entries.count < limits.maxEntries else { throw PackageTreeError.limitExceeded }
        }
    }

    private struct CapturedEntryObservation {
        let rawComponents: [String]
        let metadata: FileMetadata
        let includeSize: Bool
    }
}
