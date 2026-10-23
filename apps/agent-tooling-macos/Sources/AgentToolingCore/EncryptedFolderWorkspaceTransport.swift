import CryptoKit
import Foundation

public enum EncryptedFolderTransportError: Error, Equatable, Sendable {
    case invalidFolder
    case invalidDocument
    case documentTooLarge
    case unsupportedFormat
    /// The folder holds something this key does not open. A wrong key is not a
    /// reason to overwrite what is there.
    case cannotDecrypt
    case writeFailed
    /// Something else published while this device was preparing. Merge and
    /// publish again; this transport never overwrites a head it did not expect.
    case remoteAdvanced(remoteHead: String)
}

/// Publishes encrypted workspace revisions through an existing sync folder.
/// Only the format version and salt are plaintext. The device key is stored
/// beside the database, so encryption protects against the sync service, not
/// another process able to read the user's files.
/// Content-digest compare-and-set prevents concurrent writes from overwriting
/// each other; conflicts require a merge.
public actor EncryptedFolderWorkspaceTransport {
    public static let documentFileName = "workspace.sealed"
    public static let formatVersion = 2
    private static let documentLimit = ((WorkspaceRevisionArchive.maximumBytes + 30) / 3) * 4 + 1024

    private let folder: URL
    private let key: SymmetricKey

    /// `folder` must exist. It is not created here: a person points this at a
    /// folder their sync service already knows about, and quietly creating one
    /// somewhere unexpected would be the wrong answer to a mistyped path.
    public init(folder: URL, key: SymmetricKey) throws {
        guard folder.isFileURL, folder.path.hasPrefix("/"), !folder.path.contains("\0"),
            folder.standardizedFileURL.path == folder.path,
            (try? folder.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
        else {
            throw EncryptedFolderTransportError.invalidFolder
        }
        self.folder = folder
        self.key = key
    }

    private var file: URL { folder.appending(path: Self.documentFileName) }

    /// What the folder holds now, and the head that names it.
    ///
    /// The head is the digest of the sealed bytes, so it changes whenever
    /// anything is published and is the same on every Mac that reads the folder.
    public func remoteState() async throws -> GitWorkspaceRemoteState {
        guard FileManager.default.fileExists(atPath: file.path) else {
            return .init(head: nil, document: nil)
        }
        let bytes: Data
        do { bytes = try Data(contentsOf: file, options: [.mappedIfSafe]) } catch { throw EncryptedFolderTransportError.unsupportedFormat }
        guard bytes.count <= Self.documentLimit else {
            throw EncryptedFolderTransportError.documentTooLarge
        }
        let head = Self.digest(bytes)
        let envelope: Envelope
        do { envelope = try AgentToolingCoding.decoder().decode(Envelope.self, from: bytes) } catch {
            throw EncryptedFolderTransportError.unsupportedFormat
        }
        guard envelope.formatVersion == 1 || envelope.formatVersion == Self.formatVersion else {
            throw EncryptedFolderTransportError.unsupportedFormat
        }
        let plain: Data
        do {
            let box = try AES.GCM.SealedBox(combined: envelope.sealed)
            plain = try AES.GCM.open(box, using: key)
        } catch {
            // Wrong key, or someone changed the bytes. Either way this is not
            // a folder to publish over: the head is reported so the caller can
            // say what it found rather than replacing it.
            throw EncryptedFolderTransportError.cannotDecrypt
        }
        if envelope.formatVersion == 1 { return .init(head: head, document: try Self.decode(plain)) }
        let archive = try WorkspaceRevisionArchive.decode(plain)
        return .init(head: head, document: archive.document, ancestors: archive.ancestors)
    }

    /// Seals the document and writes it, but only if the folder still holds
    /// exactly what the caller last saw.
    public func publish(
        document: PortableWorkspaceDocument,
        ancestors: [PortableWorkspaceDocument] = [],
        expectedRemoteHead: String?
    ) async throws -> GitWorkspacePublishReceipt {
        let remote = try await remoteState()
        let observed = remote.head
        guard observed == expectedRemoteHead else {
            throw EncryptedFolderTransportError.remoteAdvanced(remoteHead: observed ?? "")
        }
        let plain = try WorkspaceRevisionArchive(
            document: document, ancestors: ancestors + remote.ancestors + [remote.document].compactMap { $0 }
        ).encoded()
        let sealed: Data
        do {
            guard let combined = try AES.GCM.seal(plain, using: key).combined else {
                throw EncryptedFolderTransportError.writeFailed
            }
            sealed = combined
        } catch { throw EncryptedFolderTransportError.writeFailed }
        let bytes = try AgentToolingCoding.encoder().encode(
            Envelope(formatVersion: Self.formatVersion, sealed: sealed))

        // Written through a temporary file in the same folder and moved into
        // place, so a sync service never picks up a half-written box.
        let temporary = folder.appending(path: Self.documentFileName + ".\(UUID().uuidString).partial")
        do {
            try bytes.write(to: temporary, options: .atomic)
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: temporary.path)
        } catch { throw EncryptedFolderTransportError.writeFailed }
        // One last look before replacing: a Mac that published between the read
        // above and this moment must not be overwritten.
        guard try Self.currentHead(of: file) == expectedRemoteHead else {
            try? FileManager.default.removeItem(at: temporary)
            throw EncryptedFolderTransportError.remoteAdvanced(
                remoteHead: try Self.currentHead(of: file) ?? "")
        }
        do { _ = try FileManager.default.replaceItemAt(file, withItemAt: temporary) } catch {
            try? FileManager.default.removeItem(at: temporary)
            throw EncryptedFolderTransportError.writeFailed
        }
        return .init(
            commit: Self.digest(bytes), previousHead: observed,
            revisionID: document.revision.id)
    }

    private static func currentHead(of file: URL) throws -> String? {
        guard FileManager.default.fileExists(atPath: file.path) else { return nil }
        let bytes: Data
        do { bytes = try Data(contentsOf: file, options: [.mappedIfSafe]) } catch { throw EncryptedFolderTransportError.unsupportedFormat }
        guard bytes.count <= documentLimit else { throw EncryptedFolderTransportError.documentTooLarge }
        return digest(bytes)
    }

    private static func digest(_ bytes: Data) -> String {
        SHA256.hash(data: bytes).lowercaseHex
    }

    private static func decode(_ bytes: Data) throws -> PortableWorkspaceDocument {
        let document: PortableWorkspaceDocument
        do { document = try WorkspaceDocumentCoding.decode(bytes) } catch { throw EncryptedFolderTransportError.invalidDocument }
        do { try document.validateStructure() } catch { throw EncryptedFolderTransportError.invalidDocument }
        return document
    }

    private struct Envelope: Codable {
        let formatVersion: Int
        let sealed: Data
    }
}

extension EncryptedFolderWorkspaceTransport: WorkspaceRevisionTransport {
    /// The sealed box holds the document and its ancestry. Content and status do not
    /// travel this way; the caller sees `carriesContent == false` and keeps
    /// them local.
    public nonisolated var carriesContent: Bool { false }

    public func publish(
        document: PortableWorkspaceDocument,
        ancestors: [PortableWorkspaceDocument],
        content: [CapturedPackageTree],
        status: PublishedDeviceStatus?,
        expectedRemoteHead: String?
    ) async throws -> GitWorkspacePublishReceipt {
        try await publish(document: document, ancestors: ancestors, expectedRemoteHead: expectedRemoteHead)
    }

    public func content(for digest: ContentDigest) async throws -> CapturedPackageTree? { nil }
}
