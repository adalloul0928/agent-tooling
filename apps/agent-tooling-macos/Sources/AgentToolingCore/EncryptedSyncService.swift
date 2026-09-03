import CryptoKit
import Foundation
import Security

/// An opt-in encrypted file sync format. The user chooses a folder backed by
/// iCloud Drive, Dropbox, a NAS, or any other sync provider; Agent Tooling
/// neither operates a cloud service nor uploads credentials on its own.
public final class EncryptedSyncService {
    public static let archiveFileName = "agent-tooling.encrypted.json"
    private static let maximumArchiveBytes = 512 * 1_024 * 1_024
    private static let maximumLibraryFiles = 10_000
    private static let maximumLibraryBytes = 384 * 1_024 * 1_024

    private let store: WorkspaceStore
    private let fileManager: FileManager
    private let keyProvider: any SyncKeyProviding

    public init(
        store: WorkspaceStore,
        fileManager: FileManager = .default,
        keyProvider: any SyncKeyProviding = KeychainSyncKeyProvider()
    ) {
        self.store = store
        self.fileManager = fileManager
        self.keyProvider = keyProvider
    }

    public func exportPlan(snapshot: WorkspaceSnapshot, destinationFolder: URL) throws -> OperationPlan {
        let portableSnapshot = snapshot.portableDesiredState()
        try WorkspaceSnapshotValidator.validate(portableSnapshot, mode: .portableImport)
        let destination = destinationFolder
            .standardizedFileURL
            .appending(path: Self.archiveFileName, directoryHint: .notDirectory)
        let directFolder = destinationFolder.standardizedFileURL
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: directFolder.path(percentEncoded: false), isDirectory: &isDirectory),
            isDirectory.boolValue,
            (try directFolder.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) != true,
            directFolder.resolvingSymlinksInPath().standardizedFileURL == directFolder
        else {
            throw EncryptedSyncError.missingDestination(destinationFolder.path(percentEncoded: false))
        }
        let key = try keyProvider.loadOrCreateKey()
        let payload = PortableSyncPayload(snapshot: portableSnapshot, library: try libraryFiles())
        let envelope = try seal(payload, key: key)
        let archiveData = try JSONEncoder.agentTooling().encode(envelope)
        guard archiveData.count <= Self.maximumArchiveBytes else { throw EncryptedSyncError.archiveTooLarge }
        let contents = String(decoding: archiveData, as: UTF8.self)
        return OperationPlan(
            kind: .exportEncryptedSync,
            title: "Write encrypted sync file",
            summary:
                "Encrypt portable desired state and the managed local package library into \(Self.archiveFileName). The selected folder may be synchronized by a provider you control; no Agent Tooling cloud account is involved.",
            steps: [
                OperationStep(
                    kind: .writeEncryptedArchive, title: "Write encrypted archive",
                    detail:
                        "AES-GCM encrypt portable desired state and library files. OAuth tokens, client caches, receipts, and observed machine state are excluded.",
                    destinationPath: destination.path(percentEncoded: false), contents: contents),
                OperationStep(
                    kind: .manual, title: "Verify your sync provider",
                    detail:
                        "Confirm the selected folder is available on the other device before importing. Keep the recovery key in a secure password manager.",
                    requiresUserAction: true),
            ],
            requiresConfirmation: true
        )
    }

    public func importPreview(at archiveURL: URL) throws -> EncryptedSyncImportPreview {
        let archive = archiveURL.standardizedFileURL
        guard archive.lastPathComponent == Self.archiveFileName else {
            throw EncryptedSyncError.invalidArchiveName(archive.lastPathComponent)
        }
        let values = try archive.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey, .isSymbolicLinkKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true else { throw EncryptedSyncError.invalidArchive }
        guard (values.fileSize ?? Self.maximumArchiveBytes + 1) <= Self.maximumArchiveBytes else {
            throw EncryptedSyncError.archiveTooLarge
        }
        let archiveData = try boundedArchiveData(at: archive)
        let envelope = try JSONDecoder.agentTooling().decode(EncryptedSyncEnvelope.self, from: archiveData)
        let payload = try open(envelope, key: keyProvider.loadKey())
        let libraryData = try JSONEncoder.agentTooling().encode(payload.library)
        let plan = OperationPlan(
            kind: .restoreEncryptedSync,
            title: "Restore encrypted Agent Tooling sync",
            summary:
                "Replace the managed local package library and portable desired state from a verified encrypted archive. The existing library is preserved as a rollback artifact. Local client observations and credentials are not replaced.",
            steps: [
                OperationStep(
                    kind: .replaceManagedLibrary, title: "Restore managed package library",
                    detail:
                        "Replace only the managed Agent Tooling library from the decrypted archive. Existing library content is moved to Receipts/Rollback first.",
                    destinationPath: store.libraryURL.path(percentEncoded: false), contents: String(decoding: libraryData, as: UTF8.self)),
                OperationStep(
                    kind: .scan, title: "Re-scan local clients",
                    detail: "Compare the restored desired state with the actual local Claude, Codex, and Gemini configurations.",
                    isReversible: false),
            ],
            requiresConfirmation: true
        )
        return EncryptedSyncImportPreview(
            archiveURL: archive, snapshot: payload.snapshot, libraryFileCount: payload.library.count, plan: plan)
    }

    public func recoveryKey() throws -> String {
        try keyProvider.loadOrCreateKey().base64EncodedString()
    }

    public func importRecoveryKey(_ value: String) throws {
        let normalized = try Self.normalizedRecoveryKey(value)
        guard let data = Data(base64Encoded: normalized) else { throw EncryptedSyncError.invalidRecoveryKey }
        try keyProvider.replaceKey(data)
    }

    public static func normalizedRecoveryKey(_ value: String) throws -> String {
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard normalized.count <= 128,
            let data = Data(base64Encoded: normalized),
            data.count == 32
        else { throw EncryptedSyncError.invalidRecoveryKey }
        return normalized
    }

    private func libraryFiles() throws -> [EncryptedLibraryFile] {
        let initialFingerprint = try DirectoryFingerprint.sha256(
            of: store.libraryURL,
            fileManager: fileManager,
            maximumItems: Self.maximumLibraryFiles,
            maximumBytes: Self.maximumLibraryBytes
        )
        let rootValues = try store.libraryURL.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard rootValues.isDirectory == true, rootValues.isSymbolicLink != true else {
            throw EncryptedSyncError.unsupportedLibraryItem(store.libraryURL.path(percentEncoded: false))
        }
        guard
            let enumerator = fileManager.enumerator(
                at: store.libraryURL,
                includingPropertiesForKeys: [.isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey]
            )
        else { return [] }
        var fileCount = 0
        var byteCount = 0
        let files = try enumerator.compactMap { item -> EncryptedLibraryFile? in
            guard let url = item as? URL else { return nil }
            let values = try url.resourceValues(forKeys: [
                .contentModificationDateKey,
                .fileResourceIdentifierKey,
                .fileSizeKey,
                .isRegularFileKey,
                .isDirectoryKey,
                .isSymbolicLinkKey,
            ])
            if values.isSymbolicLink == true { throw EncryptedSyncError.unsupportedLibraryItem(url.path(percentEncoded: false)) }
            if values.isDirectory == true { return nil }
            guard values.isRegularFile == true else { throw EncryptedSyncError.unsupportedLibraryItem(url.path(percentEncoded: false)) }
            let relative = try relativeLibraryPath(for: url)
            guard isSafeRelativePath(relative) else { throw EncryptedSyncError.unsafeLibraryPath(relative) }
            guard let initialSize = values.fileSize,
                initialSize >= 0,
                initialSize <= Self.maximumLibraryBytes - byteCount
            else {
                throw EncryptedSyncError.libraryTooLarge
            }
            let initialIdentifier = values.fileResourceIdentifier.map { String(describing: $0) }
            let handle = try FileHandle(forReadingFrom: url)
            defer { try? handle.close() }
            let remaining = Self.maximumLibraryBytes - byteCount
            guard remaining >= 0 else { throw EncryptedSyncError.libraryTooLarge }
            let data = try handle.read(upToCount: remaining + 1) ?? Data()
            fileCount += 1
            let (newByteCount, overflow) = byteCount.addingReportingOverflow(data.count)
            guard !overflow, fileCount <= Self.maximumLibraryFiles, newByteCount <= Self.maximumLibraryBytes else {
                throw EncryptedSyncError.libraryTooLarge
            }
            byteCount = newByteCount
            guard data.count == initialSize else { throw EncryptedSyncError.libraryChangedWhileReading(relative) }
            let finalValues = try url.resourceValues(forKeys: [
                .contentModificationDateKey,
                .fileResourceIdentifierKey,
                .fileSizeKey,
                .isRegularFileKey,
                .isSymbolicLinkKey,
            ])
            guard finalValues.isRegularFile == true,
                finalValues.isSymbolicLink != true,
                finalValues.fileSize == initialSize,
                finalValues.contentModificationDate == values.contentModificationDate,
                finalValues.fileResourceIdentifier.map({ String(describing: $0) }) == initialIdentifier
            else {
                throw EncryptedSyncError.libraryChangedWhileReading(relative)
            }
            let attributes = try fileManager.attributesOfItem(atPath: url.path(percentEncoded: false))
            let permissions = (attributes[.posixPermissions] as? NSNumber)?.intValue ?? 0
            return EncryptedLibraryFile(relativePath: relative, data: data, isExecutable: permissions & 0o111 != 0)
        }
        let finalFingerprint = try DirectoryFingerprint.sha256(
            of: store.libraryURL,
            fileManager: fileManager,
            maximumItems: Self.maximumLibraryFiles,
            maximumBytes: Self.maximumLibraryBytes
        )
        guard finalFingerprint == initialFingerprint else {
            throw EncryptedSyncError.libraryChangedWhileReading("managed library")
        }
        return files.sorted { $0.relativePath < $1.relativePath }
    }

    private func relativeLibraryPath(for url: URL) throws -> String {
        // FileManager may return /var while the workspace was created through
        // /private/var, so compare both standardized and symlink-resolved roots.
        let roots = [store.libraryURL.standardizedFileURL, store.libraryURL.standardizedFileURL.resolvingSymlinksInPath()]
        let candidates = [url.standardizedFileURL, url.standardizedFileURL.resolvingSymlinksInPath()]
        for root in roots {
            let rootPath = root.path(percentEncoded: false).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            for candidate in candidates {
                let path = candidate.path(percentEncoded: false).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
                if path.hasPrefix(rootPath + "/") {
                    return String(path.dropFirst(rootPath.count + 1))
                }
            }
        }
        throw EncryptedSyncError.unsafeLibraryPath(url.path(percentEncoded: false))
    }

    private func seal(_ payload: PortableSyncPayload, key: Data) throws -> EncryptedSyncEnvelope {
        let plaintext = try JSONEncoder.agentTooling().encode(payload)
        guard plaintext.count <= Self.maximumArchiveBytes else { throw EncryptedSyncError.archiveTooLarge }
        let sealed = try AES.GCM.seal(plaintext, using: SymmetricKey(data: key))
        guard let combined = sealed.combined else { throw EncryptedSyncError.encryptionFailed }
        return EncryptedSyncEnvelope(version: 1, createdAt: .now, cipherText: combined.base64EncodedString())
    }

    private func open(_ envelope: EncryptedSyncEnvelope, key: Data) throws -> PortableSyncPayload {
        guard envelope.format == "agent-tooling-encrypted-sync",
            envelope.version == 1,
            envelope.createdAt.timeIntervalSinceReferenceDate.isFinite,
            let combined = Data(base64Encoded: envelope.cipherText)
        else { throw EncryptedSyncError.invalidArchive }
        let sealed = try AES.GCM.SealedBox(combined: combined)
        let data = try AES.GCM.open(sealed, using: SymmetricKey(data: key))
        let payload = try JSONDecoder.agentTooling().decode(PortableSyncPayload.self, from: data)
        try validateLibraryFiles(payload.library)
        do {
            try WorkspaceSnapshotValidator.validate(payload.snapshot, mode: .portableImport)
        } catch {
            throw EncryptedSyncError.invalidArchive
        }
        return payload
    }

    private func boundedArchiveData(at archive: URL) throws -> Data {
        let initialValues = try archive.resourceValues(forKeys: [
            .contentModificationDateKey,
            .fileResourceIdentifierKey,
            .fileSizeKey,
            .isRegularFileKey,
            .isSymbolicLinkKey,
        ])
        guard initialValues.isRegularFile == true,
            initialValues.isSymbolicLink != true,
            let initialSize = initialValues.fileSize,
            initialSize >= 0,
            initialSize <= Self.maximumArchiveBytes
        else {
            throw EncryptedSyncError.invalidArchive
        }
        let initialIdentifier = initialValues.fileResourceIdentifier.map { String(describing: $0) }
        let handle = try FileHandle(forReadingFrom: archive)
        defer { try? handle.close() }
        let data = try handle.read(upToCount: Self.maximumArchiveBytes + 1) ?? Data()
        guard data.count <= Self.maximumArchiveBytes, data.count == initialSize else {
            throw EncryptedSyncError.archiveChangedWhileReading
        }
        let finalValues = try archive.resourceValues(forKeys: [
            .contentModificationDateKey,
            .fileResourceIdentifierKey,
            .fileSizeKey,
            .isRegularFileKey,
            .isSymbolicLinkKey,
        ])
        guard finalValues.isRegularFile == true,
            finalValues.isSymbolicLink != true,
            finalValues.fileSize == initialSize,
            finalValues.contentModificationDate == initialValues.contentModificationDate,
            finalValues.fileResourceIdentifier.map({ String(describing: $0) }) == initialIdentifier
        else {
            throw EncryptedSyncError.archiveChangedWhileReading
        }
        return data
    }

    private func isSafeRelativePath(_ path: String) -> Bool {
        let components = path.split(separator: "/", omittingEmptySubsequences: false)
        return !path.isEmpty
            && path.count <= 8_192
            && components.count <= 64
            && !path.hasPrefix("/")
            && !path.hasSuffix("/")
            && !components.contains(where: { $0.isEmpty || $0 == ".." || $0 == "." })
    }

    private func validateLibraryFiles(_ files: [EncryptedLibraryFile]) throws {
        guard files.count <= Self.maximumLibraryFiles else { throw EncryptedSyncError.invalidArchive }
        let paths = files.map(\.relativePath)
        guard Set(paths).count == paths.count,
            paths.allSatisfy(isSafeRelativePath)
        else { throw EncryptedSyncError.invalidArchive }
        let sortedPaths = paths.sorted()
        for pair in zip(sortedPaths, sortedPaths.dropFirst()) where pair.1.hasPrefix(pair.0 + "/") {
            throw EncryptedSyncError.invalidArchive
        }
        var byteCount = 0
        for file in files {
            let (sum, overflow) = byteCount.addingReportingOverflow(file.data.count)
            guard !overflow, sum <= Self.maximumLibraryBytes else { throw EncryptedSyncError.invalidArchive }
            byteCount = sum
        }
    }
}

