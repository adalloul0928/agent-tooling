import CryptoKit
import Foundation

public enum ConfigurationEditError: Error, Equatable, Sendable {
    case unsupportedSetting
    case constrainedByHigherLayer
    case layerNotWritable
    case missingSourcePath
    case fileChangedSinceReview(currentFingerprint: String?)
    case unsupportedFormat
    case writeFailed
    case backupFailed
    case valueRejected
    /// The file was written, but re-reading it does not show the intended
    /// value. Nothing further is attempted.
    case notEffectiveAfterWrite
}

/// One reviewed change to one setting in one file.
public struct ConfigurationEdit: Hashable, Sendable {
    public let key: String
    public let layer: ConfigurationLayerKind
    public let sourcePath: String
    public let newValue: ConfigurationValue
    /// The file's content as it was when the person reviewed it. A file that
    /// moved on since then is never overwritten.
    public let expectedFingerprint: String?

    public init(
        key: String,
        layer: ConfigurationLayerKind,
        sourcePath: String,
        newValue: ConfigurationValue,
        expectedFingerprint: String?
    ) {
        self.key = key
        self.layer = layer
        self.sourcePath = sourcePath
        self.newValue = newValue
        self.expectedFingerprint = expectedFingerprint
    }
}

public struct ConfigurationEditReceipt: Hashable, Sendable {
    public let key: String
    public let sourcePath: String
    public let backupPath: String
    public let previousFingerprint: String
    public let newFingerprint: String
    /// What the client will now use, re-read after the write.
    public let effectiveValue: ConfigurationValue
}

/// Writes one setting into one native file, and verifies afterwards that the
/// change actually won.
///
/// Everything else in the file survives: unknown keys, key order and formatting
/// choices this build does not understand are preserved, because those are the
/// person's, not ours. A file that changed since it was reviewed is never
/// overwritten. A backup is written first, and the file is re-read and resolved
/// again afterwards — a write that does not produce the intended effective
/// value is reported rather than being called success.
///
/// Only JSON layers are supported. Codex's TOML keeps comments and formatting
/// this build cannot reproduce faithfully, so editing it here would risk
/// rewriting someone's file to satisfy a parser.
public struct ConfigurationEditor: Sendable {
    public static let maximumFileBytes = 1 << 20

    public init() {}

    /// Checks a proposed change against what the inspector currently reports.
    public func validate(
        _ edit: ConfigurationEdit,
        against configuration: EffectiveConfiguration
    ) throws {
        guard let row = configuration.rows.first(where: { $0.key == edit.key }) else {
            throw ConfigurationEditError.unsupportedSetting
        }
        guard let writable = row.writableLayer else { throw ConfigurationEditError.constrainedByHigherLayer }
        guard writable == edit.layer else { throw ConfigurationEditError.layerNotWritable }
        guard row.contributions.contains(where: { $0.layer == edit.layer }) || !edit.sourcePath.isEmpty else {
            throw ConfigurationEditError.missingSourcePath
        }
    }

    /// The file's current content fingerprint, for review and for the write's
    /// own precondition.
    public func fingerprint(of path: String) throws -> String? {
        guard FileManager.default.fileExists(atPath: path) else { return nil }
        let bytes = try read(path)
        return SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
    }

    public func apply(
        _ edit: ConfigurationEdit,
        adapter: some ConfigurationAdapter,
        installedClientVersion: String?
    ) throws -> ConfigurationEditReceipt {
        let current = try fingerprint(of: edit.sourcePath)
        guard current == edit.expectedFingerprint else {
            throw ConfigurationEditError.fileChangedSinceReview(currentFingerprint: current)
        }
        let original = FileManager.default.fileExists(atPath: edit.sourcePath)
            ? try read(edit.sourcePath) : Data("{}".utf8)
        guard var object = try? JSONSerialization.jsonObject(with: original) as? [String: Any] else {
            throw ConfigurationEditError.unsupportedFormat
        }
        try Self.set(edit.key, to: edit.newValue, in: &object)

        // A backup before the write, so the person's own file is recoverable
        // whatever happens next.
        let backupPath = edit.sourcePath + ".agent-tooling-backup"
        do { try original.write(to: URL(fileURLWithPath: backupPath), options: .atomic) }
        catch { throw ConfigurationEditError.backupFailed }

        let updated: Data
        do {
            updated = try JSONSerialization.data(
                withJSONObject: object, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        } catch { throw ConfigurationEditError.valueRejected }
        do { try updated.write(to: URL(fileURLWithPath: edit.sourcePath), options: .atomic) }
        catch { throw ConfigurationEditError.writeFailed }

        // Re-read and resolve again: the write is only a success if the client
        // would now actually use this value.
        let reader = ConfigurationLayerReader()
        let layer = try reader.layer(at: URL(fileURLWithPath: edit.sourcePath),
                                     kind: edit.layer, isWritable: true)
        let resolved = EffectiveConfigurationResolver.resolve(
            adapter: adapter, installedClientVersion: installedClientVersion,
            layers: layer.map { [$0] } ?? [])
        guard let row = resolved.rows.first(where: { $0.key == edit.key }),
              row.value == edit.newValue else {
            throw ConfigurationEditError.notEffectiveAfterWrite
        }
        guard let newFingerprint = try fingerprint(of: edit.sourcePath),
              let previous = try fingerprint(of: backupPath) else {
            throw ConfigurationEditError.writeFailed
        }
        return .init(key: edit.key, sourcePath: edit.sourcePath, backupPath: backupPath,
                     previousFingerprint: previous, newFingerprint: newFingerprint,
                     effectiveValue: row.value)
    }
}

extension ConfigurationLayerReader {
    /// Reads one already-identified file as a layer of a known kind.
    func layer(at url: URL, kind: ConfigurationLayerKind, isWritable: Bool) throws -> ConfigurationLayer? {
        try jsonLayer(at: url, kind: kind, isWritable: isWritable)
    }
}

private extension ConfigurationEditor {
    func read(_ path: String) throws -> Data {
        let bytes: Data
        do { bytes = try Data(contentsOf: URL(fileURLWithPath: path), options: [.mappedIfSafe]) }
        catch { throw ConfigurationEditError.writeFailed }
        guard bytes.count <= Self.maximumFileBytes else { throw ConfigurationEditError.unsupportedFormat }
        return bytes
    }

    /// Sets one key, including the documented `permissions.*` nesting, leaving
    /// every other key and every value this build does not interpret untouched.
    static func set(_ key: String, to value: ConfigurationValue, in object: inout [String: Any]) throws {
        let encoded = try json(value)
        let parts = key.split(separator: ".", maxSplits: 1)
        guard parts.count == 2 else {
            object[key] = encoded
            return
        }
        let parent = String(parts[0])
        let child = String(parts[1])
        var nested = object[parent] as? [String: Any] ?? [:]
        nested[child] = encoded
        object[parent] = nested
    }

    static func json(_ value: ConfigurationValue) throws -> Any {
        switch value {
        case .string(let text): text
        case .number(let number): number
        case .boolean(let flag): flag
        case .list(let values): try values.map { try json($0) }
        // An opaque value is something this build read but never understood;
        // writing it back would be inventing content.
        case .opaque: throw ConfigurationEditError.valueRejected
        }
    }
}
