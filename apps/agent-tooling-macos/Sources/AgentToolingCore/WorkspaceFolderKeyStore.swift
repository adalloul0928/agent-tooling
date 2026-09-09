import CryptoKit
import Foundation

public enum WorkspaceFolderKeyError: Error, Equatable, Sendable {
    case invalidRoot
    case unreadable
    case unsupportedFormat
    case invalidRecoveryPhrase
}

/// The key that opens an encrypted sync folder, and the phrase that carries it
/// to another Mac.
///
/// The key is random, not derived from anything a person typed: a passphrase
/// people would actually remember is a poor key, and this build has no password
/// hashing worth trusting for one. Setting up a second Mac means moving the key
/// itself, shown once as a recovery phrase.
///
/// It is stored beside the workspace database, readable only by the account
/// that owns it. That is what makes this "the sync service cannot read your
/// library", not "nobody with your Mac can". The distinction is the whole
/// security claim and the app states it rather than implying more.
public struct WorkspaceFolderKeyStore: Sendable {
    public static let formatVersion = 1
    /// Crockford's base32: the ten digits and the letters except i, l, o and
    /// u. Thirty-two symbols exactly, which is what base32 needs.
    static let alphabet = Array("0123456789abcdefghjkmnpqrstvwxyz")

    private let file: URL

    public init(containerRoot: URL) throws {
        guard containerRoot.isFileURL, containerRoot.path.hasPrefix("/"),
              !containerRoot.path.contains("\0"),
              containerRoot.standardizedFileURL.path == containerRoot.path else {
            throw WorkspaceFolderKeyError.invalidRoot
        }
        file = containerRoot.appending(path: "folder-sync-key.json")
    }

    /// The stored key, or `nil` when this Mac has none. A file this build
    /// cannot read is an error: treating it as "no key" would offer to make a
    /// new one and leave the folder unreadable by everything already in it.
    public func read() throws -> SymmetricKey? {
        guard FileManager.default.fileExists(atPath: file.path) else { return nil }
        let bytes: Data
        do { bytes = try Data(contentsOf: file, options: [.mappedIfSafe]) }
        catch { throw WorkspaceFolderKeyError.unreadable }
        guard bytes.count <= 8_192 else { throw WorkspaceFolderKeyError.unsupportedFormat }
        let record: Record
        do { record = try AgentToolingCoding.decoder().decode(Record.self, from: bytes) }
        catch { throw WorkspaceFolderKeyError.unsupportedFormat }
        guard record.formatVersion == Self.formatVersion, record.key.count == 32 else {
            throw WorkspaceFolderKeyError.unsupportedFormat
        }
        return SymmetricKey(data: record.key)
    }

    public func write(_ key: SymmetricKey) throws {
        let record = Record(formatVersion: Self.formatVersion,
                            key: key.withUnsafeBytes { Data($0) })
        let bytes = try AgentToolingCoding.encoder().encode(record)
        do { try bytes.write(to: file, options: .atomic) }
        catch { throw WorkspaceFolderKeyError.unreadable }
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    }

    /// Forgets the key on this Mac. Whatever is in the folder stays sealed, and
    /// stays readable by any Mac that still holds the phrase.
    public func remove() throws {
        guard FileManager.default.fileExists(atPath: file.path) else { return }
        do { try FileManager.default.removeItem(at: file) }
        catch { throw WorkspaceFolderKeyError.unreadable }
    }

    public static func generate() -> SymmetricKey { SymmetricKey(size: .bits256) }

    /// The key as something a person can read off one screen and type into
    /// another, in groups of five.
    public static func recoveryPhrase(for key: SymmetricKey) -> String {
        let bytes = key.withUnsafeBytes { Array($0) }
        var value = 0
        var bits = 0
        var characters: [Character] = []
        for byte in bytes {
            value = (value << 8) | Int(byte)
            bits += 8
            while bits >= 5 {
                bits -= 5
                characters.append(alphabet[(value >> bits) & 31])
            }
        }
        if bits > 0 { characters.append(alphabet[(value << (5 - bits)) & 31]) }
        return stride(from: 0, to: characters.count, by: 5)
            .map { String(characters[$0..<min($0 + 5, characters.count)]) }
            .joined(separator: "-")
    }

    /// Reads a phrase back.
    ///
    /// Spacing, dashes and letter case are ignored, and the letters that look
    /// like digits are read as the digits they look like — someone copying this
    /// off another screen should not be defeated by punctuation or by the shape
    /// of a character.
    public static func key(fromRecoveryPhrase phrase: String) throws -> SymmetricKey {
        let cleaned = phrase.lowercased()
            .map { character -> Character in
                switch character {
                case "o": "0"
                case "i", "l": "1"
                default: character
                }
            }
            .filter { alphabet.contains($0) }
        guard cleaned.count == 52 else { throw WorkspaceFolderKeyError.invalidRecoveryPhrase }
        var value = 0
        var bits = 0
        var bytes: [UInt8] = []
        for character in cleaned {
            guard let index = alphabet.firstIndex(of: character) else {
                throw WorkspaceFolderKeyError.invalidRecoveryPhrase
            }
            value = (value << 5) | index
            bits += 5
            if bits >= 8 {
                bits -= 8
                bytes.append(UInt8((value >> bits) & 0xFF))
            }
        }
        guard bytes.count == 32 else { throw WorkspaceFolderKeyError.invalidRecoveryPhrase }
        return SymmetricKey(data: Data(bytes))
    }

    private struct Record: Codable {
        let formatVersion: Int
        let key: Data
    }
}