public struct EncryptedSyncImportPreview: Sendable {
    public var archiveURL: URL
    public var snapshot: WorkspaceSnapshot
    public var libraryFileCount: Int
    public var plan: OperationPlan
}

struct EncryptedLibraryFile: Codable, Hashable, Sendable {
    var relativePath: String
    var data: Data
    /// Optional for archives created before execution metadata was retained.
    /// A missing value restores conservatively as a non-executable file.
    var isExecutable: Bool?

    init(relativePath: String, data: Data, isExecutable: Bool? = nil) {
        self.relativePath = relativePath
        self.data = data
        self.isExecutable = isExecutable
    }
}

private struct PortableSyncPayload: Codable, Sendable {
    var snapshot: WorkspaceSnapshot
    var library: [EncryptedLibraryFile]
}

private struct EncryptedSyncEnvelope: Codable, Sendable {
    var format = "agent-tooling-encrypted-sync"
    var version: Int
    var createdAt: Date
    var cipherText: String
}

public protocol SyncKeyProviding: Sendable {
    func loadKey() throws -> Data
    func loadOrCreateKey() throws -> Data
    func replaceKey(_ key: Data) throws
}

public final class KeychainSyncKeyProvider: SyncKeyProviding, @unchecked Sendable {
    private let service = "com.agenttooling.encrypted-sync"
    private let account = "workspace-key"

