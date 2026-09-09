import Foundation

public enum WorkspaceLinkedPresetStoreError: Error, Equatable, Sendable {
    case invalidRoot
    case unsupportedFormat
    case unreadable
    case tooManySubscriptions
}

/// Which presets this Mac follows, and where it places their members.
///
/// Device-local on purpose. What a preset contains is shared, and so is the
/// result of following one — the assignments it contributes are ordinary
/// portable intent that syncs like anything else. The standing decision to keep
/// following it is this Mac's own, so linking on one Mac does not silently make
/// another Mac start changing itself whenever the preset's author edits it.
public struct WorkspaceLinkedPresetStore: Sendable {
    public static let formatVersion = 1
    /// A ceiling, so a corrupted or hostile file cannot make startup unbounded.
    public static let maximumSubscriptions = 256

    private let file: URL

    public init(containerRoot: URL) throws {
        guard containerRoot.isFileURL, containerRoot.path.hasPrefix("/"),
              !containerRoot.path.contains("\0"),
              containerRoot.standardizedFileURL.path == containerRoot.path else {
            throw WorkspaceLinkedPresetStoreError.invalidRoot
        }
        file = containerRoot.appending(path: "linked-presets.json")
    }

    /// A file this build cannot read is an error, never silently treated as
    /// "nothing is linked" — that would look like the person unlinked
    /// everything, and the next catch-up would remove real assignments.
    public func read() throws -> [LinkedPresetSubscription] {
        guard FileManager.default.fileExists(atPath: file.path) else { return [] }
        let bytes: Data
        do { bytes = try Data(contentsOf: file, options: [.mappedIfSafe]) }
        catch { throw WorkspaceLinkedPresetStoreError.unreadable }
        guard bytes.count <= 1_024_000 else { throw WorkspaceLinkedPresetStoreError.unsupportedFormat }
        let record: Record
        do { record = try AgentToolingCoding.decoder().decode(Record.self, from: bytes) }
        catch { throw WorkspaceLinkedPresetStoreError.unsupportedFormat }
        guard record.formatVersion == Self.formatVersion else {
            throw WorkspaceLinkedPresetStoreError.unsupportedFormat
        }
        guard record.subscriptions.count <= Self.maximumSubscriptions else {
            throw WorkspaceLinkedPresetStoreError.tooManySubscriptions
        }
        // One subscription per preset. Two would each think they own the same
        // contributions and would take turns undoing each other.
        guard Set(record.subscriptions.map(\.presetID)).count == record.subscriptions.count else {
            throw WorkspaceLinkedPresetStoreError.unsupportedFormat
        }
        return record.subscriptions.sorted { $0.presetID.rawValue.uuidString < $1.presetID.rawValue.uuidString }
    }

    public func write(_ subscriptions: [LinkedPresetSubscription]) throws {
        guard subscriptions.count <= Self.maximumSubscriptions else {
            throw WorkspaceLinkedPresetStoreError.tooManySubscriptions
        }
        guard Set(subscriptions.map(\.presetID)).count == subscriptions.count else {
            throw WorkspaceLinkedPresetStoreError.unsupportedFormat
        }
        let record = Record(formatVersion: Self.formatVersion, subscriptions: subscriptions)
        let bytes = try AgentToolingCoding.encoder().encode(record)
        do { try bytes.write(to: file, options: .atomic) }
        catch { throw WorkspaceLinkedPresetStoreError.unreadable }
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    }

    private struct Record: Codable {
        let formatVersion: Int
        let subscriptions: [LinkedPresetSubscription]
    }
}
