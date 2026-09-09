import CryptoKit
import Foundation

public struct PackageTreeLimits: Hashable, Sendable {
    public static let `default` = PackageTreeLimits()
    public let maxEntries: Int
    public let maxFileBytes: Int
    public let maxTotalBytes: Int
    public let maxDepth: Int
    public let maxPathBytes: Int

    public init(maxEntries: Int = 10_000, maxFileBytes: Int = 32 * 1_024 * 1_024,
                maxTotalBytes: Int = 128 * 1_024 * 1_024, maxDepth: Int = 64, maxPathBytes: Int = 4_096) {
        self.maxEntries = maxEntries
        self.maxFileBytes = maxFileBytes
        self.maxTotalBytes = maxTotalBytes
        self.maxDepth = maxDepth
        self.maxPathBytes = maxPathBytes
    }

    func validate() throws {
        guard maxEntries >= 0, maxFileBytes >= 0, maxTotalBytes >= 0,
              maxDepth > 0, maxDepth <= 256, maxPathBytes > 0, maxPathBytes <= 16_384 else {
            throw PackageTreeError.limitExceeded
        }
    }
}

public enum PackageTreeEntryKind: Hashable, Sendable {
    case directory
    case file(bytes: Data, executable: Bool)
    case symbolicLink(target: String)
}

public struct PackageTreeEntry: Hashable, Sendable {
    public let relativePath: String
    public let kind: PackageTreeEntryKind

    public init(relativePath: String, kind: PackageTreeEntryKind) {
        self.relativePath = relativePath
        self.kind = kind
    }
}

/// Sanitized failures: no raw source paths, content, link values, or OS error strings.
public enum PackageTreeError: Error, Equatable, Sendable {
    case invalidPath, caseCollision, invalidStructure, unsupportedItem, unsafeSymbolicLink
    case limitExceeded, changedDuringCapture, ioFailure, invalidDigest
}

/// Immutable, validated complete package bytes, distinct from a source/assignment authority.
/// Not Codable: workspace metadata contains the digest, not embedded executable content.
public struct CapturedPackageTree: Hashable, Sendable {
    public let entries: [PackageTreeEntry]
    public let digest: ContentDigest
    public let totalFileBytes: Int
    /// Local administrative metadata omitted during capture; never part of portable content.
    public let excludedRootGitMetadata: Bool