    public init() {}

    public func loadKey() throws -> Data {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
            kSecReturnData: true,
            kSecMatchLimit: kSecMatchLimitOne,
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status != errSecItemNotFound else { throw EncryptedSyncError.missingRecoveryKey }
        guard status == errSecSuccess, let data = result as? Data, data.count == 32 else {
            throw EncryptedSyncError.keychain(status)
        }
        return data
    }

    public func loadOrCreateKey() throws -> Data {
        do { return try loadKey() } catch EncryptedSyncError.missingRecoveryKey {}
        let key = SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) }
        try replaceKey(key)
        return key
    }

    public func replaceKey(_ key: Data) throws {
        guard key.count == 32 else { throw EncryptedSyncError.invalidRecoveryKey }
        let lookup: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
        ]
        let attributes: [CFString: Any] = [
            kSecValueData: key,
            kSecAttrAccessible: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
        ]
        let add = lookup.merging(attributes) { _, new in new }
        let status = SecItemAdd(add as CFDictionary, nil)
        if status == errSecDuplicateItem {
            let update = SecItemUpdate(lookup as CFDictionary, attributes as CFDictionary)
            guard update == errSecSuccess else { throw EncryptedSyncError.keychain(update) }
        } else if status != errSecSuccess {
            throw EncryptedSyncError.keychain(status)
        }
    }
}

