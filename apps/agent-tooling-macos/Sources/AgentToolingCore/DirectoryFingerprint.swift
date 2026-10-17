import CryptoKit
import Foundation

enum DirectoryFingerprint {
    /// - Parameter afterReading: runs with a file's relative path once its
    ///   bytes are hashed and before it is checked again, so a test can change
    ///   the file in between. Nothing else passes it.
    static func sha256(
        of root: URL,
        fileManager: FileManager = .default,
        maximumItems: Int = 10_000,
        maximumBytes: Int = 384 * 1_024 * 1_024,
        afterReading: (String) throws -> Void = { _ in }
    ) throws -> String {
        let normalizedRoot = root.standardizedFileURL
        let rootValues = try normalizedRoot.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard rootValues.isDirectory == true, rootValues.isSymbolicLink != true,
            let enumerator = fileManager.enumerator(
                at: normalizedRoot,
                includingPropertiesForKeys: [
                    .contentModificationDateKey, .fileResourceIdentifierKey, .isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey,
                    .fileSizeKey,
                ]
            )
        else { throw DirectoryFingerprintError.unsafeItem(normalizedRoot.path(percentEncoded: false)) }
        // The walk names each item under the folder's real path, so a root
        // reached through a link above it, or spelled in another case, is
        // also matched as that real path. The root itself is still never a
        // link: that is refused above.
        let resolvedRoot = normalizedRoot.resolvingSymlinksInPath().standardizedFileURL

        let rootIsExecutable = try isExecutable(at: normalizedRoot, fileManager: fileManager)
        var entries: [Entry] = []
        var totalBytes = 0
        for case let url as URL in enumerator {
            guard entries.count < maximumItems else { throw DirectoryFingerprintError.tooLarge }
            let values = try url.resourceValues(forKeys: [
                .contentModificationDateKey, .fileResourceIdentifierKey, .isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey,
                .fileSizeKey,
            ])
            guard values.isSymbolicLink != true,
                values.isDirectory == true || values.isRegularFile == true,
                let relativePath = PathContainment.relativePath(ofEnumerated: url, under: normalizedRoot, resolvedRoot: resolvedRoot)
            else {
                throw DirectoryFingerprintError.unsafeItem(url.path(percentEncoded: false))
            }
            let size = values.isRegularFile == true ? values.fileSize ?? -1 : 0
            guard size >= 0 else { throw DirectoryFingerprintError.unsafeItem(url.path(percentEncoded: false)) }
            let (newTotal, overflow) = totalBytes.addingReportingOverflow(size)
            guard !overflow, newTotal <= maximumBytes else { throw DirectoryFingerprintError.tooLarge }
            totalBytes = newTotal
            entries.append(
                Entry(
                    url: url,
                    relativePath: relativePath,
                    isDirectory: values.isDirectory == true,
                    isExecutable: try isExecutable(at: url, fileManager: fileManager),
                    size: size,
                    resourceIdentifier: values.fileResourceIdentifier.map { String(describing: $0) },
                    modificationDate: values.contentModificationDate
                ))
        }

        var hasher = SHA256()
        hasher.update(data: Data((rootIsExecutable ? "RX\0" : "R-\0").utf8))
        for entry in entries.sorted(by: { $0.relativePath < $1.relativePath }) {
            hasher.update(data: Data((entry.isDirectory ? "D\0" : "F\0").utf8))
            hasher.update(data: Data(entry.relativePath.utf8))
            // Installation normalizes private read/write permissions while
            // preserving whether an item is executable. Bind that meaningful
            // mode bit so chmod +x/-x after review invalidates the fingerprint.
            hasher.update(data: Data((entry.isExecutable ? "\0X" : "\0-").utf8))
            hasher.update(data: Data("\0\(entry.size)\0".utf8))
            guard !entry.isDirectory else { continue }

            let handle = try FileHandle(forReadingFrom: entry.url)
            defer { try? handle.close() }
            while let chunk = try handle.read(upToCount: 64 * 1_024), !chunk.isEmpty {
                hasher.update(data: chunk)
            }
            try afterReading(entry.relativePath)
            // The walk fetched these values with the URL and the URL keeps
            // them, so asking it again would repeat them and the check could
            // never fail. Clear them, so the file is looked at as it is now.
            var current = entry.url
            current.removeAllCachedResourceValues()
            let finalValues = try current.resourceValues(forKeys: [
                .contentModificationDateKey, .fileResourceIdentifierKey, .isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey,
            ])
            guard finalValues.isRegularFile == true,
                finalValues.isSymbolicLink != true,
                finalValues.fileSize == entry.size,
                finalValues.contentModificationDate == entry.modificationDate,
                finalValues.fileResourceIdentifier.map({ String(describing: $0) }) == entry.resourceIdentifier,
                try isExecutable(at: entry.url, fileManager: fileManager) == entry.isExecutable
            else {
                throw DirectoryFingerprintError.changedWhileReading(entry.relativePath)
            }
        }
        return hasher.finalize().lowercaseHex
    }

    private static func isExecutable(at url: URL, fileManager: FileManager) throws -> Bool {
        let attributes = try fileManager.attributesOfItem(atPath: url.path(percentEncoded: false))
        guard let permissions = (attributes[.posixPermissions] as? NSNumber)?.intValue else {
            throw DirectoryFingerprintError.unsafeItem(url.path(percentEncoded: false))
        }
        return permissions & 0o111 != 0
    }

    private struct Entry {
        var url: URL
        var relativePath: String
        var isDirectory: Bool
        var isExecutable: Bool
        var size: Int
        var resourceIdentifier: String?
        var modificationDate: Date?
    }
}

enum DirectoryFingerprintError: LocalizedError {
    case unsafeItem(String)
    case changedWhileReading(String)
    case tooLarge

    var errorDescription: String? {
        switch self {
        case .unsafeItem(let path): "The directory contains a symbolic link or unsupported item at \(path)."
        case .changedWhileReading(let path): "\(path) changed while the directory was being reviewed."
        case .tooLarge: "The directory exceeds the supported fingerprint limits."
        }
    }
}
