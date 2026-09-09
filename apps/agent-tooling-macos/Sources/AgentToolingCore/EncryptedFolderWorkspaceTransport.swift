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

/// Carries portable workspace revisions through a folder, encrypted.
///
/// The folder is meant to be one a file-sync service already keeps in step —
/// iCloud Drive, Dropbox, a network share. What lands there is a sealed box and
/// a small plaintext header holding the format version and the salt; the
/// document itself, including every name in the person's library, is never
/// written in the clear. The service moving the folder cannot read it.
///
/// What this is not: it is not protection from someone who can read this Mac.
/// The key lives in a file beside the workspace database, readable by the
/// account that owns it — see `WorkspaceFolderKeyStore`. The threat it answers
/// is the sync service and anyone else who can see the folder's contents, which
/// is exactly the threat a plain shared folder has and a private Git repository
/// mostly does not.
///
/// Publishing is compare-and-set on a content digest of what is there, so two
/// Macs writing at once produce a refusal and a merge rather than one silently
/// winning.
public actor EncryptedFolderWorkspaceTransport {
    public static let documentFileName = "workspace.sealed"
    public static let formatVersion = 1
    private static let documentLimit = 32 << 20

    private let folder: URL
    private let key: SymmetricKey

    /// `folder` must exist. It is not created here: a person points this at a
    /// folder their sync service already knows about, and quietly creating one
    /// somewhere unexpected would be the wrong answer to a mistyped path.
    public init(folder: URL, key: SymmetricKey) throws {
        guard folder.isFileURL, folder.path.hasPrefix("/"), !folder.path.contains("\0"),
              folder.standardizedFileURL.path == folder.path,
              (try? folder.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true else {
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
        do { bytes = try Data(contentsOf: file, options: [.mappedIfSafe]) }
        catch { throw EncryptedFolderTransportError.unsupportedFormat }
        guard bytes.count <= Self.documentLimit else {
            throw EncryptedFolderTransportError.documentTooLarge
        }
        let head = Self.digest(bytes)
        let envelope: Envelope
        do { envelope = try AgentToolingCoding.decoder().decode(Envelope.self, from: bytes) }
        catch { throw EncryptedFolderTransportError.unsupportedFormat }
        guard envelope.formatVersion == Self.formatVersion else {
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
        return .init(head: head, document: try Self.decode(plain))
    }

    /// Seals the document and writes it, but only if the folder still holds
    /// exactly what the caller last saw.
    public func publish(
        document: PortableWorkspaceDocument,
        expectedRemoteHead: String?
    ) async throws -> GitWorkspacePublishReceipt {
        let observed = try Self.currentHead(of: file)
        guard observed == expectedRemoteHead else {
            throw EncryptedFolderTransportError.remoteAdvanced(remoteHead: observed ?? "")
        }
        let plain = try Self.encode(document)
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
        let temporary = folder.appending(path: Self.documentFileName + ".partial")
        do {
            try bytes.write(to: temporary, options: .atomic)
            try? FileManager.default.setAttributes([.posixPermissions: 0o600],
                                                   ofItemAtPath: temporary.path)
        } catch { throw EncryptedFolderTransportError.writeFailed }
        // One last look before replacing: a Mac that published between the read
        // above and this moment must not be overwritten.
        guard try Self.currentHead(of: file) == expectedRemoteHead else {
            try? FileManager.default.removeItem(at: temporary)
            throw EncryptedFolderTransportError.remoteAdvanced(
                remoteHead: try Self.currentHead(of: file) ?? "")
        }
        do { _ = try FileManager.default.replaceItemAt(file, withItemAt: temporary) }
        catch {
            try? FileManager.default.removeItem(at: temporary)
            throw EncryptedFolderTransportError.writeFailed
        }
        return .init(commit: Self.digest(bytes), previousHead: observed,
                     revisionID: document.revision.id)
    }

    private static func currentHead(of file: URL) throws -> String? {
        guard FileManager.default.fileExists(atPath: file.path) else { return nil }
        let bytes: Data
        do { bytes = try Data(contentsOf: file, options: [.mappedIfSafe]) }
        catch { throw EncryptedFolderTransportError.unsupportedFormat }
        guard bytes.count <= documentLimit else { throw EncryptedFolderTransportError.documentTooLarge }
        return digest(bytes)
    }

    private static func digest(_ bytes: Data) -> String {
        SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
    }

    private static func encode(_ document: PortableWorkspaceDocument) throws -> Data {
        try document.validateStructure()
        let bytes = try WorkspaceDocumentCoding.encode(document)
        guard bytes.count <= documentLimit else {
            throw EncryptedFolderTransportError.documentTooLarge
        }
        return bytes
    }

    private static func decode(_ bytes: Data) throws -> PortableWorkspaceDocument {
        let document: PortableWorkspaceDocument
        do { document = try WorkspaceDocumentCoding.decode(bytes) }
        catch { throw EncryptedFolderTransportError.invalidDocument }
        do { try document.validateStructure() }
        catch { throw EncryptedFolderTransportError.invalidDocument }
        return document
    }

    private struct Envelope: Codable {
        let formatVersion: Int
        let sealed: Data
    }
}

extension EncryptedFolderWorkspaceTransport: WorkspaceRevisionTransport {}
