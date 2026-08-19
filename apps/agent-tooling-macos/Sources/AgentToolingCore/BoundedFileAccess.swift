import Foundation

enum BoundedFileAccess {
    static let maximumTextBytes = 1 * 1_024 * 1_024
    static let maximumConfigurationBytes = 4 * 1_024 * 1_024
    static let maximumDirectoryEntries = 10_000
    static let maximumDirectoryDepth = 12

    static func readUTF8(
        at url: URL,
        maximumBytes: Int = maximumTextBytes,
        allowSymbolicLink: Bool = true
    ) throws -> String {
        let originalValues = try url.resourceValues(forKeys: [.isSymbolicLinkKey])
        guard allowSymbolicLink || originalValues.isSymbolicLink != true else {
            throw BoundedFileAccessError.symbolicLink(url.path(percentEncoded: false))
        }

        let resolvedURL = url.resolvingSymlinksInPath().standardizedFileURL
        let values = try resolvedURL.resourceValues(forKeys: [
            .contentModificationDateKey,
            .fileResourceIdentifierKey,
            .isRegularFileKey,
            .fileSizeKey,
        ])
        guard values.isRegularFile == true else {
            throw BoundedFileAccessError.notARegularFile(url.path(percentEncoded: false))
        }
        guard let fileSize = values.fileSize, fileSize >= 0, fileSize <= maximumBytes else {
            throw BoundedFileAccessError.fileTooLarge(url.lastPathComponent, maximumBytes)
        }

        let handle = try FileHandle(forReadingFrom: resolvedURL)
        defer { try? handle.close() }
        let data = try handle.read(upToCount: maximumBytes + 1) ?? Data()
        guard data.count <= maximumBytes, data.count == fileSize else {
            if data.count > maximumBytes {
                throw BoundedFileAccessError.fileTooLarge(url.lastPathComponent, maximumBytes)
            }
            throw BoundedFileAccessError.changedWhileReading(url.lastPathComponent)
        }
        guard let contents = String(data: data, encoding: .utf8) else {
            throw BoundedFileAccessError.invalidUTF8(url.lastPathComponent)
        }

        let resourceIdentifier = values.fileResourceIdentifier.map { String(describing: $0) }
        let finalValues = try resolvedURL.resourceValues(forKeys: [
            .contentModificationDateKey,
            .fileResourceIdentifierKey,
            .isRegularFileKey,
            .fileSizeKey,
        ])
        guard finalValues.isRegularFile == true,
            let finalSize = finalValues.fileSize,
            finalSize == fileSize,
            finalValues.contentModificationDate == values.contentModificationDate,
            finalValues.fileResourceIdentifier.map({ String(describing: $0) }) == resourceIdentifier
        else {
            throw BoundedFileAccessError.changedWhileReading(url.lastPathComponent)
        }
        return contents
    }

    static func descendantDirectories(
        under root: URL,
        fileManager: FileManager,
        maximumEntries: Int = maximumDirectoryEntries,
        maximumDepth: Int = maximumDirectoryDepth
    ) -> [URL] {
        let resolvedRoot = root.resolvingSymlinksInPath().standardizedFileURL
        guard isDirectory(resolvedRoot) else { return [] }

        var result: [URL] = []
        var queue: [(url: URL, depth: Int)] = [(resolvedRoot, 0)]
        var visited = Set([resolvedRoot.path(percentEncoded: false)])
        var inspectedEntries = 0

        while !queue.isEmpty, inspectedEntries < maximumEntries {
            let current = queue.removeFirst()
            guard current.depth < maximumDepth,
                let children = try? fileManager.contentsOfDirectory(
                    at: current.url,
                    includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
                    options: [.skipsHiddenFiles]
                )
            else { continue }

            for child in children.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
                inspectedEntries += 1
                guard inspectedEntries <= maximumEntries else { break }
                let directValues = try? child.resourceValues(forKeys: [.isSymbolicLinkKey])
                let resolvedChild = child.resolvingSymlinksInPath().standardizedFileURL
                guard isDirectory(resolvedChild) else { continue }
                result.append(resolvedChild)

                let isLink = directValues?.isSymbolicLink == true
                let linkedSkill = isLink && isRegularFile(resolvedChild.appending(path: "SKILL.md"))
                let canTraverseLink = !isLink || contains(resolvedChild, within: resolvedRoot)
                guard !linkedSkill,
                    canTraverseLink,
                    visited.insert(resolvedChild.path(percentEncoded: false)).inserted
                else { continue }
                queue.append((resolvedChild, current.depth + 1))
            }
        }
        return result
    }

    static func relativeRegularFiles(
        under root: URL,
        fileManager: FileManager,
        maximumEntries: Int = maximumDirectoryEntries,
        maximumDepth: Int = maximumDirectoryDepth
    ) -> [String] {
        let resolvedRoot = root.resolvingSymlinksInPath().standardizedFileURL
        guard isDirectory(resolvedRoot),
            let enumerator = fileManager.enumerator(
                at: resolvedRoot,
                includingPropertiesForKeys: [.isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey],
                options: [.skipsHiddenFiles, .skipsPackageDescendants]
            )
        else { return [] }

        var result: [String] = []
        var inspectedEntries = 0
        while let item = enumerator.nextObject() as? URL {
            inspectedEntries += 1
            guard inspectedEntries <= maximumEntries else { break }
            let values = try? item.resourceValues(forKeys: [.isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey])
            if values?.isSymbolicLink == true {
                if values?.isDirectory == true { enumerator.skipDescendants() }
                continue
            }
            guard values?.isRegularFile == true,
                let relative = relativePath(of: item, under: resolvedRoot),
                relative.split(separator: "/").count <= maximumDepth
            else { continue }
            result.append(relative)
        }
        return result.sorted()
    }

    static func isRegularFile(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
    }

    private static func isDirectory(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
    }

    private static func contains(_ child: URL, within root: URL) -> Bool {
        let rootPath = root.path(percentEncoded: false).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let childPath = child.path(percentEncoded: false).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return childPath == rootPath || childPath.hasPrefix(rootPath + "/")
    }

    private static func relativePath(of child: URL, under root: URL) -> String? {
        let rootPath = root.path(percentEncoded: false).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let childPath = child.standardizedFileURL.path(percentEncoded: false).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard childPath.hasPrefix(rootPath + "/") else { return nil }
        return String(childPath.dropFirst(rootPath.count + 1))
    }
}

enum BoundedFileAccessError: LocalizedError {
    case symbolicLink(String)
    case notARegularFile(String)
    case fileTooLarge(String, Int)
    case invalidUTF8(String)
    case changedWhileReading(String)

    var errorDescription: String? {
        switch self {
        case .symbolicLink(let path): "Refusing to read the symbolic link at \(path)."
        case .notARegularFile(let path): "The item at \(path) is not a regular file."
        case .fileTooLarge(let name, let maximumBytes): "\(name) exceeds the \(maximumBytes / 1_024) KB read limit."
        case .invalidUTF8(let name): "\(name) is not valid UTF-8 text."
        case .changedWhileReading(let name): "\(name) changed while it was being read."
        }
    }
}