    public init(entries: [PackageTreeEntry], limits: PackageTreeLimits = .default,
                excludedRootGitMetadata: Bool = false) throws {
        try limits.validate()
        guard entries.count <= limits.maxEntries else { throw PackageTreeError.limitExceeded }
        var canonical: [PackageTreeEntry] = []
        var identities = Set<String>()
        var total = 0
        for entry in entries {
            try Task.checkCancellation()
            let path = entry.relativePath.precomposedStringWithCanonicalMapping
            try Self.validatePath(path, limits: limits)
            let key = path.folding(options: .caseInsensitive, locale: Locale(identifier: "en_US_POSIX"))
            guard identities.insert(key).inserted else { throw PackageTreeError.caseCollision }
            let kind: PackageTreeEntryKind
            switch entry.kind {
            case .directory:
                kind = .directory
            case .file(let bytes, let executable):
                let (sum, overflow) = total.addingReportingOverflow(bytes.count)
                guard bytes.count <= limits.maxFileBytes, !overflow, sum <= limits.maxTotalBytes else {
                    throw PackageTreeError.limitExceeded
                }
                total = sum
                kind = .file(bytes: bytes, executable: executable)
            case .symbolicLink(let target):
                let target = target.precomposedStringWithCanonicalMapping
                guard !target.isEmpty, !target.hasPrefix("/"), !target.contains("\\"),
                      !target.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains),
                      target.utf8.count <= limits.maxPathBytes,
                      !target.split(separator: "/").contains(where: { $0.lowercased() == ".git" }) else {
                    throw PackageTreeError.unsafeSymbolicLink
                }
                kind = .symbolicLink(target: target)
            }
            canonical.append(.init(relativePath: path, kind: kind))
        }
        canonical.sort { $0.relativePath.utf8.lexicographicallyPrecedes($1.relativePath.utf8) }
        var index: [String: PackageTreeEntryKind] = [:]
        for entry in canonical { index[entry.relativePath] = entry.kind }
        for entry in canonical {
            let components = entry.relativePath.split(separator: "/").map(String.init)
            if components.count > 1 {
                let parent = components.dropLast().joined(separator: "/")
                guard case .directory? = index[parent] else { throw PackageTreeError.invalidStructure }
            }
            if case .symbolicLink(let target) = entry.kind {
                try Self.validateLink(Array(components.dropLast()) + target.components(separatedBy: "/"), index: index)
            }
        }
        self.entries = canonical
        self.digest = Self.computeDigest(canonical)
        self.totalFileBytes = total
        self.excludedRootGitMetadata = excludedRootGitMetadata
    }

    /// Selects one complete directory and rebases its contents as a new tree.
    /// This is a byte projection only; it does not create a new artifact or
    /// confer independent content authority. Links are revalidated after the
    /// rebase, so a link that leaves the selected subtree rejects the export.
    public func subtree(at relativePath: String) throws -> CapturedPackageTree {
        try Task.checkCancellation()
        if relativePath == "." { return self }
        guard relativePath.utf8.elementsEqual(relativePath.precomposedStringWithCanonicalMapping.utf8) else {
            throw PackageTreeError.invalidPath
        }
        try Self.validatePath(relativePath, limits: .default)
        guard let selected = entries.first(where: { $0.relativePath == relativePath }) else {
            throw PackageTreeError.invalidStructure
        }
        guard case .directory = selected.kind else {
            throw PackageTreeError.unsupportedItem
        }

        let prefix = relativePath + "/"
        let projected = entries.compactMap { entry -> PackageTreeEntry? in
            guard entry.relativePath.hasPrefix(prefix) else { return nil }
            return PackageTreeEntry(
                relativePath: String(entry.relativePath.dropFirst(prefix.count)),
                kind: entry.kind
            )
        }
        // Root administrative metadata cannot occur below the captured root:
        // nested .git components are rejected by the original tree validator.
        return try CapturedPackageTree(entries: projected)
    }

    private static func validatePath(_ path: String, limits: PackageTreeLimits) throws {
        guard !path.isEmpty, !path.hasPrefix("/"), !path.contains("\\"),
              !path.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else {
            throw PackageTreeError.invalidPath
        }
        let parts = path.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." && $0.lowercased() != ".git" }) else {
            throw PackageTreeError.invalidPath
        }
        guard parts.count <= limits.maxDepth, path.utf8.count <= limits.maxPathBytes else {
            throw PackageTreeError.limitExceeded
        }
    }

    private static func validateLink(_ components: [String], index: [String: PackageTreeEntryKind]) throws {
        var pending = Array(components.reversed())
        var resolved: [String] = []
        var expansions = 0
        while let next = pending.popLast() {
            try Task.checkCancellation()
            if next.isEmpty || next == "." { continue }
            if next == ".." {
                guard !resolved.isEmpty else { throw PackageTreeError.unsafeSymbolicLink }
                resolved.removeLast()
                continue
            }
            let path = (resolved + [next]).joined(separator: "/")
            guard let kind = index[path] else { throw PackageTreeError.unsafeSymbolicLink }
            switch kind {
            case .directory:
                resolved.append(next)
            case .file:
                guard pending.isEmpty else { throw PackageTreeError.unsafeSymbolicLink }
                resolved.append(next)
            case .symbolicLink(let target):
                expansions += 1
                guard expansions <= 64 else { throw PackageTreeError.unsafeSymbolicLink }
                pending.append(contentsOf: target.components(separatedBy: "/").reversed())
            }
        }
    }

    /// Length framing and kind/execute bytes make the preimage unambiguous.
    /// Paths and link targets are NFC; payload files retain their exact bytes.
    private static func computeDigest(_ entries: [PackageTreeEntry]) -> ContentDigest {
        var hash = SHA256()
        hash.update(data: Data("agent-tooling.package-tree.v1\0".utf8))
        appendInteger(entries.count, to: &hash)
        for entry in entries {
            appendBytes(Data(entry.relativePath.utf8), to: &hash)
            switch entry.kind {
            case .directory:
                hash.update(data: Data([100]))
            case .file(let bytes, let executable):
                hash.update(data: Data([102, executable ? 1 : 0]))
                appendBytes(bytes, to: &hash)
            case .symbolicLink(let target):
                hash.update(data: Data([108]))
                appendBytes(Data(target.utf8), to: &hash)
            }
        }
        return .init(value: hash.finalize().map { String(format: "%02x", $0) }.joined())
    }

    private static func appendInteger(_ value: Int, to hash: inout SHA256) {
        var integer = UInt64(value).bigEndian
        withUnsafeBytes(of: &integer) { hash.update(bufferPointer: $0) }
    }

    private static func appendBytes(_ bytes: Data, to hash: inout SHA256) {
        appendInteger(bytes.count, to: &hash)
        hash.update(data: bytes)
    }
}