struct FixedSyncKeyProvider: SyncKeyProviding, Sendable {
    let key: Data
    init(key: Data = Data(repeating: 7, count: 32)) { self.key = key }
    func loadKey() throws -> Data { key }
    func loadOrCreateKey() throws -> Data { key }
    func replaceKey(_: Data) throws {}
}

enum EncryptedSyncError: LocalizedError, Sendable {
    case missingDestination(String)
    case invalidArchiveName(String)
    case invalidArchive
    case encryptionFailed
    case unsafeLibraryPath(String)
    case invalidRecoveryKey
    case missingRecoveryKey
    case keychain(OSStatus)
    case archiveTooLarge
    case libraryTooLarge
    case unsupportedLibraryItem(String)
    case archiveChangedWhileReading
    case libraryChangedWhileReading(String)

    var errorDescription: String? {
        switch self {
        case .missingDestination(let path): "The selected encrypted sync folder is unavailable: \(path)"
        case .invalidArchiveName(let name): "Select \(EncryptedSyncService.archiveFileName), not \(name)."
        case .invalidArchive: "The encrypted sync archive is invalid or cannot be decrypted with the current recovery key."
        case .encryptionFailed: "Agent Tooling could not create the encrypted archive."
        case .unsafeLibraryPath(let path): "The archive contains an unsafe library path: \(path)"
        case .invalidRecoveryKey: "The recovery key must be a 32-byte Base64 value."
        case .missingRecoveryKey: "This Mac does not have the recovery key for the encrypted sync archive. Import the key before restoring."
        case .keychain(let status): "The macOS Keychain could not access the encrypted sync key (status \(status))."
        case .archiveTooLarge: "The encrypted sync archive exceeds the supported size limit."
        case .libraryTooLarge: "The managed library contains too many files or is too large to sync safely."
        case .unsupportedLibraryItem(let path):
            "The managed library contains a symbolic link or unsupported file that cannot be synchronized safely: \(path)"
        case .archiveChangedWhileReading: "The encrypted sync archive changed while it was being inspected. Choose it again and retry."
        case .libraryChangedWhileReading(let path):
            "The managed library file \(path) changed while the archive was being prepared. Retry after local edits finish."
        }
    }
}
